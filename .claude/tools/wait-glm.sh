#!/usr/bin/env bash
# wait-glm.sh — Block until all given GLM agent PIDs exit, with progress
# monitoring, stall detection, and health-check.
#
# Each Bash tool call runs in a new shell, so `wait $PID` fails with
# "not a child of this shell". This script polls PIDs with kill -0
# instead, which works for any process on the system.
#
# Features:
# - Progress report: first at 30s, then every 60s, showing alive agents and log sizes
# - STALLED detection: flags agents with 0-byte log after 2+ minutes
# - Automatic health check after all agents finish
#
# Usage (backward-compatible — bare PIDs still work):
#   .claude/tools/wait-glm.sh PID1 [PID2 PID3 ...]
#   .claude/tools/wait-glm.sh name1:PID1 [name2:PID2 ...]
#
# When names are provided, progress monitoring and health check target
# only those agents. Bare PIDs skip log monitoring during wait.
#
# Output:
#   Progress: first at 30s, then every 60s, STALLED warnings, finish events, health summary.
#   Polls every 10 seconds.

set -euo pipefail

[[ $# -eq 0 ]] && { echo "Usage: wait-glm.sh PID1 [PID2 ...] or name1:PID1 [name2:PID2 ...]" >&2; exit 1; }

# Parse arguments — support both "PID" and "name:PID" formats
PIDS=()
NAMES=()
HAS_NAMES=false

for arg in "$@"; do
  if [[ "$arg" == *:* ]]; then
    HAS_NAMES=true
    NAMES+=("${arg%%:*}")
    PIDS+=("${arg##*:}")
  else
    NAMES+=("")
    PIDS+=("$arg")
  fi
done

DONE=()
for pid in "${PIDS[@]}"; do
  DONE+=("false")
done

POLL=0
FIRST_PROGRESS=3    # 3 polls × 10s = 30s (first report)
PROGRESS_EVERY=6    # 6 polls × 10s = 60s (subsequent reports)
STALL_AFTER=12      # 12 polls × 10s = 2 minutes

while true; do
  alive=0
  POLL=$((POLL + 1))

  for i in "${!PIDS[@]}"; do
    pid="${PIDS[$i]}"
    if [[ "${DONE[$i]}" == "true" ]]; then
      continue
    fi
    if kill -0 "$pid" 2>/dev/null; then
      alive=$((alive + 1))
    else
      DONE[$i]="true"
      label="${NAMES[$i]:-PID $pid}"
      echo "PID $pid: finished ($label)"
    fi
  done

  [[ $alive -eq 0 ]] && break

  # Progress report: first at 30s, then every 60s (only with name:pid format)
  if [[ "$HAS_NAMES" == "true" && ($POLL -eq $FIRST_PROGRESS || ($POLL -gt $FIRST_PROGRESS && $(( (POLL - FIRST_PROGRESS) % PROGRESS_EVERY )) -eq 0)) ]]; then
    elapsed=$((POLL * 10))
    echo ""
    echo "--- Progress (${elapsed}s elapsed, $alive alive) ---"
    for i in "${!PIDS[@]}"; do
      if [[ "${DONE[$i]}" == "true" ]]; then continue; fi
      pid="${PIDS[$i]}"
      name="${NAMES[$i]}"
      [[ -z "$name" ]] && continue
      log="tmp/${name}-log.txt"
      if [[ -f "$log" ]]; then
        bytes=$(wc -c < "$log" 2>/dev/null || echo 0)
        if [[ "$bytes" -eq 0 && $POLL -ge $STALL_AFTER ]]; then
          echo "  STALLED: $name (PID $pid) — 0-byte log after ${elapsed}s"
        else
          echo "  $name (PID $pid): ${bytes} bytes"
        fi
      else
        if [[ $POLL -ge $STALL_AFTER ]]; then
          echo "  STALLED: $name (PID $pid) — log file missing after ${elapsed}s"
        else
          echo "  $name (PID $pid): waiting for log..."
        fi
      fi
    done
  fi

  sleep 10
done

echo ""
echo "All ${#PIDS[@]} agents finished."

# ── Health check: verify logs and reports ──
echo ""
echo "=== HEALTH CHECK ==="
EMPTY_LOGS=0
MISSING_REPORTS=0
EMPTY_REPORTS=0
HEALTHY=0

health_check_agent() {
  local name="$1"
  local log="tmp/${name}-log.txt"
  local report="tmp/${name}-report.md"

  if [[ ! -f "$log" ]]; then
    echo "MISSING LOG: $log — agent log file not found"
    EMPTY_LOGS=$((EMPTY_LOGS + 1))
    return
  fi

  if [[ ! -s "$log" ]]; then
    echo "EMPTY LOG: $log — agent produced no output (likely crashed or failed to start)"
    EMPTY_LOGS=$((EMPTY_LOGS + 1))
    return
  fi

  if [[ ! -f "$report" ]]; then
    MISSING_REPORTS=$((MISSING_REPORTS + 1))
    echo "MISSING REPORT: $report — agent ran but did not write report"
  elif [[ ! -s "$report" ]]; then
    EMPTY_REPORTS=$((EMPTY_REPORTS + 1))
    echo "EMPTY REPORT: $report — agent wrote 0-byte report"
  else
    local bytes
    bytes=$(wc -c < "$report")
    HEALTHY=$((HEALTHY + 1))
    echo "OK: $name (report: ${bytes} bytes)"
  fi
}

if [[ "$HAS_NAMES" == "true" ]]; then
  # Check only the named agents
  for name in "${NAMES[@]}"; do
    [[ -n "$name" ]] && health_check_agent "$name"
  done
else
  # Fallback: check all log files in tmp/
  for log in tmp/*-log.txt; do
    [[ -f "$log" ]] || continue
    name="${log#tmp/}"
    name="${name%-log.txt}"
    health_check_agent "$name"
  done
fi

echo ""
echo "Health: $HEALTHY OK, $EMPTY_LOGS empty/missing logs, $MISSING_REPORTS missing reports, $EMPTY_REPORTS empty reports"

if [[ $EMPTY_LOGS -gt 0 || $MISSING_REPORTS -gt 0 || $EMPTY_REPORTS -gt 0 ]]; then
  echo ""
  echo "ACTION REQUIRED: $((EMPTY_LOGS + MISSING_REPORTS + EMPTY_REPORTS)) agent(s) failed — respawn or note gaps before verification."
fi

echo ""
ls tmp/*-report.md 2>/dev/null || echo "No report files found in tmp/"
