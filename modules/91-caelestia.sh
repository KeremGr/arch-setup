#!/usr/bin/env bash
# Caelestia: full experience (shell, Hyprland config, fish, foot, starship, btop,
# fastfetch, Thunar, GTK+Qt theming, PipeWire, clipboard, fonts, tools, Neovim
# and Code-OSS themes). Firefox/Spotify/Discord parts are replaced by our own
# LibreWolf / spotify-launcher+Spicetify / Vesktop setup in 92-apps.
source "$(dirname "$0")/../lib.sh"
require_user
CFG=${XDG_CONFIG_HOME:-$HOME/.config}
ENABLE=vscode,nvim
DISABLE=firefox,spotify,vscodium,zed,discord,todoist,uwsm,zen

section "Personal Hyprland overrides (written before install so nothing flips back)"
install -D -m 0644 "$SETUP_DIR/files/hypr-user.lua" "$CFG/caelestia/hypr-user.lua"
sed -i "s/@XKB_LAYOUT@/$XKB_LAYOUT/; s/@XKB_VARIANT@/$XKB_VARIANT/" "$CFG/caelestia/hypr-user.lua"
# NVIDIA env vars only for NVIDIA-only machines (on laptops with two GPUs they'd break the iGPU desktop)
[[ $GPU == nvidia ]] || sed -i '/^-- BEGIN arch-setup nvidia/,/^-- END arch-setup nvidia/d' "$CFG/caelestia/hypr-user.lua"
install -D -m 0644 "$SETUP_DIR/files/hypr-vars.lua" "$CFG/caelestia/hypr-vars.lua"
ok "Monitors at highest refresh rate, keyboard $XKB_LAYOUT, GPU $GPU, LibreWolf/Code as defaults"

section "Neovim base (LazyVim: LSP, completion, treesitter)"
if [[ ! -e $CFG/nvim ]]; then
    git clone -q --depth 1 https://github.com/LazyVim/starter "$CFG/nvim"
    rm -rf "$CFG/nvim/.git"
    ok "LazyVim starter installed (plugins download on first nvim launch)"
else
    ok "$CFG/nvim exists — kept"
fi

section "Safety check: every package Caelestia will install"
MANIFEST=$(mktemp)
curl -sfL --proto '=https' https://raw.githubusercontent.com/caelestia-dots/caelestia/main/manifest.toml -o "$MANIFEST" \
    || die "Could not fetch the Caelestia manifest"
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
caelestia install --aur-helper paru --noconfirm --enable-components "$ENABLE" --disable-components "$DISABLE"
ok "Caelestia installed (your previous ~/.config was backed up to ~/.config.bak by Caelestia)"
