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

**AES-256-CBC with SHA-256-derived key**
Key length: 256 bits. AES-256 has no known practical attacks.
The key is derived as `SHA-256("git-vault:v2:aes-key:" + passphrase)`, providing domain separation from the HMAC key.

**Encrypt-then-MAC (HMAC-SHA256)**
The correct pattern for CBC: the ciphertext is authenticated **before** decryption.
Guards against padding oracle attacks and tampering detection.
The HMAC key is derived independently: `SHA-256("git-vault:v2:hmac-key:" + passphrase)`.

**Deterministic IV derived from content**
`IV = SHA-256("git-vault:v2:iv:" + passphrase + SHA-256(plaintext))[:16]`
Required so that git does not mark unchanged files as modified.
Known consequence: two files with the same content produce the same ciphertext (git-crypt has the same limitation). For secrets this is acceptable.

**Binary-safe**
stdin is written to a temp file before processing; never passed through bash variables (which truncate null bytes). Round-trip verified with all values 0x00–0xFF.

**Domain separation in key derivation**
Each purpose has its own prefix: `aes-key:`, `hmac-key:`, `iv:`.
Prevents reuse of cryptographic material across different uses.

**Hardened temp directory**
The temp directory is created with mode 700 immediately after `mktemp -d`, preventing other users from reading plaintext on shared systems.

### Known weaknesses and mitigations

**Key derivation without a cost-factor KDF**

```
Current:  AES_KEY = SHA-256("git-vault:v2:aes-key:" + passphrase)
Better:   AES_KEY = PBKDF2(passphrase, salt, iterations=600000, SHA-256)
          or Argon2id(passphrase, salt, m=64MB, t=3, p=4)
```

SHA-256 is very fast: an attacker can test ~1 billion passphrases/second on modern hardware. PBKDF2 with 600,000 iterations reduces this to ~10,000/second.

**Practical impact:** Only relevant if the attacker obtains the ciphertext AND the passphrase is weak (dictionary word, short). With a passphrase of 20+ random characters, SHA-256 is sufficient. Minimum key length of 20 characters is enforced at setup and rotation time.

**Implementable mitigation with openssl:**
```bash
# In setup.sh, generate a random salt in .git/vault-salt (never committed)
openssl rand -hex 32 > .git/vault-salt
# In vault.sh, derive with PBKDF2:
AES_KEY=$(openssl kdf -keylen 32 -kdfopt digest:SHA2-256 \
  -kdfopt pass:"$passphrase" -kdfopt salt:"$(cat .git/vault-salt)" \
  -kdfopt iter:600000 PBKDF2 2>/dev/null | xxd -p -c 64)
```
Note: the salt would need to be synchronized across team machines, adding operational complexity. Planned for v3.

**AES-CBC instead of AES-GCM**

`openssl enc` does not support AEAD (GCM). CBC with external HMAC (Encrypt-then-MAC) is security-equivalent, but is more code and more error surface.
With HMAC-SHA256 correctly implemented, the difference is academic.

**The IV is not secret**

The IV is stored in plaintext in the encrypted file (required for decryption without knowing the plaintext). An attacker who sees two commits can tell whether a file's content changed by comparing IVs.

**Plaintext in temporary files**

Plaintext is written to `$TMPDIR` (via `mktemp`). If the disk is not encrypted (FileVault/LUKS), residual plaintext could persist in disk sectors after the temp file is deleted.

Current mitigations in place:
- Temp directory created with mode 700 (prevents access by other users on the same machine)
- Trap on `EXIT INT TERM` ensures cleanup runs on Ctrl-C and kill signals

Remaining gap: `rm` does not securely wipe data; disk sectors may still hold plaintext. Mitigation: use `shred` or mount `$TMPDIR` on a `tmpfs`. Planned for v2.1.

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
| KDF | SHA-256 (weak for short passphrases) | No explicit KDF |
| Key rotation | ✓ (rotate.sh, with verification and backup) | Manual |
| Format versioning | ✓ (GITVAULT:2) | Yes |
| GPG (multi-user) | ✗ | ✓ |
| Maintenance | In your repo | External project |

---

## Roadmap

### v2.1 — Short term (no format changes)
- [x] Automatic integrity self-test in `setup.sh`
- [x] Key length enforcement (minimum 20 characters)
- [x] Hardened temp directory (mode 700)
- [x] Signal handling for temp cleanup (EXIT INT TERM)
- [x] Key backup before rotation + pre/post verification
- [ ] `shred` or `tmpfs` for temporary files
- [ ] Multi-key support in `.gitattributes` (different keys per directory)

### v3 — Medium term (new format `GITVAULT:3`)
- [ ] PBKDF2/Argon2id for key derivation (salt in `.git/vault-salt`)
- [ ] Per-file salt to eliminate IV correlation
- [ ] Automatic v2 → v3 migration on first `git add`

### Out of scope (would require external dependencies)
- Per-user GPG encryption (like git-crypt): requires `gpg`
- Native AES-GCM: requires libsodium or python3 with pycryptodome
- Access auditing: requires external infrastructure
