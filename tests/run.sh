#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
git diff --check
/bin/bash -n bootstrap scripts/bootstrap-lib.sh
for file in home/dot_local/bin/executable_* home/dot_local/share/*/*.zsh; do
  /bin/zsh -n "$file"
done
python3 tests/test-bootstrap.py
/bin/bash tests/test-dotfiles.sh
/bin/bash tests/test-secretive-ssh.sh
/bin/zsh tests/test-asf-secret.zsh
/bin/zsh tests/test-asf.zsh
/bin/zsh tests/test-vault-setup.zsh
SYNC_SCRIPT="$ROOT/home/dot_local/bin/executable_backup-vault.sh" /bin/zsh home/dot_local/share/vault-backup/executable_test-vault-sync.zsh
