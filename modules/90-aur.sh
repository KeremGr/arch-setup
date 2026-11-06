#!/usr/bin/env bash
# Build the vetted AUR packages. Each package's build files are hashed and
# compared to vetted/aur.lock (the exact files that were reviewed). If anything
# changed since review, the build stops and shows you the files to approve.
source "$(dirname "$0")/../lib.sh"
require_user
LOCK=$SETUP_DIR/vetted/aur.lock
BUILD_ROOT=${XDG_CACHE_HOME:-$HOME/.cache}/arch-setup/aur
mkdir -p "$BUILD_ROOT"

# makepkg's default is 'sudo -k', which throws away the sudo session install.sh
# opened and asks for the password on every dependency/package install. This
# private config (used only for these builds) makes it reuse that session.
# The sudo session stays tied to this terminal and expires 5 min after the end.
MAKEPKG_CONF_SETUP=$BUILD_ROOT/makepkg.conf
printf 'source /etc/makepkg.conf\nfor f in /etc/makepkg.conf.d/*.conf; do [[ -f $f ]] && source "$f"; done\nPACMAN_AUTH=(sudo)\n' >"$MAKEPKG_CONF_SETUP"

# Parallel compile jobs sized to free memory (~1.2 GB per C++ job), so small machines
# don't run out of RAM (the install USB has no swap). cmake --build reads the second one.
mem_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
JOBS=$(( mem_kb / 1200000 )); (( JOBS < 1 )) && JOBS=1; (( JOBS > $(nproc) )) && JOBS=$(nproc)
export MAKEFLAGS="-j$JOBS" CMAKE_BUILD_PARALLEL_LEVEL=$JOBS
info "Building with $JOBS parallel jobs ($(( mem_kb / 1024 / 1024 )) GiB RAM free)"

ORDER=(paru python-materialyoucolor libcava ttf-rubik-vf qt6-m3shapes-git quickshell-git
       caelestia-cli caelestia-shell qtengine darkly-bin papirus-folders pwvucontrol
       spicetify-cli spicetify-marketplace-bin vesktop-bin)

section "Rust toolchain (needed to build paru + pwvucontrol)"
rustup toolchain list 2>/dev/null | grep -q stable || rustup default stable
ok "rustup stable ready"

# Packages that link Qt's private API must be rebuilt after every Qt update, or the shell breaks.
QT_LINKED=(quickshell-git qt6-m3shapes-git qtengine)
installed_epoch() { date -d "$(LC_ALL=C pacman -Qi "$1" 2>/dev/null | awk -F': ' '/^Install Date/{print $2}')" +%s 2>/dev/null || echo 0; }
needs_qt_rebuild() {
    local p=$1
    [[ " ${QT_LINKED[*]} " == *" $p "* ]] || return 1
    (( $(installed_epoch qt6-base) > $(installed_epoch "$p") ))
}

