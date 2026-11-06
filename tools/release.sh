#!/usr/bin/env bash
# Publish a signed release.  Usage: tools/release.sh 1.0.0   (needs VERSION + a CHANGELOG.md section)
#
# Trust model: the install command people type contains the signing key's FINGERPRINT.
# It accepts a download only if it carries a valid signature from exactly that key, so a
# hacked GitHub account or a swapped release file is rejected. The private key never
# leaves this PC (passphrase-protected); only its public half is published.
#
# Steps (stops at the first problem; nothing is pushed before you approve it):
#   1. clean tree on main, signing key configured, gh logged in
#   2. full privacy audit + Gitleaks over the whole history
#   3. signed tag vX.Y.Z (verified)
#   4. dist/a.tgz from that tag + signature (a.sig) + public key (k) + signed SHA256SUMS (all verified)
#   5. shows exactly what will be published -> you type the version to approve
#   6. pushes the tag and creates the GitHub release with those files
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
V=${1:?usage: tools/release.sh 1.0.0}
[[ $V =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must look like 1.2.3"; exit 1; }
T=v$V
die() { printf '\e[1;31m  ✗ %s\e[0m\n' "$*" >&2; exit 1; }
ok()  { printf '\e[1;32m  ✓\e[0m %s\n' "$*"; }

KEY=$(git config --get user.signingkey || true)
[[ $KEY =~ ^[0-9A-F]{40}$ ]] || die "git config user.signingkey must be the full 40-character fingerprint"
gpg --list-secret-keys "$KEY" >/dev/null 2>&1 || die "signing key $KEY not in this keyring"
[[ $(git branch --show-current) == main ]] || die "not on main"
[[ -z $(git status --porcelain) ]] || die "uncommitted changes"
git rev-parse -q --verify "refs/tags/$T" >/dev/null && die "tag $T already exists"
[[ $(<VERSION) == "$V" ]] || die "VERSION file says $(<VERSION), not $V — update VERSION + CHANGELOG.md and commit first"
grep -q "^## $V" CHANGELOG.md || die "CHANGELOG.md has no '## $V' section"
[[ $(<keys/release-signing-key.fpr) == "$KEY" ]] || die "keys/release-signing-key.fpr doesn't match the signing key"
gh auth status >/dev/null 2>&1 || die "gh is not logged in"
ok "clean main, key ${KEY: -16}, gh logged in"

python3 -I tools/privacy-audit.py --all || die "privacy audit failed"
gitleaks git --redact --no-banner . || die "gitleaks failed"
ok "privacy + secrets: whole history clean"

git tag -s "$T" -u "$KEY" -m "arch-setup $T"
git tag -v "$T" 2>&1 | grep -q "Good signature" || { git tag -d "$T"; die "tag signature did not verify"; }
ok "signed tag $T"

rm -rf dist; mkdir dist
# Short names keep the install command short: a.tgz (unpacks to a/), a.sig, k (binary public key
# for gpgv). a.tgz.sig + k.asc are the same data under the v1.0.0 names, for older updaters.
git archive --format=tar.gz --prefix=a/ -o dist/a.tgz "$T"
gpg --batch --yes -u "$KEY" --detach-sign -o dist/a.sig dist/a.tgz
cp dist/a.sig dist/a.tgz.sig
gpg --export "$KEY" >dist/k
gpg --export --armor "$KEY" >dist/k.asc
(cd dist && sha256sum a.tgz a.sig a.tgz.sig k k.asc >SHA256SUMS)
gpg --batch --yes -u "$KEY" --detach-sign -o dist/SHA256SUMS.sig dist/SHA256SUMS
# Verify exactly like the install command will (gpgv with only the published key)
gpgv --status-fd 1 --keyring ./dist/k dist/a.sig dist/a.tgz 2>/dev/null | grep -qE "VALIDSIG .* $KEY\$" \
    || { git tag -d "$T"; die "release signature does not verify against $KEY"; }
ok "dist/ built and verified"

echo
echo "  ── Will be published ─────────────────────────────────────────"
echo "  tag:     $T  ($(git rev-parse --short "$T"^{commit}))"
echo "  files:"; ls -l dist | tail -n +2 | sed 's/^/    /'
echo "  archive contents:"; tar -tzf dist/a.tgz | sed 's/^/    /'
echo "  ──────────────────────────────────────────────────────────────"
read -r -p "  Type $V to publish, anything else cancels: " a
[[ $a == "$V" ]] || { git tag -d "$T" >/dev/null; die "cancelled (tag removed, nothing pushed)"; }

git push origin "$T"
gh release create "$T" dist/* --verify-tag --title "arch-setup $T" --notes "Verify before running — see the README (Install)."
ok "released $T"
