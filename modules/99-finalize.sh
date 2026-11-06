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

section "Password tool"
install -D -m 0755 "$SETUP_DIR/files/arch-setup-passwd" /usr/local/bin/arch-setup-passwd
ok "Change your password with: sudo arch-setup-passwd (keeps disk encryption + GRUB in sync)"

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
if [[ $IN_CHROOT == 1 ]]; then
    ok "The first-login setup runs this check when it finishes"
else
    systemctl enable arch-setup-firstboot.service
    ok "Armed"
fi
