# Quick Start Guide

Get claude-ops running on a fresh machine in 10 minutes.

## 1. Clone and install

```bash
git clone https://github.com/austinbrowne/claude-ops.git
cd claude-ops
./scripts/install.sh
```

The installer walks you through everything: dependency checks (offers to install missing ones via Homebrew), GitHub/Claude auth verification, target repo configuration, cron schedule, and runner setup.

## 2. Verify

```bash
# Check everything is configured
./scripts/install.sh --check

# Dry run — prints the prompt without calling Claude
./scripts/dispatch.sh --role product-manager --target <your-target> --task "triage issues" --dry-run
```

## 3. Start the runner

```bash
./scripts/start-runner.sh
```

This starts the GitHub Actions self-hosted runner in a tmux session. It **must** run in tmux (not as a launchd service) so it can access the macOS login keychain where Claude stores its OAuth credentials.

## 4. Set up workflows in your target repo

Copy the thin **caller** templates (not the full workflows) and set repo variables:

```bash
# Copy caller templates (~15 lines each, call reusable workflows in claude-ops)
cp callers/claude-*.yml /path/to/your-repo/.github/workflows/

# Set variables (replace org/repo and target name)
gh variable set CLAUDE_OPS_HOME --body "$(pwd)" --repo dazz-ops/your-repo
gh variable set TARGET_NAME --body "your-target-name" --repo dazz-ops/your-repo

# Commit and push
cd /path/to/your-repo
git add .github/workflows/claude-*.yml
git commit -m "feat: add claude-ops workflow callers"
git push
```

The callers never need updating — all job logic lives in `dazz-ops/claude-ops/.github/workflows/`.

### Kill switch

To disable claude-ops on any repo without removing files:

```bash
gh variable set CLAUDE_OPS_ENABLED --body "false" --repo dazz-ops/your-repo
```

Set back to `true` (or delete the variable) to re-enable.

## 5. Test it

Create a test issue on your target repo:

```bash
gh issue create --repo owner/repo \
  --title "[Test] Verify claude-ops triage" \
  --body "Test issue to verify the triage workflow fires."
```

Watch the workflow run:

```bash
gh run list --repo owner/repo --limit 5
```

The PM agent should triage the issue within a minute — categorize it, add labels, and comment.

## Day-to-day operations

### Monitor

```bash
./scripts/status.sh          # Budget, recent runs, locks, logs
tmux attach -t actions-runner # View runner output (Ctrl+B, D to detach)
tail -f logs/cron.log         # Watch cron activity
```

### Manual dispatch

```bash
# Triage issues
./scripts/dispatch.sh --role product-manager --target my-project --task "triage open issues"

# Implement a specific issue
./scripts/dispatch.sh --role developer --target my-project --task "implement issue #15"

# Review a PR
./scripts/dispatch.sh --role code-reviewer --target my-project --task "review PR #23"

# Architecture review
./scripts/dispatch.sh --role tech-lead --target my-project --task "review recent changes"
```

### Manage the runner

```bash
./scripts/start-runner.sh                    # Start (idempotent)
tmux kill-session -t actions-runner           # Stop
tmux has-session -t actions-runner && echo up # Check
```

### Manage cron

```bash
crontab -l                                   # View installed schedule
./scripts/install.sh --uninstall             # Remove claude-ops cron entries
```

## How the pipeline works

```
1. Issue opened
   → PM Triage: categorizes, labels priority, marks needs_refinement or ready_for_dev

2. Label: needs_refinement
   → PM Enhance: adds acceptance criteria, user stories, affected files

3. Label: ready_for_dev
   → Developer: implements, writes tests, runs /fresh-eyes-review, creates PR

4. PR opened
   → Code Reviewer: independent /fresh-eyes-review, approves or requests changes

5. Human merges PR

6. Friday 15:00
   → Tech Lead: weekly architecture review across all recent changes
```

Each step is triggered by GitHub Actions events (instant) with cron as a fallback (daily catch-up).

## Roles at a glance

| Role | What it does | Mode |
|------|-------------|------|
| **Product Manager** | Triage issues, write acceptance criteria, explore codebase, ideate features | Read-only |
| **Developer** | Implement features, write tests, self-review, create PRs | Read-write |
| **Code Reviewer** | Independent fresh-eyes review on PRs, approve or request changes | Read-only |
| **Tech Lead** | Architecture review, pattern validation, tech debt identification | Read-only |

No agent can merge PRs, push to main, or force push. Humans stay in the loop.

## Adding more target repos

1. Ensure the repo is in the `dazz-ops` org
2. Add to `config.json`:
   ```json
   {"name": "new-repo", "path": "/path/to/new-repo", "branch": "main", "enabled": true}
   ```
3. Copy callers: `cp callers/claude-*.yml /path/to/new-repo/.github/workflows/`
4. Set repo variables: `CLAUDE_OPS_HOME`, `TARGET_NAME`
5. Commit and push the callers

No runner registration needed — the org-level runner handles all repos automatically. Cron also picks up new targets — no schedule changes needed.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| "Not logged in" from runner | Run runner in tmux: `./scripts/start-runner.sh` |
| Agent fails in 0-1 seconds | Check `logs/cron.log` and run `./scripts/install.sh --check` |
| "Daily invocation limit reached" | Wait for next day or increase `max_daily_invocations` in config.json |
| Cron jobs not firing | Verify with `crontab -l` — look for the sentinel block |
| Workflow queued forever | Check runner is online: `gh api orgs/dazz-ops/actions/runners` |
| Want to disable claude-ops temporarily | `gh variable set CLAUDE_OPS_ENABLED --body "false" --repo dazz-ops/your-repo` |

For more details, see the full [README](../README.md) and [CLAUDE.md](../CLAUDE.md).
