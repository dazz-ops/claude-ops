---
title: Production Readiness Fixes — Crontab, Docs, Dead Config, Cron Toggle
tier: standard
status: complete
date: 2026-03-01
risk: MEDIUM
tags: [operations, cron, config, documentation, feature-flag]
reviewed: 2026-03-01
review_verdict: REVISION_REQUESTED → APPROVED (all 11 findings addressed)
---

## Problem

The production readiness audit identified 5 issues that will cause confusion or failures in deployment:

1. `schedules/crontab` contains hardcoded paths (`/Users/austin/...`) and is committed to git — useless on any other machine
2. The committed crontab has a 1x/day evening-only dev schedule, but `install.sh` generates a 3x/day schedule — operators get different behavior depending on which they use
3. CLAUDE.md documents the old evening-only schedule, not the 3x/day schedule
4. `max_invocations_per_job` exists in `config.template.json` but is never read anywhere
5. `log-cleanup.sh` header says "Sunday midnight" but the actual cron runs at 3 AM

Additionally, there's no way to disable cron jobs without manually editing the crontab — a toggle is needed for maintenance or when relying purely on event-driven triggers.

## Goals

1. Eliminate all stale/hardcoded paths from version-controlled files
2. Make `install.sh` the single source of truth for crontab generation
3. Align all schedule documentation (CLAUDE.md, job script headers) with the generated schedule
4. Remove dead config fields
5. Add a `cron_enabled` feature flag that `install.sh` respects

## Solution

### Fix 1: Remove committed crontab, add to .gitignore

Delete `schedules/crontab` from git tracking and add it to `.gitignore`. The file is machine-specific output from `install.sh` — same as `config.json`. Keep `schedules/` directory with a `.gitkeep` so the directory exists for `install.sh` to write into.

### Fix 2: Align documentation with install.sh schedule

Update CLAUDE.md fallback cron schedule section to show the 3x/day dev schedule that `install.sh` actually generates. Update all job script header comments to match. Add `# SYNC: also update CLAUDE.md schedule section` comment in `install.sh`'s crontab generation function to prevent future drift.

### Fix 3: Fix log-cleanup.sh comment

Change "Sunday midnight" → "Sunday 03:00" and update the cron expression from `0 0 * * 0` to `0 3 * * 0`.

### Fix 4: Remove dead config field

Remove `max_invocations_per_job` from `config.template.json`. Verified via `grep -r max_invocations_per_job` (zero references in any script). The daily budget cap is a separate field (`max_daily_invocations`) used by `dispatch.sh` — unaffected.

### Fix 5: Add `cron_enabled` toggle

Add `"cron_enabled": true` to `config.json` defaults. `install.sh` reads this flag:
- `true` → generate and install crontab entries (current behavior)
- `false` → remove all claude-ops crontab entries, print message confirming cron is disabled

This gives operators a clean way to run event-driven-only without cron fallback.

## Technical Approach

**Single source of truth:** `install.sh` already generates the crontab dynamically with correct paths (via `$(dirname "$0")/..` — verified). The fix is to stop committing the output and clarify that `install.sh` is authoritative. Verify during implementation that `generate_crontab()` uses `$OPS_ROOT` (computed dynamically), never literal paths.

**Sentinel-based crontab management:** Instead of fragile `grep -v claude-ops`, use fenced markers:
```
# BEGIN claude-ops managed block — do not edit manually
<crontab entries>
# END claude-ops managed block
```
When modifying the crontab, `sed` extracts everything between the markers. This is the standard convention (used by rvm, nvm, Homebrew) and eliminates both false positives (unrelated entries containing "claude-ops") and false negatives (entries without the marker).

**Crontab safety:** Before any modification:
1. Backup existing crontab: `crontab -l > "${STATE_DIR}/crontab.backup.$(date +%s)"`
2. Distinguish `crontab -l` failure modes: check stderr for "no crontab for" (OK, proceed with empty) vs other errors (abort)
3. Ensure trailing newline before appending new entries

**Idempotent install:** Both the `true` and `false` paths strip existing claude-ops entries first (same sentinel-based removal), then the `true` path appends fresh entries. Repeated runs produce identical results.

