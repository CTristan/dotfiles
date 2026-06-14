#!/bin/zsh
# Encrypted, rotating point-in-time backup of ASF's config/ into iCloud.
# Managed by chezmoi (CTristan/dotfiles) — contains NO secrets.
# Runs via the com.user.asf-backup LaunchAgent (daily + at login) and ad-hoc.
# Uses only built-in macOS tools so it works under launchd's minimal PATH.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin   # system openssl(LibreSSL)/security/tar

ASF_DIR="$HOME/Library/Application Support/ArchiSteamFarm"
DEST="$HOME/Library/Mobile Documents/com~apple~CloudDocs/ASF-Backups"
KEEP=14

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [asf-backup] $*"; }

[ -d "$ASF_DIR/config" ] || { log "FATAL: $ASF_DIR/config not found"; exit 1; }
mkdir -p "$DEST"

# Rotate FIRST, on a settled directory: globbing an iCloud dir right after a write can
# transiently return an incomplete listing, so prune before writing today's snapshot.
# Filenames sort chronologically; keep the newest $KEEP. `find` enumerates reliably.
find "$DEST" -maxdepth 1 -type f -name 'asf-config-*.tar.gz.enc' 2>/dev/null \
  | sort -r | tail -n +$((KEEP + 1)) | while IFS= read -r f; do
      rm -f "$f" && log "rotated out ${f##*/}"
    done

# Passphrase from the login Keychain. The item is created with `-T /usr/bin/security`
# so this read succeeds non-interactively (including under launchd).
if ! PW="$(security find-generic-password -s asf-backup -w 2>/dev/null)"; then
  log "FATAL: could not read 'asf-backup' passphrase from Keychain"
  exit 1
fi

STAMP="$(date '+%Y%m%d-%H%M%S')"
OUT="$DEST/asf-config-$STAMP.tar.gz.enc"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Snapshot a copy (not the live dir), then tar + AES-256 encrypt the copy.
# Passphrase is passed via env (-pass env:PW) so it never appears in `ps` argv.
cp -Rp "$ASF_DIR/config" "$TMP/config"
tar -czf - -C "$TMP" config \
  | PW="$PW" openssl enc -aes-256-cbc -pbkdf2 -salt -pass env:PW -out "$OUT"

# Keep a copy of the standalone restore script beside the snapshots (pre-chezmoi recovery).
if [ -f "$HOME/.local/bin/setup-asf" ]; then
  cp -p "$HOME/.local/bin/setup-asf" "$DEST/setup-asf.sh" 2>/dev/null || true
fi

log "wrote ${OUT##*/} ($(ls -lh "$OUT" | awk '{print $5}'))"
log "done"
