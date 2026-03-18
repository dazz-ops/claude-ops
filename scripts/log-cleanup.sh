#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# log-cleanup.sh — Remove old logs and budget files
#
# Schedule: Weekly (Sunday 03:00)
# Cron: 0 3 * * 0
# ============================================================================

OPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${OPS_ROOT}/config.json"
STATE_DIR="${OPS_ROOT}/state"
LOG_DIR="${OPS_ROOT}/logs"

if [[ -f "$CONFIG" ]]; then
  retention_days=$(jq -r '.defaults.log_retention_days // 7' "$CONFIG")
else
  echo "[cleanup] config.json not found — using default retention (7 days)"
  retention_days=7
fi
jsonl_max_bytes="${JSONL_MAX_BYTES:-1048576}"  # 1MB default threshold for rotation
jsonl_max_age_days="${JSONL_MAX_AGE_DAYS:-7}"  # Rotate if older than 7 days
jsonl_retention_days="${JSONL_RETENTION_DAYS:-30}"  # Keep rotated files 30 days

echo "[cleanup] Removing logs older than ${retention_days} days..."

# Clean old log files
find "$LOG_DIR" -name "*.log" -mtime "+${retention_days}" -delete 2>/dev/null || true
find "$LOG_DIR" -name "*.stderr" -mtime "+${retention_days}" -delete 2>/dev/null || true

# Clean old budget files (keep last 30 days regardless)
find "$STATE_DIR" -name "budget-*.json" -mtime +30 -delete 2>/dev/null || true

# ============================================================================
# JSONL Rotation — rotate invocations.jsonl by size or age
# ============================================================================

INVOCATIONS_FILE="${STATE_DIR}/invocations.jsonl"

rotate_jsonl() {
  if [[ ! -f "$INVOCATIONS_FILE" ]]; then
    echo "[cleanup] No invocations.jsonl — skipping rotation"
    return
  fi

  local file_size=0
  local should_rotate=false

  # Check file size
  if [[ -f "$INVOCATIONS_FILE" ]]; then
    file_size=$(wc -c < "$INVOCATIONS_FILE" | tr -d ' ')
  fi

  if (( file_size > jsonl_max_bytes )); then
    echo "[cleanup] invocations.jsonl is ${file_size} bytes (threshold: ${jsonl_max_bytes}) — rotating"
    should_rotate=true
  fi

  # Check file age (modified time)
  if [[ "$should_rotate" != "true" ]]; then
    local stale_files
    stale_files=$(find "$STATE_DIR" -name "invocations.jsonl" -mtime "+${jsonl_max_age_days}" 2>/dev/null)
    if [[ -n "$stale_files" ]]; then
      echo "[cleanup] invocations.jsonl is older than ${jsonl_max_age_days} days — rotating"
      should_rotate=true
    fi
  fi

  if [[ "$should_rotate" != "true" ]]; then
    echo "[cleanup] invocations.jsonl does not need rotation (${file_size} bytes, recent)"
    return
  fi

  # Rotate: mv to dated filename, then gzip
  local date_stamp
  date_stamp=$(date +%Y-%m-%d)
  local rotated_name="invocations-${date_stamp}.jsonl"

  # Handle collision if rotated today already
  if [[ -f "${STATE_DIR}/${rotated_name}" ]] || [[ -f "${STATE_DIR}/${rotated_name}.gz" ]]; then
    rotated_name="invocations-${date_stamp}-$(date +%H%M%S).jsonl"
  fi

  # Note: mv is atomic but a concurrent record_invocation append could re-create
  # invocations.jsonl between mv and the next dispatch. This is an acceptable
  # minor data loss window for a weekly audit log rotation.
  mv "$INVOCATIONS_FILE" "${STATE_DIR}/${rotated_name}"
  touch "$INVOCATIONS_FILE"  # Recreate immediately to minimize window
  gzip "${STATE_DIR}/${rotated_name}" 2>/dev/null || true

  echo "[cleanup] Rotated to ${rotated_name}.gz"
}

rotate_jsonl

# Clean old rotated JSONL files
find "$STATE_DIR" -name "invocations-*.jsonl.gz" -mtime "+${jsonl_retention_days}" -delete 2>/dev/null || true
find "$STATE_DIR" -name "invocations-*.jsonl" -mtime "+${jsonl_retention_days}" -delete 2>/dev/null || true

echo "[cleanup] Done."
