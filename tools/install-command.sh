#!/usr/bin/env bash
# Print the verified install command (for the README / to send to a friend).
# Usage: tools/install-command.sh [FINGERPRINT]   (default: keys/release-signing-key.fpr)
set -euo pipefail
cd "$(dirname "$0")/.."
F=${1:-$(<keys/release-signing-key.fpr)}
[[ $F =~ ^[0-9A-F]{40}$ ]] || { echo "need the 40-character signing key fingerprint" >&2; exit 1; }
REPO=${ARCH_SETUP_REPO:-KeremGr/arch-setup}
# Downloads the release, its signature and the public key; runs stage 1 ONLY if the signature
# was made by key $F (the fingerprint is part of the command, so a swapped key is rejected).
echo "F=$F;curl -fL --remote-name-all https://github.com/$REPO/releases/latest/download/{a.tgz,a.tgz.sig,k.asc}&&gpg --import k.asc&&gpg --status-fd 1 --verify a.tgz.sig|grep -q \"VALIDSIG.* \$F\$\"&&tar xf a.tgz&&bash a/stage1/install.sh"
