#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# status.sh — Show claude-ops status dashboard
#
# Usage: ./scripts/status.sh
# ============================================================================

OPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${OPS_ROOT}/state"
LOG_DIR="${OPS_ROOT}/logs"

echo "claude-ops Status"
echo "━━━━━━━━━━━━━━━━━"
echo ""

# Today's usage
budget_file="${STATE_DIR}/budget-$(date +%Y-%m-%d).json"
if [[ -f "$budget_file" ]]; then
  invocations=$(jq '.invocations' "$budget_file")
  max=$(jq '.max_invocations' "$budget_file")
  duration=$(jq '.total_duration_s' "$budget_file")
  echo "Today: ${invocations}/${max} invocations (${duration}s total runtime)"
else
  echo "Today: No activity yet"
fi
echo ""

# Recent invocations
echo "Recent Invocations:"
if [[ -f "${STATE_DIR}/invocations.jsonl" ]]; then
  tail -10 "${STATE_DIR}/invocations.jsonl" | jq -r \
    '"  \(.timestamp) | \(.role) → \(.target) | \(.duration_s)s | exit:\(.exit_code)"'
else
  echo "  No invocations recorded yet"
fi
echo ""

# Active locks
echo "Active Locks:"
if [[ -d "${STATE_DIR}/locks" ]]; then
  local_lock_found=false
  while IFS= read -r -d '' lockdir; do
    local_lock_found=true
    target=$(basename "$lockdir" .lock)
    pid="unknown"
    if [[ -f "${lockdir}/pid" ]]; then pid=$(<"${lockdir}/pid"); fi
    alive="dead"
    if [[ "$pid" != "unknown" ]]; then
      kill -0 "$pid" 2>/dev/null && alive="alive" || true
    fi
    echo "  $target — pid $pid ($alive)"
  done < <(find "${STATE_DIR}/locks" -maxdepth 1 -name "*.lock" -type d -print0 2>/dev/null)
  if [[ "$local_lock_found" == "false" ]]; then
    echo "  None"
  fi
else
  echo "  None"
fi
echo ""

# Recent logs
echo "Recent Logs:"
if [[ -d "$LOG_DIR" ]]; then
  local_log_found=false
  while IFS= read -r -d '' f; do
    local_log_found=true
    echo "  $(basename "$f") ($(wc -l < "$f" | tr -d ' ') lines)"
  done < <(find "$LOG_DIR" -maxdepth 1 -name "*.log" -type f -print0 2>/dev/null | head -z -n 5 2>/dev/null || find "$LOG_DIR" -maxdepth 1 -name "*.log" -type f -print0 2>/dev/null)
  if [[ "$local_log_found" == "false" ]]; then
    echo "  No logs yet"
  fi
else
  echo "  No logs yet"
fi
echo ""

# Cron status
echo "Cron Schedule:"
if crontab -l 2>/dev/null | grep -q claude-ops; then
  echo "  Installed ($(crontab -l 2>/dev/null | grep claude-ops | grep -v '^#' | wc -l | tr -d ' ') jobs)"
else
  echo "  Not installed. Run: crontab schedules/crontab"
fi
