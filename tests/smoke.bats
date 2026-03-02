#!/usr/bin/env bats
# smoke.bats — Verify dispatch.sh can be sourced without executing main()

load test_helper

@test "sourcing dispatch.sh does not execute main()" {
  # If main() ran, it would fail (no args) and set exit code != 0
  # The test_helper already sources dispatch.sh in setup() — if we got here, it worked
  [[ "$(type -t log_info)" == "function" ]]
}

@test "core functions are available after sourcing" {
  [[ "$(type -t log_info)" == "function" ]]
  [[ "$(type -t log_warn)" == "function" ]]
  [[ "$(type -t log_error)" == "function" ]]
  [[ "$(type -t read_config)" == "function" ]]
  [[ "$(type -t resolve_target)" == "function" ]]
  [[ "$(type -t check_budget)" == "function" ]]
  [[ "$(type -t record_invocation)" == "function" ]]
  [[ "$(type -t acquire_target_lock)" == "function" ]]
  [[ "$(type -t release_target_lock)" == "function" ]]
  [[ "$(type -t load_role)" == "function" ]]
  [[ "$(type -t build_prompt)" == "function" ]]
  [[ "$(type -t invoke_agent)" == "function" ]]
  [[ "$(type -t parse_summary)" == "function" ]]
  [[ "$(type -t main)" == "function" ]]
}

@test "OPS_ROOT is set correctly" {
  # OPS_ROOT should point to the repo root
  [[ -d "$OPS_ROOT" ]]
  [[ -f "${OPS_ROOT}/scripts/dispatch.sh" ]]
}

@test "read_config reads from test config" {
  local timeout
  timeout=$(read_config '.defaults.worker_timeout')
  [[ "$timeout" == "300" ]]
}

@test "read_config reads max_daily_invocations" {
  local max
  max=$(read_config '.defaults.max_daily_invocations')
  [[ "$max" == "20" ]]
}
