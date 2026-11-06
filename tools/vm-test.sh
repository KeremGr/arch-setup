#!/usr/bin/env bash
# Test the installer in virtual machines. No root needed; your real disks are never touched
# (the VMs only see their own image files).
#
#   ARCH_ISO=/path/to/verified/archlinux-x86_64.iso tools/vm-test.sh install SCENARIO
#   tools/vm-test.sh boot SCENARIO          boot the installed system (stage 2 / checks)
#   tools/vm-test.sh shot SCENARIO OUT.png  screenshot      · type SCENARIO "text" · key SCENARIO ret
#   tools/vm-test.sh parts SCENARIO         partition table of the VM's disks (VM must be off)
#
# Scenarios:
#   encrypted-data   erase whole disk + encrypted system + data disk (share + vault), Turkish Q keyboard
#   plain-keep       erase, leave 20 GiB empty for Windows later, no encryption, US keyboard
#   dualboot         a disk that already has "Windows" partitions: install into free space only,
#                    separate disk password, German keyboard. Checks the Windows partitions survive.
#
# Only the files that would be published (git allow-list) are sent to the VM. The test password
# is random per VM, kept in the VM folder (outside the repo), and never contains 'i' (it moves
# on Turkish keyboards).
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
VMS=${VM_DIR:-$HOME/vm-test}/vms
OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.4m.fd
OVMF_VARS=/usr/share/edk2/x64/OVMF_VARS.4m.fd
op=${1:?usage: vm-test.sh install|boot|shot|type|key|parts SCENARIO ...}
sc=${2:?scenario}
D=$VMS/$sc
VMCTL=(python3 -I "$REPO/tools/vmctl.py" "$D/qmp.sock")

rand_pw() { python3 -I -c 'import secrets,string,sys; a=[c for c in string.ascii_letters+string.digits if c not in "iI"]; print("".join(secrets.choice(a) for _ in range(int(sys.argv[1]))))' "$1"; }

answers() {
    local pw=$1 pw2=$2
    common="LOCALE=en_US.UTF-8
HOSTNAME_=archtest
USERNAME=tester
PASSWORD='$pw'
LOCK_ROOT=y
GPU_FORCE=other
DISK=/dev/disk/by-id/virtio-ARCHTEST-SYS"
    case $sc in
        encrypted-data) cat <<EOF
$common
KEYMAP=trq
XKB_LAYOUT=tr
XKB_VARIANT=
TIMEZONE=Europe/Berlin
WEATHER_CITY=Berlin
MIRROR_COUNTRIES="Germany,Netherlands"
DISK_MODE_N=1
ENCRYPT=y
LUKS_SAME=y
USE_DATA=y
DATA_DEV=/dev/disk/by-id/virtio-ARCHTEST-DATA
BRIDGE_GIB=4
DATA_KEEP_GIB=2
GRUB_LOCK=y
CONFIRM_DISKS="vda vdb"
EOF
        ;;
        plain-keep) cat <<EOF
$common
KEYMAP=us
XKB_LAYOUT=us
XKB_VARIANT=
TIMEZONE=UTC
WEATHER_CITY=London
MIRROR_COUNTRIES=""
DISK_MODE_N=2
KEEP_GIB=20
ENCRYPT=n
USE_DATA=n
GRUB_LOCK=n
CONFIRM_DISKS="vda"
EOF
        ;;
        dualboot) cat <<EOF
$common
KEYMAP=de-latin1
XKB_LAYOUT=de
XKB_VARIANT=
TIMEZONE=Europe/Vienna
WEATHER_CITY=Vienna
MIRROR_COUNTRIES="Austria,Germany"
DISK_MODE_N=3
ENCRYPT=y
LUKS_SAME=n
LUKS_PASS='$pw2'
USE_DATA=n
GRUB_LOCK=y
CONFIRM_DISKS="vda"
EOF
        ;;
        *) echo "unknown scenario $sc" >&2; exit 2 ;;
    esac
}

qemu_base() {
    QEMU=(qemu-system-x86_64 -enable-kvm -machine q35 -cpu host -smp "${VM_CPUS:-6}" -m "${VM_MEM:-6144}"
          -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" -drive "if=pflash,format=raw,file=$D/vars.fd"
          -drive "file=$D/sys.img,if=none,id=sys,format=raw" -device virtio-blk-pci,drive=sys,serial=ARCHTEST-SYS
          -nic user,model=virtio-net-pci -qmp "unix:$D/qmp.sock,server,nowait" -no-reboot)
    [[ -f $D/data.img ]] && QEMU+=(-drive "file=$D/data.img,if=none,id=data,format=raw" -device virtio-blk-pci,drive=data,serial=ARCHTEST-DATA)
    return 0
}

