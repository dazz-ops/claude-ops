#!/usr/bin/env bats
# budget.bats — Tests for check_budget and record_invocation

load test_helper

# ============================================================================
# check_budget
# ============================================================================

@test "check_budget creates budget file on first run" {
  run check_budget
  [[ "$status" -eq 0 ]]
  local budget_file="${STATE_DIR}/budget-$(date +%Y-%m-%d).json"
  [[ -f "$budget_file" ]]
}

@test "check_budget passes when under limit" {
  local budget_file="${STATE_DIR}/budget-$(date +%Y-%m-%d).json"
  echo '{"date":"2026-01-01","invocations":5,"total_duration_s":100,"max_invocations":20}' > "$budget_file"
  run check_budget
  [[ "$status" -eq 0 ]]
}

@test "check_budget fails when at limit" {
  local budget_file="${STATE_DIR}/budget-$(date +%Y-%m-%d).json"
  echo '{"date":"2026-01-01","invocations":20,"total_duration_s":100,"max_invocations":20}' > "$budget_file"
  run check_budget
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"limit reached"* ]]
}

@test "check_budget fails when over limit" {
  local budget_file="${STATE_DIR}/budget-$(date +%Y-%m-%d).json"
  echo '{"date":"2026-01-01","invocations":25,"total_duration_s":100,"max_invocations":20}' > "$budget_file"
  run check_budget
  [[ "$status" -ne 0 ]]
}

@test "check_budget reports current count" {
  local budget_file="${STATE_DIR}/budget-$(date +%Y-%m-%d).json"
  echo '{"date":"2026-01-01","invocations":7,"total_duration_s":100,"max_invocations":20}' > "$budget_file"
  run check_budget
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"7/20"* ]]
}

@test "check_budget uses max_daily_invocations from config" {
  # Set a low limit in config
  cat > "$CONFIG" <<'EOF'
{
  "targets": [{"name": "test-repo", "path": "/tmp/test-repo", "branch": "main", "enabled": true}],
  "defaults": {"worker_timeout": 300, "max_daily_invocations": 3, "log_retention_days": 7},
  "notifications": {"enabled": false, "method": "osascript"}
}
EOF
  local budget_file="${STATE_DIR}/budget-$(date +%Y-%m-%d).json"
  echo '{"date":"2026-01-01","invocations":3,"total_duration_s":100,"max_invocations":3}' > "$budget_file"
  run check_budget
  [[ "$status" -ne 0 ]]
}

# ============================================================================
# record_invocation
# ============================================================================

@test "record_invocation increments invocation count" {
  local budget_file="${STATE_DIR}/budget-$(date +%Y-%m-%d).json"
  echo '{"date":"2026-01-01","invocations":5,"total_duration_s":100,"max_invocations":20}' > "$budget_file"

  record_invocation "developer" "test-repo" 60 0 1000 500

  local count
  count=$(jq '.invocations' "$budget_file")
  [[ "$count" -eq 6 ]]
}

@test "record_invocation accumulates duration" {
  local budget_file="${STATE_DIR}/budget-$(date +%Y-%m-%d).json"
  echo '{"date":"2026-01-01","invocations":0,"total_duration_s":100,"max_invocations":20}' > "$budget_file"

  record_invocation "developer" "test-repo" 45 0 0 0

  local dur
  dur=$(jq '.total_duration_s' "$budget_file")
  [[ "$dur" -eq 145 ]]
}

@test "record_invocation appends to invocations.jsonl" {
  local budget_file="${STATE_DIR}/budget-$(date +%Y-%m-%d).json"
  echo '{"date":"2026-01-01","invocations":0,"total_duration_s":0,"max_invocations":20}' > "$budget_file"

  record_invocation "product-manager" "test-repo" 30 0 500 200

  local jsonl_file="${STATE_DIR}/invocations.jsonl"
  [[ -f "$jsonl_file" ]]
  local role
  role=$(tail -1 "$jsonl_file" | jq -r '.role')
  [[ "$role" == "product-manager" ]]
}

@test "record_invocation writes correct token values" {
  local budget_file="${STATE_DIR}/budget-$(date +%Y-%m-%d).json"
  echo '{"date":"2026-01-01","invocations":0,"total_duration_s":0,"max_invocations":20}' > "$budget_file"

  record_invocation "developer" "test-repo" 120 0 5000 3000

  local jsonl_file="${STATE_DIR}/invocations.jsonl"
  local input_tokens output_tokens
  input_tokens=$(tail -1 "$jsonl_file" | jq '.input_tokens')
  output_tokens=$(tail -1 "$jsonl_file" | jq '.output_tokens')
  [[ "$input_tokens" -eq 5000 ]]
  [[ "$output_tokens" -eq 3000 ]]
}

@test "record_invocation writes correct exit code" {
  local budget_file="${STATE_DIR}/budget-$(date +%Y-%m-%d).json"
  echo '{"date":"2026-01-01","invocations":0,"total_duration_s":0,"max_invocations":20}' > "$budget_file"

  record_invocation "developer" "test-repo" 10 1 0 0

  local jsonl_file="${STATE_DIR}/invocations.jsonl"
  local exit_code
  exit_code=$(tail -1 "$jsonl_file" | jq '.exit_code')
  [[ "$exit_code" -eq 1 ]]
}

@test "record_invocation handles missing budget file gracefully" {
  # No budget file exists — should still write to jsonl
  record_invocation "developer" "test-repo" 10 0 0 0

  local jsonl_file="${STATE_DIR}/invocations.jsonl"
  [[ -f "$jsonl_file" ]]
}

@test "record_invocation defaults token args to 0" {
  local budget_file="${STATE_DIR}/budget-$(date +%Y-%m-%d).json"
  echo '{"date":"2026-01-01","invocations":0,"total_duration_s":0,"max_invocations":20}' > "$budget_file"

  # Call with only 4 args (no token values)
  record_invocation "developer" "test-repo" 10 0

  local jsonl_file="${STATE_DIR}/invocations.jsonl"
  local input_tokens
  input_tokens=$(tail -1 "$jsonl_file" | jq '.input_tokens')
  [[ "$input_tokens" -eq 0 ]]
}
