#!/bin/zsh
set -euo pipefail

# ---- Configuration ----

# Prefer Homebrew on Apple Silicon, but fall back for Intel.
if [[ -x /opt/homebrew/bin/bindfs ]]; then
  BINDFS=/opt/homebrew/bin/bindfs
elif [[ -x /usr/local/bin/bindfs ]]; then
  BINDFS=/usr/local/bin/bindfs
else
  echo "ERROR: bindfs not found in /opt/homebrew/bin or /usr/local/bin" >&2
  exit 1
fi

# macOS-specific options recommended by bindfs/macFUSE docs.
# Do NOT include allow_other unless you truly need other macOS users to access the mount.
BIND_OPTS=(
  -o local
  -o extended_security
  -o noappledouble
  --perms=u=rX:g=rX:o=rX
)

# Format: TARGET => SOURCE
typeset -A MAPPINGS
MAPPINGS=(
  "$HOME/claude/readonly/obsidian" "/Users/chris/Library/Mobile Documents/iCloud~md~obsidian/Documents"
  "$HOME/claude/readonly/projects" "$HOME/projects"
)

# ---- Helpers ----

is_mounted() {
  local target="$1"
  mount | grep -F "on $target " >/dev/null 2>&1
}

source_has_entries() {
  local source="$1"
  [[ -n "$(find "$source" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)" ]]
}

target_has_entries() {
  local target="$1"
  [[ -n "$(find "$target" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)" ]]
}

target_is_readable() {
  local target="$1"
  ls -la "$target" >/dev/null 2>&1
}

force_unmount() {
  local target="$1"

  if is_mounted "$target"; then
    echo "Unmounting stale mount: $target"
    /sbin/umount "$target" >/dev/null 2>&1 || /sbin/umount -f "$target" >/dev/null 2>&1 || true
  fi
}

mount_one() {
  local source="$1"
  local target="$2"

  mkdir -p "$target"

  if [[ ! -d "$source" ]]; then
    echo "Skipping missing source: $source"
    return 0
  fi

  # If already mounted, verify health.
  if is_mounted "$target"; then
    if target_is_readable "$target"; then
      # If source has content but target appears empty, treat as stale.
      if source_has_entries "$source" && ! target_has_entries "$target"; then
        echo "Mounted but suspiciously empty: $target"
        force_unmount "$target"
      else
        echo "Healthy mount already present: $target"
        return 0
      fi
    else
      echo "Mounted but unreadable: $target"
      force_unmount "$target"
    fi
  fi

  echo "Mounting $source -> $target (read-only)"
  "$BINDFS" "${BIND_OPTS[@]}" "$source" "$target"

  # Immediate health check after mount
  if ! target_is_readable "$target"; then
    echo "ERROR: mount created but target is unreadable: $target" >&2
    return 1
  fi
}

# ---- Main ----

for TARGET SOURCE in ${(kv)MAPPINGS[@]}; do
  mount_one "$SOURCE" "$TARGET"
done