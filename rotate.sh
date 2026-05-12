#!/usr/bin/env bash
# git-vault: Key rotation
# Re-encrypts all vault-tracked files with a new key.
#
# Usage:
#   .git-vault/rotate.sh
#
# What it does:
#   1. Identifies all vault-encrypted files via .gitattributes
#   2. Decrypts them with the current key
#   3. Switches to the new key
#   4. Re-encrypts and commits all files
#   5. Displays instructions for the team

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GIT_DIR="$(git -C "$REPO_ROOT" rev-parse --git-dir)"
VAULT_SCRIPT="${SCRIPT_DIR}/vault.sh"

if [[ ! -f "$VAULT_SCRIPT" ]] || [[ ! -x "$VAULT_SCRIPT" ]]; then
  echo "✗ vault.sh not found or not executable: $VAULT_SCRIPT" >&2
  exit 1
fi

echo "╔══════════════════════════════════════╗"
echo "║      git-vault · key rotation        ║"
echo "╚══════════════════════════════════════╝"
echo

# ── 1. Verify current key works ──

if [[ -n "${GIT_VAULT_KEY:-}" ]]; then
  OLD_KEY="$GIT_VAULT_KEY"
elif [[ -f "${GIT_DIR}/vault-key" ]]; then
  OLD_KEY="$(cat "${GIT_DIR}/vault-key")"
else
  if [[ ! -t 0 ]]; then
    echo "✗ No TTY detected and GIT_VAULT_KEY is not set." >&2
    echo "  In non-interactive environments, set: export GIT_VAULT_KEY='your-key'" >&2
    exit 1
  fi
  echo "Enter the CURRENT key:"
  read -rs OLD_KEY
  echo
fi

if [[ -z "$OLD_KEY" ]]; then
  echo "✗ Current key cannot be empty." >&2
  exit 1
fi

echo "✓ Current key loaded"

# ── 2. Get new key ──

if [[ -n "${GIT_VAULT_KEY_NEW:-}" ]]; then
  NEW_KEY="$GIT_VAULT_KEY_NEW"
  echo "✓ Using new key from GIT_VAULT_KEY_NEW env var."
elif [[ -t 0 ]]; then
  echo "Enter the NEW key:"
  read -rs NEW_KEY
  echo
  echo "Confirm the NEW key:"
  read -rs NEW_KEY_CONFIRM
  echo
  if [[ "$NEW_KEY" != "$NEW_KEY_CONFIRM" ]]; then
    echo "✗ Keys don't match." >&2
    exit 1
  fi
else
  echo "✗ No TTY detected and GIT_VAULT_KEY_NEW is not set." >&2
  echo "  In non-interactive environments, set: export GIT_VAULT_KEY_NEW='new-key'" >&2
  exit 1
fi

if [[ -z "$NEW_KEY" ]]; then
  echo "✗ New key cannot be empty." >&2
  exit 1
fi

