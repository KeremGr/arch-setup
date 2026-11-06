#!/usr/bin/env bash
# Encrypted DNS (DNS-over-TLS: Cloudflare, Quad9 or Mullvad) with DNSSEC, no router/ISP DNS,
# no LLMNR/mDNS, MAC + IPv6 privacy, and blocking of two leaky endpoints.
source "$(dirname "$0")/../lib.sh"
require_root

section "systemd-resolved: DNS-over-TLS + DNSSEC ($DNS_PROVIDER)"
# Each server is pinned to its TLS name, so nobody in between can impersonate it.
case $DNS_PROVIDER in
    quad9)   DNS_SERVERS="9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net 2620:fe::fe#dns.quad9.net 2620:fe::9#dns.quad9.net" ;;
    mullvad) DNS_SERVERS="194.242.2.2#dns.mullvad.net 2a07:e340::2#dns.mullvad.net" ;;
    *)       DNS_SERVERS="1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com 2606:4700:4700::1111#cloudflare-dns.com 2606:4700:4700::1001#cloudflare-dns.com" ;;
esac
rm -f /etc/systemd/resolved.conf.d/10-cloudflare-dot.conf     # older name
write_file /etc/systemd/resolved.conf.d/10-encrypted-dns.conf <<CONF
[Resolve]
DNS=$DNS_SERVERS
# Never fall back to anyone else (the default fallback includes Google & Quad9)
FallbackDNS=
# Route ALL queries to the servers above, not to per-link (router) DNS
Domains=~.
DNSOverTLS=yes
DNSSEC=yes
LLMNR=no
MulticastDNS=no
Cache=yes
DNSStubListener=yes
CONF

write_file /etc/NetworkManager/conf.d/10-dns.conf <<'CONF'
[main]
dns=systemd-resolved
CONF

section "MAC address + IPv6 privacy"
write_file /etc/NetworkManager/conf.d/20-privacy.conf <<'CONF'
[device]
wifi.scan-rand-mac-address=yes

[connection]
# Per-network stable random MAC: hides the real hardware MAC, but the router
# still sees the same address each time (stable IP / DHCP lease).
ethernet.cloned-mac-address=stable
wifi.cloned-mac-address=stable
ipv6.ip6-privacy=2
CONF

write_file /etc/NetworkManager/conf.d/30-no-hostname.conf <<'CONF'
# Don't tell the router / network your computer's name
[connection]
ipv4.dhcp-send-hostname=false
ipv6.dhcp-send-hostname=false
CONF

section "Block leaky endpoints"
# ip-api.com: plain-HTTP IP geolocation used by the shell's weather widget when
#             no city is set (we set one, this is a second safety net).
# music.163.com: NetEase (China) lyrics lookups made by the shell's lyrics feature.
set_block /etc/hosts privacy-blocks <<'CONF'
0.0.0.0 ip-api.com
0.0.0.0 music.163.com
0.0.0.0 interface.music.163.com
CONF

section "No LAN announcements"
systemctl mask avahi-daemon.service avahi-daemon.socket >/dev/null 2>&1 || true
ok "avahi masked (the PC doesn't advertise itself on the local network)"

systemctl enable systemd-resolved.service NetworkManager.service
if [[ $IN_CHROOT == 1 ]]; then
    # The ISO bind-mounts its own resolv.conf here; the installer links it after leaving the chroot.
    ok "resolv.conf -> systemd-resolved is set when the install finishes"
    exit 0      # everything below needs a running network stack; it applies at first boot
fi

# Existing connections: ignore router DNS (new ones follow 10-encrypted-dns.conf: Domains=~.)
while IFS=: read -r uuid type; do
    [[ $type == 802-3-ethernet || $type == 802-11-wireless ]] || continue
    nmcli connection modify "$uuid" ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes
    ok "Connection $uuid ignores router DNS"
done < <(nmcli -t -f UUID,TYPE connection show)

systemctl start systemd-resolved.service
if [[ $(readlink /etc/resolv.conf) != /run/systemd/resolve/stub-resolv.conf ]]; then
    backup /etc/resolv.conf
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
fi
ok "/etc/resolv.conf -> systemd-resolved"

systemctl restart systemd-resolved NetworkManager
info "Waiting for network..."
for _ in {1..30}; do nmcli -t -f STATE general | grep -q '^connected' && break; sleep 1; done
while IFS=: read -r uuid type; do
    [[ $type == 802-3-ethernet || $type == 802-11-wireless ]] || continue
    nmcli connection up "$uuid" >/dev/null && ok "Re-activated $uuid"
done < <(nmcli -t -f UUID,TYPE connection show --active)
for _ in {1..30}; do resolvectl query archlinux.org &>/dev/null && break; sleep 1; done

if ! resolvectl query archlinux.org &>/dev/null; then
    warn "DNS failed with strict DNSSEC — retrying with DNSSEC=allow-downgrade (TLS still protects every query)"
    sed -i 's/^DNSSEC=yes/DNSSEC=allow-downgrade/' /etc/systemd/resolved.conf.d/10-encrypted-dns.conf
    systemctl restart systemd-resolved
    for _ in {1..20}; do resolvectl query archlinux.org &>/dev/null && break; sleep 1; done
fi
if ! resolvectl query archlinux.org &>/dev/null; then
    rm -f /etc/systemd/resolved.conf.d/10-encrypted-dns.conf; systemctl restart systemd-resolved
    die "Encrypted DNS does not work on this network — reverted to normal DNS so you stay online."
fi
ok "DNS over TLS works"
resolvectl query dnssec-failed.org &>/dev/null && warn "DNSSEC validation NOT active" || ok "DNSSEC validation active"
