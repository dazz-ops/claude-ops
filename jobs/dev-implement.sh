#!/usr/bin/env bash
set -euo pipefail

# Developer: Implement, self-review, fix, and PR
# Schedule: 3x daily at 11:00, 15:00, 19:00
# Cron: 0 11,15,19 * * *
#
# Each run picks ONE issue and creates a PR. Runs 3x/day for throughput.
# The schedule spaces runs so the lock is released between each.
#
# Usage:
#   dev-implement.sh              # loops all enabled targets (cron mode)
#   dev-implement.sh my-project   # runs for one target only (Actions/manual)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/scripts/lib.sh"
export GUARD_JOB_NAME="dev-implement"

implement_target() {
  local target="$1"
  guard_labeled_issues "$target" "ready_for_dev" || return 0

  "${SCRIPT_DIR}/scripts/dispatch.sh" \
    --role developer \
    --target "$target" \
    --timeout 1800 \
    --task "Implement the next ready issue, review your own work, and create a PR. Follow these steps exactly.

STEP 0 — Clean start:
  git checkout main && git pull origin main

STEP 1 — Check for open PRs to avoid duplicating work:
  Run: gh pr list --state open --json number,title,body --limit 20
  Note which issue numbers are referenced. Do NOT re-implement those.

STEP 2 — Pick an issue:
  Run: gh issue list --label ready_for_dev --state open --json number,title,labels --limit 10
  Filter out issues with open PRs (from Step 1).
  Pick highest priority (priority:high > medium > low, then oldest).
  If nothing remains, output 'No ready issues. Waiting for PM.' and stop.

STEP 3 — Implement:
  a. Create branch: git checkout -b feat/issue-<number>-<short-slug>
  b. Read the full issue: gh issue view <number>
  c. Implement the feature or fix
  d. Write tests for all code changes
  e. Run tests to verify they pass

STEP 4 — Self-review:
  a. Stage your changes: git add the files you changed
  b. Run /fresh-eyes-review
  c. Fix ALL findings (CRITICAL, HIGH, and MEDIUM)
  d. Re-run tests after fixes
  e. If the review returns BLOCK, fix and re-run review until it passes

STEP 5 — Create PR:
  a. Commit with conventional message: feat: <description> (closes #<number>)
  b. Push: git push -u origin <branch-name>
  c. Create PR: gh pr create --title '<title>' --body 'Closes #<number>'

Only implement ONE issue per run."
}

run_for_targets implement_target "${1:-}"
