# git-vault

Transparent, zero-dependency encryption for secrets in git repositories. Files are automatically encrypted when staged and decrypted on checkout — no manual steps after initial setup.

## How it works

git-vault hooks into git's clean/smudge filter system:

- **`git add`** → clean filter encrypts the file before it enters the index
- **`git checkout`** → smudge filter decrypts the file onto disk
- **`git diff`** → textconv filter shows plaintext in diffs

The key never enters the repository. It lives in `.git/vault-key` (never committed) or an environment variable.

### Encryption format

Each encrypted file is a 4-line text file, binary-safe via base64:

```
GITVAULT:2.1
<iv_hex>            # 32 hex chars — keyed-deterministic (PBKDF2 master key + content hash)
<hmac_hex>          # 64 hex chars — HMAC-SHA256 over ciphertext (encrypt-then-MAC)
<base64_ciphertext> # AES-256-CBC output
```

Key derivation: PBKDF2-SHA256 at 600,000 iterations with a per-repo salt stored in `.git-vault/vault-salt`. The IV is derived from the PBKDF2 master key and the content hash — same content always produces the same ciphertext (git does not mark files dirty), while cross-repo correlation is eliminated because each repo has a unique salt.

Legacy `GITVAULT:2` files (SHA-256 derivation, deterministic IV) continue to decrypt correctly. Run `vault.sh upgrade` to migrate them.

## Requirements

- Bash
- OpenSSL (standard on Linux, macOS, and WSL)
- Git

No other dependencies.

## Setup

### Lead developer (first time, per repo)

Run this once inside your repository to install git-vault and configure everything:

```bash
curl -fsSL https://raw.githubusercontent.com/Jandro5vq/git-vault/master/install.sh | bash
```

This downloads the scripts into `.git-vault/`, configures git filters, walks you through key setup, and runs a self-test. Commit the result so teammates get the scripts automatically:

```bash
git add .git-vault/ .gitattributes
git commit -m "chore: add git-vault encryption"
git push
```

<details>
<summary>Manual install (no curl)</summary>

```bash
mkdir -p .git-vault
cp vault.sh setup.sh rotate.sh join.sh .git-vault/
cp .git-vault/gitconfig .git-vault/gitconfig
chmod +x .git-vault/*.sh
.git-vault/setup.sh
```

</details>

### Teammates (after cloning or pulling)

Scripts and filter definitions are already in the repo. Teammates only need to provide the shared key:

```bash
.git-vault/join.sh
```

That's it. `join.sh` wires the filters into their local `.git/config` and decrypts all vault-tracked files on disk. The key is the only thing that needs to be shared out-of-band (never commit it).

For CI/CD or non-interactive environments:

```bash
GIT_VAULT_KEY='the-shared-key' .git-vault/join.sh
```

**Mark which files to encrypt in `.gitattributes`:**

```gitattributes
secrets/*     filter=git-vault diff=git-vault
secrets/**    filter=git-vault diff=git-vault
*.secret      filter=git-vault diff=git-vault
.env          filter=git-vault diff=git-vault
```

Note: both `secrets/*` and `secrets/**` are needed — `**` alone does not match files directly inside `secrets/` on all git versions.

From this point on, matching files are encrypted automatically on every `git add`.

## Key storage

git-vault looks for the key in this order:

1. `GIT_VAULT_KEY` environment variable
2. `.git/vault-key` file (created by `setup.sh`)

Use the environment variable in CI/CD pipelines where a filesystem key is not available.

## Usage

After setup, standard git commands work as usual — encryption and decryption are invisible.

```bash
# Add a secret — encrypted automatically
echo "DB_PASSWORD=hunter2" > .env
git add .env
git commit -m "Add environment config"

# Diff shows plaintext
git diff HEAD~1 .env

# Manual encrypt/decrypt (for inspection)
cat file.txt | .git-vault/vault.sh encrypt
cat encrypted.txt | .git-vault/vault.sh decrypt

# Check filter configuration and list encrypted files
.git-vault/vault.sh status
```

## Key rotation

Run this when a team member leaves or a key is compromised:

```bash
.git-vault/rotate.sh
```

The script:
1. Verifies all files decrypt successfully with the current key — **before** switching keys
2. Creates a timestamped backup of the old key at `.git/vault-key.bak.<timestamp>`
3. Switches to the new key and re-encrypts all vault-tracked files
4. Verifies re-encryption succeeded before asking for commit confirmation
5. Prompts `yes` to commit, or exits cleanly so you can inspect staged files first

After committing, the script prints instructions to share with the team.

### Rotation in CI/CD (non-interactive)

Pass both keys as environment variables to skip all prompts:

```bash
export GIT_VAULT_KEY="current-key"
export GIT_VAULT_KEY_NEW="new-key-at-least-20-chars"
.git-vault/rotate.sh
```

**Note:** Historical commits remain decryptable with the old key. To remove old secrets from history entirely, rewrite git history with [BFG Repo Cleaner](https://rtyley.github.io/bfg-repo-cleaner/) or `git filter-repo` after rotation.

## Security model

**Protects against:** An attacker who gains read access to the repository (leaked remote, compromised hosting, ex-employee with a clone).

**Does not protect against:**
- Filename and path exposure (stored plaintext in git)
- A compromised machine where the key is already loaded
- Files not listed in `.gitattributes`
- Access revocation without key rotation (one shared key = team access)

**Cryptographic design:**
- Key derivation: PBKDF2-SHA256, 600,000 iterations, per-repo salt (GITVAULT:2.1)
- Cipher: AES-256-CBC
- Authentication: HMAC-SHA256 (encrypt-then-MAC pattern)
- AES key and HMAC key are derived separately from the PBKDF2 master key
- Random IV per encryption — eliminates deterministic IV correlation
- Temp directory mode 700; `shred` wipes plaintext before `rm`

See [SECURITY.md](SECURITY.md) for the full cryptographic analysis and threat model.

## Limitations

- **Shared key model** — no per-user encryption. Losing the key means losing access to all historical secrets.
- **Minimum key length** — keys shorter than 20 characters are rejected at setup and rotation time.
- **PBKDF2, not Argon2** — PBKDF2-SHA256 at 600k iterations resists GPU attacks reasonably well; Argon2id (planned for v3) is stronger against memory-hard attacks.
- **One key per repository** — different directories cannot have different keys in v2.
- **Requires OpenSSL** — not a pure Bash solution; `openssl enc` must be available.
- **Historical commits** — rotation re-encrypts current HEAD only; history still decryptable with the old key.

## File reference

| File | Purpose |
|------|---------|
| `install.sh` | One-liner installer for the lead developer: downloads scripts and runs setup |
| `join.sh` | Teammate onboarding: wires filters and saves key — the only step after cloning |
| `vault.sh` | Core encrypt/decrypt engine; implements git filters |
| `setup.sh` | Lead developer setup: key storage, filter configuration, and self-test |
| `rotate.sh` | Key rotation: verifies, backs up, re-encrypts, and commits with confirmation |
| `.git-vault/gitconfig` | Committed filter definitions — included by teammates' local `.git/config` |
| `.gitattributes` | Patterns that determine which files are encrypted |
| `SECURITY.md` | Detailed cryptographic analysis |
