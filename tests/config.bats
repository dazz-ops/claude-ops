#!/usr/bin/env bats
# config.bats — Tests for read_config and resolve_target

load test_helper

# ============================================================================
# read_config
# ============================================================================

@test "read_config reads string values" {
  local method
  method=$(read_config '.notifications.method')
  [[ "$method" == "osascript" ]]
}

@test "read_config reads numeric values" {
  local timeout
  timeout=$(read_config '.defaults.worker_timeout')
  [[ "$timeout" == "300" ]]
}

@test "read_config reads boolean values" {
  local enabled
  enabled=$(read_config '.notifications.enabled')
  [[ "$enabled" == "false" ]]
}

@test "read_config returns null for missing keys" {
  local result
  result=$(read_config '.nonexistent_key')
  [[ "$result" == "null" ]]
}

# ============================================================================
# resolve_target
# ============================================================================

@test "resolve_target returns path for enabled target" {
  local path
  path=$(resolve_target "test-repo")
  [[ "$path" == "/tmp/test-repo" ]]
}

@test "resolve_target exits on disabled target" {
  run resolve_target "disabled-repo"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"disabled"* ]]
}

@test "resolve_target exits on unknown target" {
  run resolve_target "no-such-repo"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"not found"* ]]
}

@test "resolve_target exits when target path doesn't exist" {
  # Add a target with a non-existent path
  cat > "$CONFIG" <<'EOF'
{
  "targets": [
    {"name": "missing-path-repo", "path": "/tmp/definitely-does-not-exist-12345", "branch": "main", "enabled": true}
  ],
  "defaults": {"worker_timeout": 300, "max_daily_invocations": 20, "log_retention_days": 7},
  "notifications": {"enabled": false, "method": "osascript"}
}
EOF
  run resolve_target "missing-path-repo"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"does not exist"* ]]
}
