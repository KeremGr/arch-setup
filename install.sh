#!/usr/bin/env bash
# arch-setup — one command for the whole secure, fast Caelestia desktop.
#   bash ~/arch-setup/install.sh            run everything
#   bash ~/arch-setup/install.sh --from 60  resume from a module after fixing a problem
SETUP_DIR=$(cd "$(dirname "$0")" && pwd)
export SETUP_DIR
source "$SETUP_DIR/lib.sh"
require_user

FROM=00
[[ ${1:-} == --from ]] && FROM=${2:?usage: --from NN}
ROOT_MODULES_A=(10-base 20-network 30-firewall 40-hardening 50-performance 55-gaming 60-storage 70-snapshots 80-login)
USER_MODULES=(90-aur 91-caelestia 92-apps 93-themes)
ROOT_MODULES_B=(95-desktop-root 99-finalize)

mkdir -p "$SETUP_DIR/logs"
LOG=$SETUP_DIR/logs/install-$(date +%F-%H%M%S).log
export WARN_LOG=$SETUP_DIR/logs/warnings.txt; : >"$WARN_LOG"

# ---------------------------------------------------------------- preflight
section "Preflight"
[[ -f /etc/arch-release ]] || die "Not Arch Linux"
[[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || die "Run this from inside your Hyprland session (a terminal on the desktop)"
ping -c1 -W3 archlinux.org &>/dev/null || curl -sfI --max-time 5 https://archlinux.org >/dev/null || die "No internet connection"
(( $(df --output=avail -B1G / | tail -1) >= 15 )) || die "Less than 15 GB free on /"
ok "Arch · Hyprland session · online · disk space OK"

cat <<EOF

${c_info}This will set up the whole system. It will:${c_off}
  • Upgrade Arch; install everything from official, signed repos (+ 15 reviewed AUR packages)
  • DNS-over-TLS to Cloudflare with DNSSEC; firewall (deny incoming); kernel + sudo hardening;
    AppArmor; no core dumps; MAC/IPv6 privacy; optional root-password lock
  • NVIDIA Wayland tuning, early KMS, zram, noatime, faster boot; greetd login screen
  • Optional extra data disk (only the one you choose): exFAT share + encrypted storage & backups
  • btrfs snapshots before every update, bootable from GRUB; /home moved to its own subvolume at next boot
  • Caelestia shell (full), LibreWolf, Code-OSS, Neovim, Spotify+Spicetify, Vesktop — all recolour live
  • Custom schemes Autumn Forest / Nocturne / Cream with matching wallpapers (two-way sync)
  • After the reboot: automatic self-check, golden snapshot, first backup
  It does NOT touch any disk you did not choose.
  Log: $LOG
EOF
read -r -p "Type YES to start: " ans </dev/tty; [[ $ans == YES ]] || die "Cancelled — nothing changed."

LOCK_ROOT=n
confirm "Lock the root password? (recommended: admin only through sudo)" && LOCK_ROOT=y

PASS=""
if [[ ! -b /dev/disk/by-partlabel/VAULT && $FROM < 61 ]]; then
    echo
    info "Choose a passphrase for the encrypted HDD vault."
    echo "   The TPM unlocks it automatically; you only need this if the TPM ever refuses"
    echo "   (BIOS reset, moving the disk). Write it down somewhere safe — it cannot be recovered."
    while :; do
        read -r -s -p "   Passphrase (min 12 chars): " PASS </dev/tty; echo
        read -r -s -p "   Repeat: " p2 </dev/tty; echo
        [[ ${#PASS} -ge 12 && $PASS == "$p2" ]] && break
        warn "Too short or did not match — try again"
    done
    unset p2
fi

DEFAULT_CITY=$(timedatectl show -p Timezone --value); DEFAULT_CITY=${DEFAULT_CITY##*/}; DEFAULT_CITY=${DEFAULT_CITY//_/ }
read -r -p "City for the weather widget [$DEFAULT_CITY]: " WEATHER_CITY </dev/tty
export WEATHER_CITY=${WEATHER_CITY:-$DEFAULT_CITY}

info "Your sudo password (asked once; kept alive only while this runs):"
sudo -v || die "sudo failed"
( while kill -0 $$ 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 30; done ) &
KEEPALIVE=$!

cleanup() {
    sudo -n rm -f /run/arch-setup/luks.pass 2>/dev/null || true
    kill "$KEEPALIVE" 2>/dev/null || true
}
trap cleanup EXIT

if [[ -n $PASS ]]; then
    sudo install -d -m 0700 /run/arch-setup
    printf '%s' "$PASS" | sudo install -m 0600 /dev/stdin /run/arch-setup/luks.pass   # RAM only (tmpfs)
    unset PASS
fi

exec > >(tee -a "$LOG") 2>&1

run_module() {
    local m=$1 as=$2
    [[ ${m%%-*} < $FROM ]] && { info "skip $m (--from $FROM)"; return; }
    printf '\n%s╔══ %s ══%s\n' "$c_info" "$m" "$c_off"
    local rc=0
    if [[ $as == root ]]; then
        sudo env SETUP_DIR="$SETUP_DIR" SETUP_USER="$USER" LOCK_ROOT="$LOCK_ROOT" WARN_LOG="$WARN_LOG" \
            bash "$SETUP_DIR/modules/$m.sh" || rc=$?
    else
        bash "$SETUP_DIR/modules/$m.sh" || rc=$?
    fi
    if (( rc != 0 )); then
        printf '\n%s✗ Module %s failed (exit %s).%s\n' "$c_err" "$m" "$rc" "$c_off"
        echo "  Nothing after it was run. Full log: $LOG"
        echo "  Fix the problem, then resume with:  bash $SETUP_DIR/install.sh --from ${m%%-*}"
        exit "$rc"
    fi
}

for m in "${ROOT_MODULES_A[@]}"; do run_module "$m" root; done
for m in "${USER_MODULES[@]}";   do run_module "$m" user; done
for m in "${ROOT_MODULES_B[@]}"; do run_module "$m" root; done

section "Done"
if [[ -s $WARN_LOG ]]; then warn "Warnings during setup:"; cat "$WARN_LOG"; fi
cat <<EOF

${c_ok}Everything is installed.${c_off} Reboot now. At the next boot:
  1. /home moves onto its own subvolume (a few seconds, before the login screen)
  2. The new login screen (greetd) appears — log in as usual
  3. A self-check runs, then the GOLDEN snapshot + first backup are taken
     Report: ~/arch-setup/firstboot-report.txt

Keyboard: SUPER opens the launcher. Change scheme or wallpaper there — the other follows.
EOF
confirm "Reboot now?" && systemctl reboot