# Our own small, reviewed patches (vetted/patches/<pkg>/*.patch), applied at build time so the
# installed package itself contains them (pacman -Qk stays clean). Their hash is stamped into
# the package description, so a changed patch set triggers a rebuild.
patch_dir() { echo "$SETUP_DIR/vetted/patches/$1"; }
patch_stamp() { local pd; pd=$(patch_dir "$1"); [[ -d $pd ]] || return 0; (cd "$pd" && cat ./*.patch | sha256sum | cut -c1-12); }
installed_stamp_ok() {
    local want; want=$(patch_stamp "$1"); [[ -z $want ]] && return 0
    LC_ALL=C pacman -Qi "$1" 2>/dev/null | grep -q "arch-setup patches $want"
}

dir_hash() { (cd "$1" && find . -type f ! -name .SRCINFO | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -c1-64); }

aur_build() {
    local pkg=$1 vetted_ver vetted_hash vetted_commit d h ver
    read -r _ vetted_ver vetted_hash vetted_commit < <(grep -E "^$pkg " "$LOCK") || die "$pkg is not in the vetted list"
    vetted_commit=${vetted_commit#commit=}
    [[ $pkg != *-git || $vetted_commit =~ ^[0-9a-f]{40}$ ]] || die "$pkg: no reviewed upstream commit in the vetted list"

    if pkg_installed "$pkg"; then
        ver=$(pacman -Q "$pkg" | awk '{print $2}')
        local current=n
        if [[ -n $vetted_commit ]]; then [[ $ver == *"${vetted_commit:0:7}"* ]] && current=y
        else [[ ${ver%-*} == "$vetted_ver" ]] && current=y; fi
        if [[ $current == y ]] && ! installed_stamp_ok "$pkg"; then
            info "$pkg needs our reviewed patches — rebuilding"
        elif [[ $current == y ]] && needs_qt_rebuild "$pkg"; then
            info "$pkg was built against an older Qt — rebuilding"
        elif [[ $current == y ]]; then
            ok "$pkg $ver already installed (reviewed version)"; return
        fi
    fi

    d=$BUILD_ROOT/$pkg
    rm -rf "$d"; mkdir -p "$d"
    curl -sfL --proto '=https' --tlsv1.2 "https://aur.archlinux.org/cgit/aur.git/snapshot/$pkg.tar.gz" | tar -xz -C "$BUILD_ROOT" \
        || die "Could not download $pkg from the AUR"
    h=$(dir_hash "$d")
    if [[ $h != "$vetted_hash" ]]; then
        warn "$pkg build files CHANGED since they were reviewed (vetted $vetted_ver)."
        warn "Read them carefully. Look for: unknown download URLs, 'SKIP' checksums, curl|sh, post-install scripts."
        for f in "$d"/PKGBUILD "$d"/*.install "$d"/*.hook "$d"/*.sh; do
            [[ -f $f ]] && { printf '\n%s----- %s -----%s\n' "$c_dim" "${f##*/}" "$c_off"; cat "$f"; }
        done
        echo
        confirm "Install $pkg with these build files?" || die "Stopped: $pkg not approved"
    else
        ok "$pkg build files match the reviewed version"
    fi

    # -git packages: build exactly the reviewed upstream commit, never whatever is newest
    if [[ -n $vetted_commit ]]; then
        sed -i -E "/^source=/,/\)/ s|(git\+[^\"' )#]+)|\1#commit=$vetted_commit|" "$d/PKGBUILD"
        grep -q "#commit=$vetted_commit" "$d/PKGBUILD" || die "$pkg: could not pin the reviewed commit"
        ok "$pkg pinned to reviewed commit ${vetted_commit:0:12}"
    fi

    local pd stamp; pd=$(patch_dir "$pkg"); stamp=$(patch_stamp "$pkg")
    if [[ -n $stamp ]]; then
        grep -q '^prepare()' "$d/PKGBUILD" && die "$pkg: PKGBUILD has its own prepare() — merge our patches by hand"
        install -d "$d/arch-setup-patches"; cp "$pd"/*.patch "$d/arch-setup-patches/"
        cat >>"$d/PKGBUILD" <<'PB'

# arch-setup: reviewed patches (vetted/patches/<pkg>)
prepare() {
    cd "$srcdir/$(find "$srcdir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | head -1 | xargs basename)"
    for p in "$startdir"/arch-setup-patches/*.patch; do patch -Np1 -i "$p"; done
}
PB
        sed -i -E "s|^pkgdesc=(['\"])(.*)(['\"])$|pkgdesc=\1\2 [arch-setup patches $stamp]\3|" "$d/PKGBUILD"
        grep -q "arch-setup patches $stamp" "$d/PKGBUILD" || die "$pkg: could not stamp the patch set"
        ok "$pkg: $(ls "$pd"/*.patch | wc -l) reviewed patch(es) will be applied"
    fi

    if [[ -d $d/keys/pgp ]]; then
        gpg --batch --quiet --import "$d"/keys/pgp/*.asc 2>/dev/null && ok "Imported $pkg signing key"
    fi
    info "Building $pkg..."
    # no --needed: a rebuild of the same version (our patches, a Qt update) must really be installed
    (cd "$d" && makepkg --config "$MAKEPKG_CONF_SETUP" -si --noconfirm --cleanbuild >"$d/build.log" 2>&1) \
        || { tail -n 40 "$d/build.log"; die "$pkg failed to build (full log: $d/build.log)"; }
    if [[ -n $vetted_commit ]]; then
        for g in "$d"/src/*/.git; do
            [[ $(git -C "${g%/.git}" rev-parse HEAD) == "$vetted_commit" ]] || die "$pkg was not built from the reviewed commit"
        done
        ok "$pkg built from the reviewed commit"
    fi
    ok "$pkg $(pacman -Q "$pkg" | awk '{print $2}') installed"
}

section "AUR packages (vetted)"
SKIP=()
[[ $WANT_SPOTIFY == y ]] || SKIP+=(spicetify-cli spicetify-marketplace-bin)
[[ $WANT_DISCORD == y ]] || SKIP+=(vesktop-bin)
for p in "${ORDER[@]}"; do
    if [[ " ${SKIP[*]} " == *" $p "* ]]; then info "$p not needed (your choice)"; continue; fi
    aur_build "$p"
done
ok "All AUR packages installed"

section "Reviewed AUR packages only change through arch-setup-update"
# 'pacman -Syu' / 'paru -Syu' skip these; arch-setup-update rebuilds them at reviewed versions.
IGN="IgnorePkg = ${ORDER[*]}   # arch-setup: reviewed AUR packages (update with arch-setup-update)"
if grep -q '# arch-setup: reviewed AUR packages' /etc/pacman.conf; then
    sudo sed -i "s|^IgnorePkg = .*# arch-setup: reviewed AUR packages.*|$IGN|" /etc/pacman.conf
else
    sudo sed -i "/^\[options\]/a $IGN" /etc/pacman.conf
fi
pacman-conf IgnorePkg | grep -qx quickshell-git || die "Could not add the IgnorePkg line"
ok "System updates leave the ${#ORDER[@]} reviewed AUR packages alone"

section "paru: no automatic -git updates"
# -git packages build straight from upstream code; they update only after a review.
if grep -q '^Devel$' /etc/paru.conf 2>/dev/null; then
    sudo sed -i 's/^Devel$/#Devel  # arch-setup: -git pkgs update only after review/' /etc/paru.conf
fi
ok "paru won't pull unreviewed upstream code on its own"
