#!/bin/zsh
set -euo pipefail

# Associative array for source/target mappings
# Format: TARGET => SOURCE (target is the key, source is the value)
typeset -A MAPPINGS
MAPPINGS=(
  "$HOME/claude/readonly/obsidian" "/Users/chris/Library/Mobile Documents/iCloud~md~obsidian/Documents"
  "$HOME/claude/readonly/projects" "$HOME/projects"
)

for TARGET SOURCE in ${(kv)MAPPINGS[@]}; do
  # Create target directory if it doesn't exist
  mkdir -p "$TARGET"

  # If already mounted, skip to the next mapping
  if mount | grep -F "on $TARGET " >/dev/null 2>&1; then
    echo "Already mounted: $TARGET"
    continue
  fi

  echo "Mounting $SOURCE -> $TARGET (read-only)"
  /usr/local/bin/bindfs --perms=a-w "$SOURCE" "$TARGET"
done
