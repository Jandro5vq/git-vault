#!/usr/bin/env bash
# git-vault v2 — Transparent file encryption for git
# Binary-safe, HMAC-SHA256 integrity, format versioning
#
# Encrypted format (one value per line):
#   GITVAULT:2             format version
#   <iv_hex>               deterministic IV (32 hex)
#   <hmac_hex>             HMAC-SHA256 of ciphertext
#   <base64_ciphertext>    AES-256-CBC encrypted content

set -eo pipefail

VAULT_HEADER="GITVAULT:2"
CIPHER="aes-256-cbc"

# Global temp dir — created once, cleaned on exit
_VAULT_TMP="$(mktemp -d)"
chmod 700 "$_VAULT_TMP"
trap 'rm -rf "$_VAULT_TMP"' EXIT

# ──────────── key management ────────────

find_key() {
  if [[ -n "${GIT_VAULT_KEY:-}" ]]; then
    printf '%s' "$GIT_VAULT_KEY"
    return
  fi
  local git_dir
  git_dir="$(git rev-parse --git-dir 2>/dev/null || echo ".git")"
  if [[ -f "${git_dir}/vault-key" ]]; then
    cat "${git_dir}/vault-key"
    return
  fi
  echo >&2 "[git-vault] ERROR: no key found. Run: .git-vault/setup.sh"
  return 1
}

derive_aes_key() {
  printf 'git-vault:v2:aes-key:%s' "$1" \
    | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}'
}

derive_iv_from_hash() {
  printf 'git-vault:v2:iv:%s:%s' "$1" "$2" \
    | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}' | cut -c1-32
}

derive_hmac_key() {
  printf 'git-vault:v2:hmac-key:%s' "$1" \
    | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}'
}

# ──────────── encrypt (clean filter) ────────────

do_encrypt() {
  local passphrase
  passphrase="$(find_key)" || exit 1

  local tmp_plain="$_VAULT_TMP/plain"
  local tmp_enc="$_VAULT_TMP/cipher"

  # Binary-safe: stdin → file (not bash variable)
  cat > "$tmp_plain"

  # Don't double-encrypt
  if head -1 "$tmp_plain" 2>/dev/null | grep -q "^GITVAULT:"; then
    cat "$tmp_plain"
    return
  fi

  local content_hash aes_key iv hmac_key
  content_hash="$(openssl dgst -sha256 -hex "$tmp_plain" 2>/dev/null | awk '{print $NF}')"
  aes_key="$(derive_aes_key "$passphrase")"
  iv="$(derive_iv_from_hash "$passphrase" "$content_hash")"
  hmac_key="$(derive_hmac_key "$passphrase")"

  # Encrypt: file → file (binary-safe)
  openssl enc -${CIPHER} -nosalt \
    -K "$aes_key" -iv "$iv" \
    -in "$tmp_plain" -out "$tmp_enc" 2>/dev/null

  local b64_cipher
  b64_cipher="$(openssl base64 -A -in "$tmp_enc")"

  # Encrypt-then-MAC
  local hmac
  hmac="$(printf '%s' "$b64_cipher" | openssl dgst -sha256 -hmac "$hmac_key" -hex 2>/dev/null | awk '{print $NF}')"

  printf '%s\n%s\n%s\n%s\n' "$VAULT_HEADER" "$iv" "$hmac" "$b64_cipher"
}

# ──────────── decrypt (smudge filter) ────────────

do_decrypt() {
  local tmp_in="$_VAULT_TMP/input"
  local tmp_enc="$_VAULT_TMP/cipher_bin"

  cat > "$tmp_in"

  local header
  header="$(head -1 "$tmp_in")"

  if [[ "$header" != GITVAULT:* ]]; then
    cat "$tmp_in"
    return
  fi

  local version="${header#GITVAULT:}"
  if [[ "$version" != "2" ]]; then
    echo >&2 "[git-vault] WARNING: unknown format '$version'."
    cat "$tmp_in"
    return
  fi

  local passphrase
  passphrase="$(find_key)" || { cat "$tmp_in"; return; }

  local iv hmac_stored b64_cipher
  iv="$(sed -n '2p' "$tmp_in")"
  hmac_stored="$(sed -n '3p' "$tmp_in")"
  b64_cipher="$(sed -n '4p' "$tmp_in")"

  # Verify HMAC BEFORE decrypting
  local hmac_key hmac_computed
  hmac_key="$(derive_hmac_key "$passphrase")"
  hmac_computed="$(printf '%s' "$b64_cipher" | openssl dgst -sha256 -hmac "$hmac_key" -hex 2>/dev/null | awk '{print $NF}')"

  if [[ "$hmac_stored" != "$hmac_computed" ]]; then
    echo >&2 "[git-vault] HMAC mismatch — wrong key or tampered data. Run: .git-vault/vault.sh status"
    cat "$tmp_in"
    return
  fi

  local _ossl_err="$_VAULT_TMP/ossl_err"
  if ! printf '%s' "$b64_cipher" | openssl base64 -A -d -out "$tmp_enc" 2>"$_ossl_err"; then
    echo >&2 "[git-vault] ERROR: base64 decode failed: $(cat "$_ossl_err")"
    cat "$tmp_in"
    return
  fi

  local aes_key
  aes_key="$(derive_aes_key "$passphrase")"

  if ! openssl enc -${CIPHER} -nosalt -d \
    -K "$aes_key" -iv "$iv" \
    -in "$tmp_enc" 2>"$_ossl_err"; then
    echo >&2 "[git-vault] ERROR: decryption failed: $(cat "$_ossl_err")"
    cat "$tmp_in"
  fi
}

# ──────────── diff (textconv) ────────────

do_diff() {
  local file="${1:?missing file argument}"
  if head -1 "$file" 2>/dev/null | grep -q "^GITVAULT:"; then
    local self_dir
    self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if ! cat "$file" | "$self_dir/vault.sh" decrypt; then
      echo "[git-vault: cannot decrypt — run '.git-vault/vault.sh status' to diagnose]"
    fi
  else
    cat "$file"
  fi
}

# ──────────── status ────────────

do_status() {
  echo "git-vault v2"
  echo "────────────"
  if find_key >/dev/null 2>&1; then echo "✓ Key: configured"; else echo "✗ Key: NOT configured"; fi
  if git config --get filter.git-vault.clean >/dev/null 2>&1; then echo "✓ Filters: active"; else echo "✗ Filters: inactive"; fi
  echo ""
  echo "Encrypted files:"
  git ls-files 2>/dev/null | while read -r f; do
    git check-attr filter -- "$f" 2>/dev/null | grep -q "filter: git-vault$" && echo "  🔒 $f"
  done
}

# ──────────── main ────────────

case "${1:-}" in
  encrypt) do_encrypt ;;
  decrypt) do_decrypt ;;
  diff)    do_diff "${2:-}" ;;
  status)  do_status ;;
  *) echo >&2 "Usage: vault.sh {encrypt|decrypt|diff <file>|status}"; exit 1 ;;
esac