case $op in
install)
    ISO=${ARCH_ISO:?set ARCH_ISO to a verified Arch ISO}
    rm -rf "$D"; mkdir -p "$VMS"; chattr +C "$VMS" 2>/dev/null || true; mkdir -p "$D/www"; chmod 700 "$D"
    cp "$OVMF_VARS" "$D/vars.fd"
    truncate -s 64G "$D/sys.img"
    [[ $sc == encrypted-data ]] && truncate -s 24G "$D/data.img"
    if [[ $sc == dualboot ]]; then
        truncate -s 96G "$D/sys.img"
        # A disk that looks like Windows: EFI + MSR + 40 GiB "C:" + recovery, rest free
        sgdisk -n 1:0:+100M -t 1:ef00 -c "1:EFI system partition" \
               -n 2:0:+16M -t 2:0c01 -c "2:Microsoft reserved partition" \
               -n 3:0:+40G -t 3:0700 -c "3:Basic data partition" \
               -n 4:0:+600M -t 4:2700 -c "4:Windows recovery" "$D/sys.img" >/dev/null
        sgdisk -p "$D/sys.img" | awk '/^ +[0-9]+ /' >"$D/windows-before.txt"
    fi
    pw=$(rand_pw 16); pw2=$(rand_pw 16)
    umask 077; printf '%s\n' "$pw" >"$D/password"; printf '%s\n' "$pw2" >"$D/disk-password"
    answers "$pw" "$pw2" >"$D/www/answers"
    # Ship exactly what would be published
    (cd "$REPO" && git ls-files -z -co --exclude-standard | tar --null -T - -czf "$D/www/arch-setup.tar.gz" --transform 's,^,arch-setup/,')
    port=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
    cat >"$D/www/run.sh" <<EOF
#!/bin/bash
exec > >(tee /dev/ttyS0) 2>&1
cd /root && curl -fsS http://10.0.2.2:$port/arch-setup.tar.gz | tar xz && curl -fsS http://10.0.2.2:$port/answers -o /root/answers
if bash /root/arch-setup/stage1/install.sh --answers /root/answers; then echo "ARCH-SETUP-STAGE1: OK"
else echo "ARCH-SETUP-STAGE1: FAIL"; tail -n 60 /tmp/arch-setup/stage1.log 2>/dev/null; fi
sync; sleep 3; poweroff
EOF
    bsdtar -xf "$ISO" -C "$D" arch/boot/x86_64/vmlinuz-linux arch/boot/x86_64/initramfs-linux.img
    opts=$(bsdtar -xOf "$ISO" loader/entries/01-archiso-linux.conf | awk '$1=="options"{$1=""; print}')
    (cd "$D/www" && exec python3 -I -m http.server --bind 127.0.0.1 "$port" >/dev/null 2>&1) &
    srv=$!
    trap 'kill $srv 2>/dev/null || true' EXIT
    qemu_base
    QEMU+=(-cdrom "$ISO" -kernel "$D/arch/boot/x86_64/vmlinuz-linux" -initrd "$D/arch/boot/x86_64/initramfs-linux.img"
           -append "$opts script=http://10.0.2.2:$port/run.sh console=tty0 console=ttyS0,115200"
           -display none -vga std -serial "file:$D/serial-install.log")
    echo "VM $sc installing (serial log: $D/serial-install.log)"
    "${QEMU[@]}"
    if grep -q 'ARCH-SETUP-STAGE1: OK' "$D/serial-install.log"; then echo "STAGE1 OK ($sc)"; else echo "STAGE1 FAILED ($sc)"; exit 1; fi
    if [[ $sc == dualboot ]]; then
        sgdisk -p "$D/sys.img" | awk '/^ +[0-9]+ /' | head -4 >"$D/windows-after.txt"
        diff "$D/windows-before.txt" "$D/windows-after.txt" && echo "Windows partitions untouched ✓"
    fi
    ;;
boot)
    qemu_base
    QEMU+=(-device virtio-vga-gl -display egl-headless -vnc "unix:$D/vnc.sock" -serial "file:$D/serial-boot.log")
    [[ ${VM_NOGL:-0} == 1 ]] && QEMU=("${QEMU[@]/virtio-vga-gl/virtio-vga}") && QEMU=("${QEMU[@]/egl-headless/none}")
    echo "VM $sc booting (QMP: $D/qmp.sock)"
    exec "${QEMU[@]}"
    ;;
shot)  if [[ -S $D/vnc.sock ]]; then python3 -I "$REPO/tools/vmctl.py" "$D/vnc.sock" vncshot "${3:?out.png}"
       else "${VMCTL[@]}" shot "${3:?out.png}"; fi ;;
type)  "${VMCTL[@]}" type "${3:?text}" ;;
key)   "${VMCTL[@]}" key "${3:?key}" ;;
parts) sgdisk -p "$D/sys.img"; [[ -f $D/data.img ]] && sgdisk -p "$D/data.img"; true ;;
*) echo "unknown op $op" >&2; exit 2 ;;
esac
