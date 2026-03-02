---
title: Harden claude-ops — Tests, Race Conditions, Parsing, and Operations
tier: comprehensive
status: complete
date: 2026-03-01
risk: MEDIUM
tags: [testing, security, concurrency, operations, bash, hardening]
reviewed: 2026-03-01
review_verdict: REVISION_REQUESTED → APPROVED (all findings addressed)
---

# Plan: Harden claude-ops — Tests, Race Conditions, Parsing, and Operations

## Problem

The codebase exploration identified 5 hardening gaps:

1. **No tests** — dispatch.sh (611 lines), 6 job scripts, install.sh, status.sh, and log-cleanup.sh have zero unit or integration tests. Safety relies entirely on manual testing.
2. **Budget race condition** — Concurrent read-only roles (PM, Reviewer, Tech Lead) can corrupt `state/budget-*.json` since they don't acquire locks. Two processes reading/incrementing/writing simultaneously can lose updates.
3. **Hardcoded paths** — GitHub Actions workflows reference `/Users/austin/Git_Repos/claude-ops` directly. If the runner setup changes, workflows break silently.
4. **Fragile YAML parsing** — `load_role()` uses sed to parse YAML frontmatter. Trailing whitespace, tabs, multi-line values, or matching strings in the markdown body can silently return wrong results. Past solution explicitly recommends migrating to yq.
5. **invocations.jsonl grows forever** — No archival or rotation. Will eventually consume disk and slow any tooling that reads it.

## Goals

1. Establish a test framework and write tests for all critical dispatch.sh functions
2. Eliminate budget file race condition under concurrent read-only roles
3. Parameterize all paths so workflows are portable across machines
4. Replace sed-based YAML parsing with yq for robust frontmatter extraction
5. Add rotation/archival for invocations.jsonl and improve log-cleanup.sh

## Solution

Five workstreams with explicit dependency ordering:

**WS1+WS2 — Test Infrastructure + yq Migration (coupled):** These are a single atomic phase. Set up bats-core with PATH-stub mocks. Refactor dispatch.sh for testability. Replace sed-based `load_role()` with yq (hard requirement — no sed fallback). Write tests covering both the refactored structure and the new yq parsing, including edge cases. Tests are written against the yq-based interface from the start, acknowledging the WS1↔WS2 dependency.

**WS3 — Log Rotation (prerequisite for WS4):** Add JSONL rotation to `log-cleanup.sh` (cross-platform bash, no newsyslog). This bounds invocations.jsonl size before WS4 introduces a budget lock that scans it.

**WS4 — Budget Atomicity (concurrency fix):** Fix the existing stale lock race condition in target locks first. Then introduce a budget-specific lock using the corrected pattern. Enforce strict lock ordering: budget lock is always acquired and released independently from target lock — never held simultaneously. All failure modes fail closed (abort, never skip).

**WS5 — Path Parameterization (portability):** Replace hardcoded `/Users/austin/Git_Repos/claude-ops` in GitHub Actions workflows with a validated configurable variable. Fail hard if variable is unset or invalid — no silent fallback.

## Fail-Closed Principle

**All new failure modes in this plan fail closed (abort with error) unless there is a documented justification for fail-open.** Specifically:

| Failure | Behavior | Justification |
|---------|----------|---------------|
| yq not installed | **Abort** — do not fall back to sed | sed is the parser being replaced for security reasons |
| yq parse returns empty/error | **Abort** — do not continue with empty values | Empty disallowedTools grants full access |
| `mode` field fails to parse | **Abort** — do not default to read-write | Unknown mode could bypass restrictions |
| Budget lock acquisition fails | **Abort** — do not skip budget check | Skipping allows unlimited invocations |
| Budget lock stale (PID dead) | **Break lock with warning, retry once** | Stale locks block all dispatches |
| `CLAUDE_OPS_HOME` not set | **Abort** — do not fall back to `$HOME/claude-ops` | Silent fallback masks misconfiguration |
| `CLAUDE_OPS_HOME` invalid | **Abort** — path must be absolute, existing, no metacharacters | Prevents path traversal/injection |
| `record_invocation()` fails | **Log error, continue** (fail-open) | Invocation already ran; budget undercount is preferable to crashing the agent mid-run |

