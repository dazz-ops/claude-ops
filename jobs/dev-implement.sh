#!/usr/bin/env bash
set -euo pipefail

# Developer: Pick and implement next issue
# Schedule: Daily at 11:00 AM (after PM triage + enhance)
# Cron: 0 11 * * * /path/to/claude-ops/jobs/dev-implement.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"${SCRIPT_DIR}/scripts/dispatch.sh" \
  --role developer \
  --target claude-agent-protocol \
  --timeout 1800 \
  --task "Implement the next ready issue. Follow these steps exactly.

STEP 0 — Reset to main:
  git checkout main && git pull origin main

STEP 1 — Check for open PRs you should NOT duplicate:
  Run: gh pr list --state open --json number,title,body --limit 20
  Extract all issue numbers referenced in PR titles and bodies (look for #N, closes #N, fixes #N).
  These issues already have PRs — do NOT implement them again.

STEP 2 — Pick an issue:
  Run: gh issue list --label ready_for_dev --state open --json number,title,labels --limit 10
  Filter out any issues that already have open PRs (from Step 1).
  From the remaining, pick the highest priority (priority:high > priority:medium > priority:low, then oldest first).
  If no issues remain, output 'No ready issues without open PRs. Waiting for PM triage.' and stop.

STEP 3 — Implement:
  a. Create a feature branch: git checkout -b feat/issue-<number>-<short-slug>
  b. Read the full issue: gh issue view <number>
  c. Run /implement (start-issue) with the issue number
  d. Write tests for all code changes
  e. Run tests to verify they pass
  f. Commit with conventional message: feat: <description> (closes #<number>)
  g. Push the branch: git push -u origin <branch-name>
  h. Create a PR: gh pr create --title '<title>' --body 'Closes #<number>'

Only implement ONE issue per run."
