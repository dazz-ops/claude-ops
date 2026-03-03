# claude-ops

Autonomous agent orchestration system. Uses **GitHub Actions event-driven triggers** (primary) and **cron fallback** (catch-up) to invoke Claude Code CLI across four roles (PM, Developer, Code Reviewer, Tech Lead) targeting repos with the godmode protocol installed.

The Mac Mini acts as a self-hosted GitHub Actions runner, reacting to GitHub events within minutes. Cron serves as a reduced-frequency fallback for missed events.

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
│   ├── install.sh              # Setup: deps, auth, config, crontab
│   ├── dispatch.sh             # Core dispatcher: loads role, invokes claude -p
│   ├── lib.sh                  # Shared helpers: target enumeration, polling guards
│   ├── status.sh               # Dashboard
│   └── log-cleanup.sh          # Weekly cleanup
├── workflows/                  # GitHub Actions workflow templates (copy to target repos)
├── docs/plans/                 # Planning documents
├── docs/solutions/             # Captured learnings
├── state/                      # Runtime (gitignored)
└── logs/                       # Run logs (gitignored)
```

### Trigger Architecture (Hybrid)

```
GitHub Event (issue opened, PR created, label added)
  → GitHub Actions workflow fires (in target repo, from workflows/ templates)
  → Runs on self-hosted runner (Mac Mini)
  → Calls dispatch.sh with target name + event context
  → dispatch.sh handles everything: role, locking, budget, claude -p, logging

Cron (fallback — daily 22:00 for most jobs)
  → Same jobs/*.sh scripts
  → Polling guards skip if no work remains (deduplication)
```

| Trigger | Workflow | Job Script |
|---------|----------|-----------|
| Issue opened | `claude-triage.yml` | `pm-triage.sh` |
| Label `needs_refinement` | `claude-enhance.yml` | `pm-enhance.sh` |
| Label `ready_for_dev` | `claude-implement.yml` | `dev-implement.sh` |
| PR opened/synchronized | `claude-review.yml` | `dev-review-prs.sh` |
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
  → Code Reviewer runs independent fresh-eyes review on PR → [approve/request changes]
  → Human merges → Tech Lead reviews architecture (Friday)
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
