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
  echo "  -c, --config FILE     Validate the supplied hook against the"
  echo "                        matcher in FILE (a hooks.json). The script"
  echo "                        reports which matchers select the hook and"
  echo "                        fails when the hook would never run in a"
  echo "                        real session because no matcher selected it."
  echo ""
  echo "Examples:"
  echo "  $0 validate-bash.sh test-input.json"
  echo "  $0 -v -t 30 validate-write.sh write-input.json"
  echo "  $0 --expect deny guard.mjs input.json   # fail if hook does not deny"
  echo "  $0 -c hooks.json guard.mjs input.json"
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
CONFIG=""

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
    -c|--config)
      CONFIG="$2"
      shift 2
      if [ ! -f "$CONFIG" ]; then
        echo "❌ Error: Config file not found: $CONFIG"
        exit 1
      fi
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

# ---- Matcher evaluation (only when --config is supplied) -----------------
#
# Claude Code's documented matcher semantics (see
# plugins/plugin-dev/skills/hook-development/SKILL.md, "Matchers"):
#
#   * "*" matches every tool name
#   * "A|B|C" matches any of A, B or C
#   * an otherwise "plain" string (alphanumerics, underscore, hyphen,
#     space) is an exact, case-sensitive match
#   * anything else is an unanchored regex against the tool name
#
# The matcher is case-sensitive. Empty string is treated as a wildcard
# (matches everything), matching the runtime's documented behaviour.
#
# This implementation does NOT depend on jq, so it works on hosts where
# jq is not installed. The same regex-extraction strategy used by the
# permissionDecision decoder in --expect is used to pull values out of
# the config JSON.

