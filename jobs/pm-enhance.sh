#!/usr/bin/env bash
set -euo pipefail

# PM Issue Enhancement — flesh out needs_refinement issues
# Schedule: Daily at 10:00 AM (after triage)
# Cron: 0 10 * * *

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"
TARGET_PATH=$(jq -r '.targets[] | select(.name == "claude-agent-protocol") | .path' "${SCRIPT_DIR}/config.json")

# Polling guard: skip if no needs_refinement issues exist
if [[ -n "$TARGET_PATH" ]] && [[ -d "$TARGET_PATH" ]]; then
  REFINEMENT_COUNT=$(cd "$TARGET_PATH" && gh issue list --label needs_refinement --state open --json number --jq length 2>/dev/null) || REFINEMENT_COUNT=""
  if [[ -z "$REFINEMENT_COUNT" ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] pm-enhance: WARNING — could not determine issue count (gh failed), proceeding." >> "${LOG_DIR}/cron.log"
  elif [[ "$REFINEMENT_COUNT" == "0" ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] pm-enhance: No needs_refinement issues, skipping." >> "${LOG_DIR}/cron.log"
    exit 0
  fi
fi

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
