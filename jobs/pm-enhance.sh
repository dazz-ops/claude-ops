#!/usr/bin/env bash
set -euo pipefail

# PM Issue Enhancement — flesh out needs_refinement issues
# Schedule: Daily at 10:00 AM (after triage)
# Cron: 0 10 * * *
#
# Usage:
#   pm-enhance.sh              # loops all enabled targets (cron mode)
#   pm-enhance.sh my-project   # runs for one target only (Actions/manual)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/scripts/lib.sh"
export GUARD_JOB_NAME="pm-enhance"

enhance_target() {
  local target="$1"
  guard_labeled_issues "$target" "needs_refinement" || return 0

  "${SCRIPT_DIR}/scripts/dispatch.sh" \
    --role product-manager \
    --target "$target" \
    --timeout 900 \
    --task "Enhance issues that need refinement. Process at most 3 issues per run.
1. List issues needing refinement: gh issue list --label needs_refinement --state open --json number,title --limit 3
2. If none found, output 'No issues need refinement' and stop.
3. For each needs_refinement issue:
   a. Read the issue body carefully.
   b. Run /explore to understand the affected code areas.
   c. Edit the issue to add:
      - Clear acceptance criteria (checkboxes)
      - Affected files and functions
      - Implementation hints if the approach is obvious
      - Edge cases to watch for
   d. Remove 'needs_refinement' label and add 'ready_for_dev' label.
4. Summarize which issues were enhanced and what was added."
}

run_for_targets enhance_target "${1:-}"
