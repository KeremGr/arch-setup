#!/usr/bin/env bash
# Shared checks for the git hooks. Any failure blocks the commit/push.
set -euo pipefail
ROOT=$(git rev-parse --show-toplevel)
red=$'\e[1;31m'; grn=$'\e[1;32m'; off=$'\e[0m'
fail() { printf '%s✗ BLOCKED:%s %s\n' "$red" "$off" "$*" >&2; exit 1; }
pass() { printf '%s✓%s %s\n' "$grn" "$off" "$*"; }

check_identity() {
    local approved email name
    approved=$(git config --get arch-setup.approvedEmail || true)
    email=$(git config --get user.email || true)
    name=$(git config --get user.name || true)
    [[ -n $approved ]] || fail "no approved email yet (set from the exact address shown in GitHub settings)"
    [[ $approved == *@users.noreply.github.com ]] || fail "approved email is not a GitHub noreply address"
    [[ $email == "$approved" ]] || fail "user.email ($email) is not the approved noreply address"
    [[ -n $name ]] || fail "user.name is not set"
    [[ $name == "$(git config --get arch-setup.approvedName || true)" ]] || fail "user.name ($name) is not the approved name"
    pass "identity: $name <$email>"
}

check_ignored_not_tracked() {
    # Files matching .gitignore must not be in the index...
    local bad
    bad=$(git ls-files -ci --exclude-standard)
    [[ -z $bad ]] || fail "ignored files are tracked:"$'\n'"$bad"
    # ...nor anywhere in history.
    bad=$(git log --all --name-only --format= 2>/dev/null | sort -u | git check-ignore --no-index --stdin || true)
    [[ -z $bad ]] || fail "ignored files exist in git history (rewrite history before pushing):"$'\n'"$bad"
    pass "no ignored files tracked or in history"
}

need_gitleaks() { command -v gitleaks >/dev/null || fail "gitleaks is not installed"; }
