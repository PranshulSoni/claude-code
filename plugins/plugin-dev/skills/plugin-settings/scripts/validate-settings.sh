#!/bin/bash
# Settings File Validator
# Validates .claude/plugin-name.local.md structure

set -euo pipefail

# Usage
if [ $# -eq 0 ]; then
  echo "Usage: $0 <path/to/settings.local.md>"
  echo ""
  echo "Validates plugin settings file for:"
  echo "  - File existence and readability"
  echo "  - YAML frontmatter structure"
  echo "  - Required --- markers"
  echo "  - Field format"
  echo ""
  echo "Example: $0 .claude/my-plugin.local.md"
  exit 1
fi

SETTINGS_FILE="$1"

echo "🔍 Validating settings file: $SETTINGS_FILE"
echo ""

# Check 1: File exists
if [ ! -f "$SETTINGS_FILE" ]; then
  echo "❌ File not found: $SETTINGS_FILE"
  exit 1
fi
echo "✅ File exists"

# Check 2: File is readable
if [ ! -r "$SETTINGS_FILE" ]; then
  echo "❌ File is not readable"
  exit 1
fi
echo "✅ File is readable"

# Check 3: Has frontmatter markers
# Count '^---$' lines but also accept a leading UTF-8 BOM (issue
# #73158): the first '---' line of a BOM-prefixed file starts with
# EF BB BF, which the strict ^---$ regex would miss. We strip a
# leading BOM from the file content before counting, without modifying
# the file on disk.
if [ "$(head -c 3 "$SETTINGS_FILE" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "efbbbf" ]; then
  MARKER_COUNT=$(tail -c +4 "$SETTINGS_FILE" | grep -c '^---$' || echo "0")
else
  MARKER_COUNT=$(grep -c '^---$' "$SETTINGS_FILE" 2>/dev/null || echo "0")
fi

if [ "$MARKER_COUNT" -lt 2 ]; then
  echo "❌ Invalid frontmatter: found $MARKER_COUNT '---' markers (need at least 2)"
  echo "   Expected format:"
  echo "   ---"
  echo "   field: value"
  echo "   ---"
  echo "   Content..."
  exit 1
fi
echo "✅ Frontmatter markers present"

# Check 4: Extract and validate frontmatter
# Strip a leading UTF-8 BOM if present (issue #73158). PowerShell's
# default UTF-8 encoding on Windows writes a BOM, which causes the
# frontmatter regex below to silently miss the opening '---' marker.
# A BOM is the three-byte sequence EF BB BF. The file is not modified
# on disk; the stripped content is used only for the regex match.
if [ "$(head -c 3 "$SETTINGS_FILE" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "efbbbf" ]; then
  SETTINGS_CONTENT=$(tail -c +4 "$SETTINGS_FILE")
else
  SETTINGS_CONTENT=$(cat "$SETTINGS_FILE")
fi
FRONTMATTER=$(printf '%s\n' "$SETTINGS_CONTENT" | sed -n '/^---$/,/^---$/{ /^---$/d; p; }')

if [ -z "$FRONTMATTER" ]; then
  echo "❌ Empty frontmatter (nothing between --- markers)"
  exit 1
fi
echo "✅ Frontmatter not empty"

# Check 5: Frontmatter has valid YAML-like structure
if ! echo "$FRONTMATTER" | grep -q ':'; then
  echo "⚠️  Warning: Frontmatter has no key:value pairs"
fi

# Check 6: Look for common fields
echo ""
echo "Detected fields:"
echo "$FRONTMATTER" | grep '^[a-z_][a-z0-9_]*:' | while IFS=':' read -r key value; do
  echo "  - $key: ${value:0:50}"
done

# Check 7: Validate common boolean fields
for field in enabled strict_mode; do
  VALUE=$(echo "$FRONTMATTER" | grep "^${field}:" | sed "s/${field}: *//" || true)
  if [ -n "$VALUE" ]; then
    if [ "$VALUE" != "true" ] && [ "$VALUE" != "false" ]; then
      echo "⚠️  Field '$field' should be boolean (true/false), got: $VALUE"
    fi
  fi
done

# Check 8: Check body exists
BODY=$(awk '/^---$/{i++; next} i>=2' "$SETTINGS_FILE")

echo ""
if [ -n "$BODY" ]; then
  BODY_LINES=$(echo "$BODY" | wc -l | tr -d ' ')
  echo "✅ Markdown body present ($BODY_LINES lines)"
else
  echo "⚠️  No markdown body (frontmatter only)"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Settings file structure is valid"
echo ""
echo "Reminder: Changes to this file require restarting Claude Code"
exit 0
