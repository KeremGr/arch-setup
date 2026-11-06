#!/usr/bin/env bash
# arch-setup — stage 1: install the whole system from the Arch Linux ISO.
#
#   Boot the Arch ISO (UEFI, Secure Boot off), connect to the internet, then run the
#   verified one-line command from the README. This script:
#     1. asks every question first (nothing is written while you answer)
#     2. shows a summary, then for EACH disk a final confirmation with its exact model,
#        size and the partitions that will be affected (you type the disk name)
#     3. partitions + (optionally) encrypts, installs Arch, GRUB and every system module
#     4. builds the vetted AUR packages
#   After the reboot you log in and a window finishes the desktop (stage 2).
#
#   Never guesses a disk. Never touches a disk you did not type the name of.
#
#   Unattended test mode (VMs only): stage1/install.sh --answers FILE
set -euo pipefail
SETUP_DIR=$(cd "$(dirname "$0")/.." && pwd)
export SETUP_DIR
ARCH_SETUP_CONF=/nonexistent    # never read an installed system's answers here
# shellcheck source=../lib.sh
source "$SETUP_DIR/lib.sh"

MNT=/mnt
LOGDIR=/tmp/arch-setup; mkdir -p "$LOGDIR"
LOG=$LOGDIR/stage1.log
ANSWERS=""
[[ ${1:-} == --answers ]] && ANSWERS=${2:?usage: --answers FILE}
MIN_ROOT_GIB=40

