#!/usr/bin/env bash
# Final system steps: GRUB password protection, rebuild initramfs + GRUB once,
# and arm the first-boot check + golden snapshot.
source "$(dirname "$0")/../lib.sh"
require_root
: "${SETUP_USER:?}"

if [[ -f /etc/grub.d/01_password ]]; then
    section "GRUB: menu editing needs your password, normal boot stays automatic"
    write_file /usr/local/lib/arch-setup/grub-unrestricted.sh 0755 <<'SH'
#!/bin/sh
# Normal boot entries need no password; editing/console/snapshots do.
sed -i 's/^CLASS="--class gnu-linux --class gnu --class os"$/CLASS="--class gnu-linux --class gnu --class os --unrestricted"/' /etc/grub.d/10_linux
SH
    /usr/local/lib/arch-setup/grub-unrestricted.sh
    grep -q -- '--unrestricted"' /etc/grub.d/10_linux || die "Could not mark normal boot as unrestricted — NOT regenerating GRUB"
    write_file /etc/pacman.d/hooks/90-grub-unrestricted.hook <<'HOOK'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = grub

[Action]
Description = Keeping normal boot password-free (arch-setup)...
When = PostTransaction
Exec = /bin/sh -c '/usr/local/lib/arch-setup/grub-unrestricted.sh && grub-mkconfig -o /boot/grub/grub.cfg'
HOOK
fi

section "Password + update tools"
install -D -m 0755 "$SETUP_DIR/files/arch-setup-passwd" /usr/local/bin/arch-setup-passwd
ok "Change your password with: sudo arch-setup-passwd (keeps disk encryption + GRUB in sync)"
install -D -m 0755 "$SETUP_DIR/files/arch-setup-update" /usr/local/bin/arch-setup-update
install -D -m 0755 "$SETUP_DIR/files/arch-setup-vpn" /usr/local/bin/arch-setup-vpn
install -D -m 0755 "$SETUP_DIR/files/night-light-toggle" /usr/local/bin/night-light-toggle
ok "Get reviewed updates with: arch-setup-update (signature-checked, snapshot first)"

section "Dual boot ready (Windows now or later)"
grep -q '^GRUB_DISABLE_OS_PROBER=false' /etc/default/grub || echo 'GRUB_DISABLE_OS_PROBER=false' >>/etc/default/grub
pacman -S --needed --noconfirm os-prober ntfs-3g >/dev/null
install -D -m 0755 "$SETUP_DIR/files/os-detect.sh" /usr/local/lib/arch-setup/os-detect.sh
write_file /etc/systemd/system/arch-setup-os-detect.service <<'CONF'
[Unit]
Description=arch-setup: find other systems (e.g. Windows) for the GRUB menu, keep GRUB first
After=local-fs.target

[Service]
Type=oneshot
Nice=10
IOSchedulingClass=idle
ExecStart=/usr/local/lib/arch-setup/os-detect.sh

[Install]
WantedBy=multi-user.target
CONF
systemctl enable arch-setup-os-detect.service >/dev/null 2>&1
ok "Other systems are found at every boot; GRUB stays first in the boot order"

section "Rebuilding initramfs + GRUB (once)"
mkinitcpio -P
[[ -d /boot/grub ]] || die "/boot/grub not found"
grub-mkconfig -o /boot/grub/grub.cfg
if [[ -f /etc/grub.d/01_password ]]; then
    grep -q password_pbkdf2 /boot/grub/grub.cfg && grep -q -- '--unrestricted' /boot/grub/grub.cfg \
        || die "GRUB password block missing from grub.cfg"
    ok "GRUB locked: normal boot free; editing, console and snapshots need your password"
fi
ok "Boot files rebuilt"

section "First-boot check + golden snapshot (runs automatically after reboot)"
install -D -m 0755 "$SETUP_DIR/files/firstboot.sh" /usr/local/lib/arch-setup/firstboot.sh
write_file /etc/arch-setup/firstboot.env <<CONF
SETUP_USER=$SETUP_USER
LOCK_ROOT=${LOCK_ROOT:-n}
CONF
write_file /etc/systemd/system/arch-setup-firstboot.service <<CONF
[Unit]
Description=arch-setup: verify the system and take the golden snapshot
After=multi-user.target arch-setup-migrate-home.service network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/arch-setup/firstboot-done

[Service]
Type=oneshot
EnvironmentFile=/etc/arch-setup/firstboot.env
ExecStart=/usr/local/lib/arch-setup/firstboot.sh

[Install]
WantedBy=multi-user.target
CONF
live systemctl daemon-reload
if [[ ${ARCH_SETUP_UPDATE:-0} == 1 ]]; then
    ok "Update: first-boot check not re-armed (it already ran)"
elif [[ $IN_CHROOT == 1 ]]; then
    ok "The first-login setup runs this check when it finishes"
else
    systemctl enable arch-setup-firstboot.service
    ok "Armed"
fi
