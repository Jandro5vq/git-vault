#!/usr/bin/env bash
# git-vault — Transparent file encryption for git
# Binary-safe, HMAC-SHA256 integrity, format versioning
#
# Supported formats:
#   GITVAULT:2   — AES-256-CBC, SHA-256 key derivation, deterministic IV (legacy)
#   GITVAULT:2.1 — AES-256-CBC, PBKDF2-SHA256 key derivation (600k iter), random IV
#
# Encrypted format (one value per line):
#   GITVAULT:<version>     format version
#   <iv_hex>               IV (32 hex chars = 16 bytes)
#   <hmac_hex>             HMAC-SHA256 of ciphertext (encrypt-then-MAC)
#   <base64_ciphertext>    AES-256-CBC encrypted content

set -eo pipefail

CIPHER="aes-256-cbc"
PBKDF2_ITER=600000

# ──────────── secure temp dir ────────────

_VAULT_TMP="$(mktemp -d)"
chmod 700 "$_VAULT_TMP"

_secure_rm() {
  if command -v shred >/dev/null 2>&1; then
    find "$1" -type f -exec shred -uzn 1 {} \; 2>/dev/null || true
  fi
  rm -rf "$1"
}
trap '_secure_rm "$_VAULT_TMP"' EXIT INT TERM

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

_find_salt() {
  local repo_root
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
  printf '%s/.git-vault/vault-salt' "$repo_root"
}

# PBKDF2-SHA256 via openssl enc: encrypts /dev/null to extract the derived key bytes.
# Available since OpenSSL 1.1.0 / LibreSSL 3.3 (2021).
derive_master_key() {
  local passphrase="$1" salt_file="$2"
  local salt_hex
  salt_hex="$(cat "$salt_file")"
  printf '%s' "$passphrase" \
    | openssl enc -aes-256-cbc \
        -pbkdf2 -iter "$PBKDF2_ITER" -md sha256 \
        -S "$salt_hex" -pass stdin \
        -in /dev/null -out /dev/null -p 2>/dev/null \
    | awk -F= '/^key=/{print $2}'
}

# Domain-separated key derivation (SHA-256). Input is master key (PBKDF2) or raw passphrase (v2).
derive_aes_key() {
  printf 'git-vault:v2:aes-key:%s' "$1" \
    | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}'
}

derive_hmac_key() {
  printf 'git-vault:v2:hmac-key:%s' "$1" \
    | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}'
}

# Legacy v2: deterministic IV derived from passphrase + content hash
_derive_iv_v2() {
  printf 'git-vault:v2:iv:%s:%s' "$1" "$2" \
    | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}' | cut -c1-32
}

# ──────────── encrypt (clean filter) ────────────

do_encrypt() {
  local passphrase
  passphrase="$(find_key)" || exit 1

  local tmp_plain="$_VAULT_TMP/plain"
  local tmp_enc="$_VAULT_TMP/cipher"

  cat > "$tmp_plain"

  # Don't double-encrypt
  if head -1 "$tmp_plain" 2>/dev/null | grep -q "^GITVAULT:"; then
    cat "$tmp_plain"
    return
  fi

  local salt_file
  salt_file="$(_find_salt)"

  local header master_key iv
  if [[ -f "$salt_file" ]]; then
    header="GITVAULT:2.1"
    master_key="$(derive_master_key "$passphrase" "$salt_file")"
    iv="$(openssl rand -hex 16)"
  else
    # Legacy path: no salt → v2 format with SHA-256 and deterministic IV
    header="GITVAULT:2"
    master_key="$passphrase"
    local content_hash
    content_hash="$(openssl dgst -sha256 -hex "$tmp_plain" 2>/dev/null | awk '{print $NF}')"
    iv="$(_derive_iv_v2 "$passphrase" "$content_hash")"
  fi

  local aes_key hmac_key
  aes_key="$(derive_aes_key "$master_key")"
  hmac_key="$(derive_hmac_key "$master_key")"

  openssl enc -${CIPHER} -nosalt \
    -K "$aes_key" -iv "$iv" \
    -in "$tmp_plain" -out "$tmp_enc" 2>/dev/null

  local b64_cipher
  b64_cipher="$(openssl base64 -A -in "$tmp_enc")"

  local hmac
  hmac="$(printf '%s' "$b64_cipher" | openssl dgst -sha256 -hmac "$hmac_key" -hex 2>/dev/null | awk '{print $NF}')"

  printf '%s\n%s\n%s\n%s\n' "$header" "$iv" "$hmac" "$b64_cipher"
}

# ──────────── decrypt (smudge filter) ────────────