# ------------------------------------------------------------------ helpers
ask() {            # ask VAR "Question" [default]
    local __v=$1 q=$2 d=${3:-} r
    if [[ -n $ANSWERS ]]; then [[ -n ${!__v:-} ]] || printf -v "$__v" '%s' "$d"; return; fi
    read -r -p "  $q${d:+ [$d]}: " r </dev/tty
    printf -v "$__v" '%s' "${r:-$d}"
}
ask_yn() {         # ask_yn VAR "Question" y|n
    local __v=$1 q=$2 d=$3 r
    if [[ -n $ANSWERS ]]; then [[ -n ${!__v:-} ]] || printf -v "$__v" '%s' "$d"; return; fi
    while :; do
        read -r -p "  $q [$([[ $d == y ]] && echo Y/n || echo y/N)]: " r </dev/tty
        r=${r:-$d}
        case ${r,,} in y|yes) printf -v "$__v" y; return;; n|no) printf -v "$__v" n; return;; esac
    done
}
ask_secret() {     # ask_secret VAR "What" minlen
    local __v=$1 what=$2 min=$3 a b
    if [[ -n $ANSWERS ]]; then [[ -n ${!__v:-} ]] || die "answers file: $__v missing"; return; fi
    while :; do
        read -r -s -p "  $what (min $min characters): " a </dev/tty; echo
        read -r -s -p "  Repeat: " b </dev/tty; echo
        if [[ $a != "$b" ]]; then warn "Didn't match — try again"; continue; fi
        if (( ${#a} < min )); then warn "Too short — try again"; continue; fi
        break
    done
    printf -v "$__v" '%s' "$a"
}
in_vm() { [[ $(systemd-detect-virt 2>/dev/null || echo none) != none ]]; }
part_path() { local d=$1 n=$2; [[ $d =~ [0-9]$ ]] && echo "${d}p$n" || echo "$d$n"; }   # nvme0n1 -> nvme0n1p2
gib() { echo $(( $1 / 1024 / 1024 / 1024 )); }
stable_id() {      # /dev/sdX -> /dev/disk/by-id/... (stable across reboots), else itself
    local dev=$1 l
    for l in /dev/disk/by-id/*; do
        [[ $l == *-part* || $l == */dm-* || $l == */lvm-* || $l == */md-* ]] && continue
        [[ $(readlink -f "$l") == "$dev" ]] && { echo "$l"; return; }
    done
    echo "$dev"
}
iso_disk() { local s; s=$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true); [[ -n $s ]] && lsblk -no PKNAME "$s" 2>/dev/null | head -1; }
free_bytes() {     # largest unpartitioned region on DISK, in bytes
    local disk=$1 ss
    ss=$(blockdev --getss "$disk")
    sfdisk -F -q "$disk" 2>/dev/null | awk -v ss="$ss" 'NF>=3 && $3 ~ /^[0-9]+$/ {b=$3*ss; if (b>m) m=b} END {print m+0}'
}
list_disks() {     # candidate disks, one per line: /dev/NAME
    local skip; skip=$(iso_disk || true)
    lsblk -dpno NAME,TYPE,RO | awk '$2=="disk" && $3=="0" {print $1}' | grep -vE '/dev/(zram|loop|sr|fd)' \
        | { if [[ -n $skip ]]; then grep -v "^/dev/$skip$"; else cat; fi; }
}
show_disk() {      # human description + its partitions
    local d=$1
    printf '  %s%s%s  %s  %s  %s\n' "$c_ok" "${d#/dev/}" "$c_off" "$(lsblk -dno SIZE "$d" | xargs)" \
        "$(lsblk -dno MODEL "$d" | xargs)" "$(lsblk -dno TRAN "$d" | xargs)"
    lsblk -no NAME,SIZE,FSTYPE,PARTLABEL,LABEL "$d" | tail -n +2 | sed 's/^/        /'
    if lsblk -no FSTYPE,PARTTYPE "$d" | grep -qiE 'ntfs|e3c9e316-0b5c-4db8-817d-f92df00215ae'; then
        echo "        ${c_warn}↳ looks like Windows is installed here${c_off}"
    fi
    local f; f=$(free_bytes "$d"); (( f >= 1024**3 )) && echo "        free (unpartitioned): $(gib "$f") GiB"
    return 0
}
pick_disk() {      # pick_disk VAR "purpose" [exclude]
    local __v=$1 purpose=$2 excl=${3:-} name
    if [[ -n $ANSWERS ]]; then
        [[ -b ${!__v:-} ]] || die "answers file: $__v is not a block device"
        printf -v "$__v" '%s' "$(readlink -f "${!__v}")"; return
    fi
    while :; do
        read -r -p "  Type the disk name for $purpose (e.g. ${c_ok}nvme0n1${c_off} or ${c_ok}sda${c_off}): " name </dev/tty
        name=${name#/dev/}
        if ! list_disks | grep -qx "/dev/$name"; then warn "'$name' is not one of the disks listed above"; continue; fi
        if [[ -n $excl && /dev/$name == "$excl" ]]; then warn "That disk is already used for the system"; continue; fi
        printf -v "$__v" '%s' "/dev/$name"; return
    done
}
confirm_disk() {   # the last check before ANY write to a disk
    local disk=$1 what=$2 typed
    echo
    printf '%s╔══════════════════════ FINAL CHECK — %s ══════════════════════%s\n' "$c_err" "${disk#/dev/}" "$c_off"
    echo "  Disk:      $disk"
    echo "  Model:     $(lsblk -dno MODEL "$disk" | xargs)"
    echo "  Serial:    $(lsblk -dno SERIAL "$disk" | xargs)"
    echo "  Capacity:  $(lsblk -dno SIZE "$disk" | xargs) ($(lsblk -dbno SIZE "$disk") bytes)"
    echo "  Current partitions:"
    lsblk -o NAME,SIZE,FSTYPE,PARTLABEL,LABEL,MOUNTPOINTS "$disk" | sed 's/^/     /'
    echo
    echo "  What will happen: $what"
    printf '%s╚═════════════════════════════════════════════════════════════════════%s\n' "$c_err" "$c_off"
    if [[ -n $ANSWERS ]]; then
        in_vm || die "Unattended disk confirmation is only allowed inside a virtual machine"
        [[ ${CONFIRM_DISKS:-} == *"${disk#/dev/}"* ]] || die "answers file: CONFIRM_DISKS does not name ${disk#/dev/}"
        warn "unattended VM test: confirmed ${disk#/dev/} from the answers file"; return
    fi
    read -r -p "  Type ${c_err}${disk#/dev/}${c_off} to confirm, anything else stops: " typed </dev/tty
    [[ $typed == "${disk#/dev/}" ]] || die "Stopped — nothing was written to any disk."
}
release_disk() {   # make sure nothing on DISK is mounted / open / used as swap
    local disk=$1 p
    for p in $(lsblk -lnpo NAME "$disk" | tac); do
        umount -q "$p" 2>/dev/null || true
        swapoff "$p" 2>/dev/null || true
    done
    for p in $(lsblk -lnpo NAME,TYPE "$disk" | awk '$2=="crypt"{print $1}'); do cryptsetup close "$p" 2>/dev/null || true; done
    [[ -z $(lsblk -no MOUNTPOINTS "$disk" | tr -d '[:space:]') ]] || die "$disk is still in use"
}
first_free_partnum() { local disk=$1 n used; used=$(sgdisk -p "$disk" | awk '/^ +[0-9]+ /{print $1}'); for n in $(seq 1 128); do grep -qx "$n" <<<"$used" || { echo "$n"; return; }; done; }

cleanup() {
    rm -f "$MNT/etc/sudoers.d/99-arch-setup-install" 2>/dev/null || true
    [[ -n ${KF:-} ]] && shred -u "$KF" 2>/dev/null || true
    [[ -n ${KF2:-} ]] && shred -u "$KF2" 2>/dev/null || true
}
trap cleanup EXIT

# ------------------------------------------------------------------ preflight
clear 2>/dev/null || true
printf '%s\n  arch-setup — secure, fast Hyprland + Caelestia desktop\n%s\n' "$c_info" "$c_off"
[[ $EUID -eq 0 ]] || die "Run as root (the Arch ISO logs you in as root)"
[[ -d /sys/firmware/efi/efivars ]] || die "Not booted in UEFI mode. Enable UEFI (disable CSM/Legacy) in the BIOS and boot the USB again."
sb=$(od -An -t u1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c 2>/dev/null | awk '{print $NF}' || true)
[[ ${sb:-0} == 1 ]] && die "Secure Boot is ON. Turn it off in the BIOS (this setup uses unsigned GRUB/drivers), then boot the USB again."
[[ -d /run/archiso ]] || warn "This doesn't look like the Arch ISO — continuing, but this is only tested there"
curl -sfI --max-time 8 https://archlinux.org >/dev/null || die "No internet. Ethernet works by itself; for Wi-Fi run: iwctl  (then: station wlan0 connect YOUR-WIFI)"
timedatectl set-ntp true 2>/dev/null || true
ok "UEFI · Secure Boot off · online"

if [[ -n $ANSWERS ]]; then
    in_vm || die "--answers (unattended) only runs inside a virtual machine"
    # shellcheck source=/dev/null
    source "$ANSWERS"
    export NONINTERACTIVE=1
    warn "UNATTENDED TEST MODE (virtual machine)"
fi

# ------------------------------------------------------------------ questions
section "1/7  Keyboard, language, time"
echo "  Common keyboards: us · uk · de · fr · es · it · trq (Turkish Q) · trf (Turkish F) · ru · pl · br-abnt2"
while :; do
    ask KEYMAP "Console keyboard layout" "us"
    if localectl list-keymaps 2>/dev/null | grep -qx "$KEYMAP"; then break; fi
    warn "Unknown keymap '$KEYMAP' (see: localectl list-keymaps)"; [[ -n $ANSWERS ]] && die "bad KEYMAP"
done
loadkeys "$KEYMAP" 2>/dev/null || true      # so the passwords you type next use your layout
case $KEYMAP in
    trq) d_xkb=tr d_var="" ;;  trf) d_xkb=tr d_var=f ;;  uk) d_xkb=gb d_var="" ;;
    de|de-latin1|de-latin1-nodeadkeys) d_xkb=de d_var="" ;;  fr|fr-latin1|fr-latin9|fr-pc) d_xkb=fr d_var="" ;;
    br-abnt2) d_xkb=br d_var="" ;;  pl|pl2) d_xkb=pl d_var="" ;;  ru) d_xkb=us,ru d_var="" ;;
    *) d_xkb=${KEYMAP%%-*} d_var="" ;;
