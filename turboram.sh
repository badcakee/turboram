#!/usr/bin/env bash
# ram.sh - "download more RAM" for Linux
#
# What it really does:
#   1. Asks how much RAM you want, then makes a swapfile on your disk to cover
#      the difference. If your disk doesn't have room, it tells you the max.
#   2. Turns on zswap: a compressed cache in real RAM that sits in front of the
#      swapfile, so recently swapped stuff comes back fast. (Your SSD's own
#      cache lives inside the drive; the OS can't use it as memory.)
#   3. Disguises swap as RAM: a small service keeps a live copy of
#      /proc/meminfo with swap folded into the RAM numbers and the swap
#      numbers zeroed, and mounts it over the real one. fastfetch, neofetch,
#      htop, free, etc. all read that file, so they show it as RAM.
#   4. Removes the Swap line from fastfetch and the Swp bar from htop.
#   (It also runs apt update first, on Debian/Ubuntu-based systems.)
#
# The extra "RAM" is still disk, so it's much slower than real RAM. It keeps
# apps from crashing when you run out; it won't make anything faster.
#
# Usage:
#   sudo ./ram.sh          ask how much RAM you want and set it up (run again to resize)
#   ram.sh status          show the REAL numbers behind the disguise
#   sudo ram.sh remove     undo everything

set -euo pipefail
export LC_ALL=C

# when piped from curl, save to a real file and re-run from there with the keyboard attached
if [[ ! -f ${BASH_SOURCE[0]:-} ]]; then
  tmp=$(mktemp /tmp/turboram.XXXXXX.sh)
  curl -fsSL https://raw.githubusercontent.com/badcakee/turboram/main/turboram.sh -o "$tmp"
  exec sudo bash "$tmp" "$@" </dev/tty
fi

# what the script calls the extra RAM when it talks to you (change it if you want)
BRAND=TurboRAM

SWAPDIR=/ramsh
SWAPFILE=$SWAPDIR/swapfile
STATE=/run/ram-sh
FAKE=$STATE/meminfo
REALPROC=$STATE/proc
LIB=/var/lib/ram-sh
BIN=/usr/local/sbin/ram.sh
UNIT=/etc/systemd/system/ram-sh.service
ZSWAP=/sys/module/zswap/parameters

SELF=$(readlink -f "${BASH_SOURCE[0]}")

if [[ -t 1 ]]; then B=$'\e[1m' R=$'\e[31m' G=$'\e[32m' Y=$'\e[33m' N=$'\e[0m'; else B= R= G= Y= N=; fi
say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "${Y}$*${N}" >&2; }
die()  { printf '%s\n' "${R}$*${N}" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || exec sudo bash "$SELF" "$@"; }

# MiB -> "12.5 GB" / "512 MB"
human() { awk -v m="$1" 'BEGIN { if (m >= 1024) printf "%.1f GB", m / 1024; else printf "%d MB", m }'; }

# "16", "16g", "16 GB", "1.5T", "512M" -> MiB. A plain number means GB.
parse_size() {
  local s=${1,,}
  s=${s//[[:space:]]/}
  [[ $s =~ ^([0-9]+([.][0-9]+)?)(g|gb|gib|m|mb|mib|t|tb|tib)?$ ]] || return 1
  local mult=1024
  case ${BASH_REMATCH[3]} in m*) mult=1 ;; t*) mult=1048576 ;; esac
  awk -v n="${BASH_REMATCH[1]}" -v m="$mult" 'BEGIN { printf "%d", n * m }'
}

# one field (in kB) from a meminfo file
mem_kb() { awk -v k="$1:" '$1 == k { print $2; f = 1; exit } END { if (!f) print 0 }' "${2:-/proc/meminfo}"; }

# swap that isn't ours (zram, distro swap partition, ...), in kB
other_swap_kb() { awk -v me="$SWAPFILE" 'NR > 1 && $1 != me { s += $3 } END { print s + 0 }' /proc/swaps; }
ours_active()   { awk -v me="$SWAPFILE" '$1 == me { f = 1 } END { exit !f }' /proc/swaps; }

disk_type() {
  local src rota
  src=$(findmnt -no SOURCE -T /)
  src=${src%%\[*}   # btrfs shows /dev/sda2[/@]
  rota=$(lsblk -dno ROTA "$src" 2>/dev/null | head -n 1 | tr -d '[:space:]') || true
  case $rota in 0) echo SSD ;; 1) echo HDD ;; *) echo "unknown type" ;; esac
}

# ---------------------------------------------------------------- disguise --

