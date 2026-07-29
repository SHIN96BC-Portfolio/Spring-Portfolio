#!/usr/bin/env bash
# Install repo Git hooks (no Node). Uses core.hooksPath -> .githooks
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

if [[ ! -d .git ]]; then
  echo "install-git-hooks: not a git repository: ${ROOT}" >&2
  exit 1
fi

chmod +x .githooks/commit-msg .githooks/pre-push
git config core.hooksPath .githooks

echo "Git hooks installed."
echo "  core.hooksPath = $(git config --get core.hooksPath)"
echo "  hooks: commit-msg (message), pre-push (branch)"
