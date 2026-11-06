#!/usr/bin/env bash
# NVIDIA on Wayland, early KMS, zram, SSD + boot speed tuning.
source "$(dirname "$0")/../lib.sh"
require_root

if has_nvidia; then
    section "NVIDIA"
    write_file /etc/modprobe.d/nvidia.conf <<'CONF'
options nvidia_drm modeset=1 fbdev=1
# Keep VRAM contents across suspend (no corrupted desktop after sleep)
options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_TemporaryFilePath=/var/tmp
# Faster CPU<->GPU memory mapping
options nvidia NVreg_UsePageAttributeTable=1
CONF
    systemctl enable nvidia-suspend.service nvidia-hibernate.service nvidia-resume.service
    ok "NVIDIA suspend/resume services enabled"
fi

section "initramfs: early graphics, encrypted root, snapshot-boot overlay"
# GPU=nvidia: load NVIDIA early ('kms' would pull nouveau in, Arch wiki). Others use 'kms'.
# encrypt: asks for the disk password at boot (after keymap, so your layout works).
# grub-btrfs-overlayfs: lets read-only snapshots boot from the GRUB menu.
MODS=(); KMS=kms; CRYPT=""
[[ $GPU == nvidia ]] && { MODS=(nvidia nvidia_modeset nvidia_uvm nvidia_drm); KMS=""; }
[[ $ROOT_ENCRYPTED == yes ]] && CRYPT=encrypt
printf 'MODULES=(%s)\nHOOKS=(%s)\n' "${MODS[*]}" \
    "base udev autodetect microcode modconf $KMS keyboard keymap consolefont block $CRYPT filesystems fsck grub-btrfs-overlayfs" \
    | sed -E 's/  +/ /g' | write_file /etc/mkinitcpio.conf.d/10-arch-setup.conf
# (initramfs is regenerated once at the end, in 99-finalize)

section "zram (compressed RAM swap)"
write_file /etc/systemd/zram-generator.conf <<'CONF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
CONF
write_file /etc/sysctl.d/91-zram.conf <<'CONF'
# Recommended for zram (Arch wiki): swap to compressed RAM early, no readahead
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
CONF
live sysctl --system >/dev/null

section "SSD: noatime"
if [[ $IN_CHROOT == 0 ]] && findmnt -no OPTIONS / | grep -q relatime; then
    backup /etc/fstab
    awk '$2=="/" && $3=="btrfs" {sub(/relatime/,"noatime",$4)} {print}' OFS='\t' /etc/fstab >/etc/fstab.tmp
    findmnt --verify --tab-file /etc/fstab.tmp >/dev/null 2>&1 || { rm -f /etc/fstab.tmp; die "fstab verification failed"; }
    mv /etc/fstab.tmp /etc/fstab
    mount -o remount,noatime /
fi
ok "Root mounted with noatime (fewer SSD writes)"

section "Boot speed + responsiveness"
systemctl disable NetworkManager-wait-online.service 2>/dev/null || true
systemctl enable systemd-oomd.service
write_file /etc/systemd/journald.conf.d/10-size.conf <<'CONF'
[Journal]
SystemMaxUse=300M
CONF
ok "wait-online off, systemd-oomd on, journal capped at 300M"
