#!/usr/bin/env bash
# Kernel + system hardening that does NOT cost FPS or break Steam/Flatpak/browsers.
source "$(dirname "$0")/../lib.sh"
require_root
: "${SETUP_USER:?}" "${LOCK_ROOT:?}"

section "sysctl hardening"
write_file /etc/sysctl.d/90-hardening.conf <<'CONF'
# Kernel info leaks / attack surface
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
kernel.kexec_load_disabled = 1
dev.tty.ldisc_autoload = 0
vm.unprivileged_userfaultfd = 0
kernel.yama.ptrace_scope = 1
fs.suid_dumpable = 0
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
# Unprivileged user namespaces stay ON: browser/Flatpak sandboxes need them.

# Network
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
CONF
live sysctl --system >/dev/null; ok "sysctl hardening written (active now / from first boot)"

section "Core dumps off (they can contain passwords/keys)"
write_file /etc/systemd/coredump.conf.d/10-disable.conf <<'CONF'
[Coredump]
Storage=none
ProcessSizeMax=0
CONF
write_file /etc/security/limits.d/10-nocore.conf <<'CONF'
* hard core 0
CONF

section "sudo"
TMP=$(mktemp)
cat >"$TMP" <<'CONF'
Defaults timestamp_timeout=5
Defaults passwd_tries=3
Defaults use_pty
Defaults logfile="/var/log/sudo.log"
CONF
visudo -cqf "$TMP" || die "sudoers syntax check failed (nothing changed)"
install -m 0440 "$TMP" /etc/sudoers.d/10-hardening; rm -f "$TMP"
visudo -cq || die "Global sudoers check failed!"
ok "sudo: 5 min timeout, 3 tries, pty, logged to /var/log/sudo.log"

section "AppArmor"
pacman -S --needed --noconfirm apparmor
systemctl enable apparmor.service
GRUB=/etc/default/grub
LSM='lsm=landlock,lockdown,yama,integrity,apparmor,bpf'
if ! grep -q 'apparmor' "$GRUB"; then
    backup "$GRUB"
    sed -i -E "s/^(GRUB_CMDLINE_LINUX_DEFAULT=\")(.*)\"/\1\2 $LSM\"/" "$GRUB"
fi
ok "AppArmor on kernel command line (active after reboot)"

section "Root account"
if passwd -S root | awk '{print $2}' | grep -q '^L'; then
    ok "root already locked"
elif [[ $LOCK_ROOT == y ]]; then
    id -nG "$SETUP_USER" | grep -qw wheel || die "$SETUP_USER is not in wheel — refusing to lock root."
    passwd -l root >/dev/null && ok "root password locked (admin via sudo only)"
else
    warn "root lock skipped (your choice)"
fi
