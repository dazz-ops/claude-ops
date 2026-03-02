---
title: "bash set -e breaks [[ condition ]] && command pattern when sourced"
date: 2026-03-01
category: tooling
tags: [bash, set-e, sourcing, bats, testing, gotcha]
severity: medium
confidence: high
---

# bash set -e Breaks [[ ]] && Command Pattern

## Problem

When a script with `set -e` is sourced by another script (e.g., for testing), the common pattern `[[ condition ]] && command` aborts the sourcing script if the condition evaluates to false.

```bash
# In script.sh (has set -euo pipefail at top):

# BROKEN: if condition is false, set -e sees exit code 1 and aborts
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
```

When sourced (e.g., `source script.sh`), `BASH_SOURCE[0] != $0`, so `[[ ]]` returns exit code 1. With `set -e` active, this immediately terminates the calling script.

## Root Cause

`set -e` (errexit) causes bash to exit when any command returns non-zero. The `[[ ]] && command` pattern is a single compound command — when `[[ ]]` is false, the whole expression returns 1. Bash's `set -e` sees this as a failure and aborts.

The `if/then/fi` construct is specifically exempted from `set -e` — conditions in `if` statements don't trigger errexit. This is documented in the bash manual under "errexit" exceptions.

## Fix

Use `if/fi` instead of `&&`:

```bash
# CORRECT: if/fi is exempt from set -e
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

## Gotchas

- This only manifests when the script is **sourced** — direct execution works fine (condition is true)
- The error is silent and confusing: the sourcing test just fails with a generic exit
- This applies to any `[[ ]] && ...` or `command && ...` under `set -e`, not just source guards
- bats `setup()` functions that source scripts are the most common trigger
- When sourcing scripts in bats, also watch for global variable assignments that overwrite test variables — save and restore around `source`:
  ```bash
  local saved_var="$MY_VAR"
  source ./script.sh
  export MY_VAR="$saved_var"
  ```

## General Pattern

Under `set -e`:
1. Never use `[[ condition ]] && action` for conditional execution — use `if/fi`
2. Never use `command1 && command2` where command1 might legitimately fail — use `if command1; then command2; fi`
3. Use `|| true` to suppress expected failures: `grep pattern file || true`
