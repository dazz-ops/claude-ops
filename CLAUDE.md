# claude-ops

Autonomous agent orchestration system. Uses **GitHub Actions event-driven triggers** (primary) and **cron fallback** (catch-up) to invoke Claude Code CLI across four roles (PM, Developer, Code Reviewer, Tech Lead) targeting repos in the `dazz-ops` GitHub organization.

The Mac Mini acts as an org-level self-hosted GitHub Actions runner, reacting to GitHub events within minutes. Cron serves as a reduced-frequency fallback for missed events. Workflow logic is centralized via **reusable workflows** — target repos contain only thin caller files (~15 lines).

## Quick Start

```bash
./scripts/install.sh          # Check deps, configure targets, generate crontab
./scripts/install.sh --check  # Check dependencies only
./scripts/dispatch.sh --role product-manager --target <name> --task "triage issues" --dry-run
./scripts/status.sh           # Dashboard
```

## Architecture

```
claude-ops/
├── config.template.json        # Template (committed) — install.sh generates config.json
├── config.json                 # Machine-specific (gitignored)
├── roles/                      # Agent personas (prompt + tool restrictions)
│   ├── product-manager.md      # Read-only: triage, enhance, explore, ideate
│   ├── developer.md            # Read-write: implement, self-review, PR
│   ├── code-reviewer.md        # Read-only: fresh-eyes review open PRs
│   └── tech-lead.md            # Read-only: architecture, patterns, tech debt
├── jobs/                       # Job scripts (called by both Actions and cron)
│   ├── pm-triage.sh            # Categorize and prioritize issues
│   ├── pm-enhance.sh           # Flesh out needs_refinement issues
│   ├── pm-explore.sh           # Explore codebase + ideate new features
│   ├── dev-implement.sh        # Implement → self-review → fix → PR
│   ├── dev-review-prs.sh       # Fresh-eyes review all open PRs
│   └── tech-lead-review.sh     # Architecture review
├── schedules/
│   └── crontab                 # Reduced-frequency fallback (hybrid mode)
├── scripts/
│   ├── install.sh              # Setup: deps, auth, config, runner, crontab
│   ├── dispatch.sh             # Core dispatcher: loads role, invokes claude -p
│   ├── lib.sh                  # Shared helpers: target enumeration, polling guards
│   ├── status.sh               # Dashboard
│   ├── start-runner.sh         # Start GitHub Actions runner in tmux session
│   └── log-cleanup.sh          # Weekly cleanup
├── .github/workflows/          # Reusable workflows (workflow_call — job logic lives here)
├── callers/                    # Thin caller templates for target repos (~15 lines each)
├── workflows/                  # Legacy workflow templates (deprecated — use callers/ instead)
├── docs/plans/                 # Planning documents
├── docs/solutions/             # Captured learnings
├── state/                      # Runtime (gitignored)
└── logs/                       # Run logs (gitignored)
```

### Trigger Architecture (Hybrid)

```
GitHub Event (issue opened, PR created, label added)
  → Thin caller workflow fires (in target repo, from callers/ templates)
  → Calls reusable workflow in dazz-ops/claude-ops/.github/workflows/
  → Runs on org-level self-hosted runner (Mac Mini)
  → Calls dispatch.sh with target name + event context
  → dispatch.sh handles everything: role, locking, budget, claude -p, logging

Cron (fallback — daily catch-up)
  → Same jobs/*.sh scripts
  → Polling guards skip if no work remains (deduplication)
```

**Kill switch:** Set `CLAUDE_OPS_ENABLED=false` as a repo variable on any target repo to disable all claude-ops workflows instantly.

| Trigger | Workflow | Job Script |
|---------|----------|-----------|
| Issue opened | `claude-triage.yml` | `pm-triage.sh` |
| Label `needs_refinement` | `claude-enhance.yml` | `pm-enhance.sh` |
| Label `ready_for_dev` | `claude-implement.yml` | `dev-implement.sh` |
| PR opened/synchronized | `claude-review.yml` | `dev-review-prs.sh` |
| PR review: changes requested | `claude-fix-review.yml` | `dispatch.sh` (developer) |
| Weekly Fri 15:00 | `claude-tech-review.yml` | `tech-lead-review.sh` |
| Manual (GitHub UI) | `claude-dispatch.yml` | `dispatch.sh` |

## Schedule

### Primary: Event-Driven (GitHub Actions)

Jobs fire within minutes of the triggering event. No fixed schedule — reacts in real time.

