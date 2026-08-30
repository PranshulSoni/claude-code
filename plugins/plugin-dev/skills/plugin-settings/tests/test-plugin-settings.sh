#!/usr/bin/env bash
# Regression test suite for plugin-settings BOM handling

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSE_FRONTMATTER="$SCRIPT_DIR/../scripts/parse-frontmatter.sh"
VALIDATE_SETTINGS="$SCRIPT_DIR/../scripts/validate-settings.sh"
BASH_BIN="${BASH:-bash}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PASSED=0
FAILED=0

# Create BOM test files
BOM_FILE="$TMP_DIR/bom.local.md"
printf '\xef\xbb\xbf---\nenabled: true\nstrict_mode: false\n---\nBody text\n' > "$BOM_FILE"

echo "=== Running plugin-settings Tests ==="

# 1. parse-frontmatter on BOM file
val=$("$BASH_BIN" "$PARSE_FRONTMATTER" "$BOM_FILE" enabled)
if [ "$val" = "true" ]; then
  echo "✅ parse-frontmatter extracts from BOM file"
  PASSED=$((PASSED + 1))
else
  echo "❌ parse-frontmatter failed on BOM file: got '$val'"
  FAILED=$((FAILED + 1))
fi

# 2. validate-settings on BOM file
if "$BASH_BIN" "$VALIDATE_SETTINGS" "$BOM_FILE" >/dev/null 2>&1; then
  echo "✅ validate-settings accepts BOM file"
  PASSED=$((PASSED + 1))
else
  echo "❌ validate-settings failed on BOM file"
  FAILED=$((FAILED + 1))
fi

echo ""
echo "=== Summary: $PASSED passed, $FAILED failed ==="
if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
