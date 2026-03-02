#!/usr/bin/env bats
# locking.bats — Tests for target lock and budget lock

load test_helper

# ============================================================================
# acquire_target_lock / release_target_lock
# ============================================================================

@test "acquire_target_lock creates lock directory" {
  run acquire_target_lock "test-repo"
  [[ "$status" -eq 0 ]]
  [[ -d "${STATE_DIR}/locks/test-repo.lock" ]]
}

@test "acquire_target_lock writes PID file" {
  acquire_target_lock "test-repo"
  [[ -f "${STATE_DIR}/locks/test-repo.lock/pid" ]]
  local pid
  pid=$(<"${STATE_DIR}/locks/test-repo.lock/pid")
  [[ "$pid" == "$$" ]]
}

@test "acquire_target_lock fails on live contention" {
  # Create a lock held by our own PID (still alive)
  mkdir -p "${STATE_DIR}/locks/test-repo.lock"
  echo $$ > "${STATE_DIR}/locks/test-repo.lock/pid"

  run acquire_target_lock "test-repo"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"locked by another agent"* ]]
}

@test "acquire_target_lock recovers stale lock with dead PID" {
  # Create a lock with a definitely-dead PID
  mkdir -p "${STATE_DIR}/locks/test-repo.lock"
  echo 99999 > "${STATE_DIR}/locks/test-repo.lock/pid"

  # Verify the PID is actually dead (it should be on any normal system)
  if kill -0 99999 2>/dev/null; then
    skip "PID 99999 is unexpectedly alive"
  fi

  run acquire_target_lock "test-repo"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Stale lock"* ]]
}

@test "acquire_target_lock recovers lock with no PID file" {
  # Create lock directory without a PID file
  mkdir -p "${STATE_DIR}/locks/test-repo.lock"

  run acquire_target_lock "test-repo"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"no PID file"* ]]
}

@test "release_target_lock removes lock directory" {
  acquire_target_lock "test-repo"
  [[ -d "${STATE_DIR}/locks/test-repo.lock" ]]

  release_target_lock "test-repo"
  [[ ! -d "${STATE_DIR}/locks/test-repo.lock" ]]
}

@test "release_target_lock is idempotent" {
  # Releasing a non-existent lock should not error
  run release_target_lock "test-repo"
  [[ "$status" -eq 0 ]]
}

@test "target locks are independent per target" {
  acquire_target_lock "repo-a"
  acquire_target_lock "repo-b"

  [[ -d "${STATE_DIR}/locks/repo-a.lock" ]]
  [[ -d "${STATE_DIR}/locks/repo-b.lock" ]]

  release_target_lock "repo-a"
  [[ ! -d "${STATE_DIR}/locks/repo-a.lock" ]]
  [[ -d "${STATE_DIR}/locks/repo-b.lock" ]]

  release_target_lock "repo-b"
}

# ============================================================================
# acquire_budget_lock / release_budget_lock
# ============================================================================

@test "acquire_budget_lock creates lock directory" {
  run acquire_budget_lock
  [[ "$status" -eq 0 ]]
  [[ -d "${STATE_DIR}/locks/budget.lock" ]]
}

@test "acquire_budget_lock writes PID file" {
  acquire_budget_lock
  [[ -f "${STATE_DIR}/locks/budget.lock/pid" ]]
  local pid
  pid=$(<"${STATE_DIR}/locks/budget.lock/pid")
  [[ "$pid" == "$$" ]]
}

@test "acquire_budget_lock recovers stale lock" {
  # Create a stale budget lock
  mkdir -p "${STATE_DIR}/locks/budget.lock"
  echo 99999 > "${STATE_DIR}/locks/budget.lock/pid"

  if kill -0 99999 2>/dev/null; then
    skip "PID 99999 is unexpectedly alive"
  fi

  run acquire_budget_lock
  [[ "$status" -eq 0 ]]
}

@test "release_budget_lock removes lock directory" {
  acquire_budget_lock
  [[ -d "${STATE_DIR}/locks/budget.lock" ]]

  release_budget_lock
  [[ ! -d "${STATE_DIR}/locks/budget.lock" ]]
}

@test "release_budget_lock is idempotent" {
  run release_budget_lock
  [[ "$status" -eq 0 ]]
}

@test "stale lock cleanup removes .stale directories" {
  # Create a stale budget lock
  mkdir -p "${STATE_DIR}/locks/budget.lock"
  echo 99999 > "${STATE_DIR}/locks/budget.lock/pid"

  if kill -0 99999 2>/dev/null; then
    skip "PID 99999 is unexpectedly alive"
  fi

  acquire_budget_lock
  # After acquiring, stale directories should be cleaned up
  local stale_count
  stale_count=$(find "${STATE_DIR}/locks" -name "budget.lock.stale.*" -type d 2>/dev/null | wc -l | tr -d ' ')
  [[ "$stale_count" -eq 0 ]]
  release_budget_lock
}