| Event | Action |
|-------|--------|
| Issue opened | PM Triage |
| Label `needs_refinement` | PM Enhance |
| Label `ready_for_dev` | Developer Implement |
| PR opened/updated | Code Reviewer Review |
| PR review: changes requested | Developer Fix Review Findings |
| Manual trigger | Any role via dispatch |

### Fallback: Cron (Catch-Up)

<!-- SYNC: this schedule must match install.sh generate_crontab() -->

Reduced frequency. Catches work missed by events (offline runner, API-created issues).

```
09:00      PM Triage             — catch issues without events (email/API-created)
10:00      PM Enhance            — flesh out needs_refinement issues
11:00      Developer (slot 1/3)  — implement ready_for_dev issues
13:00      Code Reviewer (1/3)   — fresh-eyes review open PRs
15:00      Developer (slot 2/3)  — implement
17:00      Code Reviewer (2/3)   — review PRs
19:00      Developer (slot 3/3)  — implement
21:00      Code Reviewer (3/3)   — review PRs
08:00 Mon  PM Explore/Ideate    — discover gaps, brainstorm features, file issues
15:00 Fri  Tech Lead             — weekly architecture review
03:00 Sun  Log Cleanup
```

## Flow

```
PM files/enhances issues → [ready_for_dev]
  → Developer implements + self-reviews → [PR]
  → Code Reviewer runs independent fresh-eyes review on PR
    → [approve] → Human merges → Tech Lead reviews architecture (Friday)
    → [request changes] → Developer fixes findings → push → re-review (loop)
```

The Developer runs `/fresh-eyes-review` on its own code and fixes all findings before creating the PR (first review pass). The Code Reviewer then runs a second independent `/fresh-eyes-review` on the PR with zero context (second review pass). This catches issues the first pass missed.

Human merges PRs after inspecting them. No agent can merge.

## Why Two Review Passes

A single fresh-eyes review doesn't catch everything. The implementing Developer has implicit context that can blind its review. The Code Reviewer:
- Has zero context about the implementation (true fresh eyes)
- Reviews the PR diff against main (not staged changes)
- Posts findings directly on the PR for human visibility
- Can approve or request changes

## Safety

- Four roles, clear boundaries: PM reads + files issues, Developer writes code, Code Reviewer reads + reviews PRs, Tech Lead reads + advises
- Two-pass review: Developer self-reviews, then Code Reviewer provides independent review
- **Review action enforcement:** Code Reviewer MUST use `--request-changes` for FIX_BEFORE_COMMIT verdicts and `--approve` for clean reviews. This maps to GitHub's review state so humans can trust the PR status at a glance. See `roles/code-reviewer.md` Review Action Protocol.
- **Recommended branch protection:** Enable "Require approvals" on the target repo's main branch. This ensures no PR merges without the Code Reviewer's explicit approval, creating a hard gate that the agent cannot bypass.
- Read-only roles skip target lock (safe to overlap)
- Read-write roles verify clean working tree before dispatch
- No agent can merge PRs, push to main, or force push
- Daily invocation cap (default 30/day)
- `--dangerously-skip-permissions` required for headless mode — tool access enforced via `--disallowedTools` (denylist; `--allowedTools` whitelist is broken in bypass mode, see GitHub issue #12232)

## Installation

```bash
git clone <repo-url> && cd claude-ops
./scripts/install.sh
```

Requires: bash, jq, git, claude (Claude Code CLI), gh (GitHub CLI authenticated with repo scope)

The installer will auto-detect missing dependencies and offer to install them via Homebrew/npm. It also offers to download and configure the GitHub Actions self-hosted runner.

## Runner Setup

The self-hosted GitHub Actions runner **must run in a tmux session**, not as a launchd service. This is because the Claude Code CLI stores OAuth credentials in `~/.claude/` and accesses them via the macOS login keychain. launchd services run outside the user's login session and cannot access the keychain, causing `claude -p` to fail with "Not logged in."

```bash
# Start the runner (idempotent — skips if session exists)
./scripts/start-runner.sh

# Or with a custom runner directory
./scripts/start-runner.sh /path/to/actions-runner

# Attach to see runner output
tmux attach -t actions-runner

# Stop the runner
tmux kill-session -t actions-runner
```

See `docs/solutions/launchd-keychain-access.md` for the full analysis.

### HOME in cron environments

Cron and GitHub Actions runner environments may not inherit `HOME`. dispatch.sh sets it explicitly:

```bash
export HOME="${HOME:-$(eval echo ~"$(whoami)")}"
```

The generated crontab also includes `HOME=...` in its environment block.
