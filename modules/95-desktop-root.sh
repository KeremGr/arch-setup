#!/usr/bin/env bash
# Root steps that need the desktop packages (installed by Caelestia in the user modules):
# exact-command sudo rule for folder colours, performance power profile.
source "$(dirname "$0")/../lib.sh"
require_root
: "${SETUP_USER:?}"

section "Folder icon colours follow your scheme (exact-command sudo rule)"
# Caelestia runs `sudo -n papirus-folders -C <colour> -u`. Instead of allowing
# papirus-folders with ANY arguments (Caelestia's suggestion), allow only these
# exact commands — nothing else can be run password-less.
if command -v papirus-folders >/dev/null; then
    TMP=$(mktemp)
    papirus-folders -l --theme Papirus-Dark 2>/dev/null | sed -E 's/^[[:space:]>*]+//; s/[[:space:]].*$//' | grep -E '^[a-z]+$' | sort -u |
        while read -r c; do echo "$SETUP_USER ALL=(root) NOPASSWD: /usr/bin/papirus-folders -C $c -u"; done >"$TMP"
    if [[ -s $TMP ]] && visudo -cqf "$TMP"; then
        install -m 0440 "$TMP" /etc/sudoers.d/50-caelestia-papirus
        visudo -cq && ok "$(wc -l <"$TMP") exact papirus-folders commands allowed"
    else
        warn "Could not build papirus sudo rule — folder colours stay default"
    fi
    rm -f "$TMP"
fi

section "Power profile: performance"
if pkg_installed power-profiles-daemon; then
    systemctl enable --now power-profiles-daemon.service
    for _ in {1..10}; do powerprofilesctl list &>/dev/null && break; sleep 1; done
    # Not every CPU/firmware offers 'performance' (VMs, some desktops): then keep 'balanced'.
    if powerprofilesctl list 2>/dev/null | grep -qE '^\*? *performance:'; then
        powerprofilesctl set performance && ok "performance profile (switchable from the Caelestia panel)"
    else
        ok "This CPU has no 'performance' profile — keeping 'balanced' (switchable from the Caelestia panel)"
    fi
else
    warn "power-profiles-daemon not installed — power profile unchanged"
fi