esac
ask XKB_LAYOUT "Desktop keyboard layout (xkb)" "$d_xkb"
[[ $XKB_LAYOUT =~ ^[a-z]{2,3}(,[a-z]{2,3})*$ ]] || die "Invalid desktop layout '$XKB_LAYOUT'"
ask XKB_VARIANT "Desktop keyboard variant (empty = standard)" "$d_var"
[[ $XKB_VARIANT =~ ^[a-z0-9_]*$ ]] || die "Invalid variant '$XKB_VARIANT'"

while :; do
    ask LOCALE "System language" "en_US.UTF-8"
    grep -q "^${LOCALE} " /usr/share/i18n/SUPPORTED 2>/dev/null && break
    warn "Unknown locale '$LOCALE' (examples: en_US.UTF-8, tr_TR.UTF-8, de_DE.UTF-8)"; [[ -n $ANSWERS ]] && die "bad LOCALE"
done
while :; do
    ask TIMEZONE "Timezone (Region/City, e.g. Europe/Berlin, America/New_York)" "UTC"
    [[ $TIMEZONE != *..* && -f /usr/share/zoneinfo/$TIMEZONE ]] && break
    warn "Unknown timezone '$TIMEZONE'"; [[ -n $ANSWERS ]] && die "bad TIMEZONE"
done
# Region formats (°C/°F, 24h/12h clock, dates, paper size) follow the country, not the language
cc=$(awk -v tz="$TIMEZONE" -F'\t' '$3==tz {print substr($1,1,2); exit}' /usr/share/zoneinfo/zone1970.tab 2>/dev/null || true)
d_fmt=$LOCALE
if [[ -n $cc ]]; then
    cands=$(grep -oE "^[a-z]{2,3}_${cc}\.UTF-8" /usr/share/i18n/SUPPORTED || true)
    d_fmt=$(grep -m1 -E "^${cc,,}_" <<<"$cands" || grep -m1 -E "^en_" <<<"$cands" || head -1 <<<"$cands" || true)
    [[ -n $d_fmt ]] || d_fmt=$LOCALE
fi
while :; do
    ask FORMATS "Region formats: units, clock, dates (language stays $LOCALE)" "$d_fmt"
    grep -q "^${FORMATS} " /usr/share/i18n/SUPPORTED 2>/dev/null && break
    warn "Unknown locale '$FORMATS'"; [[ -n $ANSWERS ]] && die "bad FORMATS"
