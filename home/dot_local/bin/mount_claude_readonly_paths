#!/bin/zsh
set -euo pipefail

SOURCE="/Users/chris/Library/Mobile Documents/iCloud~md~obsidian/Documents"
TARGET="$HOME/claude/readonly/obsidian"

mkdir -p "$TARGET"

# If already mounted, do nothing.
if mount | grep -F "on $TARGET " >/dev/null 2>&1; then
  exit 0
fi

# Mount read-only mirror
/usr/local/bin/bindfs --perms=a-w "$SOURCE" "$TARGET"
EOF