## Technical Approach

### WS1+WS2 — Test Infrastructure + yq Migration (Coupled)

**Test framework:**
- **bats-core** (most mature bash testing framework, TAP-compliant)
- Mock strategy: **PATH-stub scripts** in `tests/mocks/` directory (simpler than bats-mock, no extra dependency). Each mock is a minimal shell script that records calls and returns canned output.
- Each test uses a unique temp directory (`$BATS_TMPDIR/$BATS_TEST_NAME`) for state isolation — no shared filesystem state between tests.
- Minimum test count gate: CI must fail if test count is below a threshold (prevents vacuous pass from empty test directory).

**Testability refactor:**
- Guard `main()` with `[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"` so sourcing doesn't execute.
- Export all testable functions.
- Write a smoke test immediately after refactor (source + call one function) before expanding test suite.

**yq migration:**
- yq is a **hard requirement** — no sed fallback. If yq is not installed, `load_role()` aborts with a fatal error.
- Use mikefarah/yq (Go implementation, not kislyuk/yq Python wrapper). Pin minimum version in install.sh: `yq >= 4.x`. Verify after install with `yq --version`.
- Replace sed parsing with: `yq -f extract '.field' roles/$role.md`
- yq's `--front-matter=extract` mode reads between `---` delimiters natively. Single-file processing only (multi-file is broken in yq).

**Tightened cross-validation guard:**
- Validate `mode` against explicit allowlist: must be exactly `read-only` or `read-write`. If empty, null, or any other value → abort.
- For `read-only` mode: validate `disallowedTools` is non-empty AND contains at minimum `Write,Edit,NotebookEdit` (not just "is non-empty").
- Log parsed values before the guard check for audit trail.
- Guard runs identically regardless of parser — same validation code path.

**Key test targets (minimum 5 tests per function):**
- `check_budget()` — normal, exceeded, missing file, corrupted file, concurrent access
- `acquire_target_lock()` / `release_target_lock()` — acquire, deny, stale detection, stale race
- `load_role()` — valid roles, malformed YAML, empty fields, cross-validation abort, mode validation
- `build_prompt()` — prompt assembly with task, context injection
- `resolve_target()` — valid target, disabled target, missing path
- `record_invocation()` — JSONL format, budget update, disk full

**Why coupled:** Tests written against sed-based parsing would break when yq replaces it. Writing tests against the yq interface from the start avoids this dependency. Reverting WS2 requires also reverting WS1's parsing tests.

### WS3 — Log Rotation (via log-cleanup.sh)

- **No newsyslog** — implement rotation directly in `log-cleanup.sh` (already runs via cron, cross-platform bash, no sudo required).
- Rotation logic: if `invocations.jsonl` exceeds size threshold (e.g., 1MB) or age threshold (e.g., 7 days), rotate:
  1. `mv state/invocations.jsonl state/invocations-YYYY-MM-DD.jsonl`
  2. `gzip state/invocations-YYYY-MM-DD.jsonl`
  3. Delete rotated files older than 30 days.
