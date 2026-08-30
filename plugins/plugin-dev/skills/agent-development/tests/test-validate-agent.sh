#!/usr/bin/env bash
# Regression test suite for validate-agent.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="$SCRIPT_DIR/../scripts/validate-agent.sh"
REPO_ROOT="$SCRIPT_DIR/../../../../.."
BASH_BIN="${BASH:-bash}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PASSED=0
FAILED=0

run_test() {
  local name="$1"
  local file_path="$2"
  local content="$3"
  local expected_status="$4"
  local expected_substr="$5"

  local target="$file_path"
  if [ -n "$content" ]; then
    target="$TMP_DIR/agent.md"
    printf '%s\n' "$content" > "$target"
  fi

  set +e
  local output
  output=$("$BASH_BIN" "$VALIDATOR" "$target" 2>&1)
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

echo "=== Running validate-agent.sh Tests ==="

# 1. Shipped plugin-validator agent
run_test "Shipped plugin-validator agent validates cleanly" \
  "$REPO_ROOT/plugins/plugin-dev/agents/plugin-validator.md" \
  "" \
  0 \
  "name: plugin-validator"

# 2. Warning does not abort under set -e
run_test "Agent with warning continues to completion" \
  "" \
  $'---\nname: helper\ndescription: Use this agent when helping with tasks.\nmodel: inherit\ncolor: blue\n---\nYou are an agent.\nResponsibilities:\n1. Assist user.\nOutput: text.\n' \
  0 \
  "name is too generic: helper"

# 3. UTF-8 BOM is supported
run_test "Agent with UTF-8 BOM validates" \
  "" \
  $'\xef\xbb\xbf---\nname: bom-agent\ndescription: Use this agent when testing.\n  <example>\n  user: hi\n  </example>\nmodel: sonnet\ncolor: red\n---\nYou are an agent.\nResponsibilities:\n1. Help.\nOutput: text.\n' \
  0 \
  "name: bom-agent"

# 4. Missing required field fails
run_test "Missing name fails" \
  "" \
  $'---\ndescription: Use this agent when testing.\nmodel: inherit\ncolor: blue\n---\nYou are an agent.\n' \
  1 \
  "Missing required field: name"

echo ""
echo "=== Summary: $PASSED passed, $FAILED failed ==="
if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
