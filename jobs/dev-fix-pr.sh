#!/usr/bin/env bash
set -euo pipefail

# Developer: Fix PRs that have QA review findings
# Schedule: Daily at 4:00 PM (after QA review at 2:00 PM)
# Cron: 0 16 * * * /path/to/claude-ops/jobs/dev-fix-pr.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"${SCRIPT_DIR}/scripts/dispatch.sh" \
  --role developer \
  --target claude-agent-protocol \
  --timeout 1800 \
  --task "Fix PRs that have QA review findings. Follow these steps exactly.

STEP 0 — Reset to main:
  git checkout main && git pull origin main

STEP 1 — Find PRs with QA findings:
  Run: gh pr list --state open --json number,title --limit 10
  For each open PR, check its comments: gh pr view <number> --comments
  Look for comments containing the marker '<!-- claude-ops:qa-review -->' that also contain
  findings (CRITICAL, HIGH, MEDIUM, or NEEDS_WORK).
  Skip PRs where the most recent comment after the QA review is a fix confirmation
  (contains '<!-- claude-ops:dev-fix -->').

STEP 2 — Fix the highest priority PR:
  Pick the PR with the most severe findings (CRITICAL > HIGH > MEDIUM).
  If no PRs need fixing, output 'No PRs need fixing.' and stop.
  a. Check out the PR branch: gh pr checkout <number>
  b. Read the QA review comment to understand the findings
  c. For each finding: read the relevant code, apply the fix
  d. Run tests to verify fixes don't break anything
  e. Commit: fix: address QA review findings on PR #<number>
  f. Push the fixes: git push
  g. Comment on the PR confirming fixes: gh pr comment <number> --body '<!-- claude-ops:dev-fix -->
     Fixed the following QA findings:
     - [list what was fixed]
     Ready for re-review.'

Only fix ONE PR per run."
