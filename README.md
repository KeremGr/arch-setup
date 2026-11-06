# arch-setup

One command turns a computer into a secure, private and fast **Arch Linux** desktop with
**Hyprland** and the **Caelestia** shell. It runs from the official Arch ISO, asks a few
questions, and never touches a disk you didn't name.

> **Personal, non-commercial project.** Made by a student (Zhanius) to learn Linux and to set up
> my own PC and a friend's. It is **not affiliated with, endorsed by, or supported by** the
> Caelestia authors (caelestia-dots) or Arch Linux. All credit for the Caelestia shell, its
> design and its dotfiles goes to them. This project only automates installing their software
> from its official sources and configures it. Please report problems with this installer
> **here, not to Caelestia**. No warranty: use it at your own risk, and back up your data.
>
> If you are an author of any software used here and want something changed, credited
> differently or removed, please open an issue and it will be done.

## Credits

- **[Caelestia](https://github.com/caelestia-dots)** by caelestia-dots: the shell
  ([caelestia-dots/shell](https://github.com/caelestia-dots/shell)), CLI and dotfiles
  ([caelestia-dots/caelestia](https://github.com/caelestia-dots/caelestia)). For Caelestia
  itself, see their repositories and community.
- **[Arch Linux](https://archlinux.org)**, **[Hyprland](https://hypr.land)**,
  **[Quickshell](https://quickshell.org)** and every package author whose work is installed.
- Wallpaper photographers on Wikimedia Commons (credited in each wallpaper folder).

Not copied into this repository: none of their code, art or dotfiles. Everything is downloaded
from the original sources at install time. The single exception is a small patch to
caelestia-shell (a night-light quick toggle, see `vetted/patches/`). It is licensed under the
same **GPL-3.0** as caelestia-shell and applied only when the package is built on your own PC.

## What you get

- **Private by default:** encrypted DNS (DNS-over-TLS + DNSSEC) with no fallback to your
  provider; a randomised MAC address per network; your computer's name isn't sent to the
  router; no LAN announcements; the shell's IP-geolocation and lyrics calls are blocked.
- **Hardened:** firewall that blocks everything incoming, kernel/sysctl hardening, AppArmor,
  no core dumps, sudo hardening, an optional root lock, an optional GRUB menu lock.
- **Encryption (optional):** an encrypted system disk (LUKS2) and/or an encrypted data disk
  that opens with your login password. Each gets a paper recovery key.
- **Safe updates:** a btrfs snapshot before and after every package change, bootable
  straight from the GRUB menu. Daily encrypted backups if you add a data disk.
- **Fast:** graphics driver picked for your GPU (NVIDIA/AMD/Intel), early KMS, zram, every
  monitor at its highest refresh rate, low-latency settings for games.
- **Looks:** the Caelestia shell, custom colour schemes and matching scenery wallpapers.
  Changing the scheme changes the wallpaper, and the reverse. LibreWolf, Spotify, Vesktop,
  terminal, GTK and Qt all recolour live.
- **Reviewed software only:** everything comes from the official signed Arch repos, except
  15 AUR packages whose exact build files were reviewed. If one of them changes, the install
  stops and shows you the new files ([vetted/aur.lock](vetted/aur.lock)).

## Install

**You need:** a 64-bit PC with UEFI, Secure Boot **off**, internet access, and at least
42 GiB on the target disk. Back up anything you care about first.

1. Download the [Arch ISO](https://archlinux.org/download/), verify it as described there,
   write it to a USB stick and boot from it.
2. Not a US keyboard? Set yours first, so symbols like `|` `"` `{` type correctly, for example
   `loadkeys trq` (Turkish Q), `loadkeys de` or `loadkeys uk`. Then connect to the internet.
   Ethernet works by itself; for Wi-Fi run `iwctl`, then `station wlan0 connect YOUR-WIFI`.
3. Type the install command. It downloads the latest release and runs it **only if** it was
   signed by the project key `60E5 ED45 939B 671B F4DC 8EA6 3910 1B81 A306 0755`
   (Zhanius). If someone shared this project with you, check that fingerprint with them
   directly: that protects you even if this page were ever tampered with.

   ```
   curl -fLOOO https://github.com/KeremGr/arch-setup/releases/latest/download/{a.tgz,a.sig,k}&&gpgv --status-fd 1 --keyring ./k a.sig a.tgz|grep -q "VALIDSIG.* 60E5ED45939B671BF4DC8EA639101B81A3060755$"&&tar xf a.tgz&&bash a/i
   ```

   It's long. To paste it from another computer instead: on the ISO run `passwd` (set a
   temporary root password) and `ip -brief addr` (shows its address), then from the other
   computer run `ssh root@THAT-ADDRESS` and paste.

4. Answer the questions. Nothing is written while you answer:
   - keyboard, language, timezone, weather city, mirror countries
   - computer name, username, password, root lock
   - graphics (detected; it asks if it can't tell)
   - the **system disk**: you type its name. Then pick one:
     1. erase the whole disk
     2. erase it but leave space for Windows later
     3. install into free space next to an existing Windows
   - disk encryption (optional), an extra data disk (optional), boot menu lock
   - apps & preferences (press Enter for the recommended choice):
     - browser (LibreWolf or Firefox), Spotify, Discord
     - developer tools (full, basic or none), gaming (Steam), extra apps, Flatpak
     - Bluetooth, printing, a backup kernel
     - starting theme, DNS provider (Cloudflare, Quad9 or Mullvad), night light, screen lock and sleep timers
5. Check the summary, then each disk's **final check**: model, serial, size and every
   partition affected. You confirm by typing the disk's name.
6. When it finishes: remove the USB and `reboot`. Log in. A window finishes the desktop
   (10–20 minutes, asks your password once), runs a self-check, takes a **GOLDEN**
   snapshot and restarts.

## Daily use

| | |
|---|---|
| Launcher / scheme / wallpaper | `SUPER` |
| Change your password | `sudo arch-setup-passwd`. It keeps disk encryption + GRUB in sync. Don't use plain `passwd`. |
| Roll back a bad update | Pick a snapshot in the GRUB menu (needs the GRUB password if you locked it) |
| Night light on/off | `SUPER+SHIFT+N` |
| VPN on/off | the VPN toggle in the bottom-right panel (after `arch-setup-vpn add`, see below) |
| Self-check report | `~/.local/state/arch-setup/firstboot-report.txt` |
| Keep a site logged in (LibreWolf clears cookies on close) | `/opt/arch-setup/tools/librewolf-keep-logins.py site.com` with LibreWolf closed |

### VPN (free option: Proton VPN Free)

Proton VPN's free plan has no data limit and an independently audited no-logs policy
(1 device, a few countries). It works with the kernel's own WireGuard, with no extra app:

1. Create a free account at protonvpn.com and sign in at account.protonvpn.com.
2. Go to Downloads → WireGuard configuration, pick a free server, and download the `.conf` file.
3. Run `arch-setup-vpn add ~/Downloads/<file>.conf "Proton VPN"`.

The VPN toggle in the bottom-right panel then switches it on and off. `arch-setup-vpn` refuses
config files that try to run commands, and your encrypted DNS keeps working through the tunnel.
Any other WireGuard provider works the same way; Mullvad is the most private, but paid.

**Forgot your disk password?** Use the paper recovery key you wrote down during install.

## Updates

On an installed system, run:

```
arch-setup-update
```

It downloads the newest release and installs it only if it was signed by the project key, which
your PC already knows from the install. First it shows what's new and asks, then it takes a
snapshot, then it applies only the parts that changed. Normal `sudo pacman -Syu` keeps
working for everything else. The reviewed AUR packages and Caelestia's dotfiles only change
through `arch-setup-update`, so nothing unreviewed gets in.

How an update is made (maintainer):
1. `tools/check-upstream.sh` writes a report of everything that changed upstream:
   AUR build-file diffs, new commits of the `-git` sources, and Caelestia dotfile changes
   including every install hook.
2. Read it. If it's fine: `tools/approve-update.sh <package | caelestia-dots>` records the
   reviewed versions.
3. Test in the VMs (`tools/vm-test.sh`), then bump `VERSION` and add a `CHANGELOG.md` section.
4. Commit, push, then `tools/release.sh X.Y.Z` (signed). Every installed PC can then run
   `arch-setup-update`.

## Dual boot

- **Windows already installed:** choose option 3 (install into free space). Your Windows
  partitions aren't touched.
- **Windows later:** choose option 2 (leave space), then install Windows into that space.
  Windows setup makes itself the default boot entry, so open your BIOS boot menu once
  (usually F8, F11 or F12) and pick Arch/GRUB. From then on, Arch finds Windows by itself,
  adds it to the GRUB menu and puts GRUB first again.
- In Windows, turn off **Fast Startup**, and set the clock to UTC so the time isn't off by your
  timezone between the two systems:
  `reg add "HKLM\System\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /t REG_DWORD /d 1 /f`

## For maintainers

| | |
|---|---|
| `stage1/install.sh` | runs on the ISO: questions, disks, base system, all root modules (in chroot), AUR builds |
| `firstboot/finish-setup.sh` | first login: Caelestia, apps, themes, monitor modes, self-check, golden snapshot |
| `modules/NN-*.sh` | one topic each; idempotent; `IN_CHROOT=1` skips live-only steps |
| `install.sh` | alternative: set up an *already installed* Arch from inside Hyprland |
| `tools/vm-test.sh` | unattended VM installs: `encrypted-data`, `plain-keep`, `dualboot` |
| `tools/release.sh` | signed tag + signed archive + checksums; shows everything before publishing |
| `tools/check-upstream.sh`, `tools/approve-update.sh` | review upstream changes, then record approved versions |
| `tools/privacy-audit.py` | finds personal data (usernames, paths, IDs, serials, emails...) in files and history |

Commits and pushes go through `.githooks/` (`git config core.hooksPath .githooks`):
- a commit is blocked unless the committer email is the approved GitHub noreply address
- a commit is blocked if an ignored file is tracked
- a commit is blocked if the privacy audit or Gitleaks finds anything
- a push is also blocked unless the whole history passes both scans

`.gitignore` is an allow-list.

## License

MIT for this project's own code, except `vetted/patches/caelestia-shell/` (GPL-3.0-only,
because it modifies caelestia-shell). See [LICENSE](LICENSE) and
[THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md) for the software and photos it downloads.
