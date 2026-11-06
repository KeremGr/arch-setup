#!/usr/bin/env bash
# Runs once after the first reboot: verify everything, then take the golden snapshot.
set -uo pipefail
STATE=/var/lib/arch-setup
REPORT=$STATE/firstboot-report.txt
# Same settings whether started by systemd or by hand with sudo
[[ -r /etc/arch-setup/firstboot.env ]] && . /etc/arch-setup/firstboot.env
[[ -r /etc/arch-setup/install.conf ]] && . /etc/arch-setup/install.conf
: "${SETUP_USER:=${USERNAME:-}}" "${GPU:=}" "${ROOT_ENCRYPTED:=no}" "${DATA_DISK:=}"
mkdir -p "$STATE"
exec > >(tee "$REPORT") 2>&1
pass=0; fail=0
check() { local name=$1; shift; if "$@" &>/dev/null; then echo "  PASS  $name"; ((pass++)); else echo "  FAIL  $name"; ((fail++)); fi; }

# Wait (max 90s) for the network: NetworkManager-wait-online is off, so
# network-online.target fires before DHCP finishes and DNS checks would race.
for _ in {1..90}; do resolvectl query archlinux.org &>/dev/null && break; sleep 1; done

echo "arch-setup first-boot report — $(date '+%F %T')"
echo
check "AppArmor enabled"                  bash -c '[[ $(cat /sys/module/apparmor/parameters/enabled) == Y ]]'
check "Firewall active"                   bash -c 'ufw status | grep -q "Status: active"'
check "DNS-over-TLS on"                   bash -c 'resolvectl status | grep -q "+DNSOverTLS"'
check "DNS resolves"                      resolvectl query archlinux.org
check "DNSSEC rejects forged records"     bash -c '! resolvectl query dnssec-failed.org'
check "resolv.conf -> systemd-resolved"   bash -c '[[ $(readlink /etc/resolv.conf) == /run/systemd/resolve/stub-resolv.conf ]]'
check "Core dumps disabled"               bash -c 'grep -q "^Storage=none" /etc/systemd/coredump.conf.d/10-disable.conf'
[[ ${LOCK_ROOT:-n} == y ]] && check "Root account locked" bash -c 'passwd -S root | awk "{print \$2}" | grep -q ^L'
[[ $GPU == nvidia* ]] && check "NVIDIA DRM modeset" bash -c '[[ $(cat /sys/module/nvidia_drm/parameters/modeset) == Y ]]'
[[ $ROOT_ENCRYPTED == yes ]] && check "Root filesystem encrypted (LUKS)" bash -c '[[ $(lsblk -no TYPE "$(findmnt -no SOURCE / | sed "s/\[.*//")") == crypt ]]'
check "Firewall policy denies incoming"   bash -c 'ufw status verbose | grep -q "deny (incoming)"'
check "zram swap active"                  bash -c 'swapon --show | grep -q zram'
check "/home on @home"                    bash -c '[[ $(findmnt -no FSROOT /home) == /@home ]]'
check "/.snapshots on @snapshots"         bash -c '[[ $(findmnt -no FSROOT /.snapshots) == /@snapshots ]]'
if [[ -n $DATA_DISK ]]; then
    check "Vault opened at login"         test -e /dev/mapper/vault
    check "/data/storage mounted"         mountpoint -q /data/storage
    check "/data/backups mounted"         mountpoint -q /data/backups
    [[ -b /dev/disk/by-partlabel/BRIDGE ]] && check "Bridge (exFAT share) mounted" mountpoint -q /mnt/bridge
    check "Backup timer enabled"          systemctl is-enabled restic-backup.timer
fi
check "greetd login active"               systemctl is-active greetd
check "grub-btrfs daemon running"         systemctl is-active grub-btrfsd
check "Packages intact (pacman -Qk)"      bash -c '! pacman -Qkq 2>/dev/null | grep -q .'
echo

# Home snapshots (hourly, small retention) now that /home is its own subvolume
if [[ ! -f /etc/snapper/configs/home ]] && [[ $(findmnt -no FSROOT /home) == /@home ]]; then
    snapper --no-dbus -c home create-config /home
    snapper --no-dbus -c home set-config TIMELINE_CREATE=yes TIMELINE_LIMIT_HOURLY=12 TIMELINE_LIMIT_DAILY=7 \
        TIMELINE_LIMIT_WEEKLY=4 TIMELINE_LIMIT_MONTHLY=3 TIMELINE_LIMIT_YEARLY=0 ALLOW_GROUPS=wheel SYNC_ACL=yes
    echo "  home snapshots: hourly, keep 12h/7d/4w/3m"
fi

if (( fail == 0 )); then
    snapper --no-dbus -c root create --description "GOLDEN: arch-setup complete" --cleanup-algorithm "" --userdata important=yes
    [[ -f /etc/snapper/configs/home ]] && snapper --no-dbus -c home create --description "GOLDEN: arch-setup complete" --cleanup-algorithm "" --userdata important=yes
    [[ -n $DATA_DISK ]] && systemctl start restic-backup.service && echo "  first full backup to the vault done"
    echo; echo "RESULT: $pass/$pass checks passed — GOLDEN snapshot created (never auto-deleted, bootable from GRUB)."
else
    echo "RESULT: $fail check(s) failed — golden snapshot NOT taken. Fix them, then run:"
    echo "        sudo /usr/local/lib/arch-setup/firstboot.sh"
fi
touch "$STATE/firstboot-done"
if [[ -n ${SETUP_USER:-} ]]; then
    install -D -o "$SETUP_USER" -m 0644 "$REPORT" "/home/$SETUP_USER/.local/state/arch-setup/firstboot-report.txt" 2>/dev/null || true
fi
(( fail == 0 ))
