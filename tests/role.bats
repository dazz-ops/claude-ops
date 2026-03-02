#!/usr/bin/env bats
# role.bats — Tests for load_role and build_prompt

load test_helper

# ============================================================================
# load_role
# ============================================================================

@test "load_role exits on missing role file" {
  run load_role "nonexistent-role"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"not found"* ]]
}

@test "load_role exits when yq is not available" {
  # Create a role file first so we don't fail on "not found" before the yq check
  create_role_fixture "needs-yq" "read-write"
  # Create a fake yq that returns "command not found" behavior
  local fakedir="${TEST_TMPDIR}/no-yq-bin"
  mkdir -p "$fakedir"
  # Override PATH to exclude real yq — put fakedir first with no yq in it
  # but keep basic tools available
  local saved_path="$PATH"
  export PATH="${fakedir}"
  run load_role "needs-yq"
  export PATH="$saved_path"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"yq"* ]]
}

@test "load_role parses mode from frontmatter" {
  create_role_fixture "tester" "read-only" "Write,Edit,NotebookEdit,Bash"
  load_role "tester"
  [[ "$ROLE_MODE" == "read-only" ]]
}

@test "load_role parses tools from frontmatter" {
  create_role_fixture "tester" "read-write"
  load_role "tester"
  [[ "$ROLE_TOOLS" == "Read,Grep,Glob,Bash" ]]
}

@test "load_role parses disallowedTools from frontmatter" {
  create_role_fixture "tester" "read-only" "Write,Edit,NotebookEdit,Bash"
  load_role "tester"
  [[ "$ROLE_DISALLOWED_TOOLS" == *"Write"* ]]
  [[ "$ROLE_DISALLOWED_TOOLS" == *"Edit"* ]]
}

@test "load_role extracts prompt body" {
  create_role_fixture "tester" "read-write"
  load_role "tester"
  [[ "$ROLE_PROMPT" == *"tester Role"* ]]
  [[ "$ROLE_PROMPT" == *"You are a test role"* ]]
}

@test "load_role rejects invalid mode" {
  create_role_fixture "bad-mode" "dangerous"
  run load_role "bad-mode"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"invalid mode"* ]]
}

@test "load_role rejects empty mode" {
  create_role_fixture "no-mode" ""
  run load_role "no-mode"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"no mode field"* ]]
}

@test "load_role rejects read-only role without disallowedTools" {
  create_role_fixture "unsafe-readonly" "read-only" ""
  run load_role "unsafe-readonly"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"no disallowedTools"* ]]
}

@test "load_role rejects read-only role missing Write in disallowedTools" {
  create_role_fixture "missing-write" "read-only" "Edit,NotebookEdit"
  run load_role "missing-write"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"Write"* ]]
}

@test "load_role rejects read-only role missing Edit in disallowedTools" {
  create_role_fixture "missing-edit" "read-only" "Write,NotebookEdit"
  run load_role "missing-edit"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"Edit"* ]]
}

@test "load_role rejects read-only role missing NotebookEdit in disallowedTools" {
  create_role_fixture "missing-nb" "read-only" "Write,Edit"
  run load_role "missing-nb"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"NotebookEdit"* ]]
}

@test "load_role accepts read-write role without disallowedTools" {
  create_role_fixture "full-access" "read-write" ""
  run load_role "full-access"
  [[ "$status" -eq 0 ]]
}

@test "load_role accepts read-only role with all required disallowedTools" {
  create_role_fixture "safe-readonly" "read-only" "Write,Edit,NotebookEdit,Bash"
  run load_role "safe-readonly"
  [[ "$status" -eq 0 ]]
}

# ============================================================================
# build_prompt
# ============================================================================

@test "build_prompt includes role prompt" {
  local result
  result=$(build_prompt "You are a tester." "run tests" "/tmp/repo")
  [[ "$result" == *"You are a tester."* ]]
}

@test "build_prompt wraps task in XML tags" {
  local result
  result=$(build_prompt "Role" "my test task" "/tmp/repo")
  [[ "$result" == *"<task>"* ]]
  [[ "$result" == *"my test task"* ]]
  [[ "$result" == *"</task>"* ]]
}

@test "build_prompt includes target path in environment" {
  local result
  result=$(build_prompt "Role" "task" "/Users/test/my-repo")
  [[ "$result" == *"/Users/test/my-repo"* ]]
}

@test "build_prompt includes timestamp" {
  local result
  result=$(build_prompt "Role" "task" "/tmp/repo")
  # Should contain an ISO 8601 timestamp
  [[ "$result" =~ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ]]
}

@test "build_prompt includes dispatch summary format" {
  local result
  result=$(build_prompt "Role" "task" "/tmp/repo")
  [[ "$result" == *"DISPATCH_SUMMARY_START"* ]]
  [[ "$result" == *"DISPATCH_SUMMARY_END"* ]]
}

@test "build_prompt includes safety instructions" {
  local result
  result=$(build_prompt "Role" "task" "/tmp/repo")
  [[ "$result" == *"Do NOT push to remote"* ]]
  [[ "$result" == *"Do NOT modify the protocol plugin"* ]]
}
