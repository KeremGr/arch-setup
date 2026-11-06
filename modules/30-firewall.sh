#!/usr/bin/env bash
# UFW: deny all incoming, allow outgoing. Nothing is exposed to the network.
source "$(dirname "$0")/../lib.sh"
require_root

section "Firewall"
pacman -S --needed --noconfirm ufw
if [[ $IN_CHROOT == 1 ]]; then
    # Install mode: write the policy; ufw loads it at first boot (it can't touch the
    # ISO's own firewall from inside the chroot).
    sed -i -E 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="DROP"/; s/^DEFAULT_OUTPUT_POLICY=.*/DEFAULT_OUTPUT_POLICY="ACCEPT"/;
               s/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="DROP"/' /etc/default/ufw
    sed -i -E 's/^ENABLED=.*/ENABLED=yes/; s/^LOGLEVEL=.*/LOGLEVEL=low/' /etc/ufw/ufw.conf
    grep -q '^DEFAULT_INPUT_POLICY="DROP"' /etc/default/ufw && grep -q '^ENABLED=yes' /etc/ufw/ufw.conf \
        || die "Could not write the firewall policy"
    systemctl enable ufw.service
    ok "Firewall armed: incoming denied, outgoing allowed (active from the first boot)"
    exit 0
fi
ufw --force reset >/dev/null
rm -f /etc/ufw/*.rules.[0-9]*_[0-9]* 2>/dev/null || true
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed
ufw logging low
ufw --force enable
systemctl enable ufw.service
ufw status verbose
ok "Firewall active: incoming denied, outgoing allowed"
