#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# start-runner.sh — Start GitHub Actions self-hosted runner in a tmux session
#
# The runner MUST run in a tmux session (not a launchd service) so it can
# access the macOS login keychain. The Claude Code CLI stores OAuth
# credentials in ~/.claude/ and reads them via the keychain — launchd
# services run outside the user's login session and cannot access it.
#
# Usage:
#   ./scripts/start-runner.sh                     # Default: ~/actions-runner
#   ./scripts/start-runner.sh /path/to/runner      # Custom runner directory
#
# Idempotent: skips if the tmux session already exists.
# ============================================================================

RUNNER_DIR="${1:-${HOME}/actions-runner}"
SESSION_NAME="actions-runner"

# Validate runner directory
if [[ ! -d "$RUNNER_DIR" ]]; then
  echo "ERROR: Runner directory does not exist: $RUNNER_DIR"
  echo "  Download the runner first: https://github.com/actions/runner/releases"
  echo "  Or run: ./scripts/install.sh (includes runner setup)"
  exit 1
fi

if [[ ! -f "${RUNNER_DIR}/run.sh" ]]; then
  echo "ERROR: run.sh not found in $RUNNER_DIR — is this a GitHub Actions runner?"
  exit 1
fi

# Check for tmux
if ! command -v tmux &>/dev/null; then
  echo "ERROR: tmux is required but not found"
  echo "  Install: brew install tmux"
  exit 1
fi

# Idempotent — skip if session already exists
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  echo "Runner tmux session '$SESSION_NAME' already exists"
  echo "  Attach: tmux attach -t $SESSION_NAME"
  echo "  Stop:   tmux kill-session -t $SESSION_NAME"
  exit 0
fi

# Build PATH for the runner session — ensure Homebrew, npm globals, and
# standard paths are available so claude, gh, jq, etc. are found.
RUNNER_PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
[[ -d "/opt/homebrew/bin" ]] && RUNNER_PATH="/opt/homebrew/bin:${RUNNER_PATH}"
[[ -d "${HOME}/.local/bin" ]] && RUNNER_PATH="${HOME}/.local/bin:${RUNNER_PATH}"

# Detect npm global bin directory (where claude CLI lives)
if command -v npm &>/dev/null; then
  npm_bin="$(npm prefix -g 2>/dev/null)/bin"
  if [[ -d "$npm_bin" && ":${RUNNER_PATH}:" != *":${npm_bin}:"* ]]; then
    RUNNER_PATH="${npm_bin}:${RUNNER_PATH}"
  fi
fi

# Start the runner in a detached tmux session
tmux new-session -d -s "$SESSION_NAME" \
  "export PATH=\"${RUNNER_PATH}\"; cd \"${RUNNER_DIR}\" && ./run.sh"

echo "Started GitHub Actions runner in tmux session '$SESSION_NAME'"
echo "  Attach: tmux attach -t $SESSION_NAME"
echo "  Stop:   tmux kill-session -t $SESSION_NAME"
