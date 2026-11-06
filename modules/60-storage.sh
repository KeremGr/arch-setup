#!/usr/bin/env bash
# Optional extra data disk (only if you picked one during install):
#   BRIDGE  exFAT, readable from Windows/macOS (optional)
#   VAULT   LUKS2-encrypted btrfs (@storage = your files, @backups = restic backups).
#           It opens with YOUR login password when you log in (no TPM, no extra prompt);
#           a paper recovery key also opens it.
# Daily encrypted, deduplicated restic backups of /home and /etc into @backups.
# Partitioning + encryption happen in the installer (stage 1), behind the disk confirmation.
source "$(dirname "$0")/../lib.sh"
require_root
: "${SETUP_USER:?}"
USER_UID=$(id -u "$SETUP_USER"); USER_GID=$(id -g "$SETUP_USER")
BRIDGE=/dev/disk/by-partlabel/BRIDGE
VAULT=/dev/disk/by-partlabel/VAULT

section "Extra data disk"
[[ -n $HDD_ID ]] || { info "No extra data disk chosen — skipping storage setup"; exit 0; }
[[ -b $VAULT ]] || { warn "No VAULT partition found (expected on $HDD_ID) — skipping storage setup"; exit 0; }
cryptsetup isLuks "$VAULT" || die "$VAULT is not LUKS-encrypted — refusing to use it"
ok "VAULT found (LUKS2)"

install -d -m 0755 /data
install -d -m 0755 -o "$SETUP_USER" -g "$USER_GID" /data/storage
install -d -m 0700 /data/backups
# Vault: never opened at boot (no prompt, no TPM); opened at login by PAM below.
set_block /etc/fstab vault <<CONF
/dev/mapper/vault  /data/storage  btrfs  subvol=/@storage,noatime,compress=zstd:3,noauto,nofail  0 0
/dev/mapper/vault  /data/backups  btrfs  subvol=/@backups,noatime,compress=zstd:3,noauto,nofail  0 0
CONF
if [[ -b $BRIDGE ]]; then
    install -d -m 0755 /mnt/bridge
    BRIDGE_UUID=$(blkid -s UUID -o value "$BRIDGE")
    set_block /etc/fstab bridge <<CONF
UUID=$BRIDGE_UUID  /mnt/bridge  exfat  noatime,nofail,uid=$USER_UID,gid=$USER_GID,dmask=022,fmask=133,nosuid,nodev,noexec  0 0
CONF
    ok "BRIDGE (exFAT share) mounts at /mnt/bridge"
fi

section "Vault opens with your login password"
write_file /usr/local/lib/arch-setup/vault-unlock.sh 0755 <<'SH'
#!/bin/bash
# Called by PAM (greetd login) with the typed password on stdin. Opens + mounts the vault.
# Always exits 0 so login is never blocked by it.
. /etc/arch-setup/install.conf 2>/dev/null
[[ ${PAM_USER:-} == "${USERNAME:-}" ]] || exit 0
[[ -e /dev/mapper/vault ]] || { IFS= read -r -d '' pw; printf '%s' "$pw" | cryptsetup open --key-file=- /dev/disk/by-partlabel/VAULT vault 2>/dev/null; unset pw; }
[[ -e /dev/mapper/vault ]] && { mountpoint -q /data/storage || mount /data/storage; mountpoint -q /data/backups || mount /data/backups; }
exit 0
SH
PAMF=/etc/pam.d/greetd
[[ -f $PAMF ]] || die "$PAMF missing (greetd not installed?)"
if ! grep -q vault-unlock "$PAMF"; then
    backup "$PAMF"
    sed -i '/^auth\s\+include\s\+system-local-login/a auth       optional     pam_exec.so expose_authtok quiet /usr/local/lib/arch-setup/vault-unlock.sh' "$PAMF"
fi
grep -q vault-unlock "$PAMF" || die "Could not add the vault unlock to $PAMF"
ok "Login opens the vault (password changes: run 'arch-setup-passwd', not plain passwd)"

section "Automatic backups (restic → encrypted vault)"
install -d -m 0755 /etc/arch-setup     # readable: install.conf (no secrets); restic.pass itself is 0600
[[ -s /etc/arch-setup/restic.pass ]] || { head -c 48 /dev/urandom | base64 >/etc/arch-setup/restic.pass; chmod 0600 /etc/arch-setup/restic.pass; }
write_file /etc/arch-setup/restic-excludes.txt <<'CONF'
/home/*/.cache
/home/*/.local/share/Trash
/home/*/.local/share/spotify-launcher
/home/*/.cargo/registry
/home/*/.rustup/toolchains
/home/*/.npm
/home/*/.local/share/nvim/lazy
/home/*/**/node_modules
/home/*/**/target/debug
/home/*/**/target/release
/home/*/.snapshots
CONF
write_file /etc/systemd/system/restic-backup.service <<'CONF'
[Unit]
Description=Encrypted backup of /home and /etc to the vault
# Runs only while the vault is open (it opens when you log in)
ConditionPathIsMountPoint=/data/backups

[Service]
Type=oneshot
Environment=RESTIC_REPOSITORY=/data/backups/restic RESTIC_PASSWORD_FILE=/etc/arch-setup/restic.pass RESTIC_CACHE_DIR=/var/cache/restic
CacheDirectory=restic
Nice=19
IOSchedulingClass=idle
ExecStartPre=/bin/sh -c '/usr/bin/restic cat config >/dev/null 2>&1 || /usr/bin/restic init'
ExecStart=/usr/bin/restic backup --exclude-caches --exclude-file=/etc/arch-setup/restic-excludes.txt --tag auto /home /etc
ExecStartPost=/usr/bin/restic forget --tag auto --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
CONF
write_file /etc/systemd/system/restic-backup.timer <<'CONF'
[Unit]
Description=Daily encrypted backup

[Timer]
OnCalendar=daily
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
CONF
live systemctl daemon-reload
systemctl enable restic-backup.timer
ok "Daily backup enabled (7 daily, 4 weekly, 6 monthly kept)"
