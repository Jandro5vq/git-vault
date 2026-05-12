# git-vault: Security Analysis

## Executive summary

git-vault is a pragmatic solution for small teams that need to encrypt secrets in a git repository without installing external tools. The primary threat model is: **an attacker who gains read access to the repository (GitHub breach, accidentally public repo, ex-employee).**

---

## What it protects

- Content of files marked in `.gitattributes`
- History of those files in git (all previous commits)
- An attacker with the repo but without the key gets only ciphertext

## What it does NOT protect (inherent limitations)

| Not protected | Reason |
|---|---|
| Filenames | Git stores them in plaintext; visible in `git ls-tree` |
| Commit messages | Plaintext in the git object store |
| Metadata | Dates, sizes, whether content changed |
| Unmarked files | Only files listed in `.gitattributes` are encrypted |
| Individual revocation | One shared key = cannot revoke one person without rotating for everyone |
| Memory on a compromised machine | If the system is compromised, an attacker can read plaintext from the process |

---

## Cryptographic analysis

### Strengths

**AES-256-CBC with PBKDF2-SHA256-derived key (GITVAULT:2.1)**
Key length: 256 bits. AES-256 has no known practical attacks.
The master key is derived via PBKDF2-SHA256 at 600,000 iterations with a per-repo salt stored in `.git-vault/vault-salt`. AES and HMAC keys are then derived from the master key with domain-separated SHA-256: `SHA-256("git-vault:v2:aes-key:" + master_key)`.

**Encrypt-then-MAC (HMAC-SHA256)**
The correct pattern for CBC: the ciphertext is authenticated **before** decryption.
Guards against padding oracle attacks and tampering detection.
The HMAC key is derived independently: `SHA-256("git-vault:v2:hmac-key:" + master_key)`.

**Random IV (GITVAULT:2.1)**
`IV = openssl rand -hex 16` — 128 bits of CSPRNG output per encryption.
Eliminates the deterministic IV correlation attack present in GITVAULT:2. Re-encrypting the same file produces different ciphertext each time (except when the double-encrypt guard fires, which returns the existing ciphertext unchanged).

**Binary-safe**
stdin is written to a temp file before processing; never passed through bash variables (which truncate null bytes). Round-trip verified with all values 0x00–0xFF.

**Domain separation in key derivation**
Each purpose has its own prefix: `aes-key:`, `hmac-key:`.
Prevents reuse of cryptographic material across different uses.

**Hardened temp directory**
The temp directory is created with mode 700 immediately after `mktemp -d`, preventing other users from reading plaintext on shared systems.

**Secure temp file deletion**
Plaintext temp files are wiped with `shred -uzn 1` (if available) before `rm -rf`, overwriting disk sectors to reduce forensic recoverability.

### Known weaknesses and mitigations

**AES-CBC instead of AES-GCM**

`openssl enc` does not support AEAD (GCM). CBC with external HMAC (Encrypt-then-MAC) is security-equivalent, but is more code and more error surface.
With HMAC-SHA256 correctly implemented, the difference is academic.

**The IV is stored in plaintext**

The IV is stored in the encrypted file header (required for decryption). In GITVAULT:2, the IV was deterministic, so an attacker could detect whether two commits encrypted the same content. In GITVAULT:2.1, the IV is random — this leaks only that a file was *re-encrypted* (not whether the content changed), which is acceptable.

**Shared salt for PBKDF2**

The salt in `.git-vault/vault-salt` is per-repo (committed) but shared across all team members. This is correct — it prevents rainbow tables while allowing the team to derive the same master key from the same passphrase. It does not provide per-user isolation; that requires GPG (out of scope for this tool).

**Plaintext in temporary files**

Plaintext is written to `$TMPDIR` (via `mktemp`). If the disk is not encrypted (FileVault/LUKS), residual plaintext may persist in freed disk sectors.

Current mitigations:
- Temp directory created with mode 700 (prevents access by other users)
- `shred -uzn 1` overwrites temp files before removal when `shred` is available
- Trap on `EXIT INT TERM` ensures cleanup runs on Ctrl-C and kill signals

