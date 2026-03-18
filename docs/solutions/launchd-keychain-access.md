---
title: "launchd services cannot access macOS login keychain"
date: 2026-03-18
category: infrastructure
tags: [macos, launchd, keychain, tmux, github-actions, self-hosted-runner, claude-code]
severity: high
confidence: high
---

# launchd Services Cannot Access macOS Login Keychain

## Problem

When running the GitHub Actions self-hosted runner as a macOS launchd service (the official `svc.sh install` method), the Claude Code CLI fails with "Not logged in" even though `claude login` was completed successfully by the user.

The runner starts jobs, but every `claude -p` invocation fails because it cannot find OAuth credentials.

## Root Cause

The Claude Code CLI stores OAuth credentials in `~/.claude/` and accesses them via the macOS login keychain. launchd services run in a different security context from the user's login session:

- **Login session** (Terminal, tmux): has access to the user's login keychain, which is unlocked when the user logs in
- **launchd service**: runs outside the login session, even when configured as a user-level agent (`~/Library/LaunchAgents/`). The login keychain is not available in this context

This is a macOS security boundary, not a bug. The keychain is tied to the login session, not the user identity.

## Fix

Run the GitHub Actions runner in a **tmux session** instead of as a launchd service. tmux sessions inherit the login session context and can access the keychain.

```bash
# Start the runner in a tmux session (idempotent)
./scripts/start-runner.sh

# Or manually:
tmux new-session -d -s actions-runner "cd ~/actions-runner && ./run.sh"

# Attach to see runner output:
tmux attach -t actions-runner

# Stop the runner:
tmux kill-session -t actions-runner
```

The `scripts/start-runner.sh` script handles PATH setup, idempotency (skips if the session already exists), and runner directory validation.

### Trade-offs

| Aspect | launchd service | tmux session |
|--------|----------------|--------------|
| Auto-start on boot | Yes | No (must start manually or via login item) |
| Keychain access | No | Yes |
| Survives user logout | Yes (system agent) | No (killed on logout) |
| Process management | launchctl | tmux commands |

For headless servers where no one logs out (e.g., a Mac Mini running as a build server), the tmux approach works well. If auto-start on boot is needed, add the tmux start command to the user's login items or a login shell profile.

## Related

The `HOME` environment variable also needs explicit handling. Cron and GitHub Actions runner environments may not inherit `HOME`, causing `claude` to fail because it looks for `~/.claude/`. dispatch.sh sets this explicitly:

```bash
export HOME="${HOME:-$(eval echo ~"$(whoami)")}"
```

The generated crontab also includes `HOME=...` in its environment variables.

## Applicability

Any macOS automation that uses CLI tools relying on the login keychain for credential storage. Common examples: `security` command, apps using Keychain Services API, and CLI tools that store tokens in `~/.config/` or `~/.local/` with keychain-backed encryption.
