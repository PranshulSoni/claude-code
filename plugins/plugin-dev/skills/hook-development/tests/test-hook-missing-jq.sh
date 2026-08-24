#!/usr/bin/env bash
# Regression test for test-hook.sh's missing-jq diagnostic.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_TESTER="$SCRIPT_DIR/../scripts/test-hook.sh"
BASH_PATH="${BASH:-/bin/bash}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test-hook-missing-jq.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

printf '%s\n' '{"hook_event_name":"PreToolUse","tool_name":"Write"}' > "$TMP_DIR/input.json"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$TMP_DIR/hook.sh"
chmod +x "$TMP_DIR/hook.sh"

set +e
output=$(PATH="$TMP_DIR" "$BASH_PATH" "$HOOK_TESTER" "$TMP_DIR/hook.sh" "$TMP_DIR/input.json" 2>&1)
status=$?
set -e

if [ "$status" -ne 1 ]; then
  printf 'Expected missing-jq validation to exit 1, got %s\n%s\n' "$status" "$output" >&2
  exit 1
fi

if [[ "$output" != *"jq is required but was not found on PATH"* ]]; then
  printf 'Expected a missing-jq diagnostic, got:\n%s\n' "$output" >&2
  exit 1
fi

if [[ "$output" == *"Test input is not valid JSON"* ]]; then
  printf 'Missing jq must not be reported as invalid JSON:\n%s\n' "$output" >&2
  exit 1
fi

printf 'PASS: missing jq is reported distinctly from invalid JSON\n'
