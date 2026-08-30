#!/usr/bin/env bash
# Regression test suite for validate-hook-schema.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="$SCRIPT_DIR/../scripts/validate-hook-schema.sh"
BASH_BIN="${BASH:-bash}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PASSED=0
FAILED=0

run_test() {
  local name="$1"
  local json_content="$2"
  local expected_status="$3"
  local expected_substr="$4"

  local file="$TMP_DIR/test_hooks.json"
  printf '%s\n' "$json_content" > "$file"

  set +e
  local output
  output=$("$BASH_BIN" "$VALIDATOR" "$file" 2>&1)
  local status=$?
  set -e

  local test_failed=0
  if [ "$status" -ne "$expected_status" ]; then
    echo "❌ $name: Expected exit $expected_status, got $status"
    echo "Output: $output"
    test_failed=1
  fi

  if [ -n "$expected_substr" ] && [[ "$output" != *"$expected_substr"* ]]; then
    echo "❌ $name: Output missing substring '$expected_substr'"
    echo "Output: $output"
    test_failed=1
  fi

  if [ "$test_failed" -eq 0 ]; then
    echo "✅ $name"
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
  fi
}

echo "=== Running validate-hook-schema.sh Tests ==="

# 1. Plugin wrapper format
run_test "Plugin wrapper format validates cleanly" \
  '{"description":"test hooks","hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/scripts/c.sh"}]}]}}' \
  0 \
  "Detected plugin wrapper format"

# 2. Settings format
run_test "Settings format validates cleanly" \
  '{"PreToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/scripts/e.sh"}]}]}' \
  0 \
  "Detected direct/settings format"

# 3. Non-tool events without matcher pass
run_test "UserPromptSubmit and Stop without matcher pass" \
  '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"prompt","prompt":"check prompt"}]}],"Stop":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/scripts/s.sh"}]}]}}' \
  0 \
  "All checks passed!"

# 4. PreToolUse without matcher fails
run_test "PreToolUse without matcher fails validation" \
  '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/scripts/c.sh"}]}]}}' \
  1 \
  "Missing 'matcher' field"

# 5. Invalid JSON fails
run_test "Invalid JSON fails validation" \
  '{ bad json }' \
  1 \
  "Invalid JSON syntax"

echo ""
echo "=== Summary: $PASSED passed, $FAILED failed ==="
if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