**Cron toggle jq pattern:** The jq `//` alternative operator treats `false` as falsy — `false // true` returns `true`, silently breaking the disable case. Use explicit null-check instead:
```bash
cron_enabled=$(jq -r 'if .defaults.cron_enabled == null then "true" else (.defaults.cron_enabled | tostring) end' "$CONFIG")
```
This correctly handles: missing key → `"true"` (backward-compatible), explicit `true` → `"true"`, explicit `false` → `"false"`.

**`--check` flag:** Update to report the resolved `cron_enabled` value, including whether it was defaulted. Example output: `ok  cron_enabled: true (from config)` or `ok  cron_enabled: true (defaulted — key missing from config)`.

## Implementation Steps

| # | Task | Files | Priority |
|---|------|-------|----------|
| 1 | Remove `schedules/crontab` from git, add to `.gitignore`, add `schedules/.gitkeep` | `schedules/crontab`, `.gitignore`, `schedules/.gitkeep` | HIGH |
| 2 | Add `cron_enabled` to `config.template.json`, remove `max_invocations_per_job` | `config.template.json` | HIGH |
| 3 | Update `install.sh`: sentinel markers, crontab backup, `cron_enabled` flag with correct jq, idempotent install, `--check` reporting | `scripts/install.sh` | HIGH |
| 4 | Fix `log-cleanup.sh` header comment | `scripts/log-cleanup.sh` | LOW |
| 5 | Update job script header comments to match install.sh schedule | `jobs/*.sh` | LOW |
| 6 | Update CLAUDE.md cron schedule documentation, add SYNC comment to install.sh | `CLAUDE.md`, `scripts/install.sh` | MEDIUM |

## Affected Files

| File | Action | What Changes |
|------|--------|-------------|
| `schedules/crontab` | Delete from git | Remove committed machine-specific file |
| `.gitignore` | Modify | Add `schedules/crontab` |
| `schedules/.gitkeep` | Create | Preserve directory for install.sh output |
| `config.template.json` | Modify | Add `cron_enabled: true`, remove `max_invocations_per_job` |
| `scripts/install.sh` | Modify | Sentinel markers, crontab backup, `cron_enabled` with correct jq, idempotent install, `--check` cron reporting |
| `scripts/log-cleanup.sh` | Modify | Fix header comment (midnight → 03:00) |
| `jobs/pm-enhance.sh` | Modify | Fix schedule comment |
| `jobs/dev-implement.sh` | Modify | Fix schedule comment |
| `jobs/dev-review-prs.sh` | Modify | Fix schedule comment |
| `jobs/tech-lead-review.sh` | Modify | Fix schedule comment placeholder |
| `CLAUDE.md` | Modify | Update cron schedule table to 3x/day |

## Acceptance Criteria

1. `schedules/crontab` is not tracked in git
2. `install.sh --check` works with new config fields and reports `cron_enabled` status
3. `install.sh` with `cron_enabled: true` generates and installs crontab using sentinel markers (current behavior)
4. `install.sh` with `cron_enabled: false` removes claude-ops sentinel block and prints confirmation
5. `install.sh` with `cron_enabled: false` followed by `cron_enabled: true` correctly re-adds entries (full toggle lifecycle)
6. `config.template.json` has no `max_invocations_per_job` field
7. `config.template.json` has `cron_enabled: true` in defaults
8. All job script header comments match the schedule `install.sh` generates
9. CLAUDE.md cron schedule matches `install.sh` output
10. `log-cleanup.sh` comment says 03:00, not midnight
11. Existing installs without `cron_enabled` in config default to `true` (no breakage)
12. `cron_enabled: false` (explicit) is correctly read as false (not overridden by jq `//` operator)
13. Crontab backup is created before any modification
14. `crontab -l` permission errors are detected and abort (not silently swallowed)
15. Repeated `install.sh` runs are idempotent (no duplicate entries)
16. install.sh generates crontab paths dynamically via `$OPS_ROOT`, never literal strings

## Test Strategy