# Extract a string field from a small JSON object, falling back to "".
# Order of preference: jq if available, then a regex on the input.
json_string() {
  local raw="$1" key="$2"
  if command -v jq >/dev/null 2>&1 && printf '%s' "$raw" | grep -q '{'; then
    local v
    v=$(printf '%s\n' "$raw" | jq -r --arg k "$key" '
        if type == "object" then
          ( .[$k] // empty | if type == "string" then . else (.|tostring) end )
        else empty end
      ' 2>/dev/null | head -1)
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  fi
  printf '%s\n' "$raw" \
    | grep -oE "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -1 \
    | sed -E "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/"
}

# Decide whether a single matcher value selects a given tool name.
matcher_selects() {
  local matcher="$1" tool="$2"
  # Wildcards: empty or "*" select every tool.
  if [ -z "$matcher" ] || [ "$matcher" = "*" ]; then
    return 0
  fi
  # Pipe-separated list: any exact match selects.
  if [[ "$matcher" == *"|"* ]]; then
    local item
    IFS='|' read -r -a parts <<< "$matcher"
    for item in "${parts[@]}"; do
      if [ "$item" = "$tool" ]; then
        return 0
      fi
    done
    return 1
  fi
  # Otherwise: treat as exact match iff the matcher is "plain" (only
  # alphanumerics, underscore, hyphen, space and pipe — pipe was handled
  # above), and otherwise as an unanchored regex.
  if [[ "$matcher" =~ ^[A-Za-z0-9_[:space:]-]+$ ]]; then
    [ "$matcher" = "$tool" ] && return 0 || return 1
  fi
  # Regex: anchored by the matcher semantics (unanchored in the string,
  # but the matcher is one logical regex so we use grep -E on the raw
  # tool name without implicit anchoring). We rely on the user not to
  # write malicious regex; this is a test-time tool, not a sandbox.
  if printf '%s\n' "$tool" | grep -Eq -- "$matcher"; then
    return 0
  fi
  return 1
}

if [ -n "$CONFIG" ]; then
  # Pull the event name from the test input. Only PreToolUse and
  # PostToolUse currently carry a tool_name and a matcher; for other
  # events the matcher check is skipped with a note.
  event_name=$(json_string "$(cat "$TEST_INPUT")" hook_event_name || true)
  tool_name=$(json_string "$(cat "$TEST_INPUT")" tool_name || true)

  echo "📋 Config:   $CONFIG"
  [ -n "$event_name" ] && echo "📌 Event:    $event_name"
  [ -n "$tool_name"  ] && echo "🔧 Tool:     $tool_name"
  echo ""

  if [ -z "$event_name" ] || [ -z "$tool_name" ]; then
    echo "ℹ️  Matcher check skipped: input has no hook_event_name or tool_name."
  else
    # Resolve hooks -> event -> matchers. We need just enough to read the
    # list of matchers and the list of commands under each. We do this
    # with a hand-rolled line scanner so we don't need jq.
    # Format we expect (whitespace-tolerant):
    #   "PreToolUse": [
    #     { "matcher": "...", "hooks": [ { "type": "command", "command": "..." }, ... ] },
    #     ...
    #   ]
    in_event=0
    in_matchers=0
    matcher=""
    cmd=""
    selected_count=0
    reported_count=0
    event_seen=0
    selected_cmds=()

    while IFS= read -r line; do
      if [ "$in_event" = 0 ]; then
        # Enter the event block when we see its name as a key.
        if [[ "$line" == *"\"$event_name\""*":"* ]]; then
          in_event=1
          event_seen=1
        fi
        continue
      fi
      # End of the event's array. The closing ']' line is one of:
      #   "  ]"
      #   "  ],"  (with a trailing comma)
      # We detect it by trimming the line and checking for ']' only.
      trimmed=$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/,[[:space:]]*$//; s/[[:space:]]+$//')
      if [ "$trimmed" = "]" ]; then
        break
      fi
      # New matcher entry. The matcher line in the shipped config format
      # also embeds the command(s) for this entry, e.g.
      #   { "matcher": "Write", "hooks": [ { "type": "command",
      #       "command": "bash /c/tmp/..." } ] }
      # so we handle both the multi-line and the single-line form here.
      if [[ "$line" == *"\"matcher\""*":"* ]]; then
        in_matchers=1
        matcher=$(printf '%s\n' "$line" \
          | sed -nE 's/.*"matcher"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
        reported_count=$((reported_count+1))
        echo "  matcher #$reported_count: \"$matcher\""
        if matcher_selects "$matcher" "$tool_name"; then
          echo "    ↳ selects $tool_name"
          # If the same line also carries a command, capture it now so
          # we don't lose it when the next line is the closing "]".
          if [[ "$line" == *"\"command\""*":"* ]]; then
            local_cmd=$(printf '%s\n' "$line" \
              | sed -nE 's/.*"command"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
            selected_count=$((selected_count+1))
            selected_cmds+=("$local_cmd")
          fi
        else
          echo "    ↳ does not select $tool_name"
        fi
        continue
      fi
      # A command line on its own (the multi-line form, where the matcher
      # is on a separate line from the hook entries).
      if [ "$in_matchers" = 1 ] && [[ "$line" == *"\"command\""*":"* ]]; then
        local_cmd=$(printf '%s\n' "$line" \
          | sed -nE 's/.*"command"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
        if matcher_selects "$matcher" "$tool_name"; then
          selected_count=$((selected_count+1))
          selected_cmds+=("$local_cmd")
        fi
        continue
      fi
      # A new matcher entry resets the matcher variable; we rely on the
      # fact that "matcher" lines always precede "command" lines in the
      # shipped config format. (We also reset on any "{"-opening line
      # that looks like the start of a new entry.)
      if [[ "$line" == *"{"* ]] && [ "$reported_count" -gt 0 ] \
         && [[ "$line" != *"\"hooks\""* ]] \
         && [[ "$line" != *"\"type\""* ]] \
         && [[ "$line" != *"\"command\""* ]] \
         && [[ "$line" != *"\"matcher\""* ]]; then
        # entering a new top-level entry in the array
        in_matchers=0
        matcher=""
      fi
    done < "$CONFIG"

    echo ""
    if [ "$event_seen" = 0 ]; then
      # The event is not in the config at all (e.g. a SessionStart event
      # tested against a PreToolUse-only config). We can't evaluate
      # matchers for this event, so we skip the gate and run the hook.
      echo "ℹ️  No $event_name entries in $CONFIG; matcher check skipped."
    elif [ "$reported_count" = 0 ]; then
      # The event is present but has no matcher entries. In a real
      # session no hook would run for this event, so fail.
      echo ""
      echo "❌ $event_name is in $CONFIG but has no matcher entries."
      echo "   The supplied hook would never run in a real session."
      exit 1
    else
      echo "📊 $selected_count of $reported_count matcher(s) select $tool_name"
    fi

    # If the supplied HOOK_SCRIPT is one of the selected commands, good.
    # If not, the tester is misconfigured (the hook would not run in a
    # real session). We compare the supplied path's basename against
    # the basenames of selected commands because absolute paths in
    # config often point elsewhere and we only need to catch a wrong-tool
    # misconfiguration.
    selected=0
    for c in "${selected_cmds[@]}"; do
      cb=$(basename -- "$c" 2>/dev/null)
      hb=$(basename -- "$HOOK_SCRIPT" 2>/dev/null)
      if [ "$cb" = "$hb" ]; then
        selected=1
        break
      fi
    done
    if [ "$reported_count" -gt 0 ] && [ "$selected_count" -eq 0 ]; then
      echo ""
      echo "❌ No matcher in $CONFIG selects $tool_name for $event_name."
      echo "   The supplied hook script would never run in a real session."
      exit 1
    fi
    if [ "$reported_count" -gt 0 ] && [ "$selected_count" -gt 0 ] && [ "$selected" = 0 ]; then
      echo ""
      echo "❌ The supplied hook script is NOT among the handlers selected by any matcher."
      echo "   In a real session this hook would never run for the given event/tool."
      echo "   Either the matcher in $CONFIG is wrong, or you are testing the wrong hook."
      exit 1
    fi
  fi
fi

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
