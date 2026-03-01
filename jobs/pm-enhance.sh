#!/usr/bin/env bash
set -euo pipefail

# PM Issue Enhancement — flesh out needs_refinement issues
# Schedule: Daily at 10:00 AM (after triage)
# Cron: 0 10 * * * /Users/austin/Git_Repos/claude-ops/jobs/pm-enhance.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"${SCRIPT_DIR}/scripts/dispatch.sh" \
  --role product-manager \
  --target claude-agent-protocol \
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
