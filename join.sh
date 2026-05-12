#!/usr/bin/env bash
# git-vault: onboard a new developer
# Run once after cloning. Only asks for the shared key — everything else
# is already configured in the committed repo.
#
# Usage:
#   .git-vault/join.sh
#   GIT_VAULT_KEY='the-shared-key' .git-vault/join.sh   # non-interactive / CI

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GIT_DIR="$(git -C "$REPO_ROOT" rev-parse --git-dir)"
VAULT_SCRIPT="${SCRIPT_DIR}/vault.sh"

if [[ ! -f "$VAULT_SCRIPT" ]]; then
  echo "✗ vault.sh not found at $VAULT_SCRIPT" >&2
  exit 1
fi

echo "╔══════════════════════════════════════╗"
echo "║       git-vault  ·  join             ║"
echo "╚══════════════════════════════════════╝"
echo

# ---- 1. Wire filters via the committed gitconfig (one include line) --------

GITCONFIG_REL="../.git-vault/gitconfig"
if git -C "$REPO_ROOT" config --local --get-all include.path 2>/dev/null | grep -qF "$GITCONFIG_REL"; then
  echo "✓ Filters already wired (include.path present)"
else
  git -C "$REPO_ROOT" config --local --add include.path "$GITCONFIG_REL"
  echo "✓ Filters wired via .git-vault/gitconfig"
fi

echo

# ---- 2. Get and save the key ------------------------------------------------

if [[ -n "${GIT_VAULT_KEY:-}" ]]; then
  KEY="$GIT_VAULT_KEY"
  if [[ ! -f "${GIT_DIR}/vault-key" ]]; then
    echo "$KEY" > "${GIT_DIR}/vault-key"
    chmod 600 "${GIT_DIR}/vault-key"
    echo "✓ Key from GIT_VAULT_KEY saved to ${GIT_DIR}/vault-key"
  else
    echo "✓ Key already present at ${GIT_DIR}/vault-key (GIT_VAULT_KEY ignored)"
  fi
elif [[ -f "${GIT_DIR}/vault-key" ]]; then
  KEY="$(cat "${GIT_DIR}/vault-key")"
  echo "✓ Key already present at ${GIT_DIR}/vault-key"
else
  if [[ ! -t 0 ]]; then
    echo "✗ No TTY and GIT_VAULT_KEY is not set." >&2
    echo "  In non-interactive environments: export GIT_VAULT_KEY='your-key'" >&2
    exit 1
  fi
  echo "Enter the shared vault key:"
  read -rs KEY
  echo
  if [[ -z "$KEY" ]]; then
    echo "✗ Key cannot be empty." >&2
    exit 1
  fi
  echo "$KEY" > "${GIT_DIR}/vault-key"
  chmod 600 "${GIT_DIR}/vault-key"
  echo "✓ Key saved to ${GIT_DIR}/vault-key"
fi

echo

# ---- 3. Decrypt vault-tracked files on disk --------------------------------

echo "Decrypting files..."
cd "$REPO_ROOT"
git ls-files 2>/dev/null | while read -r f; do
  if git check-attr filter -- "$f" 2>/dev/null | grep -q "filter: git-vault$"; then
    rm -f "$f"
  fi
done
if ! git checkout -- . 2>/dev/null; then
  echo "⚠ Some files may not have been decrypted automatically." >&2
  echo "  Run 'git checkout -- .' manually if needed." >&2
fi

# ---- 4. Self-test -----------------------------------------------------------

echo "Running self-test..."
_test_str="git-vault-join-$$"
_test_out="$(printf '%s' "$_test_str" | "$VAULT_SCRIPT" encrypt | "$VAULT_SCRIPT" decrypt 2>/dev/null)"
if [[ "$_test_out" == "$_test_str" ]]; then
  echo "✓ Self-test passed"
else
  echo "✗ Self-test FAILED — check your key and try again" >&2
  exit 1
fi

echo
echo "✓ Done! Encrypted files will decrypt automatically on checkout."
