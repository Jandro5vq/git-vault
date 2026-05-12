#!/usr/bin/env bash
# git-vault installer
# Adds transparent secret encryption to any git repository.
#
# Usage — run from inside the target git repo:
#   curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/install.sh | bash

set -euo pipefail

BASE_URL="https://raw.githubusercontent.com/OWNER/REPO/main"

# ── pre-flight checks ────────────────────────────────────────────────────────

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "✗ Not inside a git repository. cd into your repo first, then re-run." >&2
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "✗ openssl is required but was not found." >&2
  echo "  Install it with your package manager (e.g. brew install openssl)." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  echo "✗ curl or wget is required." >&2
  exit 1
fi

# ── download scripts ─────────────────────────────────────────────────────────

echo "╔══════════════════════════════════════╗"
echo "║      git-vault  ·  installer         ║"
echo "╚══════════════════════════════════════╝"
echo

echo "Installing into .git-vault/ ..."
mkdir -p .git-vault

_fetch() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
  else
    wget -qO "$dest" "$url"
  fi
}

for script in vault.sh setup.sh rotate.sh; do
  _fetch "$BASE_URL/$script" ".git-vault/$script"
  chmod +x ".git-vault/$script"
  echo "  ✓ .git-vault/$script"
done

# ── add .gitattributes exclusion if not already present ──────────────────────

GITATTR=".gitattributes"
if [[ -f "$GITATTR" ]] && ! grep -q "\.git-vault" "$GITATTR"; then
  printf '\n# git-vault scripts — never encrypt these\n.git-vault/**   !filter !diff\n' >> "$GITATTR"
  echo "  ✓ Added .git-vault exclusion to .gitattributes"
elif [[ ! -f "$GITATTR" ]]; then
  printf '# git-vault scripts — never encrypt these\n.git-vault/**   !filter !diff\n' > "$GITATTR"
  echo "  ✓ Created .gitattributes with .git-vault exclusion"
fi

# ── hand off to setup ─────────────────────────────────────────────────────────

echo
exec .git-vault/setup.sh
