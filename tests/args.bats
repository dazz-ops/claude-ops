#!/usr/bin/env bats
# args.bats — Tests for parse_args and main flow

load test_helper

# ============================================================================
# parse_args
# ============================================================================

@test "parse_args sets ROLE" {
  parse_args --role test-role --target test-repo --task "do stuff"
  [[ "$ROLE" == "test-role" ]]
}

@test "parse_args sets TARGET" {
  parse_args --role test-role --target my-target --task "do stuff"
  [[ "$TARGET" == "my-target" ]]
}

@test "parse_args sets TASK" {
  parse_args --role test-role --target test-repo --task "implement feature"
  [[ "$TASK" == "implement feature" ]]
}

@test "parse_args sets TIMEOUT" {
  parse_args --role test-role --target test-repo --task "do stuff" --timeout 120
  [[ "$TIMEOUT" == "120" ]]
}

@test "parse_args sets DRY_RUN" {
  parse_args --role test-role --target test-repo --task "do stuff" --dry-run
  [[ "$DRY_RUN" == "true" ]]
}

@test "parse_args exits on missing --role" {
  run parse_args --target test-repo --task "do stuff"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"Missing --role"* ]]
}

@test "parse_args exits on missing --target" {
  run parse_args --role test-role --task "do stuff"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"Missing --target"* ]]
}

@test "parse_args exits on missing --task" {
  run parse_args --role test-role --target test-repo
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"Missing --task"* ]]
}

@test "parse_args exits on empty --role value" {
  run parse_args --role "" --target test-repo --task "do stuff"
  [[ "$status" -ne 0 ]]
}

@test "parse_args exits on unknown option" {
  run parse_args --role test-role --target test-repo --task "do stuff" --invalid
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"Unknown option"* ]]
}

@test "parse_args rejects non-numeric timeout" {
  run parse_args --role test-role --target test-repo --task "do stuff" --timeout abc
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"positive integer"* ]]
}
