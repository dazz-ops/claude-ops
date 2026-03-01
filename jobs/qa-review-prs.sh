#!/usr/bin/env bash
set -euo pipefail

# QA Review Open PRs
# Schedule: Daily at 2:00 PM (after Developer has had time to work)
# Cron: 0 14 * * * /path/to/claude-ops/jobs/qa-review-prs.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"${SCRIPT_DIR}/scripts/dispatch.sh" \
  --role qa-engineer \
  --target claude-agent-protocol \
  --timeout 1800 \
  --task "Review all open PRs. Follow these steps exactly.

STEP 1 — List open PRs:
  Run: gh pr list --state open --json number,title --limit 10
  If no open PRs, output 'No open PRs to review.' and stop.

STEP 2 — For each open PR, check if it needs review:
  Run: gh pr view <number> --comments
  SKIP this PR if it already has a comment containing '<!-- claude-ops:qa-review -->'
  UNLESS there is a more recent commit or a '<!-- claude-ops:dev-fix -->' comment after
  the last QA review (meaning fixes were applied and it needs re-review).

STEP 3 — Review each PR that needs it:
  a. Read the PR diff: gh pr diff <number>
  b. Review focusing on: edge cases, error handling, security, test coverage
  c. Run shellcheck on any .sh files in the diff
  d. Run any available tests to verify they pass
  e. Classify the PR:
     - APPROVE: No issues found
     - NEEDS_WORK: Has findings that should be fixed
     - BLOCK: Has critical issues that must be fixed
  f. Post findings as a PR comment. ALWAYS start the comment with the hidden marker:
     <!-- claude-ops:qa-review -->
     Then include your findings with severity levels.

STEP 4 — If you find a bug not covered by the PR, file it as a separate issue with 'bug' label.

STEP 5 — Summarize all PRs reviewed and their status."
