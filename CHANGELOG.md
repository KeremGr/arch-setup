# Changelog

`arch-setup-update` shows the sections newer than your installed version before asking.

## 1.0.1 — 2026-11-06

- Shorter install command (223 characters instead of 279), with the same signature check.
  It uses gpgv with the published key only.
- Release files: a.tgz, a.sig, k. The v1.0.0 names are still published for older updaters.
- The main kernel boots by default; the backup LTS kernel is the next GRUB entry.
- No "Hyprland updated" popup or donation reminder on the desktop.
- README: set a non-US keyboard before typing the install command.

## 1.0.0 — 2026-11-06

First release.

- One command from the Arch ISO: questions first, a summary, then a final check per disk
  (model, serial, size, partitions) confirmed by typing the disk name.
- Disk layouts: whole disk, whole disk + space left for Windows later, or dual boot into the
  free space next to an existing Windows. Optional LUKS2 encryption with a recovery key.
- Optional encrypted data disk that opens with your login password, plus daily backups.
- Hardening, encrypted DNS, firewall, snapshots before every update (bootable from GRUB),
  optional GRUB lock.
- Graphics driver chosen for your GPU. Every monitor at its native resolution and highest
  refresh rate.
- Caelestia shell with custom schemes and colour-matched scenery wallpapers. Live recolouring
  of LibreWolf, Spotify, Vesktop, terminal, GTK and Qt.
- Only reviewed upstream code: the AUR build files are hash-checked, `-git` packages are pinned
  to reviewed commits, and Caelestia's dotfiles are pinned through a local mirror.
- `arch-setup-update`: signature-checked updates, with a snapshot taken first.
- Dual boot ready: another system is found at every boot, and GRUB stays first in the
  firmware boot order.
- Night light toggle (SUPER+SHIFT+N). `arch-setup-vpn` puts any WireGuard VPN (e.g. Proton VPN
  Free) on Caelestia's VPN toggle, refusing config files that try to run commands.
- Apps & preferences step:
  - browser (LibreWolf or Firefox), Spotify, Discord
  - developer tools (full, basic or none), gaming (Steam + 32-bit drivers), extra apps, Flatpak
  - Bluetooth, printing, a backup LTS kernel
  - starting theme, DNS provider, night light, screen lock and sleep timers