Remaining gap: on systems without `shred` (macOS, BSD), only `rm` runs. Mount `$TMPDIR` on a `tmpfs` (RAM-backed) for complete mitigation.

**Legacy GITVAULT:2 format**

Old GITVAULT:2 files use SHA-256 key derivation (no iterations) and a deterministic IV. Run `vault.sh upgrade` to migrate all tracked files to GITVAULT:2.1. After the upgrade commit, old v2 decryption still works for reading history.

---

## Trust model and key rotation

### When to rotate?

| Event | Action |
|---|---|
| A team member leaves | **Always rotate.** They already have the key and can read the history. |
| Suspected key compromise | **Rotate immediately.** |
| Periodic policy (e.g. every 6 months) | Good practice, optional. |
| Key spotted in logs/Slack | **Rotate immediately.** |

### What rotation covers

`rotate.sh` re-encrypts all marked files with the new key and creates a new commit. From that commit forward, the old key cannot decrypt the content.

The rotation script includes several safeguards:
- **Pre-switch verification:** all files are decrypted with the old key before the key file is overwritten — if any file fails, the script aborts
- **Key backup:** the old key is copied to `.git/vault-key.bak.<timestamp>` (mode 600) before being replaced, providing a recovery path if rotation fails partway through
- **Re-encryption verification:** after `git add`, one staged file is decrypted with the new key to confirm the clean filter ran correctly
- **Commit confirmation:** in interactive mode the script pauses and requires `yes` before committing, so you can inspect staged files first

**The previous history remains decryptable with the old key.**
An attacker (ex-employee, etc.) who already had the key can read earlier commits.
To remove secrets from history:

```bash
# Option 1: BFG Repo Cleaner (faster)
bfg --replace-text patterns.txt repo.git

# Option 2: git filter-repo
git filter-repo --force

# After rewriting history:
git push --force-with-lease origin master
# All clones must: git fetch && git reset --hard origin/master
```

**If the repo was public or was accessed by the attacker before rotation, assume all secrets in the history are compromised and rotate them in the corresponding services (AWS, Stripe, etc.).**

---

## Comparison with git-crypt

| Feature | git-vault | git-crypt |
|---|---|---|
| Installation | None (only openssl) | External binary |
| Cipher | AES-256-CBC + HMAC | AES-256-CTR + HMAC |
| Cryptographic security | Equivalent | Slightly better (CTR is cleaner) |
| Integrity | HMAC-SHA256 ✓ | HMAC-SHA1 (old) / SHA256 (new) |
| Binary files | ✓ | ✓ |
| KDF | PBKDF2-SHA256, 600k iter (v2.1) / SHA-256 (v2 legacy) | No explicit KDF |
| Key rotation | ✓ (rotate.sh, with verification and backup) | Manual |
| Format versioning | ✓ (GITVAULT:2) | Yes |
| GPG (multi-user) | ✗ | ✓ |
| Maintenance | In your repo | External project |

---

## Roadmap

### GITVAULT:2.1 — Implemented
- [x] Automatic integrity self-test in `setup.sh`
- [x] Key length enforcement (minimum 20 characters)
- [x] Hardened temp directory (mode 700)
- [x] Signal handling for temp cleanup (EXIT INT TERM)
- [x] Key backup before rotation + pre/post verification
- [x] `shred` before `rm` for temp file wiping
- [x] PBKDF2-SHA256 key derivation (600k iterations, shared repo salt)
- [x] Random IV — eliminates deterministic IV correlation
- [x] Hard-fail on unknown versions / decryption errors (no plaintext fallback)
- [x] `vault.sh upgrade` subcommand for in-place v2 → v2.1 migration

### GITVAULT:3 — Medium term
- [ ] Argon2id for key derivation (stronger than PBKDF2 against GPU attacks)
- [ ] Per-file salt to eliminate any residual IV correlation
- [ ] Multi-key support in `.gitattributes` (different keys per directory)
- [ ] Automatic v2.1 → v3 migration on first `git add`

### Out of scope (would require external dependencies)
- Per-user GPG encryption (like git-crypt): requires `gpg`
- Native AES-GCM: requires libsodium or python3 with pycryptodome
- Access auditing: requires external infrastructure
