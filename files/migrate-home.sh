#!/usr/bin/env bash
# Runs once at early boot (before any login): move /home onto the @home subvolume.
# Safe: copy first (reflinks = instant, no extra space), verify, then switch.
# On any failure the original /home stays exactly as it was.
set -euo pipefail
STATE=/var/lib/arch-setup
LOG=$STATE/migrate-home.log
mkdir -p "$STATE"
exec > >(tee -a "$LOG") 2>&1
echo "== migrate-home $(date -Is)"

if findmnt -no FSTYPE /home | grep -q btrfs && [[ $(findmnt -no TARGET /home) == /home ]]; then
    echo "/home is already a separate mount"; touch "$STATE/home-migrated"; exit 0
fi

ROOT_SRC=$(findmnt -no SOURCE / | sed 's/\[.*//')
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_SRC")
TOP=/run/arch-setup-top
mkdir -p "$TOP"
mount -o subvolid=5 "$ROOT_SRC" "$TOP"
cleanup() { umount "$TOP" 2>/dev/null || true; }
trap cleanup EXIT

fail() {
    echo "FAILED: $*  — leaving /home untouched"
    sed -i '/# >>> arch-setup:home >>>/,/# <<< arch-setup:home <<</d' /etc/fstab
    exit 0   # never block boot
}

[[ -d $TOP/@home ]] && btrfs subvolume delete "$TOP/@home" >/dev/null   # leftover from a failed run
btrfs subvolume create "$TOP/@home" >/dev/null || fail "create @home"
cp -a --reflink=always /home/. "$TOP/@home/" || fail "copy"

src_n=$(find /home -xdev | wc -l); dst_n=$(find "$TOP/@home" | wc -l)
src_s=$(du -sb --apparent-size /home | cut -f1); dst_s=$(du -sb --apparent-size "$TOP/@home" | cut -f1)
echo "files: $src_n -> $dst_n   bytes: $src_s -> $dst_s"
[[ $src_n -eq $dst_n && $src_s -eq $dst_s ]] || fail "verification mismatch"

cp -a /etc/fstab /etc/fstab.pre-home-migration
sed -i '/# >>> arch-setup:home >>>/,/# <<< arch-setup:home <<</d' /etc/fstab
cat >>/etc/fstab <<CONF
# >>> arch-setup:home >>>
UUID=$ROOT_UUID  /home  btrfs  subvol=/@home,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2  0 0
# <<< arch-setup:home <<<
CONF
mount /home || { cp -a /etc/fstab.pre-home-migration /etc/fstab; fail "mount"; }

[[ $(findmnt -no FSROOT /home) == /@home ]] || fail "unexpected /home source after mount"
# The old copy (inside @, now hidden under the mount) is removed to free space.
find "$TOP/@/home" -mindepth 1 -maxdepth 1 -exec rm -rf {} + || echo "warning: old /home copy not fully removed"
touch "$STATE/home-migrated"
systemctl disable arch-setup-migrate-home.service || true
echo "== done: /home is now @home"
