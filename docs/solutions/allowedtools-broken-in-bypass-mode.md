---
title: "--allowedTools silently ignored in bypass mode"
date: 2026-03-01
category: security
tags: [claude-code, cli, permissions, bypass-mode, tool-restrictions]
severity: critical
confidence: high
---

# --allowedTools Silently Ignored in Bypass Mode

## Problem

When using `claude -p --dangerously-skip-permissions`, the `--allowedTools` whitelist flag is **silently ignored**. The agent gets access to ALL tools regardless of the whitelist. No warning is emitted.

This means read-only roles (product-manager, code-reviewer, tech-lead) configured with `--allowedTools "Read,Grep,Glob,Bash"` could still use Write, Edit, and NotebookEdit tools.

## Root Cause

Confirmed bug in Claude Code CLI. Tracked as GitHub issue #12232. The `--allowedTools` whitelist is not enforced when `--dangerously-skip-permissions` is active.

## Fix

Use `--disallowedTools` (denylist) instead of `--allowedTools` (whitelist). The denylist **does** work correctly in bypass mode.

```bash
# BROKEN — whitelist silently ignored in bypass mode
claude -p "$prompt" --dangerously-skip-permissions --allowedTools "Read,Grep,Glob,Bash"

# WORKS — denylist enforced in bypass mode
claude -p "$prompt" --dangerously-skip-permissions --disallowedTools "Write,Edit,NotebookEdit"
```

For roles with full access (developer), omit the `--disallowedTools` flag entirely rather than passing an empty value.

## Gotchas

- The `--allowedTools` flag does NOT produce an error or warning when ignored — it fails silently
- Always verify tool restrictions with `--dry-run` after changing role configurations
- If the upstream bug is fixed in a future Claude Code release, `--allowedTools` may become viable again — check issue #12232

## Applicability

Any project using `claude -p --dangerously-skip-permissions` with role-based tool restrictions (e.g., cron automation, CI/CD pipelines, headless orchestration).
