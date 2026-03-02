#!/usr/bin/env bash
set -euo pipefail

# Code Reviewer: Fresh-eyes review on all open PRs
# Schedule: 3x daily at 13:00, 17:00, 21:00 (2h after each dev slot)
# Cron: 0 13,17,21 * * *
#
# This is a SECOND review pass — independent from the Developer's self-review.
# The implementing Developer already ran /fresh-eyes-review before creating
# the PR. This reviewer catches anything the first pass missed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"
TARGET_PATH=$(jq -r '.targets[] | select(.name == "claude-agent-protocol") | .path' "${SCRIPT_DIR}/config.json")

# Polling guard: skip if no open PRs exist
if [[ -n "$TARGET_PATH" ]] && [[ -d "$TARGET_PATH" ]]; then
  PR_COUNT=$(cd "$TARGET_PATH" && gh pr list --state open --json number --jq length 2>/dev/null) || PR_COUNT=""
  if [[ -z "$PR_COUNT" ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] dev-review-prs: WARNING — could not determine PR count (gh failed), proceeding." >> "${LOG_DIR}/cron.log"
  elif [[ "$PR_COUNT" == "0" ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] dev-review-prs: No open PRs, skipping." >> "${LOG_DIR}/cron.log"
    exit 0
  fi
fi

"${SCRIPT_DIR}/scripts/dispatch.sh" \
  --role code-reviewer \
  --target claude-agent-protocol \
  --timeout 1800 \
  --task "Review all open PRs that haven't been reviewed yet. Follow these steps exactly.

STEP 0 — Identify PRs to review:
  Run: gh pr list --state open --json number,title,headRefName,author,createdAt,labels --limit 20
  For each PR, check if you've already reviewed it:
    gh pr view <number> --json reviews --jq '.reviews[].body' | grep -q 'DISPATCH_SUMMARY' && skip
  Build a list of unreviewed PRs.
  If no unreviewed PRs exist, output 'No PRs need review' and stop.

STEP 1 — For each unreviewed PR (process ALL of them):
  a. Fetch and checkout the PR branch:
     git fetch origin pull/<number>/head:pr-<number>
     git checkout pr-<number>
  b. Stage the diff for review:
     git diff main...HEAD > .review/review-diff.txt
     git diff main...HEAD --name-only > .review/review-files.txt
  c. Run /fresh-eyes-review (this gives you a zero-context multi-agent review)
  d. Based on the verdict:
     - BLOCK or FIX_BEFORE_COMMIT:
       Post review requesting changes:
       gh pr review <number> --request-changes --body '<findings summary with file:line references>'
     - APPROVED_WITH_NOTES:
       Post review with comments:
       gh pr review <number> --comment --body '<findings summary>'
     - APPROVED:
       Approve the PR:
       gh pr review <number> --approve --body 'Fresh-eyes review passed. No issues found.'
  e. Return to main: git checkout main && git branch -D pr-<number>

STEP 2 — Summarize:
  List each PR reviewed, the verdict, and number of findings."
