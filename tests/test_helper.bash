# test_helper.bash — Shared setup for all bats tests
# Sources dispatch.sh functions and configures isolated test environment

# Project root (tests/ is one level below)
export OPS_ROOT="${BATS_TEST_DIRNAME}/.."

# Per-test isolation: each test gets its own temp directory
setup() {
  export TEST_TMPDIR="${BATS_TMPDIR}/${BATS_TEST_NAME}"
  mkdir -p "$TEST_TMPDIR"

  # Override state/log dirs to use test-local paths
  export STATE_DIR="${TEST_TMPDIR}/state"
  export LOG_DIR="${TEST_TMPDIR}/logs"
  mkdir -p "$STATE_DIR/locks" "$LOG_DIR"

  # Create a minimal config.json for tests
  export CONFIG="${TEST_TMPDIR}/config.json"
  cat > "$CONFIG" <<'TESTCONFIG'
{
  "targets": [
    {"name": "test-repo", "path": "/tmp/test-repo", "branch": "main", "enabled": true},
    {"name": "disabled-repo", "path": "/tmp/disabled-repo", "branch": "main", "enabled": false}
  ],
  "defaults": {
    "worker_timeout": 300,
    "max_daily_invocations": 20,
    "log_retention_days": 7
  },
  "notifications": {
    "enabled": false,
    "method": "osascript"
  }
}
TESTCONFIG

  # Create a test target directory
  mkdir -p /tmp/test-repo

  # Set up PATH stubs (prepend mocks dir so they shadow real commands)
  export ORIGINAL_PATH="$PATH"
  export PATH="${BATS_TEST_DIRNAME}/mocks:${PATH}"

  # Mock control directories (per-test isolation)
  export MOCK_CLAUDE_DIR="${TEST_TMPDIR}/mock-claude"
  export MOCK_GH_DIR="${TEST_TMPDIR}/mock-gh"
  export MOCK_GIT_DIR="${TEST_TMPDIR}/mock-git"
  mkdir -p "$MOCK_CLAUDE_DIR" "$MOCK_GH_DIR" "$MOCK_GIT_DIR"

  # Source dispatch.sh functions (main() is guarded, won't execute)
  source "${OPS_ROOT}/scripts/dispatch.sh" 2>/dev/null || true
}

teardown() {
  # Clean up per-test temp directory
  rm -rf "$TEST_TMPDIR"
  # Restore PATH
  export PATH="$ORIGINAL_PATH"
}

# Helper: create a role fixture file
create_role_fixture() {
  local name="$1"
  local mode="$2"
  local disallowed="${3:-}"
  local dir="${TEST_TMPDIR}/roles"
  mkdir -p "$dir"
  export OPS_ROOT="$TEST_TMPDIR"

  cat > "${dir}/${name}.md" <<ROLE
---
tools: Read,Grep,Glob,Bash
disallowedTools: ${disallowed}
mode: ${mode}
skills: explore, brainstorm
---

# ${name} Role

You are a test role.
ROLE
}

# Helper: assert file contains string
assert_file_contains() {
  local file="$1"
  local expected="$2"
  if ! grep -qF "$expected" "$file"; then
    echo "Expected '$expected' in $file"
    echo "File contents:"
    cat "$file"
    return 1
  fi
}
