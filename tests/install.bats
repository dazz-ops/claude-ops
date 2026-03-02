#!/usr/bin/env bats
# install.bats — Tests for install.sh cron management functions

# ============================================================================
# Setup / Teardown
# ============================================================================

setup() {
  export TEST_TMPDIR="${BATS_TMPDIR}/${BATS_TEST_NAME}"
  mkdir -p "$TEST_TMPDIR"

  # Set OPS_ROOT to test temp dir so install.sh functions use isolated paths
  export OPS_ROOT="$TEST_TMPDIR"
  mkdir -p "${OPS_ROOT}/state" "${OPS_ROOT}/logs" "${OPS_ROOT}/schedules" "${OPS_ROOT}/jobs"

  # Create a minimal config.json
  cat > "${OPS_ROOT}/config.json" <<'EOF'
{
  "targets": [],
  "defaults": {
    "worker_timeout": 300,
    "max_daily_invocations": 20,
    "log_retention_days": 7,
    "cron_enabled": true
  }
}
EOF

  # Source install.sh (main() is guarded, won't execute)
  # Save OPS_ROOT before sourcing — install.sh line 16 resets it
  local saved_ops_root="$OPS_ROOT"
  source "${BATS_TEST_DIRNAME}/../scripts/install.sh"
  export OPS_ROOT="$saved_ops_root"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ============================================================================
# read_cron_enabled
# ============================================================================

@test "read_cron_enabled returns true for explicit true" {
  cat > "${OPS_ROOT}/config.json" <<'EOF'
{"defaults": {"cron_enabled": true}}
EOF
  run read_cron_enabled
  [[ "$status" -eq 0 ]]
  [[ "$output" == "true" ]]
}

@test "read_cron_enabled returns false for explicit false" {
  cat > "${OPS_ROOT}/config.json" <<'EOF'
{"defaults": {"cron_enabled": false}}
EOF
  run read_cron_enabled
  [[ "$status" -eq 0 ]]
  [[ "$output" == "false" ]]
}

@test "read_cron_enabled defaults to true when key missing" {
  cat > "${OPS_ROOT}/config.json" <<'EOF'
{"defaults": {"worker_timeout": 300}}
EOF
  run read_cron_enabled
  [[ "$status" -eq 0 ]]
  [[ "$output" == "true" ]]
}

@test "read_cron_enabled defaults to true when defaults block missing" {
  cat > "${OPS_ROOT}/config.json" <<'EOF'
{"targets": []}
EOF
  run read_cron_enabled
  [[ "$status" -eq 0 ]]
  [[ "$output" == "true" ]]
}

@test "read_cron_enabled defaults to true when config.json missing" {
  rm -f "${OPS_ROOT}/config.json"
  run read_cron_enabled
  [[ "$status" -eq 0 ]]
  [[ "$output" == "true" ]]
}

@test "read_cron_enabled does not use jq // operator (false is not overridden)" {
  # This is the critical test — jq // treats false as falsy
  # Our implementation uses explicit null-check to avoid this
  cat > "${OPS_ROOT}/config.json" <<'EOF'
{"defaults": {"cron_enabled": false}}
EOF
  local result
  result=$(read_cron_enabled)
  [[ "$result" == "false" ]]

  # Contrast with the broken approach:
  local broken
  broken=$(jq -r '.defaults.cron_enabled // true' "${OPS_ROOT}/config.json")
  # The broken approach returns "true" for false — confirm our fix avoids this
  [[ "$broken" == "true" ]]  # proves // is broken
  [[ "$result" == "false" ]]  # proves our fix works
}

# ============================================================================
# strip_sentinel_block
# ============================================================================

@test "strip_sentinel_block removes sentinel block" {
  local input="# user entry
0 5 * * * /usr/bin/foo
# BEGIN claude-ops managed block — do not edit manually
0 9 * * * /jobs/pm-triage.sh
0 10 * * * /jobs/pm-enhance.sh
# END claude-ops managed block
# another user entry
0 6 * * * /usr/bin/bar"

  local result
  result=$(echo "$input" | strip_sentinel_block)
  [[ "$result" == *"/usr/bin/foo"* ]]
  [[ "$result" == *"/usr/bin/bar"* ]]
  [[ "$result" != *"pm-triage"* ]]
  [[ "$result" != *"pm-enhance"* ]]
  [[ "$result" != *"BEGIN claude-ops"* ]]
  [[ "$result" != *"END claude-ops"* ]]
}

@test "strip_sentinel_block preserves content when no sentinel block exists" {
  local input="# user cron entries
0 5 * * * /usr/bin/foo
0 6 * * * /usr/bin/bar"

  local result
  result=$(echo "$input" | strip_sentinel_block)
  [[ "$result" == "$input" ]]
}

@test "strip_sentinel_block handles empty input" {
  local result
  result=$(echo "" | strip_sentinel_block)
  [[ -z "$(echo "$result" | tr -d '[:space:]')" ]]
}

@test "strip_sentinel_block handles block at start of input" {
  local input="# BEGIN claude-ops managed block — do not edit manually
0 9 * * * /jobs/pm-triage.sh
# END claude-ops managed block
0 6 * * * /usr/bin/bar"

  local result
  result=$(echo "$input" | strip_sentinel_block)
  [[ "$result" != *"pm-triage"* ]]
  [[ "$result" == *"/usr/bin/bar"* ]]
}

@test "strip_sentinel_block handles block at end of input" {
  local input="0 5 * * * /usr/bin/foo
# BEGIN claude-ops managed block — do not edit manually
0 9 * * * /jobs/pm-triage.sh
# END claude-ops managed block"

  local result
  result=$(echo "$input" | strip_sentinel_block)
  [[ "$result" == *"/usr/bin/foo"* ]]
  [[ "$result" != *"pm-triage"* ]]
}

@test "strip_sentinel_block with BEGIN but no END deletes to EOF (dangerous)" {
  local input="0 5 * * * /usr/bin/foo
# BEGIN claude-ops managed block — do not edit manually
0 9 * * * /jobs/pm-triage.sh
0 10 * * * /jobs/pm-enhance.sh"

  local result
  result=$(echo "$input" | strip_sentinel_block)
  # This proves the danger — everything from BEGIN onward is deleted
  [[ "$result" == *"/usr/bin/foo"* ]]
  [[ "$result" != *"pm-triage"* ]]
  [[ "$result" != *"pm-enhance"* ]]
  # The input had content after BEGIN but no END — sed deleted to EOF
}

# ============================================================================
# generate_crontab
# ============================================================================

@test "generate_crontab creates crontab file" {
  generate_crontab
  [[ -f "${OPS_ROOT}/schedules/crontab" ]]
}

@test "generate_crontab uses dynamic OPS_ROOT paths for job entries" {
  generate_crontab
  local content
  content=$(cat "${OPS_ROOT}/schedules/crontab")
  # All job paths should reference OPS_ROOT (the test temp dir), not the real repo
  [[ "$content" == *"${OPS_ROOT}/jobs/"* ]]
  # Job entries should not contain hardcoded repo paths
  # (PATH= line may contain /Users/... for claude location — that's OK and expected)
  local job_lines
  job_lines=$(grep -E '^[0-9*]' "${OPS_ROOT}/schedules/crontab")
  [[ "$job_lines" == *"${OPS_ROOT}/"* ]]
}

@test "generate_crontab includes all expected job entries" {
  generate_crontab
  local content
  content=$(cat "${OPS_ROOT}/schedules/crontab")
  [[ "$content" == *"pm-triage.sh"* ]]
  [[ "$content" == *"pm-enhance.sh"* ]]
  [[ "$content" == *"dev-implement.sh"* ]]
  [[ "$content" == *"dev-review-prs.sh"* ]]
  [[ "$content" == *"pm-explore.sh"* ]]
  [[ "$content" == *"tech-lead-review.sh"* ]]
  [[ "$content" == *"log-cleanup.sh"* ]]
}

@test "generate_crontab produces at least 8 cron entries" {
  generate_crontab
  local count
  count=$(grep -cE '^[0-9]' "${OPS_ROOT}/schedules/crontab")
  [[ "$count" -ge 8 ]]
}

@test "generate_crontab includes SHELL and PATH" {
  generate_crontab
  local content
  content=$(cat "${OPS_ROOT}/schedules/crontab")
  [[ "$content" == *"SHELL=/bin/bash"* ]]
  [[ "$content" == *"PATH="* ]]
}

@test "generate_crontab includes 3 dev-implement entries" {
  generate_crontab
  local count
  count=$(grep -c "dev-implement.sh" "${OPS_ROOT}/schedules/crontab")
  [[ "$count" -eq 3 ]]
}

@test "generate_crontab includes 3 dev-review-prs entries" {
  generate_crontab
  local count
  count=$(grep -c "dev-review-prs.sh" "${OPS_ROOT}/schedules/crontab")
  [[ "$count" -eq 3 ]]
}

# ============================================================================
# SENTINEL_BEGIN / SENTINEL_END constants
# ============================================================================

@test "sentinel markers are defined" {
  [[ -n "$SENTINEL_BEGIN" ]]
  [[ -n "$SENTINEL_END" ]]
  [[ "$SENTINEL_BEGIN" == *"BEGIN claude-ops"* ]]
  [[ "$SENTINEL_END" == *"END claude-ops"* ]]
}

# ============================================================================
# config.template.json validation
# ============================================================================

@test "config.template.json has cron_enabled field" {
  local val
  val=$(jq '.defaults.cron_enabled' "${BATS_TEST_DIRNAME}/../config.template.json")
  [[ "$val" == "true" ]]
}

@test "config.template.json has no max_invocations_per_job field" {
  run jq '.defaults.max_invocations_per_job // "MISSING"' "${BATS_TEST_DIRNAME}/../config.template.json"
  [[ "$output" == '"MISSING"' ]]
}

# ============================================================================
# .gitignore validation
# ============================================================================

@test "schedules/crontab is in .gitignore" {
  grep -qF "schedules/crontab" "${BATS_TEST_DIRNAME}/../.gitignore"
}

# ============================================================================
# Job script header validation
# ============================================================================

@test "no job scripts contain hardcoded /Users paths" {
  run grep -rl "/Users/" "${BATS_TEST_DIRNAME}/../jobs/"
  [[ "$status" -ne 0 ]]  # grep returns 1 when no matches (good)
}

@test "no scripts contain hardcoded /Users paths" {
  run grep -rl "/Users/" "${BATS_TEST_DIRNAME}/../scripts/"
  [[ "$status" -ne 0 ]]  # grep returns 1 when no matches (good)
}

@test "log-cleanup.sh header says 03:00 not midnight" {
  local header
  header=$(head -10 "${BATS_TEST_DIRNAME}/../scripts/log-cleanup.sh")
  [[ "$header" == *"03:00"* ]]
  [[ "$header" != *"midnight"* ]]
}

# ============================================================================
# install.sh source guard
# ============================================================================

@test "install.sh can be sourced without executing main" {
  # If we got here, sourcing worked (setup already sources it)
  # Verify that main function exists but didn't run
  declare -f main > /dev/null
}

@test "install.sh functions are available after sourcing" {
  declare -f read_cron_enabled > /dev/null
  declare -f strip_sentinel_block > /dev/null
  declare -f generate_crontab > /dev/null
  declare -f backup_crontab > /dev/null
  declare -f install_crontab > /dev/null
  declare -f check_dependencies > /dev/null
}
