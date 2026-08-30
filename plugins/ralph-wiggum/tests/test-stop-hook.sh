#!/usr/bin/env bash
# Regression tests for ralph-wiggum stop-hook.sh error handlers under set -e

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STOP_HOOK="$SCRIPT_DIR/../hooks/stop-hook.sh"
BASH_BIN="${BASH:-bash}"

PASSED=0
FAILED=0

# Create a mock jq shim on PATH if jq is not installed, so test suite can run in environments without native jq
MOCK_DIR="$(mktemp -d)"
trap 'rm -rf "$MOCK_DIR"' EXIT

if ! command -v jq >/dev/null 2>&1; then
  cat << 'EOF' > "$MOCK_DIR/jq"
#!/usr/bin/env bash
exec python3 -c '
import sys, json

args = sys.argv[1:]
if not args:
    sys.exit(0)

raw = sys.stdin.read() if not sys.stdin.isatty() else ""

if "-n" in args:
    prompt = ""
    msg = ""
    for i, a in enumerate(args):
        if a == "--arg" and i + 2 < len(args):
            if args[i+1] == "prompt":
                prompt = args[i+2]
            elif args[i+1] == "msg":
                msg = args[i+2]
    print(json.dumps({"decision": "block", "reason": prompt, "systemMessage": msg}))
    sys.exit(0)

try:
    data = json.loads(raw) if raw.strip() else {}
except Exception as e:
    sys.stderr.write(str(e) + "\n")
    sys.exit(1)

query = " ".join([a for a in args if not a.startswith("-")])

if "transcript_path" in query:
    val = data.get("transcript_path")
    if val:
        print(val)
elif "message.content" in query:
    content = data.get("message", {}).get("content", [])
    texts = [item.get("text", "") for item in content if isinstance(item, dict) and item.get("type") == "text"]
    print("\n".join(texts))
else:
    print(json.dumps(data))
' "$@"
EOF
  chmod +x "$MOCK_DIR/jq"
  export PATH="$MOCK_DIR:$PATH"
fi

run_test() {
  local test_name="$1"
  local state_content="$2"
  local hook_input="$3"
  local transcript_content="$4"
  local expected_exit="$5"
  local expected_substr="$6"
  local expect_file_removed="$7"

  local temp_dir
  temp_dir="$(mktemp -d)"
  mkdir -p "$temp_dir/.claude"

  local file_created=0
  if [ -n "$state_content" ]; then
    printf '%s\n' "$state_content" > "$temp_dir/.claude/ralph-loop.local.md"
    file_created=1
  fi

  local transcript_path=""
  if [ -n "$transcript_content" ]; then
    transcript_path="$temp_dir/transcript.jsonl"
    printf '%s\n' "$transcript_content" > "$transcript_path"
    hook_input="${hook_input//TRANSCRIPT_PLACEHOLDER/$transcript_path}"
  fi

  set +e
  local output
  output=$(cd "$temp_dir" && printf '%s' "$hook_input" | PATH="$MOCK_DIR:$PATH" "$BASH_BIN" "$STOP_HOOK" 2>&1)
  local status=$?
  set -e

  local test_failed=0

  if [ "$status" -ne "$expected_exit" ]; then
    echo "❌ $test_name: Expected exit code $expected_exit, got $status"
    echo "Output: $output"
    test_failed=1
  fi

  if [ -n "$expected_substr" ] && [[ "$output" != *"$expected_substr"* ]]; then
    echo "❌ $test_name: Output did not contain expected substring '$expected_substr'"
    echo "Output: $output"
    test_failed=1
  fi

  if [ "$file_created" -eq 1 ]; then
    if [ "$expect_file_removed" = "true" ] && [ -f "$temp_dir/.claude/ralph-loop.local.md" ]; then
      echo "❌ $test_name: Expected state file to be removed, but it still exists"
      test_failed=1
    elif [ "$expect_file_removed" = "false" ] && [ ! -f "$temp_dir/.claude/ralph-loop.local.md" ]; then
      echo "❌ $test_name: Expected state file to be preserved, but it was deleted"
      test_failed=1
    fi
  fi

  rm -rf "$temp_dir"

  if [ "$test_failed" -eq 0 ]; then
    echo "✅ $test_name"
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
  fi
}

echo "=== Running Ralph Wiggum Stop Hook Tests ==="

MOCK_TRANSCRIPT='{"role":"assistant","message":{"content":[{"type":"text","text":"I am working on the task"}]}}'

# 1. State file missing iteration field
run_test "Missing iteration field produces diagnostic and cleans up" \
  $'---\nmax_iterations: 5\ncompletion_promise: null\n---\nDo the task' \
  '{"transcript_path":"/nonexistent"}' \
  "" \
  0 \
  "Problem: 'iteration' field is not a valid number" \
  "true"

# 2. State file missing max_iterations field
run_test "Missing max_iterations field produces diagnostic and cleans up" \
  $'---\niteration: 1\ncompletion_promise: null\n---\nDo the task' \
  '{"transcript_path":"/nonexistent"}' \
  "" \
  0 \
  "Problem: 'max_iterations' field is not a valid number" \
  "true"

# 3. State file with non-numeric iteration
run_test "Non-numeric iteration produces diagnostic and cleans up" \
  $'---\niteration: invalid\nmax_iterations: 5\n---\nDo the task' \
  '{"transcript_path":"/nonexistent"}' \
  "" \
  0 \
  "Problem: 'iteration' field is not a valid number" \
  "true"

# 4. State file missing prompt text (with valid transcript)
run_test "Empty prompt text produces diagnostic and cleans up" \
  $'---\niteration: 1\nmax_iterations: 5\n---\n' \
  '{"transcript_path":"TRANSCRIPT_PLACEHOLDER"}' \
  "$MOCK_TRANSCRIPT" \
  0 \
  "Problem: No prompt text found" \
  "true"

# 5. Invalid JSON on hook input with missing transcript
run_test "Invalid JSON input produces transcript not found diagnostic and cleans up" \
  $'---\niteration: 1\nmax_iterations: 5\n---\nDo the task' \
  'not-valid-json' \
  "" \
  0 \
  "Transcript file not found" \
  "true"

# 6. Reached max iterations
run_test "Max iterations reached exits cleanly and removes state file" \
  $'---\niteration: 5\nmax_iterations: 5\n---\nDo the task' \
  '{"transcript_path":"/nonexistent"}' \
  "" \
  0 \
  "Max iterations (5) reached" \
  "true"

# 7. No state file present allows clean exit
run_test "No state file present allows exit 0 immediately" \
  "" \
  '{"transcript_path":"/nonexistent"}' \
  "" \
  0 \
  "" \
  "false"

# Summary
echo ""
echo "=== Test Summary: $PASSED passed, $FAILED failed ==="
if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
