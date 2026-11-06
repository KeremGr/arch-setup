#!/usr/bin/env bash
# Gaming (only if chosen): Steam, GameMode, MangoHud and the 32-bit graphics drivers games need.
# Everything comes from the official Arch repos (multilib = Arch's own 32-bit repo).
source "$(dirname "$0")/../lib.sh"
require_root
: "${SETUP_USER:?}"
[[ $WANT_GAMING == y ]] || { info "Gaming not chosen — skipping"; exit 0; }

section "multilib (official 32-bit packages)"
if ! pacman-conf --repo-list | grep -qx multilib; then
    backup /etc/pacman.conf
    sed -i '/^#\[multilib\]$/,/^#Include/ s/^#//' /etc/pacman.conf
fi
pacman-conf --repo-list | grep -qx multilib || die "Could not enable multilib"
pacman -Sy --noconfirm >/dev/null
ok "multilib enabled"

section "Steam, GameMode, MangoHud + 32-bit drivers for GPU '$GPU'"
case $GPU in
    nvidia)        DRV=(lib32-nvidia-utils) ;;
    nvidia-hybrid) DRV=(lib32-nvidia-utils lib32-mesa lib32-vulkan-intel lib32-vulkan-radeon) ;;
    amd)           DRV=(lib32-mesa lib32-vulkan-radeon) ;;
    intel)         DRV=(lib32-mesa lib32-vulkan-intel) ;;
    *)             DRV=(lib32-mesa) ;;
esac
# Drivers first, so Steam doesn't ask which Vulkan driver to use
pacman -S --needed --noconfirm "${DRV[@]}"
pacman -S --needed --noconfirm steam gamemode lib32-gamemode mangohud lib32-mangohud
usermod -aG gamemode "$SETUP_USER"
ok "Steam ready. In a game's launch options: 'gamemoderun mangohud %command%' (performance mode + FPS overlay)"
