---
title: "Cross-validate parsed role config to prevent silent privilege escalation"
date: 2026-03-01
category: security
tags: [bash, parsing, defense-in-depth, role-config, sed, frontmatter]
severity: high
confidence: high
---

# Cross-Validate Parsed Role Config

## Problem

When using `sed` or `grep` to parse YAML-like frontmatter from role configuration files, parsing can silently return empty strings due to:
- Trailing whitespace after the colon (`disallowedTools: `)
- Tab characters instead of spaces
- Missing field entirely
- Malformed YAML (quotes, multi-line values)

If the parsed value controls security-sensitive behavior (like tool restrictions), an empty result silently grants maximum access.

## Root Cause

Shell-based text parsing (sed, grep, awk) is not a YAML parser. Edge cases in formatting produce empty strings that downstream code treats as "no restriction" rather than "parse error."

## Fix

After parsing, cross-validate the result against the expected role mode:

```bash
# Parse the field
ROLE_DISALLOWED_TOOLS=$(sed -n 's/^disallowedTools: *//p' "$role_file" | head -1)

# Trim whitespace
ROLE_DISALLOWED_TOOLS="${ROLE_DISALLOWED_TOOLS## }"
ROLE_DISALLOWED_TOOLS="${ROLE_DISALLOWED_TOOLS%% }"

# Cross-validate: read-only roles MUST have tool restrictions
if [[ "$ROLE_MODE" == "read-only" && -z "$ROLE_DISALLOWED_TOOLS" ]]; then
  log_error "Role is read-only but has no disallowedTools — aborting"
  exit 1
fi
```

## Gotchas

- The developer role intentionally has an empty `disallowedTools:` — the guard must only fire for `read-only` mode, not `read-write`
- `sed -n 's/^disallowedTools: *//p'` matches ANYWHERE in the file, not just frontmatter — if the markdown body contains that string in a code block, it could match. The `head -1` mitigates this since frontmatter comes first
- Consider migrating to `yq` for proper YAML parsing if role configs grow more complex

## General Pattern

Whenever parsing config that controls access/permissions:
1. Parse the value
2. Validate it's non-empty (or matches expected format)
3. Cross-check against related fields (mode vs restrictions, role vs capabilities)
4. Fail loudly on mismatch rather than falling through to default behavior
