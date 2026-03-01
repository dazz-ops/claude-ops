#!/usr/bin/env bash
set -euo pipefail

# PM Weekly Exploration — discover improvement opportunities
# Schedule: Monday at 8:00 AM (before daily triage)
# Cron: 0 8 * * 1 /path/to/claude-ops/jobs/pm-explore.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"${SCRIPT_DIR}/scripts/dispatch.sh" \
  --role product-manager \
  --target claude-agent-protocol \
  --timeout 900 \
  --task "Weekly exploration: Discover improvement opportunities in the codebase.
1. Run /explore to understand current state of the project.
2. Review recent commits (last 7 days) for patterns, gaps, and quality trends.
3. Check docs/plans/ for any stalled or incomplete plans.
4. Check docs/solutions/ for recurring problem patterns that suggest deeper issues.
5. If you identify 2-3 high-value improvements, file them as GitHub issues:
   - Use 'feature' or 'bug' label as appropriate.
   - Add 'needs_refinement' label (the PM enhance job will flesh them out).
   - Add a priority label.
6. Focus on: developer experience, missing tests, documentation gaps, or workflow friction.
7. Do NOT file issues that duplicate existing open issues — check first."
