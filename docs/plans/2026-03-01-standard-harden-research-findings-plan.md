---
title: Harden claude-ops Based on Research Findings
tier: standard
status: complete
date: 2026-03-01
risk: LOW
tags: [security, cost-optimization, error-handling, polling]
---

# Plan: Harden claude-ops Based on Research Findings

## Problem

Research identified four issues in claude-ops:
1. `--allowedTools` whitelist is silently ignored when using `--dangerously-skip-permissions` (confirmed bug, GitHub issue #12232). Read-only roles can currently use Write/Edit tools despite the whitelist.
2. Job scripts invoke expensive `claude -p` even when no work exists (wasted tokens/budget).
3. No token cost tracking — only duration and exit code are recorded, making cost analysis impossible.
4. SIGTERM (exit 143) from headless sessions is not distinguished from other failures, preventing targeted retry logic.

## Goals

- Fix the security boundary for read-only roles
- Eliminate wasted invocations when no work exists
- Add token usage visibility per invocation
- Improve error classification in the dispatcher

## Solution

### 1. Switch `--allowedTools` to `--disallowedTools` in dispatch.sh

The denylist works correctly in bypass mode. Change the role frontmatter from declaring what's allowed to declaring what's denied, and update `invoke_agent()` accordingly.

**Role frontmatter changes:**
- `developer.md`: `disallowedTools: ""` (empty — developer can use everything)
- `product-manager.md`: `disallowedTools: Write,Edit,NotebookEdit`
- `code-reviewer.md`: `disallowedTools: Write,Edit,NotebookEdit`
- `tech-lead.md`: `disallowedTools: Write,Edit,NotebookEdit`

**dispatch.sh changes:**
- `load_role()`: Parse `disallowedTools:` instead of `tools:` from frontmatter
- `invoke_agent()`: Pass `--disallowedTools` instead of `--allowedTools`
- Keep `tools:` in frontmatter for documentation, but add `disallowedTools:` as the enforced field

### 2. Add polling guards to all job scripts

Before calling `dispatch.sh`, each job checks if work exists using a lightweight `gh` API call. If no work, log a skip and exit 0.

| Job | Pre-check | Skip condition |
|-----|-----------|----------------|
| `pm-triage.sh` | Count open issues without priority labels | No untriaged issues |
| `pm-enhance.sh` | `gh issue list --label needs_refinement --state open --json number --jq length` | 0 needs_refinement issues |
| `dev-implement.sh` | `gh issue list --label ready_for_dev --state open --json number --jq length` | 0 ready_for_dev issues |
| `dev-review-prs.sh` | `gh pr list --state open --json number --jq length` | 0 open PRs |
| `pm-explore.sh` | None — always runs (weekly ideation) | N/A |
| `tech-lead-review.sh` | `git log --oneline --since='7 days ago'` | 0 commits in last 7 days |

### 3. Add token cost tracking to record_invocation()

The `claude -p --output-format json` response includes token usage fields. Capture these from the raw output before parsing `.result`, and pass them to `record_invocation()`.

**Changes:**
- `parse_claude_output()`: Extract `.usage.input_tokens` and `.usage.output_tokens` from JSON before cleaning up
- `record_invocation()`: Accept and log `input_tokens` and `output_tokens` alongside existing fields
- `check_budget()`: No changes — keep budget based on invocation count, not tokens

### 4. Handle SIGTERM (exit 143) in run_with_timeout()

Add explicit handling for exit code 143 in `invoke_agent()`, alongside the existing 124 (timeout) check.

**Changes in `invoke_agent()`:**
- 124 → "Agent timed out" (existing)
- 143 → "Agent killed (SIGTERM) — session may have been terminated by rate limiting"
- other non-zero → "Agent exited with code $ec" (existing)

## Implementation Steps

1. Update all four role frontmatter files — add `disallowedTools:` field
2. Update `load_role()` in dispatch.sh — parse `disallowedTools:`
3. Update `invoke_agent()` in dispatch.sh — use `--disallowedTools` flag
4. Add polling guard to `pm-triage.sh`
5. Add polling guard to `pm-enhance.sh`
6. Add polling guard to `dev-implement.sh`
7. Add polling guard to `dev-review-prs.sh`
8. Add polling guard to `tech-lead-review.sh`
9. Update `parse_claude_output()` — extract token usage
10. Update `record_invocation()` — accept and log token fields
11. Update `invoke_agent()` — handle exit code 143

## Affected Files

| File | Change |
|------|--------|
| `scripts/dispatch.sh` | `load_role()`, `invoke_agent()`, `parse_claude_output()`, `record_invocation()` |
| `roles/product-manager.md` | Add `disallowedTools:` frontmatter |
| `roles/developer.md` | Add `disallowedTools:` frontmatter |
| `roles/code-reviewer.md` | Add `disallowedTools:` frontmatter |
| `roles/tech-lead.md` | Add `disallowedTools:` frontmatter |
| `jobs/pm-triage.sh` | Add polling guard |
| `jobs/pm-enhance.sh` | Add polling guard |
| `jobs/dev-implement.sh` | Add polling guard |
| `jobs/dev-review-prs.sh` | Add polling guard |
| `jobs/tech-lead-review.sh` | Add polling guard |

## Acceptance Criteria

- [ ] Read-only roles cannot use Write, Edit, or NotebookEdit tools (verified via `--dry-run`)
- [ ] Developer role retains full tool access
- [ ] Jobs exit 0 with a log message when no work exists
- [ ] `pm-explore.sh` always runs (no guard)
- [ ] `invocations.jsonl` entries include `input_tokens` and `output_tokens` fields
- [ ] Exit code 143 produces a distinct log message mentioning SIGTERM
- [ ] All scripts pass `bash -n` syntax check
- [ ] `dispatch.sh --dry-run` shows disallowed tools instead of allowed tools

## Test Strategy

- `bash -n` all modified scripts
- `--dry-run` each role to verify disallowedTools output
- Simulate empty work conditions (no ready issues) and verify jobs skip
- Verify `invocations.jsonl` format with token fields after a real invocation

## Risks

| Risk | Mitigation |
|------|-----------|
| `--disallowedTools` with empty string may behave unexpectedly for Developer role | Test with `--dry-run`; if problematic, omit the flag entirely for Developer |
| `gh` API rate limits from polling guards | Each guard makes 1 API call; 8 calls/day is negligible |
| `claude -p` JSON output may not include `.usage` field in all cases | Use `// empty` jq fallback; record 0 if absent |
| Polling guard in pm-triage.sh is complex (filtering unlabeled issues) | Simplify: count all open issues, let the agent skip internally if all are triaged |
