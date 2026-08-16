#!/usr/bin/env bash
set -euo pipefail

TAG="${1:-}"
PROPS_FILE="${PROPS_FILE:-gradle.properties}"

if [ -z "$TAG" ]; then
  echo "Usage: $0 <tag> [gradle.properties]"
  echo "Example: $0 v1.2.3"
  exit 1
fi

VERSION_NAME="${TAG#v}"
VERSION_CODE=$(git rev-list --count HEAD 2>/dev/null || echo 1)

if [ ! -f "$PROPS_FILE" ]; then
  echo "ERROR: $PROPS_FILE not found"
  exit 1
fi

cp "$PROPS_FILE" "$PROPS_FILE.bak"

sed -i.bak -e '/^VERSION_NAME=/d' -e '/^VERSION_CODE=/d' "$PROPS_FILE"
{
  echo "VERSION_NAME=${VERSION_NAME}"
  echo "VERSION_CODE=${VERSION_CODE}"
} >> "$PROPS_FILE"

echo "=== Updated $PROPS_FILE ==="
cat "$PROPS_FILE"
echo "==========================="
echo ""
echo "VERSION_NAME=$VERSION_NAME"
echo "VERSION_CODE=$VERSION_CODE"
echo ""
echo "Backup saved to $PROPS_FILE.bak"
