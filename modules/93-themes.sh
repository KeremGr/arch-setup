#!/usr/bin/env bash
# Custom schemes (Autumn Forest, Nocturne, Cream) + matching wallpapers +
# two-way scheme <-> wallpaper sync + live recolouring of every themed app.
source "$(dirname "$0")/../lib.sh"
require_user
CFG=${XDG_CONFIG_HOME:-$HOME/.config}
DATA=${XDG_DATA_HOME:-$HOME/.local/share}/arch-setup
WALLS=$HOME/Pictures/Wallpapers
WORK=${XDG_CACHE_HOME:-$HOME/.cache}/arch-setup/schemes
VERSION=1.0.0

section "Generating colour schemes"
rm -rf "$WORK"; mkdir -p "$WORK/src/schemes"
python3 -I "$SETUP_DIR/tools/gen-schemes.py" "$WORK/src/schemes" 2>&1 | grep -v '^$' \
    || die "Scheme generation failed"
install -D -m 0644 "$WORK/src/schemes/palettes.json" "$DATA/palettes.json"
mv "$WORK/src/schemes/palettes.json" "$WORK/src/palettes.json"

section "Packaging schemes (pacman-owned files, survive updates, verifiable)"
cat >"$WORK/src/link-schemes.sh" <<'SH'
#!/bin/sh
# Link custom schemes into caelestia-cli's scheme folder (re-run by a pacman hook
# whenever caelestia-cli or python is updated, so they never disappear).
dir=$(python3 -I -c 'import caelestia, pathlib; print(pathlib.Path(caelestia.__file__).parent / "data/schemes")' 2>/dev/null) || exit 0
[ -d "$dir" ] || exit 0
for s in /usr/share/caelestia-custom/schemes/*/; do
    n=$(basename "$s"); ln -sfn "$s" "$dir/$n"
done
SH
cat >"$WORK/src/caelestia-custom-schemes.hook" <<'HOOK'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = caelestia-cli
Target = python
Target = caelestia-custom-schemes

[Action]
Description = Linking custom Caelestia colour schemes...
When = PostTransaction
Exec = /usr/share/caelestia-custom/link-schemes.sh
HOOK
cat >"$WORK/src/caelestia-custom-schemes.install" <<'INST'
pre_remove() {
    dir=$(python3 -I -c 'import caelestia, pathlib; print(pathlib.Path(caelestia.__file__).parent / "data/schemes")' 2>/dev/null) || return 0
    for s in /usr/share/caelestia-custom/schemes/*/; do rm -f "$dir/$(basename "$s")"; done
}
INST
cat >"$WORK/src/PKGBUILD" <<PKG
pkgname=caelestia-custom-schemes
pkgver=$VERSION
pkgrel=1
pkgdesc='Custom Caelestia colour schemes (arch-setup)'
arch=('any')
license=('MIT')
depends=('caelestia-cli')
install=caelestia-custom-schemes.install
package() {
    cd "\$startdir"
    install -d "\$pkgdir/usr/share/caelestia-custom"
    cp -r schemes "\$pkgdir/usr/share/caelestia-custom/"
    install -Dm755 link-schemes.sh "\$pkgdir/usr/share/caelestia-custom/link-schemes.sh"
    install -Dm644 caelestia-custom-schemes.hook "\$pkgdir/usr/share/libalpm/hooks/caelestia-custom-schemes.hook"
}
PKG
(cd "$WORK/src" && makepkg -f --noconfirm >"$WORK/build.log" 2>&1) || { tail -20 "$WORK/build.log"; die "Scheme package build failed"; }
sudo pacman -U --noconfirm "$WORK"/src/caelestia-custom-schemes-*.pkg.tar.zst >/dev/null
sudo /usr/share/caelestia-custom/link-schemes.sh
caelestia scheme list -n | grep -qx autumn-forest || die "Custom schemes not visible to Caelestia"
ok "Schemes installed: $(ls /usr/share/caelestia-custom/schemes | tr '\n' ' ')"

