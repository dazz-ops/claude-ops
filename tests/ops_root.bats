#!/usr/bin/env bats
# ops_root.bats — Tests for CLAUDE_OPS_HOME / OPS_ROOT validation

load test_helper

# ============================================================================
# validate_ops_root
# ============================================================================

@test "validate_ops_root passes for valid OPS_ROOT" {
  # OPS_ROOT is already set to BATS_TEST_DIRNAME/.. which is the repo root
  # It has config.json — use the real repo root
  local saved_root="$OPS_ROOT"
  export OPS_ROOT="${BATS_TEST_DIRNAME}/.."
  run validate_ops_root
  export OPS_ROOT="$saved_root"
  [[ "$status" -eq 0 ]]
}

@test "validate_ops_root rejects relative path" {
  export OPS_ROOT="relative/path"
  run validate_ops_root
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"absolute path"* ]]
}

@test "validate_ops_root rejects path with spaces" {
  export OPS_ROOT="/tmp/my ops dir"
  run validate_ops_root
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"metacharacters"* ]]
}

@test "validate_ops_root rejects path with semicolons" {
  export OPS_ROOT="/tmp/ops;rm -rf /"
  run validate_ops_root
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"metacharacters"* ]]
}

@test "validate_ops_root rejects path with backticks" {
  export OPS_ROOT="/tmp/ops\`whoami\`"
  run validate_ops_root
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"metacharacters"* ]]
}

@test "validate_ops_root rejects path with dollar signs" {
  export OPS_ROOT='/tmp/$HOME/ops'
  run validate_ops_root
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"metacharacters"* ]]
}

@test "validate_ops_root rejects nonexistent directory" {
  export OPS_ROOT="/tmp/definitely-does-not-exist-12345"
  run validate_ops_root
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"does not exist"* ]]
}

@test "validate_ops_root rejects directory without config.json" {
  local tmpdir="${TEST_TMPDIR}/empty-ops"
  mkdir -p "$tmpdir"
  export OPS_ROOT="$tmpdir"
  run validate_ops_root
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"config.json"* ]]
}

@test "validate_ops_root passes with config.json present" {
  local tmpdir="${TEST_TMPDIR}/valid-ops"
  mkdir -p "$tmpdir"
  echo '{}' > "${tmpdir}/config.json"
  export OPS_ROOT="$tmpdir"
  run validate_ops_root
  [[ "$status" -eq 0 ]]
}

# ============================================================================
# CLAUDE_OPS_HOME integration
# ============================================================================

@test "CLAUDE_OPS_HOME takes priority over auto-detected OPS_ROOT" {
  local tmpdir="${TEST_TMPDIR}/custom-ops"
  mkdir -p "$tmpdir"
  echo '{}' > "${tmpdir}/config.json"

  # Source dispatch.sh with CLAUDE_OPS_HOME set
  export CLAUDE_OPS_HOME="$tmpdir"
  unset OPS_ROOT
  source "${BATS_TEST_DIRNAME}/../scripts/dispatch.sh" 2>/dev/null || true
  [[ "$OPS_ROOT" == "$tmpdir" ]]
}
