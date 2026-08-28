#!/bin/bash
# Agent File Validator
# Validates agent markdown files for correct structure and content

set -euo pipefail

# Usage
if [ $# -eq 0 ]; then
  echo "Usage: $0 <path/to/agent.md>"
  echo ""
  echo "Validates agent file for:"
  echo "  - YAML frontmatter structure"
  echo "  - Required fields (name, description, model, color)"
  echo "  - Field formats and constraints"
  echo "  - System prompt presence and length"
  echo "  - Example blocks in description"
  exit 1
fi

AGENT_FILE="$1"

echo "🔍 Validating agent file: $AGENT_FILE"
echo ""

# Check 1: File exists
if [ ! -f "$AGENT_FILE" ]; then
  echo "❌ File not found: $AGENT_FILE"
  exit 1
fi
echo "✅ File exists"

# Check 2: Starts with ---
# Strip a leading UTF-8 BOM (issue #73158) before reading the first
# line so files written with PowerShell's default UTF-8 encoding on
# Windows — which prepends EF BB BF — are still recognised as valid
# frontmatter. The file is not modified on disk.
if [ "$(head -c 3 "$AGENT_FILE" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "efbbbf" ]; then
  FIRST_LINE=$(tail -c +4 "$AGENT_FILE" | head -1)
else
  FIRST_LINE=$(head -1 "$AGENT_FILE")
fi
if [ "$FIRST_LINE" != "---" ]; then
  echo "❌ File must start with YAML frontmatter (---)"
  exit 1
fi
echo "✅ Starts with frontmatter"

# Check 3: Has closing ---
if ! tail -n +2 "$AGENT_FILE" | grep -q '^---$'; then
  echo "❌ Frontmatter not closed (missing second ---)"
  exit 1
fi
echo "✅ Frontmatter properly closed"

# Extract frontmatter and system prompt
# Strip a leading UTF-8 BOM if present (issue #73158). PowerShell's
# default UTF-8 encoding on Windows writes a BOM, which causes the
# frontmatter regex below to silently miss the opening '---' marker.
# A BOM is the three-byte sequence EF BB BF. The file is not modified
# on disk; the stripped content is used only for the regex match.
if [ "$(head -c 3 "$AGENT_FILE" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "efbbbf" ]; then
  AGENT_CONTENT=$(tail -c +4 "$AGENT_FILE")
else
  AGENT_CONTENT=$(cat "$AGENT_FILE")
fi
FRONTMATTER=$(printf '%s\n' "$AGENT_CONTENT" | sed -n '/^---$/,/^---$/{ /^---$/d; p; }')
SYSTEM_PROMPT=$(printf '%s\n' "$AGENT_CONTENT" | awk '/^---$/{i++; next} i>=2')

# Check 4: Required fields
echo ""
echo "Checking required fields..."

error_count=0
warning_count=0

# Check name field
NAME=$(echo "$FRONTMATTER" | grep '^name:' | sed 's/name: *//' | sed 's/^"\(.*\)"$/\1/')

if [ -z "$NAME" ]; then
  echo "❌ Missing required field: name"
  ((error_count++))
else
  echo "✅ name: $NAME"

  # Validate name format
  if ! [[ "$NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]$ ]]; then
    echo "❌ name must start/end with alphanumeric and contain only letters, numbers, hyphens"
    ((error_count++))
  fi

  # Validate name length
  name_length=${#NAME}
  if [ $name_length -lt 3 ]; then
    echo "❌ name too short (minimum 3 characters)"
    ((error_count++))
  elif [ $name_length -gt 50 ]; then
    echo "❌ name too long (maximum 50 characters)"
    ((error_count++))
  fi

  # Check for generic names
  if [[ "$NAME" =~ ^(helper|assistant|agent|tool)$ ]]; then
    echo "⚠️  name is too generic: $NAME"
    ((warning_count++))
  fi
fi

# Check description field
DESCRIPTION=$(echo "$FRONTMATTER" | grep '^description:' | sed 's/description: *//')

if [ -z "$DESCRIPTION" ]; then
  echo "❌ Missing required field: description"
  ((error_count++))
else
  desc_length=${#DESCRIPTION}
  echo "✅ description: ${desc_length} characters"

  if [ $desc_length -lt 10 ]; then
    echo "⚠️  description too short (minimum 10 characters recommended)"
    ((warning_count++))
  elif [ $desc_length -gt 5000 ]; then
    echo "⚠️  description very long (over 5000 characters)"
    ((warning_count++))
  fi

  # Check for example blocks
  if ! echo "$DESCRIPTION" | grep -q '<example>'; then
    echo "⚠️  description should include <example> blocks for triggering"
    ((warning_count++))
  fi

  # Check for "Use this agent when" pattern
  if ! echo "$DESCRIPTION" | grep -qi 'use this agent when'; then
    echo "⚠️  description should start with 'Use this agent when...'"
    ((warning_count++))
  fi
fi

# Check model field
MODEL=$(echo "$FRONTMATTER" | grep '^model:' | sed 's/model: *//')

if [ -z "$MODEL" ]; then
  echo "❌ Missing required field: model"
  ((error_count++))
else
  echo "✅ model: $MODEL"

  case "$MODEL" in
    inherit|sonnet|opus|haiku)
      # Valid model
      ;;
    *)
      echo "⚠️  Unknown model: $MODEL (valid: inherit, sonnet, opus, haiku)"
      ((warning_count++))
      ;;
  esac
fi

# Check color field
COLOR=$(echo "$FRONTMATTER" | grep '^color:' | sed 's/color: *//')

if [ -z "$COLOR" ]; then
  echo "❌ Missing required field: color"
  ((error_count++))
else
  echo "✅ color: $COLOR"

  case "$COLOR" in
    blue|cyan|green|yellow|magenta|red)
      # Valid color
      ;;
    *)
      echo "⚠️  Unknown color: $COLOR (valid: blue, cyan, green, yellow, magenta, red)"
      ((warning_count++))
      ;;
  esac
fi

# Check tools field (optional)
TOOLS=$(echo "$FRONTMATTER" | grep '^tools:' | sed 's/tools: *//')

if [ -n "$TOOLS" ]; then
  echo "✅ tools: $TOOLS"
else
  echo "💡 tools: not specified (agent has access to all tools)"
fi

# Check 5: System prompt
echo ""
echo "Checking system prompt..."

if [ -z "$SYSTEM_PROMPT" ]; then
  echo "❌ System prompt is empty"
  ((error_count++))
else
  prompt_length=${#SYSTEM_PROMPT}
  echo "✅ System prompt: $prompt_length characters"

  if [ $prompt_length -lt 20 ]; then
    echo "❌ System prompt too short (minimum 20 characters)"
    ((error_count++))
  elif [ $prompt_length -gt 10000 ]; then
    echo "⚠️  System prompt very long (over 10,000 characters)"
    ((warning_count++))
  fi

  # Check for second person
  if ! echo "$SYSTEM_PROMPT" | grep -q "You are\|You will\|Your"; then
    echo "⚠️  System prompt should use second person (You are..., You will...)"
    ((warning_count++))
  fi

  # Check for structure
  if ! echo "$SYSTEM_PROMPT" | grep -qi "responsibilities\|process\|steps"; then
    echo "💡 Consider adding clear responsibilities or process steps"
  fi

  if ! echo "$SYSTEM_PROMPT" | grep -qi "output"; then
    echo "💡 Consider defining output format expectations"
  fi
fi

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
