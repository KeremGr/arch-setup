#!/usr/bin/env bash
# Snapshot-ready btrfs layout + snapper + snap-pac + grub-btrfs (boot menu).
#   @           /                      (snapshotted before/after every pacman run)
#   @snapshots  /.snapshots            (separate so rollbacks don't eat snapshots)
#   @pkg        /var/cache/pacman/pkg  (excluded from snapshots)
#   @home       /home                  (created at next boot, see migrate-home.sh;
#                                       a root rollback never touches your files)
source "$(dirname "$0")/../lib.sh"
require_root

ROOT_SRC=$(findmnt -no SOURCE / | sed 's/\[.*//')
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_SRC")
[[ $(findmnt -no FSTYPE /) == btrfs ]] || die "Root is not btrfs"
TOP=/run/arch-setup/btrfs-top
install -d "$TOP"
mountpoint -q "$TOP" || mount -o subvolid=5 "$ROOT_SRC" "$TOP"
trap 'umount "$TOP" 2>/dev/null || true' EXIT
OPTS="noatime,compress=zstd:3,ssd,discard=async,space_cache=v2"

section "@snapshots"
if [[ ! -f /etc/snapper/configs/root ]]; then
    [[ -e /.snapshots ]] && { btrfs subvolume delete /.snapshots 2>/dev/null || rmdir /.snapshots; }
    snapper --no-dbus -c root create-config /
    btrfs subvolume delete /.snapshots >/dev/null   # snapper made a nested one; use a top-level one instead
    mkdir /.snapshots
fi
[[ -d $TOP/@snapshots ]] || btrfs subvolume create "$TOP/@snapshots" >/dev/null
set_block /etc/fstab snapshots <<CONF
UUID=$ROOT_UUID  /.snapshots  btrfs  subvol=/@snapshots,$OPTS  0 0
CONF
mountpoint -q /.snapshots || { live systemctl daemon-reload; mount /.snapshots; }
chmod 750 /.snapshots; chown :wheel /.snapshots
ok "/.snapshots on its own subvolume"

section "@pkg (package cache, not snapshotted)"
if ! mountpoint -q /var/cache/pacman/pkg; then
    [[ -d $TOP/@pkg ]] || btrfs subvolume create "$TOP/@pkg" >/dev/null
    cp -a --reflink=always /var/cache/pacman/pkg/. "$TOP/@pkg/" 2>/dev/null || true
    set_block /etc/fstab pkg <<CONF
UUID=$ROOT_UUID  /var/cache/pacman/pkg  btrfs  subvol=/@pkg,$OPTS  0 0
CONF
    live systemctl daemon-reload
    find /var/cache/pacman/pkg -mindepth 1 -delete
    mount /var/cache/pacman/pkg
fi
ok "/var/cache/pacman/pkg on @pkg"

section "snapper policy"
snapper --no-dbus -c root set-config \
    TIMELINE_CREATE=no NUMBER_CLEANUP=yes NUMBER_LIMIT=15 NUMBER_LIMIT_IMPORTANT=5 \
    ALLOW_GROUPS=wheel SYNC_ACL=yes
ok "root: snapshot before+after every package change, keep last 15"
systemctl enable snapper-cleanup.timer snapper-timeline.timer
systemctl enable grub-btrfsd.service
ok "Snapshots will appear in the GRUB menu"

section "Keep kernel files inside snapshots"
# /boot is the FAT EFI partition and is NOT in snapshots. Copy it into the root
# subvolume right before snap-pac takes its pre-snapshot, so every snapshot
# carries the exact kernel+initramfs it was made with (for full restores).
write_file /etc/pacman.d/hooks/00-boot-backup.hook <<'CONF'
[Trigger]
Operation = Upgrade
Operation = Install
Operation = Remove
Type = Path
Target = usr/lib/modules/*/vmlinuz
Target = usr/lib/initcpio/*
Target = usr/lib/modules/*/extramodules/*
Target = usr/lib/firmware/*

[Action]
Description = Copying /boot into the root subvolume (for snapshots)...
When = PreTransaction
Exec = /usr/bin/rsync -a --delete /boot/ /.bootbackup/
CONF

section "/home migration (runs at next boot, before login)"
install -D -m 0755 "$SETUP_DIR/files/migrate-home.sh" /usr/local/lib/arch-setup/migrate-home.sh
write_file /etc/systemd/system/arch-setup-migrate-home.service <<'CONF'
[Unit]
Description=arch-setup: move /home onto its own btrfs subvolume
DefaultDependencies=no
After=systemd-remount-fs.service
Before=local-fs.target systemd-user-sessions.service display-manager.service
ConditionPathExists=!/var/lib/arch-setup/home-migrated

[Service]
Type=oneshot
ExecStart=/usr/local/lib/arch-setup/migrate-home.sh
TimeoutStartSec=30min
StandardOutput=journal+console

[Install]
WantedBy=local-fs.target
CONF
live systemctl daemon-reload
if [[ $(findmnt -no FSROOT /home 2>/dev/null) == /@home ]]; then
    install -d "$STATE_DIR"; touch "$STATE_DIR/home-migrated"
    ok "/home already on @home"
elif [[ -f $STATE_DIR/home-migrated ]]; then
    ok "/home already on @home"
else
    systemctl enable arch-setup-migrate-home.service
    ok "Armed: /home moves to @home on next boot (instant copy via reflinks)"
fi