- Verify jq expression correctly returns `"false"` for explicit `cron_enabled: false` (not `"true"`)
- Verify jq expression returns `"true"` for missing `cron_enabled` key
- Verify sentinel markers are written: `# BEGIN claude-ops` / `# END claude-ops`
- Verify crontab backup is created in `$STATE_DIR/`
- Verify `crontab -l` permission errors are detected (test with mock)
- Verify idempotency: run install.sh twice, count entries — should be identical
- Verify `--check` reports `cron_enabled` resolved value and source
- Verify `git status` shows `schedules/crontab` is untracked after `.gitignore` update
- Verify `generate_crontab()` uses `$OPS_ROOT` in all paths

## Risks

| Risk | Mitigation |
|------|-----------|
| Existing users have `schedules/crontab` installed manually | `install.sh` overwrites cron entries using sentinel block — manual entries outside the block are preserved |
| Missing `cron_enabled` breaks existing `config.json` | Backward-compatible default to `true` via explicit jq null-check (not `//` operator) |
| Removing `max_invocations_per_job` breaks something | Verified: `grep -r max_invocations_per_job` returns zero references. The daily cap is `max_daily_invocations` (separate field, used by dispatch.sh) |
| Crontab modification corrupts user's other cron jobs | Backup before modification; sentinel-based extraction only touches the claude-ops block; non-claude-ops entries are never touched |
| `crontab -l` fails with permission error | Distinguish "no crontab" (proceed) from permission/other errors (abort with message) |

## Spec-Flow Analysis

### Flow: `install.sh` cron toggle

```
User runs install.sh
  → Backup: crontab -l > $STATE_DIR/crontab.backup.$timestamp
    ├─ "no crontab for user" → proceed with empty base (OK)
    └─ other error → abort with message
  → Read config.json
  → Read .defaults.cron_enabled (explicit null-check, default: true)
  ├─ true:
  │   → Strip existing sentinel block (if any) from crontab
  │   → Generate fresh entries with dynamic paths
  │   → Append sentinel block with trailing newline
  │   → Install combined crontab
  │   → Print: "Cron schedule installed (N entries)"
  └─ false:
      → Strip existing sentinel block from crontab
      → Install stripped crontab (preserves non-claude-ops entries)
      → Print: "Cron disabled. Event-driven triggers only."
```

**Edge cases:**
- `cron_enabled` key missing → defaults to `true` (backward-compatible)
- `cron_enabled: false` → correctly read as `false` (jq null-check, not `//`)
- No existing crontab → `crontab -l` stderr says "no crontab for" → proceed with empty base
- Permission error on `crontab -l` → abort, print error, do not modify
- User has non-claude-ops cron entries → preserved (sentinel block extraction is surgical)
- Repeated runs → idempotent (strip old block, add fresh block)
- Toggle lifecycle: true → false → true works correctly (each run strips and optionally re-adds)
- Paths with spaces → not supported; `validate_ops_root()` rejects metacharacters including spaces

### `--check` output for cron_enabled

```
ok  cron_enabled: true (from config)
ok  cron_enabled: true (defaulted — key not in config)
ok  cron_enabled: false (from config) — cron jobs will not be installed
```

## Review Findings Addressed

1. Fixed jq `//` operator bug — use explicit null-check instead (AV-010)
2. Replaced `grep -v` with sentinel markers `BEGIN/END claude-ops` (ARCH-001, SEC-002)
3. Added crontab backup before modification (FLOW-002, SEC-005)
4. Distinguished `crontab -l` failure modes (FLOW-001)
5. Specified toggle lifecycle: true→false→true works (AV-016)
6. Verified install.sh generates paths dynamically via $OPS_ROOT (AV-011)
7. Specified idempotent install: strip-then-add for both paths (FLOW-003)
8. Updated `--check` to report cron_enabled state (FLOW-004, AV-017)
9. Added trailing newline requirement (AV-015)
10. Fixed terminology: "backward-compatible default" not "fail-closed" (ARCH-004)
11. Added `# SYNC` comment cross-referencing CLAUDE.md ↔ install.sh (ARCH-005)
12. Dismissed SEC-001 (git history paths — not secrets, accepted risk)
13. Risk upgraded from LOW to MEDIUM (crontab is external system state)
