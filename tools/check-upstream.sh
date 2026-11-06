#!/usr/bin/env bash
# What changed upstream since the last review? Writes a report to read before approving.
#   tools/check-upstream.sh            -> ~/arch-setup-review/upstream-YYYY-MM-DD.md
# Covers: every AUR package in vetted/aur.lock (build-file diff since the reviewed version),
# the upstream source of -git packages (new commits + diffstat since the pinned commit), and
# the Caelestia dotfiles (new commits, changed files, manifest + install hooks diff).
# Nothing is installed or approved here. Downloads go to a temporary folder.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
LOCK=$REPO/vetted/aur.lock
OUT=${1:-$HOME/arch-setup-review/upstream-$(date +%F).md}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$(dirname "$OUT")"
dir_hash() { (cd "$1" && find . -type f ! -name .SRCINFO ! -path './.git/*' | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -c1-64); }
updates=0
{
echo "# Upstream changes — $(date +%F)"
echo
echo "Read every section marked **CHANGED** before approving. Look for: new download URLs,"
echo "'SKIP' checksums, curl|sh, new install hooks, new sudo/root commands, new network calls."
echo
echo "## AUR packages"
while read -r pkg ver hash commit; do
    [[ -z $pkg || $pkg == \#* ]] && continue
    commit=${commit#commit=}
    git clone -q "https://aur.archlinux.org/$pkg.git" "$W/$pkg" 2>/dev/null || { echo "- $pkg: could not fetch"; continue; }
    head=$(git -C "$W/$pkg" rev-parse HEAD)
    newver=$(awk -F' = ' '/^\tpkgver/{v=$2} /^\tpkgrel/{r=$2} END{print v"-"r}' "$W/$pkg/.SRCINFO")
    # find the AUR commit whose build files match the reviewed hash
    base=""
    for c in $(git -C "$W/$pkg" rev-list HEAD); do
        rm -rf "$W/t"; mkdir "$W/t"; git -C "$W/$pkg" archive "$c" | tar -x -C "$W/t"
        [[ $(dir_hash "$W/t") == "$hash" ]] && { base=$c; break; }
    done
    if [[ $base == "$head" ]]; then
        echo "- $pkg $ver: build files unchanged"
    else
        updates=$((updates+1))
        echo; echo "### CHANGED: $pkg ($ver → $newver)"
        if [[ -n $base ]]; then
            echo '```diff'; git -C "$W/$pkg" diff "$base" HEAD -- . ':!.SRCINFO'; echo '```'
        else
            echo "Reviewed version not found in AUR history — read the full build files:"
            for f in "$W/$pkg"/PKGBUILD "$W/$pkg"/*.install "$W/$pkg"/*.hook "$W/$pkg"/*.sh; do
                [[ -f $f ]] && { echo "#### ${f##*/}"; echo '```bash'; cat "$f"; echo '```'; }
            done
        fi
    fi
    if [[ -n $commit ]]; then
        url=$(awk -F' = ' '/^\turl/{print $2; exit}' "$W/$pkg/.SRCINFO")
        if git clone -q --bare "$url" "$W/$pkg-src.git" 2>/dev/null; then
            n=$(git -C "$W/$pkg-src.git" rev-list --count "$commit..HEAD" 2>/dev/null || echo "?")
            if [[ $n == 0 ]]; then echo "  - upstream source: no new commits since ${commit:0:12}"
            else
                updates=$((updates+1))
                echo; echo "### CHANGED: $pkg upstream source — $n new commit(s) since ${commit:0:12} (newest $(git -C "$W/$pkg-src.git" rev-parse HEAD))"
                echo '```'; git -C "$W/$pkg-src.git" log --format='%h %ad %an: %s' --date=short "$commit..HEAD" | head -60; echo '```'
                echo '```'; git -C "$W/$pkg-src.git" diff --stat "$commit" HEAD | tail -40; echo '```'
            fi
        fi
    fi
done <"$LOCK"

echo; echo "## Caelestia dotfiles"
durl=$(awk -F= '$1=="url"{print $2}' "$REPO/vetted/caelestia-dots.lock")
dcommit=$(awk -F= '$1=="commit"{print $2}' "$REPO/vetted/caelestia-dots.lock")
git clone -q --bare "$durl" "$W/dots.git"
n=$(git -C "$W/dots.git" rev-list --count "$dcommit..HEAD")
if [[ $n == 0 ]]; then echo "- no new commits since ${dcommit:0:12}"
else
    updates=$((updates+1))
    echo "### CHANGED: $n new commit(s) since ${dcommit:0:12} (newest $(git -C "$W/dots.git" rev-parse HEAD))"
    echo '```'; git -C "$W/dots.git" log --format='%h %ad %an: %s' --date=short "$dcommit..HEAD" | head -80; echo '```'
    echo "Changed files:"; echo '```'; git -C "$W/dots.git" diff --stat "$dcommit" HEAD | tail -60; echo '```'
    echo "manifest.toml (packages + install hooks) diff:"
    echo '```diff'; git -C "$W/dots.git" diff "$dcommit" HEAD -- manifest.toml; echo '```'
    echo "Full diff: git -C <clone> diff ${dcommit:0:12} HEAD"
fi
echo
echo "---"
echo "To approve after review:  tools/approve-update.sh   (then commit, push, tools/release.sh X.Y.Z)"
} >"$OUT"
echo "Report: $OUT  ($updates change(s) to review)"
