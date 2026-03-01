#!/usr/bin/env bash
set -euo pipefail

# PM Morning Triage — categorize and prioritize only
# Schedule: Daily at 9:00 AM
# Cron: 0 9 * * * /Users/austin/Git_Repos/claude-ops/jobs/pm-triage.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"
TARGET_PATH=$(jq -r '.targets[] | select(.name == "claude-agent-protocol") | .path' "${SCRIPT_DIR}/config.json")

# Polling guard: skip if no open issues exist
if [[ -n "$TARGET_PATH" ]] && [[ -d "$TARGET_PATH" ]]; then
  OPEN_COUNT=$(cd "$TARGET_PATH" && gh issue list --state open --json number --jq length 2>/dev/null) || OPEN_COUNT=""
  if [[ -z "$OPEN_COUNT" ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] pm-triage: WARNING — could not determine issue count (gh failed), proceeding." >> "${LOG_DIR}/cron.log"
  elif [[ "$OPEN_COUNT" == "0" ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] pm-triage: No open issues, skipping." >> "${LOG_DIR}/cron.log"
    exit 0
  fi
fi

"${SCRIPT_DIR}/scripts/dispatch.sh" \
  --role product-manager \
  --target claude-agent-protocol \
  --task "Morning triage: Categorize and prioritize open issues. Do NOT enhance or add details — that is a separate job.
1. List open issues: gh issue list --state open --json number,title,labels
2. SKIP issues that already have a priority label (priority:high/medium/low) — they were triaged previously.
3. For NEW unlabeled issues:
   a. Read the issue body to understand it.
   b. Categorize: add 'bug' or 'feature' label.
   c. Prioritize: add 'priority:high', 'priority:medium', or 'priority:low'.
   d. If the issue has clear acceptance criteria and enough detail to implement, add 'ready_for_dev'.
   e. If it needs more detail (vague description, missing acceptance criteria), add 'needs_refinement'.
4. Check for stale issues (no activity in 14+ days) — comment asking if still relevant.
5. Summarize: list issues triaged and labels applied."
