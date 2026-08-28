#!/bin/bash
# Hook Testing Helper
# Tests a hook with sample input and shows output

set -euo pipefail

# Usage
show_usage() {
  echo "Usage: $0 [options] <hook-script> <test-input.json>"
  echo ""
  echo "Options:"
  echo "  -h, --help            Show this help message"
  echo "  -v, --verbose         Show detailed execution information"
  echo "  -t, --timeout N       Set timeout in seconds (default: 60)"
  echo "  -e, --expect DECISION Expect DECISION in {allow,deny,ask} and fail on mismatch."
  echo "                        When omitted the script accepts any decision and"
  echo "                        only checks that the hook ran to completion."
  echo ""
  echo "Examples:"
  echo "  $0 validate-bash.sh test-input.json"
  echo "  $0 -v -t 30 validate-write.sh write-input.json"
  echo "  $0 --expect deny guard.mjs input.json   # fail if hook does not deny"
  echo ""
  echo "Creates sample test input with:"
  echo "  $0 --create-sample <event-type>"
  exit 0
}

# Create sample input
create_sample() {
  event_type="$1"

  case "$event_type" in
    PreToolUse)
      cat <<'EOF'
{
  "session_id": "test-session",
  "transcript_path": "/tmp/transcript.txt",
  "cwd": "/tmp/test-project",
  "permission_mode": "ask",
  "hook_event_name": "PreToolUse",
  "tool_name": "Write",
  "tool_input": {
    "file_path": "/tmp/test.txt",
    "content": "Test content"
  }
}
EOF
      ;;
    PostToolUse)
      cat <<'EOF'
{
  "session_id": "test-session",
  "transcript_path": "/tmp/transcript.txt",
  "cwd": "/tmp/test-project",
  "permission_mode": "ask",
  "hook_event_name": "PostToolUse",
  "tool_name": "Bash",
  "tool_result": "Command executed successfully"
}
EOF
      ;;
    Stop|SubagentStop)
      cat <<'EOF'
{
  "session_id": "test-session",
  "transcript_path": "/tmp/transcript.txt",
  "cwd": "/tmp/test-project",
  "permission_mode": "ask",
  "hook_event_name": "Stop",
  "reason": "Task appears complete"
}
EOF
      ;;
    UserPromptSubmit)
      cat <<'EOF'
{
  "session_id": "test-session",
  "transcript_path": "/tmp/transcript.txt",
  "cwd": "/tmp/test-project",
  "permission_mode": "ask",
  "hook_event_name": "UserPromptSubmit",
  "user_prompt": "Test user prompt"
}
EOF
      ;;
    SessionStart|SessionEnd)
      cat <<'EOF'
{
  "session_id": "test-session",
  "transcript_path": "/tmp/transcript.txt",
  "cwd": "/tmp/test-project",
  "permission_mode": "ask",
  "hook_event_name": "SessionStart"
}
EOF
      ;;
    *)
      echo "Unknown event type: $event_type"
      echo "Valid types: PreToolUse, PostToolUse, Stop, SubagentStop, UserPromptSubmit, SessionStart, SessionEnd"
      exit 1
      ;;
  esac
}

# Parse arguments
VERBOSE=false
TIMEOUT=60
EXPECT=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      show_usage
      ;;
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
    -t|--timeout)
      TIMEOUT="$2"
      shift 2
      ;;
    -e|--expect)
      EXPECT="$2"
      shift 2
      case "$EXPECT" in
        allow|deny|ask) ;;
        *)
          echo "❌ Error: --expect must be one of: allow, deny, ask (got: $EXPECT)"
          exit 1
          ;;
      esac
      ;;
    --create-sample)
      create_sample "$2"
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

if [ $# -ne 2 ]; then
  echo "Error: Missing required arguments"
  echo ""
  show_usage
fi

HOOK_SCRIPT="$1"
TEST_INPUT="$2"

# Validate inputs
if [ ! -f "$HOOK_SCRIPT" ]; then
  echo "❌ Error: Hook script not found: $HOOK_SCRIPT"
  exit 1
fi

if [ ! -x "$HOOK_SCRIPT" ]; then
  echo "⚠️  Warning: Hook script is not executable. Attempting to run with bash..."
  HOOK_SCRIPT="bash $HOOK_SCRIPT"
fi

if [ ! -f "$TEST_INPUT" ]; then
  echo "❌ Error: Test input not found: $TEST_INPUT"
  exit 1
fi

# Validate test input JSON
if ! jq empty "$TEST_INPUT" 2>/dev/null; then
  echo "❌ Error: Test input is not valid JSON"
  exit 1
fi

echo "🧪 Testing hook: $HOOK_SCRIPT"
echo "📥 Input: $TEST_INPUT"
echo ""

if [ "$VERBOSE" = true ]; then
  echo "Input JSON:"
  jq . "$TEST_INPUT"
  echo ""
fi

# Set up environment
export CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-/tmp/test-project}"
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(pwd)}"
export CLAUDE_ENV_FILE="${CLAUDE_ENV_FILE:-/tmp/test-env-$$}"

