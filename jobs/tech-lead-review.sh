#!/usr/bin/env bash
set -euo pipefail

# Tech Lead: Weekly architecture review
# Schedule: Friday at 15:00
# Cron: 0 15 * * 5

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"
TARGET_PATH=$(jq -r '.targets[] | select(.name == "claude-agent-protocol") | .path' "${SCRIPT_DIR}/config.json")

# Polling guard: skip if no commits in the last 7 days
if [[ -n "$TARGET_PATH" ]] && [[ -d "$TARGET_PATH" ]]; then
  COMMIT_COUNT=$(cd "$TARGET_PATH" && git log --oneline --since='7 days ago' 2>/dev/null | wc -l | tr -d ' ') || COMMIT_COUNT=""
  if [[ -z "$COMMIT_COUNT" ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] tech-lead-review: WARNING — could not determine commit count (git failed), proceeding." >> "${LOG_DIR}/cron.log"
  elif [[ "$COMMIT_COUNT" == "0" ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] tech-lead-review: No commits in last 7 days, skipping." >> "${LOG_DIR}/cron.log"
    exit 0
  fi
fi

"${SCRIPT_DIR}/scripts/dispatch.sh" \
  --role tech-lead \
  --target claude-agent-protocol \
  --timeout 1800 \
  --task "Weekly architecture review. Focus on patterns and structure, NOT line-level code quality (QA handles that).

STEP 1 — Review the week's changes:
  Run: git log --oneline --since='7 days ago'
  Read the diffs of significant commits to understand what changed.

STEP 2 — Check architectural concerns:
  a. New dependencies: Were any added? Are they justified? Check for lighter alternatives.
  b. Pattern consistency: Do new files follow existing conventions (naming, structure, imports)?
  c. Complexity growth: Any files over 500 lines that should be split? Any god-objects forming?
  d. Module boundaries: Are concerns properly separated? Any circular dependencies emerging?
  e. Test strategy: Is the test approach consistent? Any gaps in integration vs unit coverage?

STEP 3 — Review open plans:
  Check docs/plans/ for any plans awaiting review. Comment on architectural risks or missing considerations.

STEP 4 — Check for recurring problems:
  Review docs/solutions/ — if the same type of problem keeps appearing, that suggests an architectural issue.

STEP 5 — File issues for concerns:
  For each architectural concern, file a GitHub issue:
  - Label with 'architecture' and 'tech-debt'
  - Add priority label
  - If proposing an ADR, include the full ADR text in the issue body
  Comment on relevant PRs if they have architectural implications.

STEP 6 — Summarize: what's solid, what's concerning, and recommended actions."
