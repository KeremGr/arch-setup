#!/usr/bin/env bash
# Caelestia: full experience (shell, Hyprland config, fish, foot, starship, btop,
# fastfetch, Thunar, GTK+Qt theming, PipeWire, clipboard, fonts, tools, Neovim
# and Code-OSS themes). Firefox/Spotify/Discord parts are replaced by our own
# LibreWolf / spotify-launcher+Spicetify / Vesktop setup in 92-apps.
source "$(dirname "$0")/../lib.sh"
require_user
CFG=${XDG_CONFIG_HOME:-$HOME/.config}
DISABLE=firefox,spotify,vscodium,zed,discord,todoist,uwsm,zen
case $DEV_TOOLS in
    full)  ENABLE=vscode,nvim ;;
    basic) ENABLE=nvim;  DISABLE+=,vscode ;;
    *)     ENABLE="";    DISABLE+=,vscode,nvim ;;
esac

section "Personal Hyprland overrides (written before install so nothing flips back)"
if [[ ${ARCH_SETUP_UPDATE:-0} == 1 && -f $CFG/caelestia/hypr-user.lua ]]; then
    ok "Keeping your hypr-user.lua (monitor rules, your edits)"
else
install -D -m 0644 "$SETUP_DIR/files/hypr-user.lua" "$CFG/caelestia/hypr-user.lua"
sed -i "s/@XKB_LAYOUT@/$XKB_LAYOUT/; s/@XKB_VARIANT@/$XKB_VARIANT/" "$CFG/caelestia/hypr-user.lua"
# NVIDIA env vars only for NVIDIA-only machines (on laptops with two GPUs they'd break the iGPU desktop)
[[ $GPU == nvidia ]] || sed -i '/^-- BEGIN arch-setup nvidia/,/^-- END arch-setup nvidia/d' "$CFG/caelestia/hypr-user.lua"
install -D -m 0644 "$SETUP_DIR/files/hypr-vars.lua" "$CFG/caelestia/hypr-vars.lua"
ok "Monitors at native resolution, keyboard $XKB_LAYOUT, GPU $GPU, LibreWolf/Code as defaults"
fi

section "Neovim base (LazyVim: LSP, completion, treesitter)"
if [[ $DEV_TOOLS == none ]]; then
    ok "Developer tools not chosen — skipped"
elif [[ ! -e $CFG/nvim ]]; then
    git clone -q --depth 1 https://github.com/LazyVim/starter "$CFG/nvim"
    rm -rf "$CFG/nvim/.git"
    ok "LazyVim starter installed (plugins download on first nvim launch)"
else
    ok "$CFG/nvim exists — kept"
fi

section "Caelestia dotfiles: pinned to the reviewed commit"
# A local mirror with a 'reviewed' branch at the vetted commit. caelestia-cli is pointed at it,
# so neither 'caelestia install' nor 'caelestia update' can pull unreviewed upstream changes.
# arch-setup-update moves this branch when a newer commit has been reviewed.
DOTS_URL=$(awk -F= '$1=="url"{print $2}' "$SETUP_DIR/vetted/caelestia-dots.lock")
DOTS_COMMIT=$(awk -F= '$1=="commit"{print $2}' "$SETUP_DIR/vetted/caelestia-dots.lock")
[[ $DOTS_COMMIT =~ ^[0-9a-f]{40}$ ]] || die "No reviewed Caelestia dotfiles commit in vetted/caelestia-dots.lock"
MIRROR=${XDG_DATA_HOME:-$HOME/.local/share}/arch-setup/caelestia-dots.git
if [[ -d $MIRROR ]]; then git -C "$MIRROR" fetch -q origin '+refs/heads/*:refs/heads/upstream/*'
else git clone -q --bare "$DOTS_URL" "$MIRROR"; git -C "$MIRROR" fetch -q origin '+refs/heads/*:refs/heads/upstream/*'; fi
git -C "$MIRROR" cat-file -e "$DOTS_COMMIT^{commit}" 2>/dev/null || die "Reviewed commit $DOTS_COMMIT not found upstream"
git -C "$MIRROR" update-ref refs/heads/reviewed "$DOTS_COMMIT"
python3 -I - "$CFG/caelestia/cli.json" "$MIRROR" <<'PY'
import json, sys, pathlib
p, mirror = pathlib.Path(sys.argv[1]), sys.argv[2]
d = json.loads(p.read_text()) if p.exists() and p.read_text().strip() else {}
d["dots"] = {"url": mirror, "branch": "reviewed"}
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps(d, indent=4))
PY
# An existing clone from the old upstream URL is re-cloned from the mirror by caelestia-cli itself.
ok "Dotfiles pinned to ${DOTS_COMMIT:0:12} (caelestia update follows reviewed versions only)"

section "Safety check: every package Caelestia will install"
MANIFEST=$(mktemp)
git -C "$MIRROR" show "$DOTS_COMMIT:manifest.toml" >"$MANIFEST" || die "Could not read the reviewed Caelestia manifest"
mapfile -t WANT < <(python3 -I - "$MANIFEST" "$ENABLE" "$DISABLE" <<'PY'
import sys, tomllib
m = tomllib.load(open(sys.argv[1], "rb"))
en, dis = set(sys.argv[2].split(",")), set(sys.argv[3].split(","))
pk = set(m.get("packages", []))
for c in m["components"]:
    if (c.get("default") and c["name"] not in dis) or c["name"] in en:
        pk.update(c.get("packages", []))
print("\n".join(sorted(pk)))
PY
)
bad=()
for p in "${WANT[@]}"; do
    [[ $p == local:* ]] && { bad+=("$p"); continue; }
    pkg_installed "$p" && continue
    pacman -Si "$p" &>/dev/null || bad+=("$p")
done
rm -f "$MANIFEST"
((${#bad[@]} == 0)) || die "Caelestia wants unvetted packages: ${bad[*]} — stopping. Ask for a review first."
ok "${#WANT[@]} packages: all official repo or already-vetted AUR"

section "Installing Caelestia"
# PipeWire replaces the older jack2 audio server (pulled in by ffmpeg). pacman asks
# before swapping them, which a non-interactive install can't answer, so swap it
# here explicitly. pipewire-jack provides the same 'jack' libraries ffmpeg needs.
if pkg_installed jack2 && ! pkg_installed pipewire-jack; then
    sudo pacman -S --needed --noconfirm --ask 4 pipewire-jack
    ok "jack2 replaced by pipewire-jack (official repo)"
fi
if [[ ${ARCH_SETUP_UPDATE:-0} == 1 && -d ${XDG_STATE_HOME:-$HOME/.local/state}/caelestia/dots/.git ]]; then
    # Update: apply the newly reviewed dotfiles commit (the mirror's 'reviewed' branch moved above)
    caelestia update --aur-helper paru --noconfirm
    ok "Caelestia dotfiles updated to the reviewed commit ${DOTS_COMMIT:0:12}"
else
    caelestia install --aur-helper paru --noconfirm --enable-components "$ENABLE" --disable-components "$DISABLE"
    ok "Caelestia installed (your previous ~/.config was backed up to ~/.config.bak by Caelestia)"
fi