if [ "$VERBOSE" = true ]; then
  echo "Environment:"
  echo "  CLAUDE_PROJECT_DIR=$CLAUDE_PROJECT_DIR"
  echo "  CLAUDE_PLUGIN_ROOT=$CLAUDE_PLUGIN_ROOT"
  echo "  CLAUDE_ENV_FILE=$CLAUDE_ENV_FILE"
  echo ""
fi

# Run the hook
echo "▶️  Running hook (timeout: ${TIMEOUT}s)..."
echo ""

start_time=$(date +%s)

set +e
output=$(timeout "$TIMEOUT" bash -c "cat '$TEST_INPUT' | $HOOK_SCRIPT" 2>&1)
exit_code=$?
set -e

end_time=$(date +%s)
duration=$((end_time - start_time))

# Analyze results
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Results:"
echo ""
echo "Exit Code: $exit_code"
echo "Duration: ${duration}s"
echo ""

case $exit_code in
  0)
    echo "✅ Hook approved/succeeded"
    ;;
  2)
    echo "🚫 Hook blocked/denied"
    ;;
  124)
    echo "⏱️  Hook timed out after ${TIMEOUT}s"
    ;;
  *)
    echo "⚠️  Hook returned unexpected exit code: $exit_code"
    ;;
esac

echo ""
echo "Output:"
if [ -n "$output" ]; then
  echo "$output"
  echo ""

  # Try to parse as JSON
  if echo "$output" | jq empty 2>/dev/null; then
    echo "Parsed JSON output:"
    echo "$output" | jq .
  fi
else
  echo "(no output)"
fi

# Check for environment file
if [ -f "$CLAUDE_ENV_FILE" ]; then
  echo ""
  echo "Environment file created:"
  cat "$CLAUDE_ENV_FILE"
  rm -f "$CLAUDE_ENV_FILE"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Determine the hook's actual decision so we can compare it with --expect.
#
# Per the hook output schema documented in
# plugins/plugin-dev/skills/hook-development/SKILL.md and observed in the
# shipped example hooks:
#   - exit 2 is a hard "deny"
#   - exit 0 with a `hookSpecificOutput.permissionDecision` field of "deny"
#     is also a deny (programmatic deny, used when stderr is needed for
#     structured output)
#   - exit 0 with `permissionDecision: "ask"` is "ask"
#   - exit 0 with `permissionDecision: "allow"` is "allow"
#   - exit 0 with no JSON / no permissionDecision defaults to "allow"
#     (matches Claude Code's behaviour for a hook that runs to completion
#     and emits nothing)
#
# We extract the decision without relying on jq so the script keeps working
# on hosts where jq is not installed. The hook output is small and the
# values are constrained, so a targeted grep is sufficient and avoids
# pulling in a dependency for a single field. If jq IS available we still
# prefer it for correct handling of escaped JSON strings.
extract_decision() {
  local raw="$1"
  [ -z "$raw" ] && return 1
  if command -v jq >/dev/null 2>&1; then
    # Only attempt jq if the output looks like a JSON object.
    if printf '%s' "$raw" | grep -q '^{'; then
      local v
      v=$(printf '%s\n' "$raw" | jq -r '
        if type == "object" then
          ( .hookSpecificOutput.permissionDecision //
            .permissionDecision //
            empty )
        else
          empty
        end
      ' 2>/dev/null | head -1)
      case "$v" in
        allow|deny|ask) printf '%s\n' "$v"; return 0 ;;
      esac
    fi
  fi
  # Fallback: regex on the captured output. Matches either
  #   "permissionDecision":"deny"   or   "permissionDecision": "deny"
  # inside any JSON-looking payload.
  local v
  v=$(printf '%s\n' "$raw" \
    | grep -oE '"permissionDecision"[[:space:]]*:[[:space:]]*"(allow|deny|ask)"' \
    | head -1 \
    | sed -E 's/.*"permissionDecision"[[:space:]]*:[[:space:]]*"(allow|deny|ask)".*/\1/')
  case "$v" in
    allow|deny|ask) printf '%s\n' "$v"; return 0 ;;
  esac
  return 1
}

actual_decision=""
case $exit_code in
  2)
    actual_decision="deny"
    ;;
  0)
    if extract_decision "$output" >/dev/null 2>&1; then
      actual_decision=$(extract_decision "$output")
    else
      actual_decision="allow"
    fi
    ;;
  *)
    actual_decision=""
    ;;
esac

# Decide pass/fail.
# When --expect is given, the actual decision MUST match.
# When --expect is omitted, today's behaviour is preserved: exit 0 and 2
# both pass, anything else fails. This keeps existing callers working
# unchanged.
if [ -n "$EXPECT" ]; then
  if [ -z "$actual_decision" ]; then
    echo "❌ Hook did not produce a decision (exit $exit_code); expected $EXPECT"
    exit 1
  fi
  if [ "$actual_decision" != "$EXPECT" ]; then
    echo "❌ Decision mismatch: expected $EXPECT, got $actual_decision (exit $exit_code)"
    exit 1
  fi
  echo "✅ Decision matches: $actual_decision"
  exit 0
fi

if [ $exit_code -eq 0 ] || [ $exit_code -eq 2 ]; then
  echo "✅ Test completed successfully"
  exit 0
else
  echo "❌ Test failed"
  exit 1
fi
