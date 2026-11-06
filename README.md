# arch-setup

One command turns a computer into a secure, private and fast **Arch Linux** desktop with
**Hyprland** and the **Caelestia** shell. It runs from the official Arch ISO, asks a few
questions, and never touches a disk you didn't name.

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
2. Connect to the internet. Ethernet works by itself; for Wi-Fi run `iwctl`, then
   `station wlan0 connect YOUR-WIFI`.
3. Type the install command. **Get it, including the 40-character fingerprint, from the
   person who gave you this project, or check it against the signed release page.** It
   downloads the release and runs it only if the signature was made by that exact key:

   ```
   F=<FINGERPRINT>; U=https://github.com/KeremGr/arch-setup/releases/latest/download; cd /root && curl -fLO $U/arch-setup.tar.gz -fLO $U/arch-setup.tar.gz.sig -fLO $U/release-signing-key.asc && gpg -q --import release-signing-key.asc && gpg --status-fd 1 --verify arch-setup.tar.gz.sig arch-setup.tar.gz 2>/dev/null | grep -qE "VALIDSIG .* $F$" && tar xzf arch-setup.tar.gz && bash arch-setup/stage1/install.sh || echo "NOT VERIFIED - do not continue"
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
| Self-check report | `~/.local/state/arch-setup/firstboot-report.txt` |
| Keep a site logged in (LibreWolf clears cookies on close) | `/opt/arch-setup/tools/librewolf-keep-logins.py site.com` with LibreWolf closed |

**Forgot your disk password?** Use the paper recovery key you wrote down during install.

## Updates

New upstream versions (Caelestia, quickshell, AUR packages) are reviewed first, then tested
on a real machine and in VMs, and only then released as a new signed version. `paru` doesn't
auto-update `-git` packages, so nothing unreviewed sneaks in.

## For maintainers

| | |
|---|---|
| `stage1/install.sh` | runs on the ISO: questions, disks, base system, all root modules (in chroot), AUR builds |
| `firstboot/finish-setup.sh` | first login: Caelestia, apps, themes, monitor modes, self-check, golden snapshot |
| `modules/NN-*.sh` | one topic each; idempotent; `IN_CHROOT=1` skips live-only steps |
| `install.sh` | alternative: set up an *already installed* Arch from inside Hyprland |
| `tools/vm-test.sh` | unattended VM installs: `encrypted-data`, `plain-keep`, `dualboot` |
| `tools/release.sh` | signed tag + signed archive + checksums; shows everything before publishing |
| `tools/privacy-audit.py` | finds personal data (usernames, paths, IDs, serials, emails...) in files and history |

Commits and pushes go through `.githooks/` (`git config core.hooksPath .githooks`):
- a commit is blocked unless the committer email is the approved GitHub noreply address
- a commit is blocked if an ignored file is tracked
- a commit is blocked if the privacy audit or Gitleaks finds anything
- a push is also blocked unless the whole history passes both scans

`.gitignore` is an allow-list.

## License

MIT for this project's own code. See [LICENSE](LICENSE) and
[THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md) for the software and photos it downloads.
