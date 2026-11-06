#!/usr/bin/env bash
# greetd + tuigreet: tiny text login (smallest attack surface), starts Hyprland.
source "$(dirname "$0")/../lib.sh"
require_root
: "${SETUP_USER:?}"

section "Login screen"
pacman -S --needed --noconfirm greetd greetd-tuigreet
command -v start-hyprland >/dev/null || die "start-hyprland not found"
write_file /etc/greetd/config.toml <<'CONF'
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --asterisks --greeting 'arch · hyprland · caelestia' --cmd start-hyprland"
user = "greeter"
CONF
# Switch takes effect at reboot (stopping SDDM now would end your session).
systemctl disable sddm.service 2>/dev/null || true
systemctl enable greetd.service
ok "greetd enabled, SDDM disabled (applies after reboot)"