_do_decrypt_body() {
  local version="$1" passphrase="$2" tmp_in="$3" tmp_enc="$4"

  local iv hmac_stored b64_cipher
  iv="$(sed -n '2p' "$tmp_in")"
  hmac_stored="$(sed -n '3p' "$tmp_in")"
  b64_cipher="$(sed -n '4p' "$tmp_in")"

  local master_key
  if [[ "$version" == "2.1" ]]; then
    local salt_file
    salt_file="$(_find_salt)"
    if [[ ! -f "$salt_file" ]]; then
      echo >&2 "[git-vault] ERROR: vault-salt not found but file is GITVAULT:2.1."
      echo >&2 "  Run: .git-vault/join.sh  (to fetch the salt from the committed repo)"
      exit 1
    fi
    master_key="$(derive_master_key "$passphrase" "$salt_file")"
  else
    master_key="$passphrase"
  fi

  local hmac_key hmac_computed
  hmac_key="$(derive_hmac_key "$master_key")"
  hmac_computed="$(printf '%s' "$b64_cipher" | openssl dgst -sha256 -hmac "$hmac_key" -hex 2>/dev/null | awk '{print $NF}')"

  if [[ "$hmac_stored" != "$hmac_computed" ]]; then
    echo >&2 "[git-vault] HMAC mismatch — wrong key or tampered data. Run: .git-vault/vault.sh status"
    exit 1
  fi

  local _ossl_err="$_VAULT_TMP/ossl_err"
  if ! printf '%s' "$b64_cipher" | openssl base64 -A -d -out "$tmp_enc" 2>"$_ossl_err"; then
    echo >&2 "[git-vault] ERROR: base64 decode failed: $(cat "$_ossl_err")"
    exit 1
  fi

  local aes_key
  aes_key="$(derive_aes_key "$master_key")"

  if ! openssl enc -${CIPHER} -nosalt -d \
    -K "$aes_key" -iv "$iv" \
    -in "$tmp_enc" 2>"$_ossl_err"; then
    echo >&2 "[git-vault] ERROR: decryption failed: $(cat "$_ossl_err")"
    exit 1
  fi
}

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
  if [[ "$version" != "2" && "$version" != "2.1" ]]; then
    echo >&2 "[git-vault] ERROR: unsupported format 'GITVAULT:${version}' — refusing to output plaintext."
    exit 1
  fi

  local passphrase
  passphrase="$(find_key)" || exit 1

  _do_decrypt_body "$version" "$passphrase" "$tmp_in" "$tmp_enc"
}

# ──────────── upgrade (v2 → v2.1) ────────────

do_upgrade() {
  if ! find_key >/dev/null 2>&1; then
    echo >&2 "[git-vault] ERROR: no key found. Run: .git-vault/setup.sh"
    exit 1
  fi

  local salt_file
  salt_file="$(_find_salt)"
  if [[ ! -f "$salt_file" ]]; then
    echo >&2 "[git-vault] ERROR: vault-salt not found. Run setup.sh first to generate it."
    exit 1
  fi

  local self_dir
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  local repo_root upgraded=0
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"

  while IFS= read -r f; do
    if git check-attr filter -- "$f" 2>/dev/null | grep -q "filter: git-vault$"; then
      local stored_ver
      stored_ver="$(git -C "$repo_root" show HEAD:"$f" 2>/dev/null | head -1)"
      if [[ "$stored_ver" == "GITVAULT:2" ]]; then
        printf '  Upgrading: %s ... ' "$f"
        # --renormalize forces the clean filter to re-run even if the stat cache
        # thinks the file is already staged correctly.
        if git -C "$repo_root" add --renormalize "$f" 2>/dev/null; then
          local new_ver
          new_ver="$(git -C "$repo_root" show :"$f" 2>/dev/null | head -1)"
          if [[ "$new_ver" == "GITVAULT:2.1" ]]; then
            echo "OK"
            (( upgraded++ )) || true
          else
            echo "FAILED (unexpected format: ${new_ver:-empty})"
            echo >&2 "  ✗ $f staged but format not GITVAULT:2.1 — check vault-salt"
          fi
        else
          echo "FAILED (git add error)"
          echo >&2 "  ✗ Could not stage $f"
        fi
      fi
    fi
  done < <(git -C "$repo_root" ls-files 2>/dev/null)

  if [[ $upgraded -eq 0 ]]; then
    echo "All vault-tracked files are already at GITVAULT:2.1 (or none found)."
  else
    echo
    echo "✓ Upgraded $upgraded file(s) to GITVAULT:2.1"
    echo "  Commit with: git commit -m 'chore(security): upgrade to GITVAULT:2.1'"
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
  echo "git-vault v2.1"
  echo "──────────────"

  if find_key >/dev/null 2>&1; then
    echo "✓ Key: configured"
  else
    echo "✗ Key: NOT configured"
  fi

  local salt_file
  salt_file="$(_find_salt)"
  if [[ -f "$salt_file" ]]; then
    echo "✓ KDF: PBKDF2-SHA256 (${PBKDF2_ITER} iterations, salt present)"
  else
    echo "✗ KDF: SHA-256 only (vault-salt missing — run setup.sh to enable PBKDF2)"
  fi

  if git config --get filter.git-vault.clean >/dev/null 2>&1 \
     || git config --local --get-all include.path 2>/dev/null | grep -q "git-vault"; then
    echo "✓ Filters: active"
  else
    echo "✗ Filters: inactive"
  fi

  echo
  echo "Encrypted files:"
  local found=0
  while IFS= read -r f; do
    if git check-attr filter -- "$f" 2>/dev/null | grep -q "filter: git-vault$"; then
      local ver
      ver="$(git show HEAD:"$f" 2>/dev/null | head -1 | grep -oE 'GITVAULT:[0-9.]+')"
      echo "  🔒 $f  [${ver:-unknown}]"
      found=1
    fi
  done < <(git ls-files 2>/dev/null)
  if [[ $found -eq 0 ]]; then echo "  (none)"; fi
}

# ──────────── main ────────────

case "${1:-}" in
  encrypt) do_encrypt ;;
  decrypt) do_decrypt ;;
  diff)    do_diff "${2:-}" ;;
  status)  do_status ;;
  upgrade) do_upgrade ;;
  *) echo >&2 "Usage: vault.sh {encrypt|decrypt|diff <file>|status|upgrade}"; exit 1 ;;
esac
