#!/usr/bin/env bash
# Record approval of reviewed upstream versions in the lock files (after reading the report
# from tools/check-upstream.sh). Approves the CURRENT upstream state of what you name:
#   tools/approve-update.sh caelestia-dots          newest Caelestia dotfiles commit
#   tools/approve-update.sh quickshell-git ...      newest AUR build files (+ newest upstream commit for -git)
# Shows exactly what it records; nothing is committed or released by this script.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
LOCK=$REPO/vetted/aur.lock
(( $# )) || { echo "usage: $0 caelestia-dots | <aur-package>..."; exit 1; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
dir_hash() { (cd "$1" && find . -type f ! -name .SRCINFO ! -path './.git/*' | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -c1-64); }
for name in "$@"; do
    if [[ $name == caelestia-dots ]]; then
        url=$(awk -F= '$1=="url"{print $2}' "$REPO/vetted/caelestia-dots.lock")
        git clone -q --bare "$url" "$W/dots.git"
        c=$(git -C "$W/dots.git" rev-parse HEAD)
        sed -i "s/^commit=.*/commit=$c/; s/^reviewed=.*/reviewed=$(date +%F)/" "$REPO/vetted/caelestia-dots.lock"
        echo "caelestia-dots -> $c"
        continue
    fi
    grep -q "^$name " "$LOCK" || { echo "$name is not in vetted/aur.lock"; exit 1; }
    git clone -q "https://aur.archlinux.org/$name.git" "$W/$name"
    git -C "$W/$name" archive HEAD | { mkdir "$W/t-$name"; tar -x -C "$W/t-$name"; }
    h=$(dir_hash "$W/t-$name")
    v=$(awk -F' = ' '/^\tpkgver/{print $2; exit}' "$W/$name/.SRCINFO")
    line="$name $v $h"
    if [[ $name == *-git ]]; then
        url=$(awk -F' = ' '/^\turl/{print $2; exit}' "$W/$name/.SRCINFO")
        c=$(git ls-remote "$url" HEAD | cut -f1)
        [[ $c =~ ^[0-9a-f]{40}$ ]] || { echo "could not read upstream HEAD for $name"; exit 1; }
        line+=" commit=$c"
    fi
    sed -i "s|^$name .*|$line|" "$LOCK"
    echo "$line"
done
sed -i "1s/(reviewed [0-9-]*)/(reviewed $(date +%F))/" "$LOCK"
echo
echo "Recorded. Review with: git diff vetted/   then commit, push, and tools/release.sh X.Y.Z"