# /proc/meminfo with swap folded into the RAM lines and the swap lines zeroed
fake_meminfo() {
  awk '
    { k = $1; sub(/:$/, "", k); key[NR] = k; val[k] = $2; line[NR] = $0 }
    END {
      fix["MemTotal"] = val["MemTotal"] + val["SwapTotal"]
      fix["MemFree"]  = val["MemFree"]  + val["SwapFree"]
      if ("MemAvailable" in val) fix["MemAvailable"] = val["MemAvailable"] + val["SwapFree"]
      fix["SwapTotal"] = fix["SwapFree"] = fix["SwapCached"] = fix["Zswap"] = fix["Zswapped"] = 0
      for (i = 1; i <= NR; i++)
        if (key[i] in fix) printf "%-16s%8.0f kB\n", (key[i] ":"), fix[key[i]]
        else print line[i]
    }' "$REALPROC/meminfo"
}

enable_zswap() {
  [[ -w $ZSWAP/enabled ]] || return 0
  # zram already compresses in RAM, zswap on top of it is pointless
  if grep -q '^/dev/zram' /proc/swaps; then return 0; fi
  mkdir -p "$LIB"
  [[ -e $LIB/zswap-before ]] || cat "$ZSWAP/enabled" > "$LIB/zswap-before"
  { echo zstd > "$ZSWAP/compressor" || echo lz4 > "$ZSWAP/compressor"; } 2>/dev/null || true
  echo Y > "$ZSWAP/enabled" 2>/dev/null || true
}

undisguise() {
  while findmnt -rn -M /proc/meminfo >/dev/null 2>&1; do
    umount /proc/meminfo 2>/dev/null || umount -l /proc/meminfo || break
  done
  if findmnt -rn -M "$REALPROC" >/dev/null 2>&1; then umount -l "$REALPROC" || true; fi
}

