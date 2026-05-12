#!/usr/bin/env bash
# git-vault setup: configures clean/smudge filters and stores the key.
# Run once after cloning:  .git-vault/setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GIT_DIR="$(git -C "$REPO_ROOT" rev-parse --git-dir)"

echo "╔══════════════════════════════════════╗"
echo "║         git-vault  ·  setup          ║"
echo "╚══════════════════════════════════════╝"
echo

# ---- 1. Ask for the key ----
if [[ -n "${GIT_VAULT_KEY:-}" ]]; then
  KEY="$GIT_VAULT_KEY"
  if [[ ! -f "${GIT_DIR}/vault-key" ]]; then
    echo "$KEY" > "${GIT_DIR}/vault-key"
    chmod 600 "${GIT_DIR}/vault-key"
    echo "✓ Key from GIT_VAULT_KEY saved to ${GIT_DIR}/vault-key"
  else
    echo "✓ Using key from GIT_VAULT_KEY env var (vault-key file already exists)."
  fi
elif [[ -f "${GIT_DIR}/vault-key" ]]; then
  echo "✓ Key already present at ${GIT_DIR}/vault-key"
  KEY="$(cat "${GIT_DIR}/vault-key")"
else
  echo "Enter the shared vault key (will be stored in .git/vault-key):"
  read -rs KEY
  echo
  if [[ -z "$KEY" ]]; then
    echo "✗ Key cannot be empty." >&2
    exit 1
  fi
  if [[ ${#KEY} -lt 20 ]]; then
    echo "✗ Key too short (${#KEY} chars). Use at least 20 characters for adequate security." >&2
    exit 1
  fi
  echo "$KEY" > "${GIT_DIR}/vault-key"
  chmod 600 "${GIT_DIR}/vault-key"
  echo "✓ Key saved to ${GIT_DIR}/vault-key"
fi

echo

# ---- 2. Generate PBKDF2 salt ----
VAULT_SALT_FILE="${REPO_ROOT}/.git-vault/vault-salt"
if [[ ! -f "$VAULT_SALT_FILE" ]]; then
  openssl rand -hex 32 > "$VAULT_SALT_FILE"
  echo "✓ PBKDF2 salt generated at .git-vault/vault-salt"
  echo "  Commit this file — it is not secret, just prevents rainbow tables."
else
  echo "✓ PBKDF2 salt already present at .git-vault/vault-salt"
fi

echo

# ---- 3. Configure git filters ----
VAULT_SCRIPT="${SCRIPT_DIR}/vault.sh"

git -C "$REPO_ROOT" config filter.git-vault.clean  "$VAULT_SCRIPT encrypt"
git -C "$REPO_ROOT" config filter.git-vault.smudge "$VAULT_SCRIPT decrypt"
git -C "$REPO_ROOT" config filter.git-vault.required true

git -C "$REPO_ROOT" config diff.git-vault.textconv "$VAULT_SCRIPT diff"

echo "✓ Git filters configured:"
echo "    filter.git-vault.clean  = $VAULT_SCRIPT encrypt"
echo "    filter.git-vault.smudge = $VAULT_SCRIPT decrypt"
echo "    diff.git-vault.textconv = $VAULT_SCRIPT diff"

# Also wire the committed gitconfig so teammates using join.sh get the same result
GITCONFIG_REL="../.git-vault/gitconfig"
if ! git -C "$REPO_ROOT" config --local --get-all include.path 2>/dev/null | grep -qF "$GITCONFIG_REL"; then
  git -C "$REPO_ROOT" config --local --add include.path "$GITCONFIG_REL"
fi
echo

# ---- 4. Ensure .git-vault/vault.sh is executable ----
chmod +x "$VAULT_SCRIPT"
echo "✓ ${VAULT_SCRIPT} marked as executable"
echo

# ---- 5. Remind about .gitattributes ----
GITATTR="${REPO_ROOT}/.gitattributes"
if [[ ! -f "$GITATTR" ]] || ! grep -q "git-vault" "$GITATTR" 2>/dev/null; then
  echo "⚠ Don't forget to mark files in .gitattributes. Example:"
  echo
  echo "    secrets/**  filter=git-vault diff=git-vault"
  echo "    *.secret    filter=git-vault diff=git-vault"
  echo "    .env        filter=git-vault diff=git-vault"
  echo
fi

# ---- 6. Re-checkout encrypted files so smudge filter decrypts them ----
echo "Refreshing working tree to apply decryption..."
# Remove vault-tracked files and re-checkout (forces smudge filter to run)
cd "$REPO_ROOT" || { echo "✗ Cannot cd to repo root: $REPO_ROOT" >&2; exit 1; }
git ls-files 2>/dev/null | while read -r f; do
  if git check-attr filter -- "$f" 2>/dev/null | grep -q "filter: git-vault$"; then
    rm -f "$f" 2>/dev/null
  fi
done
if ! git checkout -- . 2>/dev/null; then
  echo "⚠ Some files may not have been decrypted automatically." >&2
  echo "  Run 'git checkout -- .' manually if needed." >&2
fi

# ---- 7. Renormalize index so git doesn't see decrypted files as "dirty" ----
git add --renormalize . 2>/dev/null || true

# ---- 8. Self-test: verify encrypt/decrypt round-trip ----
echo "Running self-test..."
_test_str="git-vault-self-test-$$"
_test_out="$(printf '%s' "$_test_str" | "$VAULT_SCRIPT" encrypt | "$VAULT_SCRIPT" decrypt 2>/dev/null)"
if [[ "$_test_out" == "$_test_str" ]]; then
  echo "✓ Self-test passed: encrypt/decrypt round-trip verified"
else
  echo "✗ Self-test FAILED — encryption may not be working correctly" >&2
  exit 1
fi
echo
echo "✓ Done! Files matching your .gitattributes rules will now be"
echo "  encrypted on commit and decrypted on checkout automatically."