section "Wallpapers"
SCHEMES=$(echo /usr/lib/python3*/site-packages/caelestia/data/schemes)
# Real scenery: Wikimedia Commons Featured Pictures (free licences), colour-matched per scheme.
python3 -I "$SETUP_DIR/tools/fetch-scenery.py" "$SCHEMES" "$WALLS" "$WORK/scenery" 4 \
    && ok "Scenery photos matched to every scheme (credits in each folder's CREDITS.txt)" \
    || warn "Scenery download failed (offline?) — using generated art instead"
# Fallback: render original art for any scheme folder still empty
python3 -I "$SETUP_DIR/tools/gen-scheme-palettes.py" "$SCHEMES" "$WALLS" >"$WORK/all-pal.json"
python3 -I "$SETUP_DIR/tools/gen-wallpapers.py" "$WORK/all-pal.json" "$WALLS"
ok "Wallpapers in $WALLS/<scheme>/<flavour>-<mode>/ (drop your own photos in too)"

section "Live theming + two-way scheme <-> wallpaper sync"
install -D -m 0755 "$SETUP_DIR/files/caelestia-scheme-sync" "$HOME/.local/bin/caelestia-scheme-sync"
python3 -I - "$CFG/caelestia/cli.json" "$HOME/.local/bin/caelestia-scheme-sync from-wallpaper" <<'PY'
import json, sys, pathlib
p, hook = pathlib.Path(sys.argv[1]), sys.argv[2]
d = json.loads(p.read_text()) if p.exists() and p.read_text().strip() else {}
d.setdefault("wallpaper", {})["postHook"] = hook
t = d.setdefault("theme", {})
t["postHook"] = hook.replace("from-wallpaper", "apps")   # live-reload Spotify after recolour
for k in ("enableTerm", "enableHypr", "enableDiscord", "enableSpicetify", "enableFuzzel",
          "enableBtop", "enableNvtop", "enableHtop", "enableGtk", "enableQt", "enableCava"):
    t[k] = True
for k in ("enableChromium", "enableZed", "enableWarp", "enablePandora"):
    t[k] = False      # not installed (Chromium theming would need password-less root)
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps(d, indent=4))
PY
ok "Terminal, Hyprland, GTK, Qt, btop, fuzzel, cava, Vesktop, Spicetify recolour on every change"

install -d "$CFG/systemd/user"
cat >"$CFG/systemd/user/caelestia-scheme-sync.path" <<'UNIT'
[Unit]
Description=Watch the Caelestia scheme for wallpaper sync

[Path]
PathChanged=%h/.local/state/caelestia/scheme.json

[Install]
WantedBy=default.target
UNIT
cat >"$CFG/systemd/user/caelestia-scheme-sync.service" <<'UNIT'
[Unit]
Description=Pick a wallpaper that matches the chosen Caelestia scheme

[Service]
Type=oneshot
# Caelestia starts a detached root helper (papirus-folders); let it finish on its own
KillMode=process
ExecStart=%h/.local/bin/caelestia-scheme-sync from-scheme
UNIT
systemctl --user daemon-reload
systemctl --user enable --now caelestia-scheme-sync.path
ok "Scheme -> wallpaper watcher running"

section "Starting look: Autumn Forest"
caelestia scheme set -n autumn-forest -m dark
sleep 2
START_WALL=$(find "$WALLS/autumn-forest/default-dark" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.png' \) | sort | head -1)
[[ -n $START_WALL ]] && caelestia wallpaper -f "$START_WALL" || warn "No Autumn Forest wallpaper found in $WALLS"
ok "Scheme: $(caelestia scheme get -n) · wallpaper: $(cat "${XDG_STATE_HOME:-$HOME/.local/state}/caelestia/wallpaper/path.txt" 2>/dev/null)"
