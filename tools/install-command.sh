#!/usr/bin/env bash
# Print the exact, verified install command for the README / to send to a friend.
# Usage: tools/install-command.sh [FINGERPRINT]   (default: git config user.signingkey)
set -euo pipefail
F=${1:-$(git config --get user.signingkey || true)}
[[ $F =~ ^[0-9A-F]{40}$ ]] || { echo "need the 40-character signing key fingerprint" >&2; exit 1; }
REPO=${ARCH_SETUP_REPO:-KeremGr/arch-setup}
U=https://github.com/$REPO/releases/latest/download
# 1. download the release, its signature and the public key
# 2. accept ONLY a valid signature made by key $F (the fingerprint is part of the command,
#    so a swapped key or archive is rejected)
# 3. unpack and start stage 1
cat <<EOF
F=$F; U=$U; cd /root && curl -fLO \$U/arch-setup.tar.gz -fLO \$U/arch-setup.tar.gz.sig -fLO \$U/release-signing-key.asc && gpg -q --import release-signing-key.asc && gpg --status-fd 1 --verify arch-setup.tar.gz.sig arch-setup.tar.gz 2>/dev/null | grep -qE "VALIDSIG .* \$F\$" && tar xzf arch-setup.tar.gz && bash arch-setup/stage1/install.sh || echo "NOT VERIFIED - do not continue"
EOF