done
d_city=${TIMEZONE##*/}; d_city=${d_city//_/ }
ask WEATHER_CITY "City for the weather widget (no location tracking)" "$d_city"
ask MIRROR_COUNTRIES "Countries for package mirrors, comma-separated (empty = worldwide)" ""
[[ $MIRROR_COUNTRIES =~ ^[A-Za-z\ ,]*$ ]] || die "Invalid country list"

section "2/7  You"
while :; do
    ask HOSTNAME_ "Computer name" "arch"
    [[ $HOSTNAME_ =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] && break
    warn "Use lowercase letters, digits and '-'"; [[ -n $ANSWERS ]] && die "bad HOSTNAME_"
done
while :; do
    ask USERNAME "Your username (lowercase)" ""
    [[ $USERNAME =~ ^[a-z_][a-z0-9_-]{0,31}$ && ! $USERNAME =~ ^(root|bin|daemon|nobody|greeter|git)$ ]] && break
    warn "Lowercase letters/digits/_/-, starting with a letter"; [[ -n $ANSWERS ]] && die "bad USERNAME"
done
echo "  Your password is used for: login, sudo, the encrypted disks (unless you choose otherwise) and the GRUB menu lock."
ask_secret PASSWORD "Password" 8
(( ${#PASSWORD} < 12 )) && warn "Short password (${#PASSWORD} characters). 12+ is strongly recommended if it also protects your disks."
ask_yn LOCK_ROOT "Lock the root account? (admin only through sudo — recommended)" y

section "3/7  Graphics + processor"
lspci -nn 2>/dev/null | grep -Ei 'VGA|3D|Display' | sed 's/^/  /' || true
GPU=${GPU_FORCE:-$(detect_gpu)}
if [[ $GPU == nvidia* && -z ${GPU_FORCE:-} ]]; then
    model=$(lspci 2>/dev/null | grep -Ei 'VGA|3D' | grep -i nvidia | head -1)
    if grep -qiE 'GTX (9[0-9]{2}|10[0-9]{2})|GTX TITAN|\bGT [0-9]{3,4}\b|Quadro [KMP][0-9]|Tesla [KMP]' <<<"$model"; then
        warn "This NVIDIA card is older than RTX/GTX 16 — the current NVIDIA driver no longer supports it."
        warn "It will use the open-source 'nouveau' driver instead (works, slower in games)."
        GPU=other
    elif ! grep -qiE 'RTX|GTX 16[0-9]{2}|\b(A|L|H)[0-9]{2,4}\b|Quadro RTX|TU1|GA1|AD1|GB2' <<<"$model"; then
        warn "Couldn't tell which NVIDIA generation this is: $model"
        ask_yn nv_new "Is it an RTX card or a GTX 16xx (2018 or newer)?" y
        [[ $nv_new == y ]] || GPU=other
    fi
fi
if [[ -z $ANSWERS ]]; then
    echo "  Detected: ${c_ok}$GPU${c_off}   (nvidia · nvidia-hybrid = laptop with 2 GPUs · amd · intel · other = basic open drivers)"
    ask g "Press Enter to accept, or type another" "$GPU"
    [[ $g =~ ^(nvidia|nvidia-hybrid|amd|intel|other)$ ]] || die "Unknown GPU type '$g'"
    GPU=$g
fi
case $(grep -m1 vendor_id /proc/cpuinfo | awk '{print $3}') in
    GenuineIntel) UCODE=intel-ucode ;; AuthenticAMD) UCODE=amd-ucode ;; *) UCODE="" ;;
esac
ok "GPU: $GPU · CPU microcode: ${UCODE:-none}"

section "4/7  System disk"
echo "  Disks in this computer (the USB you booted from is hidden):"; echo
mapfile -t DISKS < <(list_disks)
(( ${#DISKS[@]} )) || die "No disks found"
for d in "${DISKS[@]}"; do show_disk "$d"; echo; done
pick_disk DISK "the SYSTEM (Arch will be installed on it)"
DISK_BYTES=$(lsblk -dbno SIZE "$DISK")
FREE=$(free_bytes "$DISK")
echo
echo "  How should ${DISK#/dev/} be used?"
echo "    1) Erase the whole disk and use all of it"
echo "    2) Erase the whole disk, but leave empty space for Windows (or anything) later"
if (( FREE >= (MIN_ROOT_GIB + 2) * 1024**3 )); then
    echo "    3) Keep everything on it and install into the free space ($(gib "$FREE") GiB) — for dual boot with an existing Windows"
fi
while :; do
    ask DISK_MODE_N "Choice" ""
    case $DISK_MODE_N in
        1) DISK_MODE=erase; break ;;
        2) DISK_MODE=erase-keep; break ;;
        3) (( FREE >= (MIN_ROOT_GIB + 2) * 1024**3 )) && { DISK_MODE=freespace; break; } ;;
    esac
    warn "Type 1, 2 or 3"; [[ -n $ANSWERS ]] && die "bad DISK_MODE_N"
done
: "${KEEP_GIB:=0}"
if [[ $DISK_MODE == erase-keep ]]; then
    max_keep=$(( $(gib "$DISK_BYTES") - 1 - MIN_ROOT_GIB ))
    (( max_keep > 0 )) || die "Disk too small to leave space"
    while :; do
        ask KEEP_GIB "How many GiB to leave empty (Windows needs 64+; max $max_keep)" "100"
        [[ $KEEP_GIB =~ ^[0-9]+$ ]] && (( KEEP_GIB >= 1 && KEEP_GIB <= max_keep )) && break
        warn "Between 1 and $max_keep"; [[ -n $ANSWERS ]] && die "bad KEEP_GIB"
    done
fi
(( $(gib "$DISK_BYTES") >= MIN_ROOT_GIB + 2 )) || die "Disk too small (need $((MIN_ROOT_GIB + 2)) GiB)"

echo
echo "  Disk encryption: the system disk can be encrypted (LUKS2). Then a password is"
echo "  needed at every boot, and a stolen disk is unreadable. Recommended for laptops."
ask_yn ENCRYPT "Encrypt the system disk?" n
ROOT_ENCRYPTED=no; : "${LUKS_SAME:=y}"
if [[ $ENCRYPT == y ]]; then
    ROOT_ENCRYPTED=yes
    ask_yn LUKS_SAME "Use your login password for it? (one password for everything)" y
    if [[ $LUKS_SAME == n ]]; then ask_secret LUKS_PASS "Disk encryption password" 12; fi
fi
[[ $LUKS_SAME == y ]] && LUKS_PASS=$PASSWORD

section "5/7  Extra data disk (optional)"
DATA_DISK=""; VPART=""; : "${DATA_DEV:=}" "${BRIDGE_GIB:=0}" "${DATA_KEEP_GIB:=0}"
others=(); for d in "${DISKS[@]}"; do [[ $d != "$DISK" ]] && others+=("$d"); done
if (( ${#others[@]} )); then
    echo "  Another disk can become encrypted storage + automatic daily backups (opens with your"
    echo "  password at login), with an optional unencrypted share for Windows/macOS."
    ask_yn USE_DATA "Set up an extra data disk?" n
    [[ $USE_DATA == y ]] || DATA_DEV=""
    if [[ $USE_DATA == y ]]; then
        for d in "${others[@]}"; do show_disk "$d"; echo; done
        pick_disk DATA_DEV "the DATA disk (it will be ERASED)" "$DISK"
        [[ $DATA_DEV != "$DISK" ]] || die "The data disk can't be the system disk"
        dmax=$(( $(gib "$(lsblk -dbno SIZE "$DATA_DEV")") - 2 ))
        ask BRIDGE_GIB "Size of the unencrypted share for Windows/macOS in GiB (0 = none)" "0"
        ask DATA_KEEP_GIB "GiB to leave empty on it (0 = none)" "0"
        [[ $BRIDGE_GIB =~ ^[0-9]+$ && $DATA_KEEP_GIB =~ ^[0-9]+$ ]] || die "Sizes must be numbers"
        (( BRIDGE_GIB + DATA_KEEP_GIB + 8 <= dmax )) || die "Not enough room left for the vault"
        DATA_DISK=$(stable_id "$DATA_DEV")
    fi
else
    info "Only one disk — skipping"
fi

section "6/7  Boot menu lock"
echo "  Lock the GRUB menu with your password: normal boot stays automatic; editing boot"
echo "  entries, the GRUB console and booting snapshots need the password."
ask_yn GRUB_LOCK "Lock the boot menu?" y
if [[ $GRUB_LOCK == y && $PASSWORD =~ [^a-hj-zA-HJ-Z0-9] && $XKB_LAYOUT != us ]]; then
    warn "GRUB always uses a US keyboard. Your password has characters that sit on other keys there —"
    warn "at the GRUB prompt, press the keys where those characters are on a US keyboard."
fi

section "7/7  Apps & preferences (Enter = recommended)"
if [[ -d /sys/class/power_supply ]] && compgen -G "/sys/class/power_supply/BAT*" >/dev/null; then LAPTOP=y; else LAPTOP=n; fi
pick() {           # pick VAR "Question" default option1 option2 ...
    local __v=$1 q=$2 d=$3; shift 3
    while :; do
        ask "$__v" "$q ($(IFS=/; echo "$*"))" "$d"
        local o; for o in "$@"; do [[ ${!__v} == "$o" ]] && return; done
        warn "Choose one of: $*"; [[ -n $ANSWERS ]] && die "bad $__v"
    done
}
pick BROWSER "Web browser" librewolf librewolf firefox
ask_yn WANT_SPOTIFY "Spotify (themed to match your desktop)?" y
ask_yn WANT_DISCORD "Discord (Vesktop, themed)?" y
pick DEV_TOOLS "Developer tools: full = Python, Rust, C/C++, Node, Code-OSS, Neovim · basic = git + Neovim" full full basic none
ask_yn WANT_GAMING "Gaming: Steam, GameMode, MangoHud, 32-bit drivers?" n
ask_yn WANT_EXTRAS "Extra apps: mpv (video), OBS (recording), LibreOffice, image viewer?" n
ask_yn WANT_FLATPAK "Flatpak + Flathub (app store for sandboxed apps)?" n
ask_yn WANT_BLUETOOTH "Bluetooth?" "$LAPTOP"
ask_yn WANT_PRINTING "Printer support?" n
ask_yn WANT_LTS "Backup kernel (linux-lts) in the boot menu, in case an update breaks the main one?" y
pick START_SCHEME "Starting colour scheme (change any time with SUPER)" autumn-forest autumn-forest nocturne cream catppuccin gruvbox rosepine tokyonight nord
pick DNS_PROVIDER "Encrypted DNS provider" cloudflare cloudflare quad9 mullvad
ask_yn NIGHT_LIGHT "Night light: warmer screen colours in the evening (toggle any time: pkill -USR1 gammastep)?" y
while :; do
    ask IDLE_LOCK_MIN "Lock the screen after how many idle minutes (0 = never)" 10
    [[ $IDLE_LOCK_MIN =~ ^[0-9]+$ ]] && break; warn "A number"; [[ -n $ANSWERS ]] && die "bad IDLE_LOCK_MIN"
done
while :; do
    ask IDLE_SLEEP_MIN "Sleep after how many idle minutes (0 = never; some monitors don't wake well)" "$([[ $LAPTOP == y ]] && echo 30 || echo 0)"
    [[ $IDLE_SLEEP_MIN =~ ^[0-9]+$ ]] && break; warn "A number"; [[ -n $ANSWERS ]] && die "bad IDLE_SLEEP_MIN"
done

# ------------------------------------------------------------------ summary
section "Summary"
data_txt=none
if [[ -n $DATA_DEV ]]; then
    data_txt="${DATA_DEV#/dev/} ($(lsblk -dno SIZE,MODEL "$DATA_DEV" | xargs)) — ERASE: encrypted vault"
    (( BRIDGE_GIB )) && data_txt+=" + $BRIDGE_GIB GiB share"
    (( DATA_KEEP_GIB )) && data_txt+=" + $DATA_KEEP_GIB GiB empty"
fi
mode_txt=$( case $DISK_MODE in
    erase) echo "ERASE all of it, use everything" ;;
    erase-keep) echo "ERASE all of it, leave $KEEP_GIB GiB empty" ;;
    freespace) echo "keep existing partitions, use $(gib "$FREE") GiB of free space" ;; esac )
cat <<EOF
  Keyboard ........ console $KEYMAP · desktop $XKB_LAYOUT${XKB_VARIANT:+ ($XKB_VARIANT)}
  Language/time ... $LOCALE (formats: $FORMATS) · $TIMEZONE · weather: $WEATHER_CITY · mirrors: ${MIRROR_COUNTRIES:-worldwide}
  Computer/user ... $HOSTNAME_ · $USERNAME (sudo) · root locked: $LOCK_ROOT
  Graphics ........ $GPU · microcode: ${UCODE:-none}
  System disk ..... ${DISK#/dev/} ($(lsblk -dno SIZE,MODEL "$DISK" | xargs)) — $mode_txt
  Encryption ...... $ROOT_ENCRYPTED$([[ $ROOT_ENCRYPTED == yes ]] && { [[ $LUKS_SAME == y ]] && echo " (login password)" || echo " (separate password)"; })
  Data disk ....... $data_txt
  Boot menu lock .. $GRUB_LOCK
  Apps ............ browser $BROWSER · spotify $WANT_SPOTIFY · discord $WANT_DISCORD · dev $DEV_TOOLS · gaming $WANT_GAMING · extras $WANT_EXTRAS · flatpak $WANT_FLATPAK
  System .......... bluetooth $WANT_BLUETOOTH · printing $WANT_PRINTING · backup kernel $WANT_LTS · DNS $DNS_PROVIDER
  Look + idle ..... theme $START_SCHEME · night light $NIGHT_LIGHT · lock ${IDLE_LOCK_MIN}m · sleep $([[ $IDLE_SLEEP_MIN == 0 ]] && echo never || echo "${IDLE_SLEEP_MIN}m")
EOF
if [[ -z $ANSWERS ]]; then
    read -r -p "  Everything correct? Type yes to continue: " a </dev/tty
    [[ $a == yes ]] || die "Stopped — nothing was written. Run the command again to start over."
fi

exec > >(tee -a "$LOG") 2>&1      # from here on, a log (passwords are never printed)

# ------------------------------------------------------------------ system disk
section "Preparing ${DISK#/dev/}"
pacman -Sy --needed --noconfirm archlinux-keyring >/dev/null 2>&1 || warn "Could not refresh the ISO's keyring (continuing)"
case $DISK_MODE in
    erase)      what="EVERYTHING on it is erased. New: 1 GiB boot (EFI) + the rest for Arch." ;;
    erase-keep) what="EVERYTHING on it is erased. New: 1 GiB boot (EFI) + Arch, and $KEEP_GIB GiB left empty." ;;
    freespace)  what="NOTHING is erased. Two new partitions (1 GiB boot + Arch) go into the $(gib "$FREE") GiB of free space." ;;
