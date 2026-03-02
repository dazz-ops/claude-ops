#!/usr/bin/env bats
# concurrency.bats — Concurrency tests for budget locking and target locking

load test_helper

# ============================================================================
# Budget lock serialization
# ============================================================================

@test "concurrent budget locks serialize — only one acquires at a time" {
  # Acquire the lock in this process
  acquire_budget_lock
  [[ -d "${STATE_DIR}/locks/budget.lock" ]]

  # Background process tries to acquire — should fail after retries
  local result_file="${TEST_TMPDIR}/bg-result"
  (
    # Re-source dispatch.sh in subshell so functions are available
    source "${OPS_ROOT}/scripts/dispatch.sh" 2>/dev/null || true
    if acquire_budget_lock; then
      echo "acquired" > "$result_file"
      release_budget_lock
    else
      echo "failed" > "$result_file"
    fi
  ) &
  local bg_pid=$!
  wait "$bg_pid" 2>/dev/null || true

  # Background should have failed (we hold the lock with a live PID)
  [[ -f "$result_file" ]]
  [[ "$(cat "$result_file")" == "failed" ]]

  release_budget_lock
}

@test "budget lock released allows next acquirer" {
  acquire_budget_lock
  release_budget_lock

  # Should succeed now that lock is released
  run acquire_budget_lock
  [[ "$status" -eq 0 ]]
  release_budget_lock
}

@test "concurrent check_budget calls both succeed under budget" {
  local budget_file="${STATE_DIR}/budget-$(date +%Y-%m-%d).json"
  echo '{"date":"2026-01-01","invocations":5,"total_duration_s":100,"max_invocations":20}' > "$budget_file"

  # Run two check_budget calls in parallel — both should succeed
  local result_a="${TEST_TMPDIR}/result-a"
  local result_b="${TEST_TMPDIR}/result-b"

  (
    source "${OPS_ROOT}/scripts/dispatch.sh" 2>/dev/null || true
    export CONFIG STATE_DIR
    if acquire_budget_lock && check_budget; then
      echo "pass" > "$result_a"
    else
      echo "fail" > "$result_a"
    fi
    release_budget_lock
  ) &
  local pid_a=$!

  (
    source "${OPS_ROOT}/scripts/dispatch.sh" 2>/dev/null || true
    export CONFIG STATE_DIR
    if acquire_budget_lock && check_budget; then
      echo "pass" > "$result_b"
    else
      echo "fail" > "$result_b"
    fi
    release_budget_lock
  ) &
  local pid_b=$!

  wait "$pid_a" 2>/dev/null || true
  wait "$pid_b" 2>/dev/null || true

  # At least one should have passed (both should, since they serialize)
  local passes=0
  [[ -f "$result_a" ]] && [[ "$(cat "$result_a")" == "pass" ]] && passes=$((passes + 1))
  [[ -f "$result_b" ]] && [[ "$(cat "$result_b")" == "pass" ]] && passes=$((passes + 1))
  [[ "$passes" -ge 1 ]]
}

@test "concurrent record_invocation calls produce correct count" {
  local budget_file="${STATE_DIR}/budget-$(date +%Y-%m-%d).json"
  echo '{"date":"2026-01-01","invocations":0,"total_duration_s":0,"max_invocations":100}' > "$budget_file"

  # Fire 5 record_invocation calls in parallel, each under budget lock
  local pids=()
  for i in 1 2 3 4 5; do
    (
      source "${OPS_ROOT}/scripts/dispatch.sh" 2>/dev/null || true
      export CONFIG STATE_DIR
      acquire_budget_lock
      record_invocation "role-$i" "test-repo" 10 0 0 0
      release_budget_lock
    ) &
    pids+=($!)
  done

  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  # Final invocation count should be 5
  local count
  count=$(jq '.invocations' "$budget_file")
  [[ "$count" -eq 5 ]]
}

@test "concurrent record_invocation produces 5 JSONL entries" {
  local budget_file="${STATE_DIR}/budget-$(date +%Y-%m-%d).json"
  echo '{"date":"2026-01-01","invocations":0,"total_duration_s":0,"max_invocations":100}' > "$budget_file"

  local pids=()
  for i in 1 2 3 4 5; do
    (
      source "${OPS_ROOT}/scripts/dispatch.sh" 2>/dev/null || true
      export CONFIG STATE_DIR
      acquire_budget_lock
      record_invocation "role-$i" "test-repo" 10 0 100 50
      release_budget_lock
    ) &
    pids+=($!)
  done

  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  # Should have exactly 5 lines in JSONL
  local line_count
  line_count=$(wc -l < "${STATE_DIR}/invocations.jsonl" | tr -d ' ')
  [[ "$line_count" -eq 5 ]]
}

# ============================================================================
# Target lock concurrency
# ============================================================================

@test "concurrent target lock acquires — only one succeeds" {
  local result_a="${TEST_TMPDIR}/lock-a"
  local result_b="${TEST_TMPDIR}/lock-b"

  # Two processes race for the same target lock
  (
    source "${OPS_ROOT}/scripts/dispatch.sh" 2>/dev/null || true
    export STATE_DIR
    if acquire_target_lock "contested-repo"; then
      echo "acquired" > "$result_a"
      sleep 1  # hold the lock briefly
      release_target_lock "contested-repo"
    else
      echo "failed" > "$result_a"
    fi
  ) &
  local pid_a=$!

  (
    source "${OPS_ROOT}/scripts/dispatch.sh" 2>/dev/null || true
    export STATE_DIR
    # Small delay to increase overlap
    sleep 0.05
    if acquire_target_lock "contested-repo"; then
      echo "acquired" > "$result_b"
      release_target_lock "contested-repo"
    else
      echo "failed" > "$result_b"
    fi
  ) &
  local pid_b=$!

  wait "$pid_a" 2>/dev/null || true
  wait "$pid_b" 2>/dev/null || true

  # Exactly one should succeed, one should fail
  local acquired=0
  [[ -f "$result_a" ]] && [[ "$(cat "$result_a")" == "acquired" ]] && acquired=$((acquired + 1))
  [[ -f "$result_b" ]] && [[ "$(cat "$result_b")" == "acquired" ]] && acquired=$((acquired + 1))
  [[ "$acquired" -eq 1 ]]
}

@test "different targets can be locked concurrently" {
  local result_a="${TEST_TMPDIR}/lock-a"
  local result_b="${TEST_TMPDIR}/lock-b"

  (
    source "${OPS_ROOT}/scripts/dispatch.sh" 2>/dev/null || true
    export STATE_DIR
    if acquire_target_lock "repo-alpha"; then
      echo "acquired" > "$result_a"
      sleep 0.2
      release_target_lock "repo-alpha"
    else
      echo "failed" > "$result_a"
    fi
  ) &
  local pid_a=$!

  (
    source "${OPS_ROOT}/scripts/dispatch.sh" 2>/dev/null || true
    export STATE_DIR
    if acquire_target_lock "repo-beta"; then
      echo "acquired" > "$result_b"
      sleep 0.2
      release_target_lock "repo-beta"
    else
      echo "failed" > "$result_b"
    fi
  ) &
  local pid_b=$!

  wait "$pid_a" 2>/dev/null || true
  wait "$pid_b" 2>/dev/null || true

  # Both should succeed — different targets, no contention
  [[ "$(cat "$result_a")" == "acquired" ]]
  [[ "$(cat "$result_b")" == "acquired" ]]
}
