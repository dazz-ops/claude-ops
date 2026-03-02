---
title: "jq alternative operator (//) treats false as falsy — breaks boolean config flags"
date: 2026-03-01
category: tooling
tags: [jq, bash, config, boolean, gotcha]
severity: high
confidence: high
---

# jq Alternative Operator Treats False as Falsy

## Problem

When reading a boolean config flag with jq's `//` (alternative) operator, explicit `false` values are silently overridden by the default. This means a feature toggle set to `false` gets treated as `true`.

```bash
# BROKEN: returns "true" even when cron_enabled is explicitly false
cron_enabled=$(jq -r '.defaults.cron_enabled // true' config.json)
```

jq's `//` returns the right-hand side for both `null` (key missing) AND `false` (key present but falsy). There's no way to distinguish "missing" from "explicitly false" with this operator.

## Root Cause

jq's `//` operator is the "alternative" operator — it returns the right operand when the left is `null` or `false`. This matches JavaScript's `||` behavior, not SQL's `COALESCE` (which only replaces null). The jq docs mention this, but it's easy to miss.

## Fix

Use an explicit null-check instead of `//`:

```bash
# CORRECT: returns "false" when cron_enabled is explicitly false
cron_enabled=$(jq -r 'if .defaults.cron_enabled == null then "true" else (.defaults.cron_enabled | tostring) end' config.json)
```

This correctly handles all three cases:
- Key missing → `"true"` (backward-compatible default)
- Key is `true` → `"true"`
- Key is `false` → `"false"`

For the `// empty` variant (used to detect presence), the same bug applies:

```bash
# BROKEN: returns empty for both missing AND false
jq -r '.defaults.cron_enabled // empty' config.json

# CORRECT: returns empty only for missing, "false" for false
jq -r 'if .defaults.cron_enabled == null then "" else (.defaults.cron_enabled | tostring) end' config.json
```

## Gotchas

- This affects ALL jq `//` usage with booleans — not just this project
- The bug is silent — no error, just wrong behavior
- `// "default"` also fails: `false // "default"` returns `"default"`
- If you see `jq ... //` in a codebase, audit every usage for boolean inputs
- Python's `or` has the same semantics; use `if x is None` for null-checks there too

## General Pattern

Whenever using a "default value" operator with booleans:
1. Check if the operator treats `false` as falsy (jq `//`, JS `||`, Python `or`)
2. If yes, use explicit null-check instead
3. Test with all three inputs: missing, true, false