esac
confirm_disk "$DISK" "$what"
release_disk "$DISK"

if [[ $DISK_MODE == freespace ]]; then
    PN_EFI=$(first_free_partnum "$DISK")
    sgdisk -n "$PN_EFI:0:+1G" -t "$PN_EFI:ef00" -c "$PN_EFI:ARCH_EFI" "$DISK" >/dev/null
    PN_ROOT=$(first_free_partnum "$DISK")
    sgdisk -n "$PN_ROOT:0:0" -t "$PN_ROOT:8309" -c "$PN_ROOT:ARCH_ROOT" "$DISK" >/dev/null
else
    for p in $(lsblk -lnpo NAME,TYPE "$DISK" | awk '$2=="part"{print $1}'); do wipefs -aq "$p" || true; done
    wipefs -aq "$DISK"; sgdisk --zap-all "$DISK" >/dev/null
    PN_EFI=1; PN_ROOT=2
    sgdisk -n 1:0:+1G -t 1:ef00 -c 1:ARCH_EFI "$DISK" >/dev/null
    if [[ $DISK_MODE == erase-keep ]]; then
        sgdisk -n "2:0:-${KEEP_GIB}G" -t 2:8309 -c 2:ARCH_ROOT "$DISK" >/dev/null
    else
        sgdisk -n 2:0:0 -t 2:8309 -c 2:ARCH_ROOT "$DISK" >/dev/null
    fi
