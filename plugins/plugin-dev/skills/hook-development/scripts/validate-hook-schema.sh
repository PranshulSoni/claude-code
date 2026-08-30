#!/bin/bash
# Hook Schema Validator
# Validates hooks.json structure and checks for common issues
#
# Supports two input shapes:
#   1. Settings format:  { "PreToolUse": [...], "SessionStart": [...] }
#   2. Plugin wrapper:   { "description": "...", "hooks": { "PreToolUse": [...], ... } }
# The plugin wrapper format is the one documented in SKILL.md for plugin
# hooks.json files; both shapes are validated by descending into the events
# dict (the top-level events for the settings format, .hooks for the wrapper).
#
# The 'matcher' field is required for tool events (PreToolUse, PostToolUse)
# and is optional for all other events, matching the documented schema.

set -euo pipefail

# Usage
if [ $# -eq 0 ]; then
  echo "Usage: $0 <path/to/hooks.json>"
  echo ""
  echo "Validates hook configuration file for:"
  echo "  - Valid JSON syntax"
  echo "  - Required fields"
  echo "  - Hook type validity"
  echo "  - Matcher patterns"
  echo "  - Timeout ranges"
  exit 1
fi

# Check jq dependency early
if ! command -v jq >/dev/null 2>&1; then
  echo "❌ Error: jq is required but not installed: https://jqlang.github.io/jq/download/" >&2
  exit 1
fi

HOOKS_FILE="$1"

if [ ! -f "$HOOKS_FILE" ]; then
  echo "❌ Error: File not found: $HOOKS_FILE"
  exit 1
fi

echo "🔍 Validating hooks configuration: $HOOKS_FILE"
echo ""

# Check 1: Valid JSON
echo "Checking JSON syntax..."
if ! jq empty "$HOOKS_FILE" 2>/dev/null; then
  echo "❌ Invalid JSON syntax"
  exit 1
fi
echo "✅ Valid JSON"

# Detect the input shape. The plugin wrapper format is:
#   { "description": "...", "hooks": { "<Event>": [ ... ] } }
# The settings format is:
#   { "<Event>": [ ... ] }
if jq -e '.hooks and (.hooks | type == "object")' "$HOOKS_FILE" >/dev/null 2>&1; then
  HOOKS_ROOT=".hooks"
  echo "✅ Detected plugin wrapper format"

  # Validate optional description field if present
  if jq -e 'has("description")' "$HOOKS_FILE" >/dev/null 2>&1; then
    desc_type=$(jq -r '.description | type' "$HOOKS_FILE" 2>/dev/null || echo "")
    if [ "$desc_type" != "string" ]; then
      echo "⚠️  'description' field should be a string"
    fi
  fi
else
  HOOKS_ROOT="."
  echo "✅ Detected direct/settings format"
fi

# Check 2: Root structure
echo ""
echo "Checking root structure..."
VALID_EVENTS=("PreToolUse" "PostToolUse" "UserPromptSubmit" "Stop" "SubagentStop" "SessionStart" "SessionEnd" "PreCompact" "Notification")

for event in $(jq -r "($HOOKS_ROOT) | keys[]" "$HOOKS_FILE"); do
  found=false
  for valid_event in "${VALID_EVENTS[@]}"; do
    if [ "$event" = "$valid_event" ]; then
      found=true
      break
    fi
  done

  if [ "$found" = false ]; then
    echo "⚠️  Unknown event type: $event"
  fi
done
echo "✅ Root structure valid"

# Check 3: Validate each hook
echo ""
echo "Validating individual hooks..."

error_count=0
warning_count=0

# Events that REQUIRE a 'matcher' field. Per the documented schema, only the
# tool events (PreToolUse, PostToolUse) use matchers; non-tool events may
# omit 'matcher' and the framework will dispatch all configured handlers.
TOOL_EVENTS_WITH_MATCHER=("PreToolUse" "PostToolUse")

requires_matcher() {
  local event="$1"
  local e
  for e in "${TOOL_EVENTS_WITH_MATCHER[@]}"; do
    if [ "$event" = "$e" ]; then
      return 0
    fi
  done
  return 1
}

for event in $(jq -r "($HOOKS_ROOT) | keys[]" "$HOOKS_FILE"); do
  hook_count=$(jq -r "($HOOKS_ROOT) | .[\"$event\"] | length" "$HOOKS_FILE")

  for ((i=0; i<hook_count; i++)); do
    # Check matcher exists (only required for tool events)
    matcher=$(jq -r "($HOOKS_ROOT) | .[\"$event\"][$i].matcher // empty" "$HOOKS_FILE")
    if [ -z "$matcher" ]; then
      if requires_matcher "$event"; then
        echo "❌ $event[$i]: Missing 'matcher' field"
        error_count=$((error_count + 1))
        continue
      fi
      # For non-tool events, a missing matcher is valid (framework
      # dispatches the hook unconditionally for that event).
    fi

    # Check hooks array exists
    hooks=$(jq -r "($HOOKS_ROOT) | .[\"$event\"][$i].hooks // empty" "$HOOKS_FILE")
    if [ -z "$hooks" ] || [ "$hooks" = "null" ]; then
      echo "❌ $event[$i]: Missing 'hooks' array"
      error_count=$((error_count + 1))
      continue
    fi

    # Validate each hook in the array
    hook_array_count=$(jq -r "($HOOKS_ROOT) | .[\"$event\"][$i].hooks | length" "$HOOKS_FILE")

    for ((j=0; j<hook_array_count; j++)); do
      hook_type=$(jq -r "($HOOKS_ROOT) | .[\"$event\"][$i].hooks[$j].type // empty" "$HOOKS_FILE")

      if [ -z "$hook_type" ]; then
        echo "❌ $event[$i].hooks[$j]: Missing 'type' field"
        error_count=$((error_count + 1))
        continue
      fi

      if [ "$hook_type" != "command" ] && [ "$hook_type" != "prompt" ]; then
        echo "❌ $event[$i].hooks[$j]: Invalid type '$hook_type' (must be 'command' or 'prompt')"
        error_count=$((error_count + 1))
        continue
      fi

      # Check type-specific fields
      if [ "$hook_type" = "command" ]; then
        command=$(jq -r "($HOOKS_ROOT) | .[\"$event\"][$i].hooks[$j].command // empty" "$HOOKS_FILE")
        if [ -z "$command" ]; then
          echo "❌ $event[$i].hooks[$j]: Command hooks must have 'command' field"
          error_count=$((error_count + 1))
        else
          # Check for hardcoded paths
          if [[ "$command" == /* ]] && [[ "$command" != *'${CLAUDE_PLUGIN_ROOT}'* ]]; then
            echo "⚠️  $event[$i].hooks[$j]: Hardcoded absolute path detected. Consider using \${CLAUDE_PLUGIN_ROOT}"
            warning_count=$((warning_count + 1))
          fi
        fi
      elif [ "$hook_type" = "prompt" ]; then
        prompt=$(jq -r "($HOOKS_ROOT) | .[\"$event\"][$i].hooks[$j].prompt // empty" "$HOOKS_FILE")
        if [ -z "$prompt" ]; then
          echo "❌ $event[$i].hooks[$j]: Prompt hooks must have 'prompt' field"
          error_count=$((error_count + 1))
        fi

        # Check if prompt-based hooks are used on supported events
        if [ "$event" != "Stop" ] && [ "$event" != "SubagentStop" ] && [ "$event" != "UserPromptSubmit" ] && [ "$event" != "PreToolUse" ]; then
          echo "⚠️  $event[$i].hooks[$j]: Prompt hooks may not be fully supported on $event (best on Stop, SubagentStop, UserPromptSubmit, PreToolUse)"
          warning_count=$((warning_count + 1))
        fi
      fi

      # Check timeout
      timeout=$(jq -r "($HOOKS_ROOT) | .[\"$event\"][$i].hooks[$j].timeout // empty" "$HOOKS_FILE")
      if [ -n "$timeout" ] && [ "$timeout" != "null" ]; then
        if ! [[ "$timeout" =~ ^[0-9]+$ ]]; then
          echo "❌ $event[$i].hooks[$j]: Timeout must be a number"
          error_count=$((error_count + 1))
        elif [ "$timeout" -gt 600 ]; then
          echo "⚠️  $event[$i].hooks[$j]: Timeout $timeout seconds is very high (max 600s)"
          warning_count=$((warning_count + 1))
        elif [ "$timeout" -lt 5 ]; then
          echo "⚠️  $event[$i].hooks[$j]: Timeout $timeout seconds is very low"
          warning_count=$((warning_count + 1))
        fi
      fi
    done
  done
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ $error_count -eq 0 ] && [ $warning_count -eq 0 ]; then
  echo "✅ All checks passed!"
  exit 0
elif [ $error_count -eq 0 ]; then
  echo "⚠️  Validation passed with $warning_count warning(s)"
  exit 0
else
  echo "❌ Validation failed with $error_count error(s) and $warning_count warning(s)"
  exit 1
fi
