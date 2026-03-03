#!/usr/bin/env bash
set -euo pipefail

# PM Weekly Exploration & Ideation
# Schedule: Monday at 8:00 AM
# Cron: 0 8 * * 1
#
# Usage:
#   pm-explore.sh              # loops all enabled targets (cron mode)
#   pm-explore.sh my-project   # runs for one target only (Actions/manual)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/scripts/lib.sh"
export GUARD_JOB_NAME="pm-explore"

explore_target() {
  local target="$1"

  "${SCRIPT_DIR}/scripts/dispatch.sh" \
    --role product-manager \
    --target "$target" \
    --timeout 900 \
    --task "Weekly exploration and ideation. Two parts: internal review and forward-looking ideas.

PART 1 — Internal review:
  a. Run /explore to understand current project state.
  b. Review commits from the last 7 days — what shipped, what's in progress.
  c. Check docs/plans/ for stalled work. Check docs/solutions/ for recurring problems.
  d. File issues for any gaps found (missing tests, stale docs, broken workflows).

PART 2 — Ideation and research:
  a. Based on what this project does and where it's heading, brainstorm 2-3 ideas for:
     - Features that would make this more useful to end users
     - Developer experience improvements
     - Integrations or automations that don't exist yet
     - Problems users likely hit that aren't addressed
  b. For each idea, file a GitHub issue:
     - Use 'feature' label
     - Add 'needs_refinement' and a priority label
     - Include: the problem it solves, who benefits, rough scope (small/medium/large)
     - Frame in terms of user value, not implementation details
  c. Do NOT file ideas that duplicate existing open issues — check first.
  d. Do NOT propose architecture or implementation plans — that's the Tech Lead's job."
}

run_for_targets explore_target "${1:-}"
