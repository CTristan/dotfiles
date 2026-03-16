#!/usr/bin/env bash
# sync-obsidian.sh — Mirror an Obsidian vault from iCloud to a local read-only copy.
# Designed for use with launchd (auto) or manual invocation.
# Chezmoi-friendly: drop in ~/.local/bin/ and manage with chezmoi.

set -euo pipefail

# --- Configuration -----------------------------------------------------------
# Override these with environment variables if needed.

# Where iCloud stores Obsidian vaults
ICLOUD_OBSIDIAN_ROOT="${ICLOUD_OBSIDIAN_ROOT:-$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents}"

# Specific vault name (leave empty to auto-detect if you only have one vault)
VAULT_NAME="${VAULT_NAME:-}"

# Where the mirror lands — stable path so tools can find it across sessions
MIRROR_ROOT="${MIRROR_ROOT:-$HOME/claude}"

# Set to 1 to force-download evicted iCloud files before syncing
DOWNLOAD_EVICTED="${DOWNLOAD_EVICTED:-1}"

# --- Logging -----------------------------------------------------------------
log() { printf '[obsidian-sync] %s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# --- Resolve vault -----------------------------------------------------------
if [[ -z "$VAULT_NAME" ]]; then
    # Auto-detect: expect exactly one vault folder
    shopt -s nullglob
    vaults=("$ICLOUD_OBSIDIAN_ROOT"/*)
    shopt -u nullglob

    if (( ${#vaults[@]} == 0 )); then
        log "ERROR: No vaults found in $ICLOUD_OBSIDIAN_ROOT"
        exit 1
    elif (( ${#vaults[@]} > 1 )); then
        log "ERROR: Multiple vaults found. Set VAULT_NAME to pick one:"
        printf '  - %s\n' "${vaults[@]##*/}"
        exit 1
    fi
    VAULT_NAME="${vaults[0]##*/}"
fi

VAULT_PATH="$ICLOUD_OBSIDIAN_ROOT/$VAULT_NAME"
MIRROR_PATH="$MIRROR_ROOT/$VAULT_NAME"

if [[ ! -d "$VAULT_PATH" ]]; then
    log "ERROR: Vault not found at $VAULT_PATH"
    exit 1
fi

# --- Force-download evicted iCloud files -------------------------------------
if [[ "$DOWNLOAD_EVICTED" == "1" ]] && command -v brctl &>/dev/null; then
    log "Requesting iCloud download for any evicted files..."
    find "$VAULT_PATH" -name '*.icloud' -exec brctl download {} \; 2>/dev/null || true
    # Give iCloud a moment to start hydrating
    sleep 2
fi

# --- Sync --------------------------------------------------------------------
mkdir -p "$MIRROR_PATH"

log "Syncing: $VAULT_PATH → $MIRROR_PATH"

rsync -a --delete \
    --exclude='.obsidian/workspace.json' \
    --exclude='.obsidian/workspace-mobile.json' \
    --exclude='.trash/' \
    "$VAULT_PATH/" "$MIRROR_PATH/"

log "Done. Mirror updated at $MIRROR_PATH"
