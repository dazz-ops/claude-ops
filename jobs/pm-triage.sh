#!/usr/bin/env bash
set -euo pipefail

# PM Morning Triage — categorize and prioritize only
# Schedule: Daily at 09:00
# Cron: 0 9 * * *
#
# Usage:
#   pm-triage.sh              # loops all enabled targets (cron mode)
#   pm-triage.sh my-project   # runs for one target only (Actions/manual)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/scripts/lib.sh"
export GUARD_JOB_NAME="pm-triage"

triage_target() {
  local target="$1"
  guard_open_issues "$target" || return 0

  "${SCRIPT_DIR}/scripts/dispatch.sh" \
    --role product-manager \
    --target "$target" \
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
}

run_for_targets triage_target "${1:-}"
