#!/usr/bin/env bash
# spawn-glm.sh — Spawn one GLM worker for Opus-GLM orchestration
#
# Cross-platform (Windows + macOS/Linux). Pipes prompt from file through
# stdin to the claude-glm wrapper, which handles all env vars, config paths,
# model mappings, and binary discovery. Stdin piping bypasses the Windows
# batch parser — no issues with special characters in prompts.
#
# Model is hardcoded to sonnet (glm-4.7) — no model selection allowed.
# Agents run until completion — no max-turns limit.
#
# Output format: stream-json for real-time log monitoring.
# Sessions are saved to ~/.claude-glm/ for debugging.
#
# Usage:
#   .claude/tools/spawn-glm.sh -n NAME -f PROMPT_FILE
#
# Arguments:
#   -n, --name         Agent name (log: tmp/{NAME}-log.txt)
#   -f, --prompt-file  Path to the prompt text file
#
# Output (stdout):
#   SPAWNED|name|pid|log_file
#
# Examples:
#   .claude/tools/spawn-glm.sh -n sec-reviewer -f tmp/sec-reviewer-prompt.txt
#   .claude/tools/spawn-glm.sh -n shell-reviewer -f tmp/shell-reviewer-prompt.txt

set -euo pipefail

# ── Detect platform → select GLM wrapper ──
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) GLM_WRAPPER="claude-glm.cmd" ;;
  *)                     GLM_WRAPPER="claude-glm" ;;
esac

command -v "$GLM_WRAPPER" &>/dev/null || \
  { echo "ERROR: $GLM_WRAPPER not found in PATH. Install claude-glm first." >&2; exit 1; }

# ── Parse arguments ──
NAME="" PROMPT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--name)        NAME="$2";        shift 2 ;;
    -f|--prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    -h|--help)        sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "ERROR: Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ── Validate ──
[[ -z "$NAME" ]]        && { echo "ERROR: -n NAME required" >&2; exit 1; }
[[ -z "$PROMPT_FILE" ]] && { echo "ERROR: -f PROMPT_FILE required" >&2; exit 1; }
[[ ! -f "$PROMPT_FILE" ]] && \
  { echo "ERROR: Prompt file not found: $PROMPT_FILE" >&2; exit 1; }
[[ ! -s "$PROMPT_FILE" ]] && \
  { echo "ERROR: Prompt file is empty: $PROMPT_FILE" >&2; exit 1; }

mkdir -p tmp
LOG="tmp/${NAME}-log.txt"
STATUS="tmp/${NAME}-status.txt"

# ── Bypass nesting guard ──
unset CLAUDECODE 2>/dev/null || true

# ── Spawn: pipe prompt file → claude-glm wrapper ──
# Model: sonnet (glm-4.7) — hardcoded, no override allowed
# No max-turns — agents run until completion
cat "$PROMPT_FILE" | "$GLM_WRAPPER" \
  -p \
  --verbose \
  --model sonnet \
  --output-format stream-json \
  --dangerously-skip-permissions \
  > "$LOG" 2>&1 &

PID=$!

RESULT="SPAWNED|${NAME}|${PID}|${LOG}"

# Write to status file (reliable) + stdout (best-effort on Windows).
# On Windows Git Bash, parallel claude-glm.cmd background launches can cause
# stdout capture loss in the Bash tool. The status file is the reliable path.
printf '%s\n' "$RESULT" > "$STATUS"
echo "$RESULT"