fi
[[ $ROOT_ENCRYPTED == yes ]] || sgdisk -t "$PN_ROOT:8304" "$DISK" >/dev/null     # Linux x86-64 root
partprobe "$DISK" 2>/dev/null || true; udevadm settle
EFI_PART=$(part_path "$DISK" "$PN_EFI"); ROOT_PART=$(part_path "$DISK" "$PN_ROOT")
for _ in {1..20}; do [[ -b $EFI_PART && -b $ROOT_PART ]] && break; sleep 0.5; done
[[ -b $EFI_PART && -b $ROOT_PART ]] || die "New partitions did not appear"
sgdisk -v "$DISK" | grep -q 'No problems found' || warn "sgdisk reported a partition table issue (see log)"
ok "Partitions: boot $EFI_PART · system $ROOT_PART"

mkfs.fat -F 32 -n ARCH_EFI "$EFI_PART" >/dev/null
ROOT_FS=$ROOT_PART
KF=$(mktemp -p /run arch-setup-key.XXXXXX); chmod 600 "$KF"
if [[ $ROOT_ENCRYPTED == yes ]]; then
    printf '%s' "$LUKS_PASS" >"$KF"
    cryptsetup luksFormat --type luks2 --pbkdf argon2id --label ARCH_LUKS --batch-mode --key-file "$KF" "$ROOT_PART"
    cryptsetup open --allow-discards --persistent --key-file "$KF" "$ROOT_PART" root
    ROOT_FS=/dev/mapper/root
    ok "System disk encrypted (LUKS2, argon2id)"
fi
mkfs.btrfs -q -f -L ARCH "$ROOT_FS"
mount "$ROOT_FS" "$MNT"
btrfs subvolume create "$MNT/@" >/dev/null
btrfs subvolume create "$MNT/@home" >/dev/null
umount "$MNT"
OPTS=noatime,compress=zstd:3,space_cache=v2
[[ $(lsblk -dno ROTA "$DISK") == 0 ]] && OPTS+=,discard=async
mount -o "$OPTS,subvol=@" "$ROOT_FS" "$MNT"
mount --mkdir -o "$OPTS,subvol=@home" "$ROOT_FS" "$MNT/home"
mount --mkdir -o umask=0077 "$EFI_PART" "$MNT/boot"
ok "btrfs: @ (system) + @home (your files) — snapshots are added later"

# ------------------------------------------------------------------ data disk
if [[ -n $DATA_DEV ]]; then
    section "Preparing data disk ${DATA_DEV#/dev/}"
    dwhat="EVERYTHING on it is erased. New: "
    (( BRIDGE_GIB )) && dwhat+="$BRIDGE_GIB GiB share (exFAT, unencrypted) + "
    dwhat+="encrypted vault"; (( DATA_KEEP_GIB )) && dwhat+=" + $DATA_KEEP_GIB GiB left empty"
    confirm_disk "$DATA_DEV" "$dwhat."
    release_disk "$DATA_DEV"
    for p in $(lsblk -lnpo NAME,TYPE "$DATA_DEV" | awk '$2=="part"{print $1}'); do wipefs -aq "$p" || true; done
    wipefs -aq "$DATA_DEV"; sgdisk --zap-all "$DATA_DEV" >/dev/null
    n=1
    if (( BRIDGE_GIB )); then sgdisk -n "1:0:+${BRIDGE_GIB}G" -t 1:0700 -c 1:BRIDGE "$DATA_DEV" >/dev/null; n=2; fi
    if (( DATA_KEEP_GIB )); then sgdisk -n "$n:0:-${DATA_KEEP_GIB}G" -t "$n:8309" -c "$n:VAULT" "$DATA_DEV" >/dev/null
    else sgdisk -n "$n:0:0" -t "$n:8309" -c "$n:VAULT" "$DATA_DEV" >/dev/null; fi
    partprobe "$DATA_DEV" 2>/dev/null || true; udevadm settle
    VPART=$(part_path "$DATA_DEV" "$n")
    for _ in {1..20}; do [[ -b $VPART ]] && break; sleep 0.5; done
    (( BRIDGE_GIB )) && mkfs.exfat -q -L BRIDGE "$(part_path "$DATA_DEV" 1)" >/dev/null
    KF2=$(mktemp -p /run arch-setup-key.XXXXXX); chmod 600 "$KF2"; printf '%s' "$PASSWORD" >"$KF2"
    cryptsetup luksFormat --type luks2 --pbkdf argon2id --label VAULT --batch-mode --key-file "$KF2" "$VPART"
    cryptsetup open --key-file "$KF2" "$VPART" vault-setup
    mkfs.btrfs -q -f -L VAULT /dev/mapper/vault-setup
    m=$(mktemp -d); mount /dev/mapper/vault-setup "$m"
    btrfs subvolume create "$m/@storage" >/dev/null; btrfs subvolume create "$m/@backups" >/dev/null
    umount "$m"; rmdir "$m"; cryptsetup close vault-setup
    ok "Data disk: ${BRIDGE_GIB:+share + }encrypted vault (opens with your password at login)"
