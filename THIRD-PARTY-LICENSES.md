# Third-party software and assets

The MIT license in `LICENSE` covers only this project's own scripts and tools.
This is a personal, non-commercial student project, not affiliated with or endorsed by any of
the projects below.
This repository does **not** redistribute third-party code, fonts, icons or photos.
The installer downloads them from their original sources, under their own licenses:

| What | From | License |
|---|---|---|
| Arch Linux packages | official Arch repositories (signed) | each package's own license (`pacman -Qi <pkg>`) |
| AUR packages in `vetted/aur.lock` | aur.archlinux.org (reviewed build files) | each package's own license |
| Caelestia shell, CLI and dotfiles | github.com/caelestia-dots | see their repositories |
| CaelestiaFox add-on | addons.mozilla.org (Mozilla-signed, SHA-256 checked) | see the add-on page |
| LazyVim starter | github.com/LazyVim/starter | Apache-2.0 |
| Scenery wallpapers | Wikimedia Commons *Featured Pictures* | public domain / CC0 / CC BY / CC BY-SA, **per photo** |

**Wallpapers:** `tools/fetch-scenery.py` keeps only freely licensed photos. It writes a
`CREDITS.txt` (title, author, license, source link) into every wallpaper folder. Keep those
credits if you share the photos (CC BY / CC BY-SA require attribution; CC BY-SA requires
sharing adaptations under the same license). The fallback wallpapers drawn by
`tools/gen-wallpapers.py` are original and covered by this project's MIT license.

## Patches to third-party code

| File | Modifies | License |
|---|---|---|
| `vetted/patches/caelestia-shell/0001-night-light-quick-toggle.patch` | caelestia-shell (github.com/caelestia-dots/shell), `modules/utilities/cards/Toggles.qml` | **GPL-3.0-only**, the same as caelestia-shell |

The patch is applied only while the package is built locally on the user's machine; no
modified caelestia-shell is distributed. The full GPL-3.0 text ships with caelestia-shell
(`/etc/xdg/quickshell/caelestia/LICENSE`) and is at https://www.gnu.org/licenses/gpl-3.0.html.