# runs forever (as the systemd service), refreshing the fake file every second
run_daemon() {
  mkdir -p "$STATE" "$REALPROC"
  undisguise
  # a second, untouched view of /proc so we can keep reading the real numbers
  mount -t proc proc "$REALPROC"
  mount --make-private "$REALPROC"
  enable_zswap

  local data last
  data=$(fake_meminfo)$'\n'
  printf '%s' "$data" > "$FAKE"
  chmod 444 "$FAKE"
  # on SELinux systems give the fake file the same label as the real one
  if [[ -e /sys/fs/selinux/enforce ]] && command -v chcon >/dev/null; then
    chcon --reference=/proc/meminfo "$FAKE" 2>/dev/null || true
  fi
  mount --bind "$FAKE" /proc/meminfo
  echo $$ > "$STATE/pid"
  trap 'undisguise; rm -f "$STATE/pid"; exit 0' TERM INT

  last=${#data}
  while :; do
    sleep 1 & wait $!
    data=$(fake_meminfo) || continue
    data+=$'\n'
    # overwrite in place (no truncate first) so readers never see an empty file
    printf '%s' "$data" 1<>"$FAKE"
    if (( ${#data} < last )); then truncate -s "${#data}" "$FAKE"; fi
    last=${#data}
  done
}

start_bg() {
  [[ -x $BIN ]] || die "Run 'sudo ./ram.sh' first."
  nohup "$BIN" _daemon >/dev/null 2>&1 &
}

stop_disguise() {
  if [[ -f $UNIT ]]; then systemctl stop ram-sh.service 2>/dev/null || true; fi
  local pid
  pid=$(cat "$STATE/pid" 2>/dev/null) || pid=
  if [[ -n $pid ]] && grep -qs _daemon "/proc/$pid/cmdline"; then
    kill "$pid" 2>/dev/null || true
    sleep 0.5
  fi
  undisguise
}

install_service() {
  [[ $SELF == "$BIN" ]] || install -m 755 "$SELF" "$BIN"
  if [[ -d /run/systemd/system ]]; then
    cat > "$UNIT" <<EOF
[Unit]
Description=$BRAND RAM (ram.sh)
After=swap.target local-fs.target

[Service]
ExecStart=$BIN _daemon
ExecStopPost=$BIN _undisguise
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl --quiet enable --now ram-sh.service
  else
    warn "No systemd here, so after a reboot run 'sudo ram.sh start' to turn $BRAND back on."
    start_bg
  fi
}

# ---------------------------------------------------------------- swapfile --

drop_swapfile() {
  if ours_active; then
    say "Turning off your old $BRAND RAM first (can take a bit)..."
    swapoff "$SWAPFILE" || die "Couldn't turn off your old $BRAND RAM, it's too full right now. Close some apps and try again."
  fi
  rm -f "$SWAPFILE"
}

make_swapfile() {   # $1 = size in MiB, $2 = filesystem type
  local mb=$1 fs=$2
  if [[ $fs == btrfs ]]; then
    # own subvolume, so the swapfile doesn't block snapshots (timeshift/snapper)
    [[ -d $SWAPDIR ]] || btrfs subvolume create "$SWAPDIR" >/dev/null
    if ! btrfs filesystem mkswapfile --size "${mb}m" "$SWAPFILE" >/dev/null 2>&1; then
      rm -f "$SWAPFILE"
      truncate -s 0 "$SWAPFILE"
      chattr +C "$SWAPFILE"   # btrfs swapfiles must be no-copy-on-write
      fallocate -l "${mb}MiB" "$SWAPFILE"
    fi
  else
    mkdir -p "$SWAPDIR"
    fallocate -l "${mb}MiB" "$SWAPFILE" 2>/dev/null ||
      dd if=/dev/zero of="$SWAPFILE" bs=1M count="$mb" status=progress
  fi
  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE" >/dev/null
  if ! swapon -p 10 "$SWAPFILE" 2>/dev/null; then
    [[ $fs != btrfs ]] || die "$BRAND doesn't work on btrfs spread over several drives. Sorry!"
    # some filesystems don't like fallocated swapfiles, so write it out for real
    rm -f "$SWAPFILE"
    dd if=/dev/zero of="$SWAPFILE" bs=1M count="$mb" status=progress
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE" >/dev/null
    swapon -p 10 "$SWAPFILE" 2>/dev/null || die "Couldn't switch $BRAND on."
  fi
}

add_fstab() {
  if grep -qF "$SWAPFILE " /etc/fstab; then return 0; fi
  [[ -e /etc/fstab.ram-sh.bak ]] || cp -p /etc/fstab /etc/fstab.ram-sh.bak
  if [[ -s /etc/fstab && -n $(tail -c 1 /etc/fstab) ]]; then echo >> /etc/fstab; fi
  printf '# added by ram.sh (undo with: sudo ram.sh remove)\n%s none swap defaults,pri=10 0 0\n' "$SWAPFILE" >> /etc/fstab
}

# ---------------------------------------------------- fastfetch / htop look --

user_home() { getent passwd "${SUDO_USER:-root}" | cut -d: -f6; }

as_user() {
  local u=${SUDO_USER:-root}
  if [[ $u == root ]]; then "$@"
  elif command -v runuser >/dev/null; then runuser -u "$u" -- "$@"
  else sudo -u "$u" -- "$@"; fi
}

fastfetch_config() {
  cat <<'EOF'
// made by ram.sh: fastfetch's default modules, minus "swap"
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
  "modules": [
    "title", "separator", "os", "host", "kernel", "uptime", "packages", "shell",
    "display", "de", "wm", "wmtheme", "theme", "icons", "font", "cursor",
    "terminal", "terminalfont", "cpu", "gpu", "memory", "disk", "localip",
    "battery", "poweradapter", "locale", "break", "colors"
  ]
}
EOF
}

# htop's default meters, minus "Swap"
htop_config() {
  local n l=AllCPUs r=
  n=$(nproc)
  if (( n > 8 )); then l=LeftCPUs4 r="RightCPUs4 "
  elif (( n > 4 )); then l=LeftCPUs2 r="RightCPUs2 "; fi
  printf '%s\n' "column_meters_0=$l Memory" "column_meter_modes_0=1 1" \
    "column_meters_1=${r}Tasks LoadAverage Uptime" "column_meter_modes_1=${r:+1 }2 2 2"
}

# drops the "Swap" meter (and its matching mode number) from an existing htoprc
HTOP_AWK='
function strip(list, bad,   n, a, i, out) {
  n = split(list, a, " "); out = ""
  for (i = 1; i <= n; i++) if (index(bad, " " i " ") == 0) out = out (out == "" ? "" : " ") a[i]
  return out
}
{ k = $0; sub(/=.*/, "", k); v = substr($0, length(k) + 2) }
NR == FNR {
  if (k ~ /^(column_meters_[0-9]+|left_meters|right_meters)$/) {
    n = split(v, a, " "); bad = " "
    for (i = 1; i <= n; i++) if (a[i] == "Swap") bad = bad i " "
    if (bad != " ") { m = k; sub(/meters/, "meter_modes", m); drop[k] = bad; drop[m] = bad }
  }
  next
}
(k in drop) { print k "=" strip(v, drop[k]); next }
{ print }'

SWAP_LINE='^[[:space:]]*"swap"[[:space:]]*,?[[:space:]]*$'

hide_in_tools() {
  local home ff hr out
  home=$(user_home)
  [[ -n $home && -d $home ]] || return 0
  ff=$home/.config/fastfetch/config.jsonc
  hr=$home/.config/htop/htoprc

  if command -v fastfetch >/dev/null; then
    if [[ ! -f $ff ]]; then
      as_user mkdir -p "${ff%/*}"
      fastfetch_config | as_user tee "$ff" >/dev/null
      as_user touch "$ff.ram-sh.made"
    elif grep -Eq "$SWAP_LINE" "$ff"; then
      [[ -e $ff.ram-sh.bak ]] || as_user cp -p "$ff" "$ff.ram-sh.bak"
      as_user sed -i -E "/$SWAP_LINE/d" "$ff"
    elif grep -qi '"swap"' "$ff" || ! grep -q '"modules"' "$ff"; then
      warn "Couldn't auto-edit $ff: delete the \"swap\" module from it yourself."
    fi
  fi

  if command -v htop >/dev/null; then
    if [[ ! -f $hr ]]; then
      as_user mkdir -p "${hr%/*}"
      htop_config | as_user tee "$hr" >/dev/null
      as_user touch "$hr.ram-sh.made"
    elif grep -Eq '^(column_meters_[0-9]+|left_meters|right_meters)=(.* )?Swap( |$)' "$hr"; then
      [[ -e $hr.ram-sh.bak ]] || as_user cp -p "$hr" "$hr.ram-sh.bak"
      out=$(awk "$HTOP_AWK" "$hr" "$hr")
      printf '%s\n' "$out" > "$hr"
    fi
  fi
}

restore_tools() {
  local home f
  home=$(user_home)
  [[ -n $home && -d $home ]] || return 0
  for f in "$home/.config/fastfetch/config.jsonc" "$home/.config/htop/htoprc"; do
    if [[ -e $f.ram-sh.bak ]]; then mv -f "$f.ram-sh.bak" "$f"
    elif [[ -e $f.ram-sh.made ]]; then rm -f "$f" "$f.ram-sh.made"; fi
  done
}

# ---------------------------------------------------------------- commands --

setup() {
  [[ -t 0 ]] || die "Run this in a terminal, it needs to ask you something."

  if command -v apt >/dev/null; then
    say "Running apt update..."
    apt update || warn "apt update failed (no internet?), carrying on anyway."
  fi

  stop_disguise   # so we see the real numbers
  # if you bail out (Ctrl+C) or something fails, put the old disguise back
  trap 'if [[ -f $UNIT ]]; then systemctl start ram-sh.service 2>/dev/null || true; fi' EXIT

  local fstype kind
  fstype=$(findmnt -no FSTYPE -T /)
  case $fstype in
    ext2|ext3|ext4|xfs|btrfs|f2fs) ;;
    *) die "$BRAND doesn't support your '$fstype' filesystem yet. Sorry!" ;;
  esac
  kind=$(disk_type)

  local ram_mb other_mb base_mb
  ram_mb=$(( $(mem_kb MemTotal) / 1024 ))
  other_mb=$(( $(other_swap_kb) / 1024 ))
  base_mb=$(( ram_mb + other_mb ))

  # free disk space, counting our old swapfile as free since it gets replaced,
  # and keeping 5% of the disk (2-10 GB) free so the system doesn't choke
  local avail_b size_b old_b=0 reserve_b room_mb
  read -r avail_b size_b < <(df -B1 --output=avail,size / | tail -n 1)
  if [[ -f $SWAPFILE ]]; then old_b=$(stat -c %s "$SWAPFILE"); fi
  reserve_b=$(( size_b / 20 ))
  reserve_b=$(( reserve_b < (2 << 30) ? (2 << 30) : reserve_b ))
  reserve_b=$(( reserve_b > (10 << 30) ? (10 << 30) : reserve_b ))
  room_mb=$(( (avail_b + old_b - reserve_b) / 1048576 ))
  room_mb=$(( room_mb < 0 ? 0 : room_mb ))

  say ""
  say "${B}ram.sh${N} - powered by ${B}$BRAND${N} technology"
  say ""
  say "  Your RAM:          $(human $base_mb)"
  say "  Most you can get:  $(human $(( base_mb + room_mb )))"
  say ""
  (( room_mb > 0 )) || die "Your storage is too full for $BRAND. Free up some space first."

  local ans want_mb extra_mb
  while :; do
    read -rp "How much RAM do you want in total? (like 16 or 16G): " ans || exit 1
    if ! want_mb=$(parse_size "$ans"); then
      warn "Type a number like 16, 16G or 512M."
      continue
    fi
    if (( want_mb <= base_mb )); then
      warn "You already have $(human $base_mb). Ask for more than that."
      continue
    fi
    extra_mb=$(( want_mb - base_mb ))
    if (( extra_mb > room_mb )); then
      warn "Too much! Your storage can't handle that. The max is $(human $(( base_mb + room_mb )))."
      continue
    fi
    if (( extra_mb > 4 * ram_mb )); then
      read -rp "That's a LOT compared to your real RAM, things might get laggy. Continue? [y/N] " ans || exit 1
      [[ $ans == [yY]* ]] || continue
    fi
    break
  done

  if [[ $kind == HDD ]]; then
    warn "Heads up: you're on a hard drive, $BRAND runs way faster on an SSD."
  fi

  say "Installing $(human $extra_mb) of $BRAND RAM..."
  drop_swapfile
  make_swapfile "$extra_mb" "$fstype"
  add_fstab
  say "Activating $BRAND..."
  install_service
  hide_in_tools

  say ""
  say "${G}Done!${N} You now have about $(human $want_mb) of RAM. Check it in fastfetch, neofetch or htop."
  say "To undo: sudo ram.sh remove"
}

status() {
  local src=/proc/meminfo on=off rt ru st su z
  if findmnt -rn -M /proc/meminfo >/dev/null 2>&1 && [[ -r $REALPROC/meminfo ]]; then
    on=on src=$REALPROC/meminfo
  fi
  rt=$(( $(mem_kb MemTotal "$src") / 1024 ))
  ru=$(( rt - $(mem_kb MemAvailable "$src") / 1024 ))
  st=$(( $(mem_kb SwapTotal "$src") / 1024 ))
  su=$(( st - $(mem_kb SwapFree "$src") / 1024 ))
  z=$(cat "$ZSWAP/enabled" 2>/dev/null) || z=
  say "Real RAM:     $(human $ru) used of $(human $rt)"
  say "Swap (disk):  $(human $su) used of $(human $st)"
  if [[ -f $SWAPFILE ]]; then
    say "  ram.sh's:   $SWAPFILE, $(human $(( $(stat -c %s "$SWAPFILE") / 1048576 )))"
  fi
  say "zswap cache:  $([[ $z == [Yy1]* ]] && echo on || echo off)"
  if [[ $on == on ]]; then
    say "Disguise:     on (tools show $(human $(( rt + st ))) of RAM)"
  else
    say "Disguise:     off"
  fi
}

remove_all() {
  drop_swapfile
  if [[ -d $SWAPDIR ]]; then
    if [[ $(findmnt -no FSTYPE -T "$SWAPDIR") == btrfs ]]; then
      btrfs subvolume delete "$SWAPDIR" >/dev/null 2>&1 || rmdir "$SWAPDIR" 2>/dev/null || true
    else
      rmdir "$SWAPDIR" 2>/dev/null || true
    fi
  fi
  sed -i '\|^# added by ram\.sh|d; \|^/ramsh/swapfile |d' /etc/fstab

  if [[ -f $UNIT ]]; then
    systemctl --quiet disable --now ram-sh.service 2>/dev/null || true
    rm -f "$UNIT"
    systemctl daemon-reload
  fi
  stop_disguise
  rm -f "$FAKE" "$STATE/pid"
  rmdir "$REALPROC" "$STATE" 2>/dev/null || true

  if [[ -f $LIB/zswap-before && -w $ZSWAP/enabled ]]; then
    cat "$LIB/zswap-before" > "$ZSWAP/enabled" 2>/dev/null || true
  fi
  rm -f "$LIB/zswap-before"
  rmdir "$LIB" 2>/dev/null || true

  restore_tools
  rm -f "$BIN"
  say "${G}$BRAND removed.${N} Your RAM is back to normal."
}

case ${1:-} in
  ""|setup)         need_root "$@"; setup ;;
  status)           status ;;
  remove|uninstall) need_root "$@"; remove_all ;;
  start)            need_root "$@"
                    if [[ -f $UNIT ]]; then systemctl start ram-sh.service; else stop_disguise; start_bg; fi ;;
  _daemon)          run_daemon ;;
  _undisguise)      undisguise ;;
  -h|--help|help)   say "usage: sudo ./ram.sh          get more RAM with $BRAND (run again to change it)"
                    say "       sudo ram.sh remove     remove $BRAND" ;;
  *)                die "usage: sudo ./ram.sh [status|remove]" ;;
esac