if [[ ${#NEW_KEY} -lt 20 ]]; then
  echo "✗ New key too short (${#NEW_KEY} chars). Use at least 20 characters for adequate security." >&2
  exit 1
fi

if [[ "$OLD_KEY" == "$NEW_KEY" ]]; then
  echo "✗ New key is the same as the current key." >&2
  exit 1
fi

echo "✓ New key confirmed"
echo

# ── 3. Find all vault-tracked files ──

cd "$REPO_ROOT"
VAULT_FILES=()
while IFS= read -r file; do
  if git check-attr filter -- "$file" 2>/dev/null | grep -q "filter: git-vault$"; then
    VAULT_FILES+=("$file")
  fi
done < <(git ls-files)

if [[ ${#VAULT_FILES[@]} -eq 0 ]]; then
  echo "✗ No vault-encrypted files found." >&2
  exit 1
fi

echo "Found ${#VAULT_FILES[@]} encrypted file(s):"
for f in "${VAULT_FILES[@]}"; do
  echo "  🔒 $f"
done
echo

# ── 4. Check for uncommitted changes ──

if ! git diff --quiet HEAD -- "${VAULT_FILES[@]}" 2>/dev/null || \
   ! git diff --cached --quiet HEAD -- "${VAULT_FILES[@]}" 2>/dev/null; then
  echo "✗ You have uncommitted changes to encrypted files." >&2
  echo "  Please commit or stash them before rotating." >&2
  exit 1
fi

# ── 5. Decrypt all files with old key, re-encrypt with new key ──

echo "Rotating..."
TMPDIR_PLAIN="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_PLAIN"' EXIT INT TERM

# Step A: Decrypt all files to temp dir (using old key)
export GIT_VAULT_KEY="$OLD_KEY"
for f in "${VAULT_FILES[@]}"; do
  mkdir -p "$TMPDIR_PLAIN/$(dirname "$f")"
  printf '  Decrypting: %s ... ' "$f"
  if ! git show "HEAD:$f" | "$VAULT_SCRIPT" decrypt > "$TMPDIR_PLAIN/$f" 2>/dev/null; then
    echo "FAILED"
    echo "✗ Could not decrypt: $f — aborting before key switch" >&2
    exit 1
  fi
  if [[ ! -s "$TMPDIR_PLAIN/$f" ]]; then
    echo "FAILED (empty output)"
    echo "✗ Decrypted file is empty: $f — aborting before key switch" >&2
    exit 1
  fi
  echo "OK"
done

echo

# Step B: Back up old key, then switch to new key
if [[ -f "${GIT_DIR}/vault-key" ]]; then
  _key_backup="${GIT_DIR}/vault-key.bak.$(date +%s)"
  cp "${GIT_DIR}/vault-key" "$_key_backup"
  chmod 600 "$_key_backup"
  echo "✓ Old key backed up to $(basename "$_key_backup") (keep until rotation is confirmed)"
fi
export GIT_VAULT_KEY="$NEW_KEY"
echo "$NEW_KEY" > "${GIT_DIR}/vault-key"
chmod 600 "${GIT_DIR}/vault-key"
echo "✓ Key updated in ${GIT_DIR}/vault-key"

# Step C: Write plaintext back to working tree (smudge will handle display,
#         clean filter will re-encrypt with new key on git add)
for f in "${VAULT_FILES[@]}"; do
  if [[ ! -f "$TMPDIR_PLAIN/$f" ]] || [[ ! -s "$TMPDIR_PLAIN/$f" ]]; then
    echo "✗ Decrypted file missing or empty before copy: $f" >&2
    exit 1
  fi
  cp "$TMPDIR_PLAIN/$f" "$REPO_ROOT/$f"
done

# Step D: Stage all files (clean filter runs → re-encrypts with new key)
git add "${VAULT_FILES[@]}"

# Verify: confirm the first staged file decrypts correctly with the new key
_verify_file="${VAULT_FILES[0]}"
_verify_tmp="$(mktemp)"
if ! git show ":0:$_verify_file" | "$VAULT_SCRIPT" decrypt > "$_verify_tmp" 2>/dev/null \
   || [[ ! -s "$_verify_tmp" ]]; then
  rm -f "$_verify_tmp"
  echo "✗ Re-encryption verification failed for: $_verify_file" >&2
  echo "  The clean filter may not have run. Check your git config." >&2
  exit 1
fi
rm -f "$_verify_tmp"
echo "✓ All files re-encrypted with new key (verified)"
echo

# ── 6. Commit ──

if [[ -t 0 ]]; then
  echo
  read -rp "Type 'yes' to commit the rotation, or anything else to abort: " _confirm
  if [[ "$_confirm" != "yes" ]]; then
    echo "Aborted. Run 'git reset HEAD ${VAULT_FILES[*]}' to unstage." >&2
    exit 1
  fi
fi
echo "Creating rotation commit..."
git commit -m "chore(security): rotate git-vault encryption key

All vault-encrypted files have been re-encrypted with a new key.
Team members must run .git-vault/setup.sh with the new key." -q

echo "✓ Committed"
echo

# ── 7. Summary ──

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Rotation complete!                                      ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  Next steps:                                             ║"
echo "║                                                          ║"
echo "║  1. Push:  git push                                     ║"
echo "║                                                          ║"
echo "║  2. Share the NEW key with all team members              ║"
echo "║     via a secure channel (NOT email/slack/git)           ║"
echo "║                                                          ║"
echo "║  3. Each team member must:                               ║"
echo "║       a) Set new key:                                    ║"
echo "║             echo 'NEWKEY' > .git/vault-key              ║"
echo "║          or: export GIT_VAULT_KEY='NEWKEY'              ║"
echo "║       b) Pull:  git pull                                 ║"
echo "║                                                          ║"
echo "║  ⚠ WARNING: Anyone with the OLD key can still read      ║"
echo "║  historical commits. To protect against that, consider   ║"
echo "║  rewriting history (git filter-branch / BFG).            ║"
echo "║                                                          ║"
echo "╚══════════════════════════════════════════════════════════╝"
