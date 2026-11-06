#!/usr/bin/env bash
# Shared helpers for arch-setup. Sourced by install.sh and every module.
set -euo pipefail
shopt -s nullglob

SETUP_DIR=${SETUP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
c_info=$'\e[1;34m'; c_ok=$'\e[1;32m'; c_warn=$'\e[1;33m'; c_err=$'\e[1;31m'; c_dim=$'\e[2m'; c_off=$'\e[0m'

info()    { printf '%s==>%s %s\n' "$c_info" "$c_off" "$*"; }
ok()      { printf '%s  ✓%s %s\n' "$c_ok" "$c_off" "$*"; }
warn()    { printf '%s  !%s %s\n' "$c_warn" "$c_off" "$*" | tee -a "${WARN_LOG:-/dev/null}" >&2; }
die()     { printf '%s  ✗ %s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }
section() { printf '\n%s━━━ %s ━━━%s\n' "$c_info" "$*" "$c_off"; }

require_root() { [[ $EUID -eq 0 ]] || die "This module must run as root (install.sh handles that)."; }
require_user() { [[ $EUID -ne 0 ]] || die "This module must run as your normal user, not root."; }

# Back up a file once, keeping the original pre-setup version.
backup() {
    local f=$1
    if [[ -e $f && ! -e $f.pre-arch-setup ]]; then
        cp -a "$f" "$f.pre-arch-setup"
        info "Backed up $f -> $f.pre-arch-setup"
    fi
}

# write_file PATH [MODE] < content   — idempotent, backs up the original once.
write_file() {
    local path=$1 mode=${2:-0644} tmp
    tmp=$(mktemp)
    cat >"$tmp"
    if [[ -f $path ]] && cmp -s "$tmp" "$path"; then
        rm -f "$tmp"; ok "$path unchanged"
    else
        backup "$path"
        install -D -m "$mode" "$tmp" "$path"; rm -f "$tmp"; ok "Wrote $path"
    fi
}

# Replace (or append) a marked block inside a file. Usage: set_block FILE NAME < content
set_block() {
    local f=$1 name=$2 begin="# >>> arch-setup:$2 >>>" end="# <<< arch-setup:$2 <<<" tmp content
    content=$(cat)
    backup "$f"
    tmp=$(mktemp)
    if [[ -f $f ]]; then
        awk -v b="$begin" -v e="$end" '$0==b{skip=1;next} $0==e{skip=0;next} !skip' "$f" >"$tmp"
    fi
    printf '%s\n%s\n%s\n' "$begin" "$content" "$end" >>"$tmp"
    if [[ -f $f ]] && cmp -s "$tmp" "$f"; then rm -f "$tmp"; ok "$f block '$name' unchanged"; return; fi
    if [[ -f $f ]]; then cat "$tmp" >"$f"; else install -D -m 0644 "$tmp" "$f"; fi
    rm -f "$tmp"; ok "Updated block '$name' in $f"
}

# Unattended runs (VM tests) never auto-approve anything: every question answers "no".
confirm() { local r; [[ ${NONINTERACTIVE:-0} == 1 ]] && { warn "unattended: '$1' -> no"; return 1; }
            read -r -p "$1 [y/N] " r </dev/tty; [[ $r =~ ^[Yy]$ ]]; }

pkg_installed() { pacman -Qq "$1" &>/dev/null; }

# Choices made during install (answers to the stage-1 questions). Nothing here is guessed:
# no answer = neutral default, and no extra data disk is touched.
ARCH_SETUP_CONF=${ARCH_SETUP_CONF:-/etc/arch-setup/install.conf}
# shellcheck source=/dev/null
[[ -r $ARCH_SETUP_CONF ]] && source "$ARCH_SETUP_CONF"
: "${KEYMAP:=us}" "${XKB_LAYOUT:=us}" "${XKB_VARIANT:=}" "${DATA_DISK:=}" "${MIRROR_COUNTRIES:=}" "${ROOT_ENCRYPTED:=no}" "${GPU:=}"
HDD_ID=$DATA_DISK     # /dev/disk/by-id/... picked by the user, or empty
# Apps & preferences (stage-1 questions). Defaults = the recommended setup.
: "${BROWSER:=librewolf}" "${WANT_SPOTIFY:=y}" "${WANT_DISCORD:=y}" "${DEV_TOOLS:=full}"
: "${WANT_GAMING:=n}" "${WANT_EXTRAS:=n}" "${WANT_FLATPAK:=n}" "${WANT_BLUETOOTH:=y}" "${WANT_PRINTING:=n}"
: "${WANT_LTS:=y}" "${START_SCHEME:=autumn-forest}" "${DNS_PROVIDER:=cloudflare}"
: "${IDLE_LOCK_MIN:=10}" "${IDLE_SLEEP_MIN:=0}" "${NIGHT_LIGHT:=y}"
STATE_DIR=/var/lib/arch-setup

# Install mode: the modules also run inside arch-chroot from the Arch ISO. There, nothing is
# "running" (no systemd, no network manager, no desktop), so live-only actions are skipped
# and take effect at the first boot instead.
if [[ -z ${IN_CHROOT:-} ]]; then
    if systemd-detect-virt --chroot -q 2>/dev/null; then IN_CHROOT=1; else IN_CHROOT=0; fi
fi
live() { if [[ $IN_CHROOT == 1 ]]; then info "(install mode, applies at first boot) skipped: $*"; return 0; fi; "$@"; }

# GPU: from the install answers; if missing (e.g. an older install), detected from the PCI bus.
# nvidia = NVIDIA only · nvidia-hybrid = laptop iGPU + NVIDIA · amd · intel · other
detect_gpu() {
    local v
    v=$(lspci -nn 2>/dev/null | grep -Ei 'VGA|3D|Display' || true)
    local n=0 a=0 i=0
    grep -qi '\[10de:' <<<"$v" && n=1
    grep -qi '\[1002:' <<<"$v" && a=1
    grep -qi '\[8086:' <<<"$v" && i=1
    if (( n && (a || i) )); then echo nvidia-hybrid
    elif (( n )); then echo nvidia
    elif (( a )); then echo amd
    elif (( i )); then echo intel
    else echo other; fi
}
[[ -n $GPU ]] || GPU=$(detect_gpu)
has_nvidia() { [[ $GPU == nvidia || $GPU == nvidia-hybrid ]]; }
