# claude-ops

Autonomous agent orchestration for software projects. Dispatches Claude Code CLI agents across four specialized roles — Product Manager, Developer, Code Reviewer, and Tech Lead — to triage issues, implement features, review PRs, and audit architecture.

- **Event-driven**: GitHub Actions trigger agents within minutes of issues, labels, and PRs
- **Cron fallback**: Catches work missed by events (offline runner, API-created issues)
- **Two-pass review**: Developer self-reviews before PR, then an independent Code Reviewer reviews with zero context
- **Human-in-the-loop**: No agent can merge PRs, push to main, or force push

## Table of Contents

- [How It Works](#how-it-works)
- [Architecture](#architecture)
- [Roles](#roles)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Self-Hosted Runner Setup](#self-hosted-runner-setup)
- [Configuration](#configuration)
- [Trigger Architecture](#trigger-architecture)
- [Usage](#usage)
- [Safety & Permissions](#safety--permissions)
- [Monitoring](#monitoring)
- [Adding a Target Repository](#adding-a-target-repository)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)
- [Project Structure](#project-structure)

## How It Works

```
Issue opened          Label: ready_for_dev        PR opened/updated
     │                       │                          │
     ▼                       ▼                          ▼
 ┌────────┐           ┌───────────┐              ┌────────────┐
 │   PM   │           │ Developer │              │   Code     │
 │ Triage │──label──▶ │ Implement │──creates──▶  │  Reviewer  │
 └────────┘           └───────────┘    PR        └────────────┘
     │                       │                          │
     │ needs_refinement      │ self-review              │ independent
     ▼                       │ (/fresh-eyes-review)     │ /fresh-eyes-review
 ┌────────┐                  │                          │
 │   PM   │                  ▼                          ▼
 │Enhance │            Push + PR ◀──────────── approve/request changes
 └────────┘                  │
                             ▼
                     Human merges PR
                             │
                     ┌───────────────┐
                     │   Tech Lead   │
                     │ Weekly Review │
                     └───────────────┘
```

**Hybrid trigger model:** GitHub Actions workflows in target repos fire on events (issue opened, label added, PR created). These run on a self-hosted runner (e.g., a Mac Mini) and call the same job scripts that cron uses. Cron runs at reduced frequency as a fallback to catch anything events missed.

## Architecture

```
claude-ops/
├── config.json              # Machine-specific targets and settings (gitignored)
├── config.template.json     # Template for config.json (committed)
├── roles/                   # Agent persona definitions (prompt + tool restrictions)
├── jobs/                    # Job scripts (called by Actions and cron)
├── scripts/                 # Core tooling: dispatcher, installer, status, shared lib
├── workflows/               # GitHub Actions workflow templates (copy to target repos)
├── schedules/               # Generated crontab (from install.sh)
├── tests/                   # Bats test suite
├── docs/                    # Plans and solution docs
├── state/                   # Runtime state: budgets, locks, invocations (gitignored)
└── logs/                    # Run logs and stderr captures (gitignored)
```

| Directory | Purpose |
|-----------|---------|
| `roles/` | One Markdown file per role. YAML frontmatter defines tool access and mode. Body is the system prompt. |
| `jobs/` | Thin shell scripts that call `dispatch.sh` with a role, target, and task description. Include polling guards to skip when there's no work. Support multi-target: no args loops all enabled targets, `$1` runs one target. |
| `scripts/` | `dispatch.sh` (core dispatcher), `lib.sh` (shared helpers for target enumeration and polling guards), `install.sh` (setup), `status.sh` (dashboard), `log-cleanup.sh` (rotation). |
| `workflows/` | GitHub Actions workflow templates. Copy to each target repo's `.github/workflows/` directory. |
| `docs/plans/` | Planning documents for in-progress features. |
| `docs/solutions/` | Captured learnings from solved problems (searchable knowledge base). |

## Roles

| Role | Mode | Capabilities | Restrictions |
|------|------|-------------|--------------|
| **Product Manager** | read-only | Triage issues, enhance with acceptance criteria, explore codebase, brainstorm features, file new issues | Cannot modify code, create branches, or push |
| **Developer** | read-write | Implement features, write tests, create branches, commit, push, create PRs, run `/fresh-eyes-review` | Cannot merge PRs, push to main, or force push |
| **Code Reviewer** | read-only | Checkout PR branches, run `/fresh-eyes-review`, post review comments, approve or request changes | Cannot modify code, commit, push, or merge |
| **Tech Lead** | read-only | Review architecture, validate patterns, identify tech debt, file architecture issues and ADR proposals | Cannot modify code, create branches, or push |

**Enforcement:** Read-only roles use `--disallowedTools Write,Edit,NotebookEdit` to block file modifications at the CLI level. The Developer role has no disallowed tools but is constrained by its system prompt (no merges, no force push, no push to main). All roles run under `--dangerously-skip-permissions` for headless operation — tool restrictions are enforced via `--disallowedTools` (denylist), not `--allowedTools` (which is [broken in bypass mode](https://github.com/anthropics/claude-code/issues/12232)).

## Prerequisites

| Dependency | Required | Purpose | Install |
|------------|----------|---------|---------|
| bash | Yes | Script runner | Pre-installed on macOS/Linux |
| jq | Yes | JSON parsing (config, state, budget) | `brew install jq` / `apt install jq` |
| git | Yes | Version control | `brew install git` / `apt install git` |
| [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) | Yes | Agent runtime (`claude -p`) | `npm install -g @anthropic-ai/claude-code` |
| [GitHub CLI](https://cli.github.com/) | Yes | Issue/PR operations | `brew install gh` / `apt install gh` |
| [yq](https://github.com/mikefarah/yq) (v4+) | Yes | YAML frontmatter parsing in role files | `brew install yq` |
| [bats-core](https://github.com/bats-core/bats-core) | Optional | Test framework (dev only) | `brew install bats-core` |
| timeout / gtimeout | Optional | Worker timeout enforcement | `brew install coreutils` (for gtimeout on macOS) |
| terminal-notifier | Optional | macOS desktop notifications | `brew install terminal-notifier` |

## Installation

```bash
git clone <repo-url> && cd claude-ops
./scripts/install.sh
```

The installer runs these steps interactively:

1. **Dependency check** — verifies all required tools are installed and on PATH
2. **Auto-install** — offers to install missing dependencies via Homebrew and npm
3. **GitHub auth validation** — confirms `gh` is authenticated with `repo` scope
4. **Claude CLI validation** — smoke-tests `claude -p` to verify subscription
5. **Directory setup** — creates `state/` and `logs/`, makes scripts executable
6. **Config generation** — copies `config.template.json` to `config.json`, prompts to add target repos
7. **Crontab generation** — writes schedule to `schedules/crontab` with correct paths
8. **Crontab installation** — optionally installs the schedule (sentinel-based, idempotent)
9. **Runner setup** — offers to download and configure the GitHub Actions self-hosted runner

### Install flags

```bash
./scripts/install.sh              # Full interactive setup
./scripts/install.sh --check      # Check dependencies and auth only (no changes)
./scripts/install.sh --uninstall  # Remove claude-ops entries from crontab
```

## Self-Hosted Runner Setup

The GitHub Actions self-hosted runner must run in a **tmux session** rather than as a launchd service. This is required because the Claude Code CLI accesses OAuth credentials via the macOS login keychain, which is not available to launchd services. See `docs/solutions/launchd-keychain-access.md` for the full analysis.

### Option A: Automatic (via install.sh)

The installer offers to download and configure the runner during `./scripts/install.sh`. It detects your architecture (arm64/x86_64), downloads the correct binary, and runs `config.sh --unattended`.

### Option B: Manual

1. Download the runner from [GitHub Actions Runner Releases](https://github.com/actions/runner/releases)
2. Extract to `~/actions-runner` (or any directory)
3. Configure: `./config.sh --url https://github.com/OWNER/REPO --token <token>`
4. Start via tmux:

```bash
./scripts/start-runner.sh                    # Default: ~/actions-runner
./scripts/start-runner.sh /path/to/runner    # Custom directory
```

### Managing the runner

```bash
# Start (idempotent — skips if session exists)
./scripts/start-runner.sh

# View runner output
tmux attach -t actions-runner

# Stop
tmux kill-session -t actions-runner
```

> **Note:** The tmux session does not survive a reboot. Add `./scripts/start-runner.sh` to your login items or shell profile if auto-start is needed.

## Configuration

`config.json` is generated from `config.template.json` during installation. It is gitignored (machine-specific paths).

```jsonc
{
  "targets": [
    {
      "name": "my-project",           // Short name used in --target flag
      "path": "/Users/you/repos/my-project",  // Absolute path to local clone
      "branch": "main",               // Main branch name
      "enabled": true                  // Set false to skip this target
    }
  ],
  "defaults": {
    "worker_timeout": 600,             // Max seconds per agent invocation
    "max_daily_invocations": 30,       // Daily budget cap across all roles
    "log_retention_days": 7,           // Days to keep log files
    "cron_enabled": true               // false = event-driven only (no cron fallback)
  },
  "notifications": {
    "enabled": false,                  // Desktop notifications on events
    "method": "terminal-notifier",     // or "osascript"
    "on_error": true,                  // Notify on agent failures
    "on_pr_created": true,             // Notify when a PR is created
    "on_budget_exceeded": true         // Notify when daily cap is hit
  }
}
```

### Adding a target

Edit `config.json` and add an entry to the `targets` array, or re-run `./scripts/install.sh` to use the interactive prompt.

## Trigger Architecture

### Event-Driven (Primary)

GitHub Actions workflows live in the **target repository** and run on a self-hosted runner. Each workflow calls the corresponding job script in claude-ops.

| GitHub Event | Workflow | Job Script | Role |
|-------------|----------|-----------|------|
| Issue opened | `claude-triage.yml` | `jobs/pm-triage.sh` | Product Manager |
| Label `needs_refinement` added | `claude-enhance.yml` | `jobs/pm-enhance.sh` | Product Manager |
| Label `ready_for_dev` added | `claude-implement.yml` | `jobs/dev-implement.sh` | Developer |
| PR opened or synchronized | `claude-review.yml` | `jobs/dev-review-prs.sh` | Code Reviewer |
| Weekly (Friday 15:00) | `claude-tech-review.yml` | `jobs/tech-lead-review.sh` | Tech Lead |
| Manual (GitHub UI) | `claude-dispatch.yml` | `scripts/dispatch.sh` | Any |

### Cron Fallback

Reduced-frequency schedule that catches work missed by events. Each job has a **polling guard** — it checks for open issues/PRs before dispatching and skips if there's nothing to do.

| Time | Job | Purpose |
|------|-----|---------|
| 09:00 daily | PM Triage | Categorize and prioritize open issues |
| 10:00 daily | PM Enhance | Flesh out `needs_refinement` issues |
| 11:00 daily | Developer (1/3) | Implement `ready_for_dev` issues |
| 13:00 daily | Code Reviewer (1/3) | Fresh-eyes review open PRs |
| 15:00 daily | Developer (2/3) | Implement |
| 17:00 daily | Code Reviewer (2/3) | Review PRs |
| 19:00 daily | Developer (3/3) | Implement |
| 21:00 daily | Code Reviewer (3/3) | Review PRs |
| 08:00 Monday | PM Explore | Codebase exploration + feature ideation |
| 15:00 Friday | Tech Lead | Weekly architecture review |
| 03:00 Sunday | Log Cleanup | Rotate logs and old budget files |

Cron can be disabled entirely by setting `"cron_enabled": false` in config.json — the system will then operate in event-driven mode only.

## Usage

### Dispatch an agent manually

```bash
# Dry run — prints the prompt without invoking Claude
./scripts/dispatch.sh \
  --role product-manager \
  --target my-project \
  --task "triage open issues" \
  --dry-run

# Live run
./scripts/dispatch.sh \
  --role developer \
  --target my-project \
  --task "implement issue #42"

# With custom timeout (seconds)
./scripts/dispatch.sh \
  --role code-reviewer \
  --target my-project \
  --task "review open PRs" \
  --timeout 1800
```

### dispatch.sh flags

| Flag | Required | Description |
|------|----------|-------------|
| `--role` | Yes | Role name (matches `roles/<name>.md`) |
| `--target` | Yes | Target repo name (matches `config.json` targets) |
| `--task` | Yes | Task description for the agent |
| `--timeout` | No | Override worker timeout in seconds (default: from config) |
| `--dry-run` | No | Print the prompt without invoking Claude |
| `--help` | No | Show usage |

### Check status

```bash
./scripts/status.sh
```

Shows: today's invocation count vs. budget, recent invocation log, active locks, recent log files, and cron installation status.

### Common workflows

```bash
# Manual triage after creating issues via API
./scripts/dispatch.sh --role product-manager --target my-project --task "triage open issues"

# Kick off implementation for a specific issue
./scripts/dispatch.sh --role developer --target my-project --task "implement issue #15"

# Review a specific PR
./scripts/dispatch.sh --role code-reviewer --target my-project --task "review PR #23"

# Architecture review on demand
./scripts/dispatch.sh --role tech-lead --target my-project --task "review recent changes for architecture concerns"
```

## Safety & Permissions

| Mechanism | Description |
|-----------|-------------|
| **Role boundaries** | Four roles with explicit capability lists. Read-only roles block Write/Edit/NotebookEdit via `--disallowedTools`. |
| **Two-pass review** | Developer runs `/fresh-eyes-review` on its own code. Code Reviewer runs an independent review on the PR with zero context. |
| **No merge capability** | No agent can merge PRs, push to main, or force push. Human merges after inspection. |
| **Daily budget cap** | Default 30 invocations/day across all roles. Tracked in `state/budget-YYYY-MM-DD.json`. |
| **Per-target locking** | Read-write roles acquire an exclusive directory lock before dispatch. Read-only roles skip locking (safe to overlap). Stale lock recovery uses atomic rename-then-mkdir. |
| **Budget locking** | Serializes budget check and record across concurrent dispatches. Never held simultaneously with target lock (prevents deadlock). |
| **Clean working tree check** | Read-write roles verify the target repo has no uncommitted changes before dispatch. |
| **Path validation** | `OPS_ROOT` is validated as an absolute path with no metacharacters — defends against injection when set via GitHub Actions vars. |
| **Polling guards** | Cron jobs check for work before dispatching (e.g., skip if no open issues). Prevents wasted invocations. |
| **Prompt injection defense** | Task text is wrapped in `<task>` XML delimiters with an explicit instruction to treat contents as data, not instructions. |
| **Crontab sentinels** | `# BEGIN claude-ops managed block` / `# END claude-ops managed block` markers enable idempotent installs. Missing END marker aborts to prevent data loss. |

## Monitoring

### Status dashboard

```bash
./scripts/status.sh
```

Displays:
- **Today's usage**: invocations consumed vs. daily budget, total runtime
- **Recent invocations**: last 10 runs with timestamp, role, target, duration, exit code
- **Active locks**: which targets are locked and by which PID (alive/dead)
- **Recent logs**: latest log files with line counts
- **Cron status**: whether the schedule is installed and how many jobs

### Logs

| Location | Contents |
|----------|----------|
| `logs/<timestamp>-<role>.log` | Full agent output per invocation |
| `logs/worker-latest.stderr` | Stderr from the most recent `claude -p` call |
| `logs/cron.log` | Cron job output (polling guard skips, warnings) |
| `state/invocations.jsonl` | Structured invocation log (role, target, duration, exit code, token usage) |
| `state/budget-YYYY-MM-DD.json` | Daily invocation count and total runtime |

### Log rotation

`log-cleanup.sh` runs weekly (Sunday 03:00) and:
- Deletes `.log` and `.stderr` files older than `log_retention_days` (default: 7)
- Deletes budget files older than 30 days
- Rotates `invocations.jsonl` by size (>1MB) or age (>7 days), compresses with gzip
- Deletes rotated JSONL files older than 30 days

## Adding a Target Repository

### 1. Configure claude-ops

Add the repo to `config.json`:

```json
{
  "targets": [
    {
      "name": "my-new-repo",
      "path": "/absolute/path/to/my-new-repo",
      "branch": "main",
      "enabled": true
    }
  ]
}
```

> **Budget note:** `max_daily_invocations` is shared across all targets. If you add multiple targets, consider increasing the cap proportionally (e.g., 30 per target).

### 2. Set up GitHub Actions in the target repo

Copy the workflow templates from `workflows/` to the target repo's `.github/workflows/` directory:

```bash
cp workflows/claude-*.yml /path/to/my-new-repo/.github/workflows/
```

Then set two **repository variables** (Settings > Secrets and variables > Actions > Variables):

| Variable | Value | Example |
|----------|-------|---------|
| `CLAUDE_OPS_HOME` | Absolute path to claude-ops on the self-hosted runner | `/Users/me/claude-ops` |
| `TARGET_NAME` | Matches `config.json` targets[].name | `my-new-repo` |

Available workflow templates:

| Template | Trigger | What it does |
|----------|---------|-------------|
| `claude-triage.yml` | Issue opened | Triages the specific issue by number |
| `claude-enhance.yml` | Label `needs_refinement` added | Enhances the specific issue |
| `claude-implement.yml` | Label `ready_for_dev` added | Implements the specific issue |
| `claude-review.yml` | PR opened/synchronized | Fresh-eyes reviews the PR (rejects fork PRs) |
| `claude-tech-review.yml` | Weekly (Friday 15:00) + manual | Architecture review |
| `claude-dispatch.yml` | Manual (workflow_dispatch) | Any role with custom task |

All templates include path validation, concurrency groups, and security protections. The event-driven workflows call `dispatch.sh` directly with the issue/PR number from the event context.

### 3. Cron fallback (optional)

Job scripts in `jobs/` automatically loop all enabled targets when run without arguments (cron mode). No per-target configuration is needed — just add the target to `config.json` and cron picks it up.

```bash
# Cron runs:
jobs/pm-triage.sh              # loops all enabled targets

# Actions/manual runs:
jobs/pm-triage.sh my-new-repo  # runs for one target only
```

## Testing

Tests use [bats-core](https://github.com/bats-core/bats-core) (Bash Automated Testing System).

```bash
# Run all tests
bats tests/

# Run a specific test file
bats tests/dispatch.bats

# Run with verbose output
bats --verbose-run tests/
```

The test suite covers dispatch.sh with 124 tests across these areas:

| Test File | Coverage |
|-----------|----------|
| `args.bats` | Argument parsing, missing/invalid flags |
| `budget.bats` | Daily invocation limits, budget file creation |
| `concurrency.bats` | Concurrent budget access, race conditions |
| `config.bats` | Config loading, target resolution, disabled targets |
| `install.bats` | Dependency checks, crontab generation, sentinel handling |
| `locking.bats` | Target lock acquire/release, stale lock recovery |
| `ops_root.bats` | OPS_ROOT validation, path traversal defense |
| `role.bats` | Role loading, mode validation, disallowedTools enforcement |
| `smoke.bats` | End-to-end dispatch with mocked claude CLI |
| `summary.bats` | Output summary parsing, missing sentinels |

Tests use mocks in `tests/mocks/` and fixtures in `tests/fixtures/` to avoid calling real external services.

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| `claude: command not found` | Claude Code CLI not installed or not on PATH | `npm install -g @anthropic-ai/claude-code` and ensure it's on your PATH |
| `Not logged in` (from runner) | Runner is a launchd service (no keychain access) | Run the runner in a tmux session instead: `./scripts/start-runner.sh` |
| `yq: command not found` | yq not installed | `brew install yq` (must be mikefarah/yq v4+, not the Python wrapper) |
| `gh: not authenticated` | GitHub CLI not logged in | `gh auth login --scopes repo` |
| `Daily invocation limit reached` | Budget cap hit (default: 30/day) | Wait for next day, or increase `max_daily_invocations` in config.json |
| `Target is locked by another agent` | A read-write role is running against the same target | Wait for it to finish, or check if the PID is stale (status.sh shows alive/dead) |
| `Stale lock detected` | Previous agent crashed without releasing lock | dispatch.sh auto-recovers stale locks (dead PID). If stuck, manually remove `state/locks/<target>.lock/` |
| `Target repo has uncommitted changes` | Previous run crashed mid-implementation | Inspect the target repo: `cd <path> && git status`. Stash or reset as appropriate. |
| `Role has no mode field` | Role markdown is missing `mode:` in frontmatter | Add `mode: read-only` or `mode: read-write` to the role's YAML frontmatter |
| `Read-only but no disallowedTools` | Safety check: read-only roles must block write tools | Add `disallowedTools: Write,Edit,NotebookEdit` to the role's frontmatter |
| Cron jobs not running | Crontab not installed, or `cron_enabled: false` | Run `./scripts/install.sh` and choose to install crontab. Check `crontab -l` for the sentinel block. |
| `OPS_ROOT missing config.json` | dispatch.sh can't find the claude-ops directory | Ensure `CLAUDE_OPS_HOME` env var (if set) points to the correct path |

## Project Structure

```
claude-ops/
├── config.template.json        # Config template (committed)
├── config.json                 # Machine-specific config (gitignored)
├── CLAUDE.md                   # AI agent instructions for this repo
├── README.md                   # This file
│
├── roles/                      # Agent persona definitions
│   ├── product-manager.md      # Read-only: triage, enhance, explore, ideate
│   ├── developer.md            # Read-write: implement, test, self-review, PR
│   ├── code-reviewer.md        # Read-only: fresh-eyes review open PRs
│   └── tech-lead.md            # Read-only: architecture review, ADR proposals
│
├── jobs/                       # Job scripts (called by Actions + cron)
│   ├── pm-triage.sh            # Categorize and prioritize open issues
│   ├── pm-enhance.sh           # Flesh out needs_refinement issues
│   ├── pm-explore.sh           # Weekly codebase exploration + ideation
│   ├── dev-implement.sh        # Implement → self-review → fix → PR
│   ├── dev-review-prs.sh       # Independent fresh-eyes review on open PRs
│   └── tech-lead-review.sh     # Weekly architecture review
│
├── scripts/
│   ├── install.sh              # Setup: deps, auth, config, runner, crontab
│   ├── dispatch.sh             # Core dispatcher: role loading, locking, budget, claude -p
│   ├── lib.sh                  # Shared helpers: target enumeration, polling guards
│   ├── status.sh               # Status dashboard
│   ├── start-runner.sh         # Start GitHub Actions runner in tmux session
│   └── log-cleanup.sh          # Weekly log rotation and cleanup
│
├── workflows/                  # GitHub Actions workflow templates (copy to target repos)
│   ├── claude-triage.yml       # Issue opened → PM triage
│   ├── claude-enhance.yml      # Label needs_refinement → PM enhance
│   ├── claude-implement.yml    # Label ready_for_dev → Developer implement
│   ├── claude-review.yml       # PR opened/synced → Code Reviewer review
│   ├── claude-tech-review.yml  # Weekly + manual → Tech Lead review
│   └── claude-dispatch.yml     # Manual dispatch (any role)
│
├── schedules/
│   └── crontab                 # Generated crontab (install.sh writes this)
│
├── tests/                      # Bats test suite (124 tests)
│   ├── *.bats                  # Test files
│   ├── fixtures/               # Test fixture data
│   ├── mocks/                  # Mock binaries for testing
│   └── test_helper.bash        # Shared test utilities
│
├── docs/
│   ├── plans/                  # Planning documents
│   └── solutions/              # Captured learnings (searchable knowledge base)
│
├── state/                      # Runtime state (gitignored)
│   ├── budget-YYYY-MM-DD.json  # Daily invocation tracking
│   ├── invocations.jsonl       # Structured invocation log
│   └── locks/                  # Per-target directory locks
│
└── logs/                       # Run logs (gitignored)
    ├── <timestamp>-<role>.log  # Full output per invocation
    ├── worker-latest.stderr    # Stderr from latest claude -p call
    └── cron.log                # Cron job output
```
