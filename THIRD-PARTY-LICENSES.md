# Third-party software and assets

The MIT license in `LICENSE` covers only this project's own scripts and tools.
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
