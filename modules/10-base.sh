#!/usr/bin/env bash
# Base system: keyboard, pacman, HTTPS-only mirrors, full upgrade, official packages.
source "$(dirname "$0")/../lib.sh"
require_root

section "Keyboard (console + login)"
# Written directly (what localectl would write), so it also works during install.
write_file /etc/vconsole.conf <<CONF
KEYMAP=$KEYMAP
CONF
write_file /etc/X11/xorg.conf.d/00-keyboard.conf <<CONF
Section "InputClass"
        Identifier "system-keyboard"
        MatchIsKeyboard "on"
        Option "XkbLayout" "$XKB_LAYOUT"
        Option "XkbModel" "pc105"
        Option "XkbVariant" "$XKB_VARIANT"
EndSection
CONF
ok "Console: $KEYMAP · X11/Wayland: $XKB_LAYOUT"

section "pacman"
PC=/etc/pacman.conf
backup "$PC"
sed -i -E 's/^#?ParallelDownloads.*/ParallelDownloads = 10/; s/^#Color$/Color/; s/^#VerbosePkgLists$/VerbosePkgLists/; s/^#CheckSpace$/CheckSpace/' "$PC"
grep -qE '^SigLevel\s*=\s*Required' "$PC" || die "pacman SigLevel is not 'Required' — signature checking weakened, refusing to continue."
ok "Parallel downloads, colour, signature checking verified (SigLevel = Required)"

section "Mirrors (HTTPS only, fastest nearby)"
pacman -S --needed --noconfirm reflector
# MIRROR_COUNTRIES comes from the install answers (e.g. "Germany,Netherlands"); empty = worldwide.
# (no blank lines: reflector reads this file as command-line arguments)
{
    echo "--save /etc/pacman.d/mirrorlist"
    echo "--protocol https"
    [[ -n $MIRROR_COUNTRIES ]] && echo "--country $MIRROR_COUNTRIES"
    echo "--latest 20"
    echo "--age 12"
    echo "--sort rate"
} | write_file /etc/xdg/reflector/reflector.conf
backup /etc/pacman.d/mirrorlist
if [[ $IN_CHROOT == 1 ]]; then refresh=(timeout 240 reflector @/etc/xdg/reflector/reflector.conf)
else refresh=(timeout 240 systemctl start reflector.service); fi
if "${refresh[@]}"; then
    ok "Mirrorlist refreshed"
else
    warn "reflector failed — keeping existing mirrorlist"
fi
systemctl enable reflector.timer

section "Full system upgrade"
# A kernel update deletes the running kernel's module folder. Load every module
# later steps need *now*, so they keep working until the reboot.
live modprobe -a dm_mod dm_crypt xts aesni_intel algif_skcipher exfat btrfs overlay 2>/dev/null || true
pacman -Syu --noconfirm

section "Official packages"
PKGS=(
    # build / tools
    git base-devel pacman-contrib rsync wget unzip jq inotify-tools fd ripgrep lazygit tree-sitter-cli
    # security / storage / snapshots
    ufw apparmor cryptsetup exfatprogs gptfdisk snapper snap-pac grub-btrfs restic fwupd zram-generator
    # boot menu finds other systems (Windows); hardware info
    os-prober ntfs-3g pciutils
    # desktop + login (the first-login setup runs in foot)
    hyprland foot greetd greetd-tuigreet
    # apps
    librewolf code neovim spotify-launcher wireguard-tools gammastep
    # dev: python, C/C++, rust
    python python-gobject uv rustup gcc clang cmake ninja meson gdb nodejs npm
    # cursors / fonts
    capitaine-cursors
)
has_nvidia && PKGS+=(libva-nvidia-driver)     # video decoding on NVIDIA under Wayland
pacman -S --needed --noconfirm "${PKGS[@]}"
ok "Installed ${#PKGS[@]} packages (all from official, signed Arch repos)"

write_file /etc/makepkg.conf.d/no-debug.conf <<'CONF'
# arch-setup: don't build -debug packages
OPTIONS=(strip docs !libtool !staticlibs emptydirs zipman purge !debug lto)
CONF

systemctl enable paccache.timer
ok "Weekly package cache cleanup enabled"
