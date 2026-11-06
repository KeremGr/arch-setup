#!/usr/bin/env bash
# Print the verified install command (for the README / to send to a friend).
# Usage: tools/install-command.sh [FINGERPRINT]   (default: keys/release-signing-key.fpr)
set -euo pipefail
cd "$(dirname "$0")/.."
F=${1:-$(<keys/release-signing-key.fpr)}
[[ $F =~ ^[0-9A-F]{40}$ ]] || { echo "need the 40-character signing key fingerprint" >&2; exit 1; }
REPO=${ARCH_SETUP_REPO:-KeremGr/arch-setup}
# Downloads the release (a.tgz), its signature (a.sig) and the public key (k). gpgv checks the
# signature against ONLY that key, and the run continues only if the signer's full fingerprint
# is exactly $F (VALIDSIG), so a swapped key or archive is rejected before anything runs.
echo "curl -fLOOO https://github.com/$REPO/releases/latest/download/{a.tgz,a.sig,k}&&gpgv --status-fd 1 --keyring ./k a.sig a.tgz|grep -q \"VALIDSIG.* $F\$\"&&tar xf a.tgz&&bash a/i"
