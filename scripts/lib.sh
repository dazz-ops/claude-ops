#!/usr/bin/env bash
# ============================================================================
# lib.sh — Shared helper library for job scripts
#
# Provides target enumeration, polling guards, and the run_for_targets loop.
# Sourced by all job scripts in jobs/.
#
# Usage (from a job script):
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/scripts/lib.sh"
#   export GUARD_JOB_NAME="pm-triage"
#
#   do_work() { local target="$1"; ...; }
#   run_for_targets do_work "${1:-}"
# ============================================================================

# OPS_ROOT resolution — same pattern as dispatch.sh
LIB_OPS_ROOT="${CLAUDE_OPS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIB_CONFIG="${LIB_OPS_ROOT}/config.json"
LIB_LOG_DIR="${LIB_OPS_ROOT}/logs"

# Ensure log directory exists for guard functions
mkdir -p "$LIB_LOG_DIR"

# ============================================================================
# Logging
# ============================================================================

_lib_timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_lib_log() {
  local job_name="${GUARD_JOB_NAME:-job}"
  local target="${1:-}"
  local message="$2"
  local label="${job_name}"
  if [[ -n "$target" ]]; then
    label="${job_name}[${target}]"
  fi
  echo "[$(_lib_timestamp)] ${label}: ${message}" >> "${LIB_LOG_DIR}/cron.log"
}

# ============================================================================
# Target Enumeration
# ============================================================================

# Outputs one target name per line for all enabled targets.
list_enabled_targets() {
  if [[ ! -f "$LIB_CONFIG" ]]; then
    echo "ERROR: config.json not found at ${LIB_CONFIG}" >&2
    return 1
  fi

  jq -r '.targets[] | select(.enabled == true) | .name' "$LIB_CONFIG"
}

# Outputs absolute path for named target, returns 1 if not found or disabled.
resolve_target_path() {
  local target_name="$1"

  if [[ ! -f "$LIB_CONFIG" ]]; then
    echo "ERROR: config.json not found at ${LIB_CONFIG}" >&2
    return 1
  fi

  local target_path
  target_path=$(jq -r --arg name "$target_name" \
    '.targets[] | select(.name == $name and .enabled == true) | .path' "$LIB_CONFIG")

  if [[ -z "$target_path" || "$target_path" == "null" ]]; then
    echo "ERROR: target '${target_name}' not found or disabled" >&2
    return 1
  fi

  if [[ ! -d "$target_path" ]]; then
    echo "ERROR: target path does not exist: ${target_path}" >&2
    return 1
  fi

  echo "$target_path"
}

# Calls callback_fn once per enabled target (or once for a specific target).
# One target's failure does not skip the rest.
#
# Usage:
#   run_for_targets my_callback            # loops all enabled targets
#   run_for_targets my_callback my-project  # runs for one target only
run_for_targets() {
  local callback_fn="$1"
  local specific_target="${2:-}"

  if [[ -n "$specific_target" ]]; then
    # Single target mode (Actions / manual invocation)
    "$callback_fn" "$specific_target" || true
    return
  fi

  # Multi-target mode (cron)
  local targets
  targets=$(list_enabled_targets) || return 1

  if [[ -z "$targets" ]]; then
    _lib_log "" "No enabled targets found, skipping."
    return 0
  fi

  local target
  while IFS= read -r target; do
    "$callback_fn" "$target" || true
  done <<< "$targets"
}

# ============================================================================
# Polling Guards
#
# Each guard returns 0 (has work) or 1 (no work).
# On gh/git failure, returns 0 (cautious: proceed rather than skip).
# Logs decisions to cron.log with target name.
# ============================================================================

# Returns 0 if the target repo has open issues, 1 if none.
guard_open_issues() {
  local target_name="$1"
  local target_path
  target_path=$(resolve_target_path "$target_name") || return 0

  local count
  count=$(cd "$target_path" && gh issue list --state open --json number --jq length 2>/dev/null) || count=""

  if [[ -z "$count" ]]; then
    _lib_log "$target_name" "WARNING — could not determine issue count (gh failed), proceeding."
    return 0
  elif [[ "$count" == "0" ]]; then
    _lib_log "$target_name" "No open issues, skipping."
    return 1
  fi

  return 0
}

# Returns 0 if the target repo has open issues with the given label, 1 if none.
guard_labeled_issues() {
  local target_name="$1"
  local label="$2"
  local target_path
  target_path=$(resolve_target_path "$target_name") || return 0

  local count
  count=$(cd "$target_path" && gh issue list --label "$label" --state open --json number --jq length 2>/dev/null) || count=""

  if [[ -z "$count" ]]; then
    _lib_log "$target_name" "WARNING — could not determine ${label} issue count (gh failed), proceeding."
    return 0
  elif [[ "$count" == "0" ]]; then
    _lib_log "$target_name" "No ${label} issues, skipping."
    return 1
  fi

  return 0
}

# Returns 0 if the target repo has open PRs, 1 if none.
guard_open_prs() {
  local target_name="$1"
  local target_path
  target_path=$(resolve_target_path "$target_name") || return 0

  local count
  count=$(cd "$target_path" && gh pr list --state open --json number --jq length 2>/dev/null) || count=""

  if [[ -z "$count" ]]; then
    _lib_log "$target_name" "WARNING — could not determine PR count (gh failed), proceeding."
    return 0
  elif [[ "$count" == "0" ]]; then
    _lib_log "$target_name" "No open PRs, skipping."
    return 1
  fi

  return 0
}

# Returns 0 if the target repo has commits in the last N days, 1 if none.
guard_recent_commits() {
  local target_name="$1"
  local days="${2:-7}"
  local target_path
  target_path=$(resolve_target_path "$target_name") || return 0

  local count
  count=$(cd "$target_path" && git log --oneline --since="${days} days ago" 2>/dev/null | wc -l | tr -d ' ') || count=""

  if [[ -z "$count" ]]; then
    _lib_log "$target_name" "WARNING — could not determine commit count (git failed), proceeding."
    return 0
  elif [[ "$count" == "0" ]]; then
    _lib_log "$target_name" "No commits in last ${days} days, skipping."
    return 1
  fi

  return 0
}
