#!/usr/bin/env bats
# summary.bats — Tests for parse_summary and parse_claude_output

load test_helper

# ============================================================================
# parse_summary
# ============================================================================

@test "parse_summary extracts summary block" {
  local output="some output
---DISPATCH_SUMMARY_START---
status: completed
actions_taken:
- did something
artifacts:
- https://github.com/test/repo/pull/1
notes: all good
---DISPATCH_SUMMARY_END---
trailing text"

  local result
  result=$(parse_summary "$output")
  [[ "$result" == *"status: completed"* ]]
  [[ "$result" == *"did something"* ]]
}

@test "parse_summary warns on missing sentinels" {
  local output="just some output with no summary"
  run parse_summary "$output"
  [[ "$output" == *"missing summary sentinels"* ]]
}

@test "parse_summary returns JSON on missing sentinels" {
  local output="just some output"
  local result
  result=$(parse_summary "$output")
  echo "$result" | jq . > /dev/null 2>&1
  [[ "$result" == *"unknown"* ]]
}

# ============================================================================
# parse_claude_output
# ============================================================================

@test "parse_claude_output extracts result field" {
  local tmpfile="${TEST_TMPDIR}/claude-output.json"
  echo '{"result":"hello world","usage":{"input_tokens":100,"output_tokens":50}}' > "$tmpfile"

  local result
  result=$(parse_claude_output "$tmpfile")
  [[ "$result" == "hello world" ]]
}

@test "parse_claude_output sets token globals" {
  local tmpfile="${TEST_TMPDIR}/claude-output.json"
  echo '{"result":"ok","usage":{"input_tokens":1500,"output_tokens":750}}' > "$tmpfile"

  parse_claude_output "$tmpfile" > /dev/null
  [[ "$LAST_INPUT_TOKENS" -eq 1500 ]]
  [[ "$LAST_OUTPUT_TOKENS" -eq 750 ]]
}

@test "parse_claude_output fails on error response" {
  local tmpfile="${TEST_TMPDIR}/claude-output.json"
  echo '{"error":"rate limit exceeded","usage":{"input_tokens":0,"output_tokens":0}}' > "$tmpfile"

  run parse_claude_output "$tmpfile"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"rate limit"* ]]
}

@test "parse_claude_output cleans up temp file" {
  local tmpfile="${TEST_TMPDIR}/claude-output.json"
  echo '{"result":"done","usage":{"input_tokens":0,"output_tokens":0}}' > "$tmpfile"

  parse_claude_output "$tmpfile" > /dev/null
  [[ ! -f "$tmpfile" ]]
}

@test "parse_claude_output handles missing usage field" {
  local tmpfile="${TEST_TMPDIR}/claude-output.json"
  echo '{"result":"no usage"}' > "$tmpfile"

  local result
  result=$(parse_claude_output "$tmpfile")
  [[ "$result" == "no usage" ]]
  [[ "$LAST_INPUT_TOKENS" -eq 0 ]]
  [[ "$LAST_OUTPUT_TOKENS" -eq 0 ]]
}