fi

# ------------------------------------------------------------------ base system
section "Installing Arch (base system)"
GPU_PKGS=()
case $GPU in
    nvidia)        GPU_PKGS=(nvidia-open nvidia-utils) ;;
    nvidia-hybrid) GPU_PKGS=(nvidia-open nvidia-utils nvidia-prime mesa vulkan-intel vulkan-radeon) ;;
    amd)           GPU_PKGS=(mesa vulkan-radeon) ;;
    intel)         GPU_PKGS=(mesa vulkan-intel intel-media-driver) ;;
    *)             GPU_PKGS=(mesa) ;;
esac
if [[ $WANT_LTS == y ]]; then
    LTS_PKGS=(linux-lts)
    [[ $GPU == nvidia* ]] && LTS_PKGS+=(nvidia-open-lts)
else LTS_PKGS=(); fi
BASE=(base linux linux-firmware "${LTS_PKGS[@]}" $UCODE btrfs-progs cryptsetup dosfstools exfatprogs networkmanager
      grub efibootmgr os-prober sudo nano git base-devel python reflector pciutils "${GPU_PKGS[@]}")
for p in "${BASE[@]}"; do pacman -Si "$p" >/dev/null 2>&1 || die "Package '$p' not found in the Arch repos"; done
pacstrap -K "$MNT" "${BASE[@]}"
genfstab -U "$MNT" | sed -E 's/,?subvolid=[0-9]+//' >>"$MNT/etc/fstab"
ok "Base system installed"

# ------------------------------------------------------------------ configure (inside the new system)
section "Configuring the new system"
LUKS_UUID=""
[[ $ROOT_ENCRYPTED == yes ]] && LUKS_UUID=$(cryptsetup luksUUID "$ROOT_PART")
install -d -m 0755 "$MNT/etc/arch-setup"
cat >"$MNT/etc/arch-setup/install.conf" <<EOF
# arch-setup install answers (no passwords). Read by the modules and tools.
USERNAME=$USERNAME
KEYMAP=$KEYMAP
XKB_LAYOUT=$XKB_LAYOUT
XKB_VARIANT=$XKB_VARIANT
LOCALE=$LOCALE
FORMATS=$FORMATS
TIMEZONE=$TIMEZONE
WEATHER_CITY="$WEATHER_CITY"
MIRROR_COUNTRIES="$MIRROR_COUNTRIES"
GPU=$GPU
ROOT_ENCRYPTED=$ROOT_ENCRYPTED
DATA_DISK=$DATA_DISK
BROWSER=$BROWSER
WANT_SPOTIFY=$WANT_SPOTIFY
WANT_DISCORD=$WANT_DISCORD
DEV_TOOLS=$DEV_TOOLS
WANT_GAMING=$WANT_GAMING
WANT_EXTRAS=$WANT_EXTRAS
WANT_FLATPAK=$WANT_FLATPAK
WANT_BLUETOOTH=$WANT_BLUETOOTH
WANT_PRINTING=$WANT_PRINTING
WANT_LTS=$WANT_LTS
START_SCHEME=$START_SCHEME
DNS_PROVIDER=$DNS_PROVIDER
IDLE_LOCK_MIN=$IDLE_LOCK_MIN
IDLE_SLEEP_MIN=$IDLE_SLEEP_MIN
NIGHT_LIGHT=$NIGHT_LIGHT
EOF
chmod 0644 "$MNT/etc/arch-setup/install.conf"

arch-chroot "$MNT" /bin/bash -s -- "$USERNAME" "$HOSTNAME_" "$TIMEZONE" "$LOCALE" "$KEYMAP" "$LUKS_UUID" "$FORMATS" <<'CHROOT'
set -euo pipefail
U=$1 H=$2 TZ=$3 L=$4 K=$5 LUKS=$6 F=$7
ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
hwclock --systohc
sed -i -E "s/^#(${L//./\\.} )/\1/; s/^#(${F//./\\.} )/\1/; s/^#(en_US\.UTF-8 )/\1/" /etc/locale.gen
locale-gen >/dev/null
# Language for menus/messages; the region's formats for units, time, dates, money, paper.
# (LC_NUMERIC stays with the language: a decimal comma breaks some programs.)
printf 'LANG=%s\n' "$L" >/etc/locale.conf
[[ $F != "$L" ]] && for v in LC_TIME LC_MEASUREMENT LC_PAPER LC_MONETARY LC_ADDRESS LC_TELEPHONE; do echo "$v=$F"; done >>/etc/locale.conf
echo "KEYMAP=$K" >/etc/vconsole.conf
echo "$H" >/etc/hostname
printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 %s\n' "$H" >/etc/hosts
id "$U" &>/dev/null || useradd -m -G wheel -s /bin/bash "$U"
install -m 0440 /dev/stdin /etc/sudoers.d/00-wheel <<<'%wheel ALL=(ALL:ALL) ALL'
# Temporary: lets the AUR builds below install packages. Removed when stage 1 ends.
install -m 0440 /dev/stdin /etc/sudoers.d/99-arch-setup-install <<<"$U ALL=(ALL:ALL) NOPASSWD: ALL"
visudo -cq
G=/etc/default/grub
sed -i -E 's/^#?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/; s/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/' "$G"
grep -q '^GRUB_DISABLE_OS_PROBER=false' "$G" || echo 'GRUB_DISABLE_OS_PROBER=false' >>"$G"
# The main kernel boots by default; the backup (LTS) kernel stays one menu entry away.
grep -q '^GRUB_TOP_LEVEL=' "$G" || echo 'GRUB_TOP_LEVEL="/boot/vmlinuz-linux"' >>"$G"
if [[ -n $LUKS ]]; then
    sed -i -E "s|^GRUB_CMDLINE_LINUX=\"(.*)\"|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$LUKS:root:allow-discards\"|" "$G"