- `status.sh` reads only the current `invocations.jsonl` (today's data). No decompression of rotated files — that's a separate reporting feature if ever needed.
- This must complete before WS4, so the budget lock scans a bounded file.

### WS4 — Budget Atomicity

**Step 1: Fix existing stale lock race condition in target locks.**

The current stale lock pattern has a race: two processes both detect a stale lock, both remove it, both attempt mkdir, one wins. While the loser fails safely (mkdir is atomic), the detection+removal sequence is not atomic. Fix:

- Stale detection: lock directory contains a PID file. Check `kill -0 $pid`. If PID is dead → stale.
- Instead of remove-then-retry, use a rename-then-mkdir approach:
  1. `mv state/locks/target.lock state/locks/target.lock.stale.$$` (atomic rename, namespaced by our PID)
  2. `mkdir state/locks/target.lock` (attempt to acquire)
  3. If mkdir succeeds: clean up `*.stale.$$`, we have the lock.
  4. If mkdir fails: someone else got it. Clean up our stale rename, abort.
- This eliminates the window between remove and mkdir.

**Step 2: Add budget-specific lock using corrected pattern.**

- Budget lock directory: `state/locks/budget.lock/`
- Same corrected pattern as target locks (rename-then-mkdir for stale handling).
- PID file written inside lock directory.
- Trap-based cleanup: budget lock cleanup composed with existing traps using function chaining (`original_trap=$(trap -p EXIT); trap "release_budget_lock; $original_trap" EXIT`).

**Lock ordering — deadlock prevention:**

Budget lock and target lock are **never held simultaneously.** The dispatch sequence is:

```
1. acquire_budget_lock()
2. check_budget()
3. release_budget_lock()
4. acquire_target_lock()     # only for read-write roles
5. invoke_agent()
6. acquire_budget_lock()
7. record_invocation()
8. release_budget_lock()
9. release_target_lock()
```

Budget lock is acquired and released in two separate windows (check and record), both independent of target lock. No nesting. No deadlock possible.

**TOCTOU note:** A process could pass budget check (step 2), then another process increments the count past the limit before step 7. This allows at most N_concurrent_roles extra invocations beyond the cap (typically 1-3). Acceptable — the budget is a rate limit, not a security boundary.

### WS5 — Path Parameterization

- Replace hardcoded paths with `${{ vars.CLAUDE_OPS_HOME }}` in all workflow files.
- **No fallback.** If `vars.CLAUDE_OPS_HOME` is not set, the workflow step fails immediately with: `"CLAUDE_OPS_HOME is not set. Set it via: gh variable set CLAUDE_OPS_HOME --body '/path/to/claude-ops'"`.
- **Input validation in dispatch.sh** (for any source of the path):
  ```bash
  [[ "$CLAUDE_OPS_HOME" =~ ^/[a-zA-Z0-9/_.-]+$ ]] || die "Invalid CLAUDE_OPS_HOME: must be absolute path, no metacharacters"
  [[ -d "$CLAUDE_OPS_HOME" ]] || die "CLAUDE_OPS_HOME does not exist: $CLAUDE_OPS_HOME"
  [[ -f "$CLAUDE_OPS_HOME/config.json" ]] || die "CLAUDE_OPS_HOME missing config.json — is this a claude-ops directory?"
  ```
- Set variable on all target repos first, then merge workflow changes. Document deployment sequence.
- Also audit and parameterize PATH references for Homebrew location.

**Cross-repo coordination:**
1. Set `CLAUDE_OPS_HOME` variable on all target repos: `gh variable set CLAUDE_OPS_HOME --body "/path/to/claude-ops" -R owner/repo`
2. Merge workflow changes to target repos.
3. Variable must exist before workflows reference it, or the step fails immediately (fail-closed).

## Implementation Steps

| # | Step | Files | Risk | Dependency |
|---|------|-------|------|------------|
| 1 | Add bats-core test infrastructure + PATH-stub mocks | `tests/`, `tests/mocks/` | LOW | — |
| 2 | Refactor dispatch.sh for testability (guard main) + smoke test | `scripts/dispatch.sh`, `tests/smoke.bats` | MEDIUM | 1 |
| 3 | Add yq to install.sh as hard requirement, pin version | `scripts/install.sh` | LOW | — |
| 4 | Replace sed parsing with yq in load_role(), tighten cross-validation guard | `scripts/dispatch.sh` | MEDIUM | 2, 3 |
| 5 | Write unit tests for dispatch.sh core functions (against yq-based parsing) | `tests/dispatch.bats` | LOW | 2, 4 |
| 6 | Add JSONL rotation to log-cleanup.sh | `scripts/log-cleanup.sh` | LOW | — |
| 7 | Fix stale lock race in existing target lock pattern | `scripts/dispatch.sh` | MEDIUM | 2 |
| 8 | Add budget lock using corrected pattern, enforce lock ordering | `scripts/dispatch.sh` | MEDIUM | 6, 7 |
| 9 | Write concurrency tests for budget locking | `tests/dispatch.bats` | LOW | 5, 8 |
| 10 | Parameterize CLAUDE_OPS_HOME + input validation | workflow `.yml` files, `scripts/dispatch.sh` | LOW | — |

## Affected Files

| File | Change Type | Description |
|------|-------------|-------------|
| `scripts/dispatch.sh` | Modify | Refactor for testability, yq migration, tightened guard, stale lock fix, budget locking, path validation |
| `scripts/install.sh` | Modify | Add bats-core and yq (pinned) to dependency checks |
| `scripts/log-cleanup.sh` | Modify | Add JSONL rotation (mv + gzip + age-based cleanup) |
| `tests/dispatch.bats` | Create | Unit tests for dispatch.sh functions |
| `tests/smoke.bats` | Create | Post-refactor smoke test |
| `tests/mocks/` | Create | PATH-stub mock scripts for claude, gh, jq, git |
| GitHub Actions workflows (in target repo) | Modify | Parameterize CLAUDE_OPS_HOME, remove fallback |

## Acceptance Criteria

1. `bats tests/` runs and passes all tests with minimum test count >= 30
2. dispatch.sh functions are individually testable (no side effects from sourcing)
3. `load_role()` uses yq (mikefarah/yq v4+), correctly parses all 4 role files, rejects malformed frontmatter
4. If yq is not installed, `load_role()` aborts with fatal error (no sed fallback)
5. Cross-validation guard aborts if: `mode` is not in `{read-only, read-write}`, or read-only role has empty/insufficient disallowedTools
6. Budget updates are serialized — concurrent `check_budget` + `record_invocation` calls don't lose updates
7. Budget lock and target lock are never held simultaneously (no deadlock possible)
8. Stale lock detection uses rename-then-mkdir (no race window between remove and acquire)
9. No hardcoded paths in any workflow file — all use `${{ vars.CLAUDE_OPS_HOME }}`
10. `CLAUDE_OPS_HOME` validated: absolute path, no metacharacters, directory exists, contains config.json
11. If `CLAUDE_OPS_HOME` is unset, workflow aborts immediately (no silent fallback)
12. invocations.jsonl rotated by log-cleanup.sh (size/age threshold, 30-day retention, gzip)
13. All new failure modes fail closed (abort) except `record_invocation()` failure (fail-open with logged error)
14. All existing functionality unchanged (no regressions)
15. Each bats test uses isolated temp directory ($BATS_TMPDIR/$BATS_TEST_NAME)

## Test Strategy

| Test Type | What | How |
|-----------|------|-----|
| Smoke | dispatch.sh sources without side effects | bats, source + call one function |
| Unit | dispatch.sh functions (budget, lock, role, prompt) | bats-core with PATH-stub mocks |
| Unit | load_role() yq parsing + cross-validation guard | bats-core with fixture role files |
| Unit | Mode validation (allowlist, empty, null, invalid) | bats-core with malformed fixtures |
| Concurrency | Budget lock under parallel processes | 20 background jobs (`&`) + wait, verify final count |
| Concurrency | Stale lock detection + recovery | bats, create lock with dead PID, verify cleanup |
| Regression | yq parsing produces correct values for all 4 roles | Assert expected field values per role |
| Edge case | Malformed YAML, empty fields, whitespace, body-matching strings | Explicit test fixtures per case |
| Fail-closed | yq missing, parse error, invalid mode, invalid path | Assert exit code != 0 for each |

## Security Review

- **SECURITY_SENSITIVE**: WS2 (yq migration) changes how tool restrictions are parsed. A parsing bug could silently grant write access to read-only roles.
  - Mitigation: yq is a hard requirement — no sed fallback. Fail closed if yq is missing or returns empty values.
  - Mitigation: Cross-validation guard tightened — validates `mode` against allowlist, validates `disallowedTools` contains minimum expected tools (not just non-empty).
  - Mitigation: Parsed values logged before guard check for audit trail.
- **SECURITY_SENSITIVE**: WS5 (path parameterization) externalizes a previously-hardcoded path into a user-controllable variable.
  - Mitigation: Input validation in dispatch.sh — absolute path, no metacharacters, directory exists, contains config.json.
  - Mitigation: Fail hard if unset — no silent fallback to $HOME.
  - Mitigation: Note: anyone with repo write access can change `vars.CLAUDE_OPS_HOME`. The validation checks (directory must exist and contain config.json) provide defense-in-depth against redirection to a malicious directory.
- WS4 (budget lock): No security impact — budget is a rate limit, not an access control.
- **Supply chain**: yq (mikefarah/yq) is a new runtime dependency in the security-critical parsing path. Mitigated by: pinning minimum version, verifying after install (`yq --version`), specifying exact distribution in install.sh.

## Past Learnings Applied

1. **cross-validate-parsed-role-config**: Parse → trim → validate → fail-loud pattern retained and tightened in yq migration. Guard now validates `mode` against allowlist and checks for minimum disallowedTools set, not just non-empty. Tests explicitly cover the edge cases documented (trailing whitespace, tabs, body-matching strings).
2. **allowedtools-broken-in-bypass-mode**: Confirmed dispatch.sh uses `--disallowedTools` (denylist). Tests verify this flag is passed correctly.
3. **github-actions-self-hosted-runner-security-gotchas**: Workflow input validation patterns applied to path parameterization. Inputs via `env:` variables, not inline `${{ }}`. No silent fallbacks.

## Spec-Flow Analysis

### Flow 1: dispatch.sh invocation (modified)

| Step | Happy Path | Error State | Edge State |
|------|-----------|-------------|------------|
| Load role | yq parses frontmatter | yq not installed → **abort** (fail-closed) | Malformed YAML → **abort** with error |
| Validate mode | mode matches allowlist | mode empty/null/unknown → **abort** | mode has whitespace → trim then validate |
| Validate disallowedTools | non-empty for read-only, contains minimum set | empty for read-only → **abort** | whitespace-only → trim, then abort if empty |
| Acquire budget lock | mkdir succeeds | Already locked → wait briefly, retry once, then **abort** | Stale lock (dead PID) → rename-then-mkdir recovery |
| Check budget | Budget file exists, under limit | File missing → create atomically | Budget exceeded → **abort** with notification |
| Release budget lock | rmdir succeeds | Already released → no-op (idempotent) | Crash during hold → trap cleanup releases |
| Acquire target lock | mkdir succeeds (read-write only) | Already locked → **abort** | Stale lock → rename-then-mkdir recovery |
| Invoke claude | JSON output parsed | Timeout (124) / SIGTERM (143) → log, exit | Empty output → log warning |
| Acquire budget lock | mkdir succeeds | Lock held by another → wait briefly, retry | — |
| Record invocation | JSONL appended, budget incremented | Disk full / permission error → **log error, continue** (fail-open) | — |
| Release budget lock | rmdir succeeds | — | — |
| Release target lock | rmdir succeeds (trap EXIT) | — | — |

### Flow 2: test execution

| Step | Happy Path | Error State | Edge State |
|------|-----------|-------------|------------|
| Source dispatch.sh | Functions loaded, main() guarded | Syntax error → bats reports failure | Missing deps → test skipped with warning |
| Create isolated temp dir | $BATS_TMPDIR/$BATS_TEST_NAME created | mkdir fails → test fails clearly | — |
| Set up PATH stubs | Mock scripts found in tests/mocks/ | Missing mock → test fails with clear error | — |
| Run assertions | All pass | Assertion mismatch → clear diff output | — |
| Teardown | Temp dir cleaned up | Cleanup failure → bats reports | — |

### Flow 3: log rotation

| Step | Happy Path | Error State | Edge State |
|------|-----------|-------------|------------|
| Check file size/age | Exceeds threshold → rotate | File missing → skip (no error) | File empty → skip |
| Rotate (mv + gzip) | New dated file created | mv fails → log error, skip rotation | gzip fails → log error, keep uncompressed |
| Cleanup old rotations | Files older than 30 days deleted | Permission error → log warning | No old files → no-op |

## Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| yq parsing differs from sed in subtle ways | HIGH | Regression tests assert expected field values for all 4 roles. No sed fallback to diverge. |
| Refactoring dispatch.sh for testability introduces regressions | MEDIUM | Smoke test immediately after refactor. Full test suite covers core functions. Dry-run all roles before merging. |
| Budget lock TOCTOU (pass check, then budget exceeded before record) | LOW | At most N_concurrent_roles extra invocations (1-3). Budget is a rate limit, not security boundary. |
| Stale lock rename-then-mkdir has edge cases | LOW | Tested explicitly. Namespaced by PID ($$ in rename). Cleanup on all paths. |
| bats-core not available on runner | MEDIUM | Add to install.sh deps. Tests are dev-only, not needed for production dispatch. |
| yq supply chain compromise | LOW | Pin version, verify after install, specify exact distribution (mikefarah/yq). |
| Cross-repo deployment coordination (WS5) | MEDIUM | Document sequence: set variable first, then merge workflows. Variable must exist before reference. |

## Dependencies

- **New external deps:** bats-core (test only), mikefarah/yq v4+ (runtime, hard requirement)
- **Install method:** `brew install bats-core yq`
- **No newsyslog** — rotation handled by existing log-cleanup.sh (cross-platform)

## Rollback Plan

- **WS1+WS2 (tests + yq):** Coupled rollback — revert load_role() to sed and revert tests that depend on yq interface. Keep sed version in git history for reference.
- **WS3 (log rotation):** Revert log-cleanup.sh rotation logic — invocations.jsonl returns to append-only.
- **WS4 (budget lock):** Remove budget lock code. Stale lock fix in target locks should be kept (independent improvement). Reverts to current concurrent budget behavior.
- **WS5 (paths):** Replace `${{ vars.CLAUDE_OPS_HOME }}` with hardcoded path in workflows.

**Note:** WS1+WS2 are coupled (not independently revertible). WS3, WS4, WS5 are independently revertible.

## Alternatives Considered

1. **sed fallback if yq not installed** — Rejected after review. Falling back to the parser being replaced for security reasons is internally contradictory. Fail closed instead.
2. **shunit2 or ShellSpec instead of bats-core** — Rejected. bats-core is most widely adopted for bash testing.
3. **bats-mock instead of PATH stubs** — Rejected after review. PATH-stub scripts in `tests/mocks/` are simpler, require no extra dependency, and are more readable.
4. **flock for budget atomicity** — Rejected. macOS lacks native flock CLI tool.
5. **newsyslog for log rotation** — Rejected after review. Requires sudo, macOS-only, newsyslog postrotate commands run as root (supply chain risk if conf file is tampered). Rotation in log-cleanup.sh is cross-platform, sudo-free, and already scheduled via cron.
6. **$HOME/claude-ops fallback for CLAUDE_OPS_HOME** — Rejected after review. Silent fallback masks misconfiguration. Fail closed instead.
7. **GitHub secrets instead of vars for CLAUDE_OPS_HOME** — Rejected. Path is not sensitive data. Secrets add unnecessary masking in logs.
8. **status.sh reading rotated/compressed files** — Rejected after review. Scope creep — status.sh reads current invocations.jsonl only. Historical reporting is a separate feature.

## Review Findings Addressed

This plan was revised after a 5-agent review (Architecture, Simplicity, Spec-Flow, Security, Adversarial Validator). Key changes:

1. Dropped sed fallback — yq is a hard requirement (ARCH-001, SIMP-001, SEC-001, AV-008)
2. Defined lock acquisition order — budget and target locks never held simultaneously (FLOW-002)
3. Fixed stale lock race — rename-then-mkdir replaces remove-then-retry (FLOW-001, ARCH-002)
4. Reordered WS3 (rotation) before WS4 (budget lock) to bound file scan (AV-011)
5. Acknowledged WS1↔WS2 coupling — not independently revertible (AV-012)
6. Added fail-closed principle for all failure modes (SEC-007)
7. Tightened cross-validation guard — mode allowlist, minimum disallowedTools set (SEC-003)
8. Added CLAUDE_OPS_HOME input validation — regex, existence, sanity check (SEC-002, FLOW-008)
9. Dropped archival summary and status.sh rotated reads — scope creep (SIMP-002, SIMP-003)
10. Replaced bats-mock with PATH stubs — simpler, no extra dep (SIMP-004)
11. Replaced newsyslog with log-cleanup.sh rotation — no sudo, cross-platform (ARCH-004, SIMP-007, SEC-004)
12. Documented cross-repo deployment sequence for WS5 (ARCH-006)
13. Added per-test temp directory isolation (FLOW-009)
14. Added minimum test count gate (FLOW-006)
15. Pinned yq version + specified distribution (ARCH-007, SEC-005, AV-004)
16. Specified mikefarah/yq explicitly (AV-004)
17. Added invocations.jsonl schema verification to tests (SEC-008)