fi
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB >/dev/null
# Fallback path, so boards that forget NVRAM boot entries still find GRUB (our own EFI partition)
[[ -e /boot/EFI/BOOT/BOOTX64.EFI ]] || grub-install --target=x86_64-efi --efi-directory=/boot --removable >/dev/null
CHROOT
printf '%s:%s\n' "$USERNAME" "$PASSWORD" | arch-chroot "$MNT" chpasswd
ok "Time, language, keyboard, computer name, user, GRUB"

if [[ $GRUB_LOCK == y ]]; then
    HASH=$(printf '%s\n%s\n' "$PASSWORD" "$PASSWORD" | arch-chroot "$MNT" grub-mkpasswd-pbkdf2 -c 200000 | awk '/grub\.pbkdf2/{print $NF}')
    [[ $HASH == grub.pbkdf2.* ]] || die "Could not create the GRUB password hash"
    install -m 0700 /dev/stdin "$MNT/etc/grub.d/01_password" <<SH
#!/bin/sh
cat <<'EOF'
set superusers="$USERNAME"
password_pbkdf2 $USERNAME $HASH
EOF
SH
    unset HASH
    ok "Boot menu lock prepared"
fi

# Recovery keys: a second way into each encrypted disk, if the password is ever forgotten.
show_recovery() {   # printed to the screen only — never into the log
    local dev=$1 label=$2 kf=$3 key
    key=$(systemd-cryptenroll --recovery-key --unlock-key-file="$kf" "$dev" 2>/dev/null | grep -E '^[cbdefghijklnrtuv-]{71}$' | tail -1) || true
    [[ -n $key ]] || { warn "Could not create a recovery key for $label (the password still works)"; return; }
    {
        printf '\n%s  RECOVERY KEY — %s%s\n' "$c_warn" "$label" "$c_off"
        printf '  %s\n' "$key"
        echo "  Write it on paper and keep it safe. It opens this disk if you forget your password."
    } >/dev/tty
    if [[ -z $ANSWERS ]]; then read -r -p "  Press Enter once it's written down... " _ </dev/tty; fi
    ok "Recovery key created for $label (shown on screen only, not logged)"
}
[[ $ROOT_ENCRYPTED == yes ]] && show_recovery "$ROOT_PART" "system disk" "$KF"
[[ -n $VPART ]] && show_recovery "$VPART" "data vault" "$KF2"
shred -u "$KF" 2>/dev/null; KF=""
[[ -n ${KF2:-} ]] && { shred -u "$KF2" 2>/dev/null; KF2=""; }

# ------------------------------------------------------------------ modules
section "Copying arch-setup into the new system"
rsync -a --delete --exclude .git --exclude logs --exclude '__pycache__' --exclude scripts "$SETUP_DIR/" "$MNT/opt/arch-setup/"
chown -R root:root "$MNT/opt/arch-setup"; chmod -R u=rwX,go=rX "$MNT/opt/arch-setup"   # readable by everyone, writable by root only

run_in() {   # run_in root|user MODULE
    local as=$1 m=$2
    printf '\n%s╔══ %s ══%s\n' "$c_info" "$m" "$c_off"
    local envs=(SETUP_DIR=/opt/arch-setup SETUP_USER="$USERNAME" LOCK_ROOT="$LOCK_ROOT" IN_CHROOT=1
                NONINTERACTIVE="${NONINTERACTIVE:-0}" WARN_LOG=/var/log/arch-setup/warnings.txt)
    if [[ $as == root ]]; then
        arch-chroot "$MNT" env "${envs[@]}" bash "/opt/arch-setup/modules/$m.sh"
    else
        arch-chroot "$MNT" runuser -u "$USERNAME" -- env "${envs[@]}" HOME="/home/$USERNAME" USER="$USERNAME" \
            bash "/opt/arch-setup/modules/$m.sh"
    fi || die "Module $m failed — see $LOG (the disk is left mounted at $MNT for inspection)"
}
install -d -m 0755 "$MNT/var/log/arch-setup"
arch-chroot "$MNT" install -o "$USERNAME" -m 0666 /dev/null /var/log/arch-setup/warnings.txt
for m in 10-base 20-network 30-firewall 40-hardening 50-performance 55-gaming 60-storage 70-snapshots 80-login; do run_in root "$m"; done
run_in user 90-aur
run_in root 99-finalize

# ------------------------------------------------------------------ first login (stage 2)
section "Preparing the first login"
H=$MNT/home/$USERNAME
install -d "$H/.config/hypr"
cat >"$H/.config/hypr/hyprland.lua" <<EOF
-- arch-setup: temporary first-login config. The setup window below installs the real
-- desktop (Caelestia), which replaces this file. SUPER+Q opens a terminal if needed.
hl.config({ input = { kb_layout = "$XKB_LAYOUT", kb_variant = "$XKB_VARIANT" },
            ecosystem = { no_update_news = true, no_donation_nag = true } })
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
hl.bind("SUPER + Q", hl.dsp.exec_cmd("foot"))
hl.on("hyprland.start", function()
    hl.exec_cmd("foot --title arch-setup /opt/arch-setup/firstboot/finish-setup.sh")
end)
EOF
arch-chroot "$MNT" chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config"
install -m 0644 "$LOG" "$MNT/var/log/arch-setup/stage1.log" 2>/dev/null || true

section "Finishing"
rm -f "$MNT/etc/sudoers.d/99-arch-setup-install"
arch-chroot "$MNT" visudo -cq || die "sudoers check failed"
ln -sf /run/systemd/resolve/stub-resolv.conf "$MNT/etc/resolv.conf"
sync
umount -R "$MNT"
[[ $ROOT_ENCRYPTED == yes ]] && cryptsetup close root
ok "Stage 1 complete"
cat <<EOF

${c_ok}The base system is installed.${c_off}
  1. Remove the USB stick, then reboot:  ${c_ok}reboot${c_off}
$([[ $ROOT_ENCRYPTED == yes ]] && echo "  2. Type your disk password when asked (your keyboard layout works there)")
  3. Log in as ${c_ok}$USERNAME${c_off}. A window opens and finishes the desktop (~10-20 min, asks your password once).
EOF
