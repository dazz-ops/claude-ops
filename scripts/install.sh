#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# install.sh — Set up claude-ops on a new machine
#
# Checks all dependencies, verifies permissions, configures target repos,
# generates config.json and crontab, and optionally installs the schedule.
#
# Usage:
#   ./scripts/install.sh              # Interactive setup
#   ./scripts/install.sh --check      # Check dependencies only
#   ./scripts/install.sh --uninstall  # Remove crontab entries
# ============================================================================

OPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Colors (disabled if not a terminal)
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; RESET=''
fi

ok()   { printf "${GREEN}✓${RESET} %s\n" "$*"; }
warn() { printf "${YELLOW}!${RESET} %s\n" "$*"; }
fail() { printf "${RED}✗${RESET} %s\n" "$*"; }
info() { printf "${BLUE}→${RESET} %s\n" "$*"; }
header() { printf "\n${BOLD}%s${RESET}\n" "$*"; }

ERRORS=0
WARNINGS=0

# ============================================================================
# Dependency Checks
# ============================================================================

check_command() {
  local cmd="$1"
  local purpose="$2"
  local install_hint="${3:-}"

  if command -v "$cmd" &>/dev/null; then
    local version
    version=$("$cmd" --version 2>/dev/null | head -1) || version="(version unknown)"
    ok "$cmd — $version"
    return 0
  else
    fail "$cmd — NOT FOUND ($purpose)"
    if [[ -n "$install_hint" ]]; then
      printf "    Install: %s\n" "$install_hint"
    fi
    ERRORS=$(( ERRORS + 1 ))
    return 1
  fi
}

check_dependencies() {
  header "Checking dependencies"

  check_command "bash" "Shell (script runner)" || true
  check_command "jq" "JSON parsing (state management)" "brew install jq / apt install jq" || true
  check_command "git" "Version control" "brew install git / apt install git" || true
  check_command "claude" "Claude Code CLI (agent runtime)" "npm install -g @anthropic-ai/claude-code" || true
  check_command "gh" "GitHub CLI (issue/PR operations)" "brew install gh / apt install gh" || true

  # Optional: timeout command
  if command -v timeout &>/dev/null; then
    ok "timeout — available (GNU coreutils)"
  elif command -v gtimeout &>/dev/null; then
    ok "gtimeout — available (will be used as timeout)"
  else
    warn "timeout/gtimeout — not found (will use fallback polling)"
    printf "    Optional: brew install coreutils (for gtimeout)\n"
    WARNINGS=$(( WARNINGS + 1 ))
  fi

  # Optional: terminal-notifier
  if command -v terminal-notifier &>/dev/null; then
    ok "terminal-notifier — available"
  else
    warn "terminal-notifier — not found (notifications will use osascript fallback)"
    printf "    Optional: brew install terminal-notifier\n"
    WARNINGS=$(( WARNINGS + 1 ))
  fi
}

# ============================================================================
# Permission / Auth Checks
# ============================================================================

check_github_auth() {
  header "Checking GitHub CLI authentication"

  if ! command -v gh &>/dev/null; then
    fail "gh not installed — skipping auth check"
    return 1
  fi

  # Check if logged in
  local auth_status
  if ! auth_status=$(gh auth status 2>&1); then
    fail "GitHub CLI not authenticated"
    printf "    Run: gh auth login\n"
    ERRORS=$(( ERRORS + 1 ))
    return 1
  fi

  ok "GitHub CLI authenticated"

  # Check required scopes
  local token_scopes
  token_scopes=$(gh auth status 2>&1 | grep -i "token scopes" | head -1) || true

  # Required operations per role:
  # PM:        gh issue create/edit/list/view/comment
  # Developer: gh pr create, gh issue view, git push
  # QA:        gh pr list/view/diff/comment, gh issue create
  # Tech Lead: gh pr list/view/diff/comment, gh issue create/comment
  #
  # Minimum scopes needed: repo (covers all of the above)

  if echo "$token_scopes" | grep -qi "repo"; then
    ok "Token has 'repo' scope (covers all agent operations)"
  else
    # gh with GitHub App auth or fine-grained tokens may not show scopes the same way
    warn "Could not verify 'repo' scope — agents need: issues (read/write), pull requests (read/write), contents (read/write)"
    printf "    If agents fail with permission errors, re-auth: gh auth login --scopes repo\n"
    WARNINGS=$(( WARNINGS + 1 ))
  fi

  # Check that git push will work (SSH or HTTPS credential helper)
  info "Developer role needs git push access to target repos"
  local git_credential
  git_credential=$(git config --global credential.helper 2>/dev/null) || true
  if [[ -n "$git_credential" ]]; then
    ok "Git credential helper configured: $git_credential"
  elif [[ -f "$HOME/.ssh/id_rsa" ]] || [[ -f "$HOME/.ssh/id_ed25519" ]]; then
    ok "SSH keys found — git push should work for SSH remotes"
  else
    warn "No git credential helper or SSH keys detected"
    printf "    Developer role needs push access. Options:\n"
    printf "      - gh auth setup-git (configures HTTPS credential helper)\n"
    printf "      - ssh-keygen and add key to GitHub\n"
    WARNINGS=$(( WARNINGS + 1 ))
  fi
}

check_claude_auth() {
  header "Checking Claude Code CLI"

  if ! command -v claude &>/dev/null; then
    fail "claude CLI not installed — skipping auth check"
    return 1
  fi

  # Check that claude -p works (basic smoke test)
  info "Testing claude -p with a trivial prompt..."
  local test_output
  if test_output=$(claude -p "Reply with exactly: OK" --output-format json 2>/dev/null); then
    local result
    result=$(echo "$test_output" | jq -r '.result // empty' 2>/dev/null) || true
    if [[ -n "$result" ]]; then
      ok "claude -p works (subscription active)"
    else
      local error
      error=$(echo "$test_output" | jq -r '.error // empty' 2>/dev/null) || true
      if [[ -n "$error" ]]; then
        fail "claude -p returned error: $error"
        ERRORS=$(( ERRORS + 1 ))
      else
        warn "claude -p returned empty result — may need authentication"
        WARNINGS=$(( WARNINGS + 1 ))
      fi
    fi
  else
    fail "claude -p failed — check your subscription and authentication"
    printf "    Run: claude login\n"
    ERRORS=$(( ERRORS + 1 ))
  fi
}

# ============================================================================
# Target Repo Configuration
# ============================================================================

add_target_interactive() {
  local config_file="$1"

  while true; do
    printf "\n"
    read -rp "Add a target repo? (y/n): " add_target
    if [[ "$add_target" != "y" ]]; then
      break
    fi

    read -rp "  Repo name (short, e.g. 'my-project'): " target_name
    if [[ -z "$target_name" ]]; then
      warn "Name cannot be empty"
      continue
    fi

    read -rp "  Absolute path to repo: " target_path
    if [[ ! -d "$target_path" ]]; then
      warn "Directory does not exist: $target_path"
      read -rp "  Add anyway? (y/n): " add_anyway
      if [[ "$add_anyway" != "y" ]]; then
        continue
      fi
    fi

    # Verify it's a git repo
    if [[ -d "$target_path" ]] && ! git -C "$target_path" rev-parse --git-dir &>/dev/null; then
      warn "$target_path is not a git repository"
      read -rp "  Add anyway? (y/n): " add_anyway
      if [[ "$add_anyway" != "y" ]]; then
        continue
      fi
    fi

    read -rp "  Main branch (default: main): " target_branch
    if [[ -z "$target_branch" ]]; then target_branch="main"; fi

    # Add to config
    local tmp
    tmp=$(mktemp)
    jq --arg name "$target_name" --arg path "$target_path" --arg branch "$target_branch" \
      '.targets += [{"name": $name, "path": $path, "branch": $branch, "enabled": true}]' \
      "$config_file" > "$tmp" && mv "$tmp" "$config_file"

    ok "Added target: $target_name → $target_path ($target_branch)"
  done
}

# ============================================================================
# Crontab Generation
# ============================================================================

generate_crontab() {
  local crontab_file="${OPS_ROOT}/schedules/crontab"
  local jobs_dir="${OPS_ROOT}/jobs"
  local log_file="${OPS_ROOT}/logs/cron.log"

  # Detect PATH for cron (needs to include claude, gh, jq locations)
  local cron_path="/usr/local/bin:/usr/bin:/bin"
  if [[ -d "/opt/homebrew/bin" ]]; then
    cron_path="/opt/homebrew/bin:${cron_path}"
  fi
  # Add the directory containing claude if it's not in standard paths
  local claude_dir
  claude_dir=$(dirname "$(command -v claude 2>/dev/null || echo "/usr/local/bin/claude")")
  if [[ ":${cron_path}:" != *":${claude_dir}:"* ]]; then
    cron_path="${claude_dir}:${cron_path}"
  fi

  cat > "$crontab_file" <<CRONTAB
# claude-ops scheduled agent jobs
# Generated by: ./scripts/install.sh
# Install: crontab schedules/crontab
# View: crontab -l
# Remove: crontab -r
#
# Logs: ${OPS_ROOT}/logs/
# Budget: ${OPS_ROOT}/state/budget-YYYY-MM-DD.json

SHELL=/bin/bash
PATH=${cron_path}

# ============================================================================
# Daily Jobs
# ============================================================================

# PM: Morning triage — categorize and prioritize open issues
0 9 * * *    ${jobs_dir}/pm-triage.sh >> ${log_file} 2>&1

# PM: Enhance — flesh out needs_refinement issues with acceptance criteria
0 10 * * *   ${jobs_dir}/pm-enhance.sh >> ${log_file} 2>&1

# Developer: Implement next ready_for_dev issue
0 11 * * *   ${jobs_dir}/dev-implement.sh >> ${log_file} 2>&1

# QA: Review open PRs with fresh-eyes methodology
0 14 * * *   ${jobs_dir}/qa-review-prs.sh >> ${log_file} 2>&1

# Developer: Fix PRs that have QA findings
0 16 * * *   ${jobs_dir}/dev-fix-pr.sh >> ${log_file} 2>&1

# ============================================================================
# Weekly Jobs
# ============================================================================

# PM: Explore codebase for improvement opportunities (Monday)
0 8 * * 1    ${jobs_dir}/pm-explore.sh >> ${log_file} 2>&1

# Tech Lead: Architecture review (Friday)
0 15 * * 5   ${jobs_dir}/tech-lead-review.sh >> ${log_file} 2>&1

# Log cleanup (Sunday)
0 3 * * 0    ${OPS_ROOT}/scripts/log-cleanup.sh >> ${log_file} 2>&1
CRONTAB

  ok "Generated crontab: $crontab_file"
}

# ============================================================================
# Directory Setup
# ============================================================================

setup_directories() {
  header "Setting up directories"

  mkdir -p "${OPS_ROOT}/state"
  mkdir -p "${OPS_ROOT}/logs"
  ok "Created state/ and logs/"

  # Make all scripts executable
  chmod +x "${OPS_ROOT}/scripts/"*.sh
  chmod +x "${OPS_ROOT}/jobs/"*.sh
  ok "Made scripts executable"
}

# ============================================================================
# Config Generation
# ============================================================================

generate_config() {
  local config_file="${OPS_ROOT}/config.json"

  if [[ -f "$config_file" ]]; then
    warn "config.json already exists"
    read -rp "  Overwrite? (y/n): " overwrite
    if [[ "$overwrite" != "y" ]]; then
      info "Keeping existing config.json"
      return
    fi
  fi

  cp "${OPS_ROOT}/config.template.json" "$config_file"
  ok "Created config.json from template"

  add_target_interactive "$config_file"

  # Verify at least one target
  local target_count
  target_count=$(jq '.targets | length' "$config_file")
  if (( target_count == 0 )); then
    warn "No targets configured — agents will have nothing to work on"
    printf "    Add targets later: edit config.json or re-run install.sh\n"
  else
    ok "$target_count target(s) configured"
  fi
}

# ============================================================================
# Summary
# ============================================================================

print_summary() {
  header "Setup Summary"

  if (( ERRORS > 0 )); then
    fail "$ERRORS error(s) found — fix these before running agents"
  fi
  if (( WARNINGS > 0 )); then
    warn "$WARNINGS warning(s) — agents may work but some features will be limited"
  fi
  if (( ERRORS == 0 && WARNINGS == 0 )); then
    ok "All checks passed"
  fi

  printf "\n"
  info "Agent permissions by role:"
  printf "  %-20s %-12s %s\n" "Role" "Mode" "Key Permissions"
  printf "  %-20s %-12s %s\n" "----" "----" "---------------"
  printf "  %-20s %-12s %s\n" "product-manager" "read-only" "gh issue create/edit, git log (no code changes)"
  printf "  %-20s %-12s %s\n" "developer" "read-write" "git commit/push, gh pr create (no merge, no force push)"
  printf "  %-20s %-12s %s\n" "qa-engineer" "read-only" "gh pr comment, gh issue create, run tests (no code changes)"
  printf "  %-20s %-12s %s\n" "tech-lead" "read-only" "gh pr/issue comment, git log (no code changes)"

  printf "\n"
  info "Daily schedule:"
  printf "  09:00  PM triage — categorize and prioritize issues\n"
  printf "  10:00  PM enhance — flesh out needs_refinement issues\n"
  printf "  11:00  Developer — implement next ready_for_dev issue\n"
  printf "  14:00  QA — review open PRs\n"
  printf "  16:00  Developer — fix PRs with QA findings\n"
  printf "  Weekly: PM explore (Mon 08:00), Tech Lead review (Fri 15:00)\n"

  printf "\n"
  info "Next steps:"
  if (( ERRORS > 0 )); then
    printf "  1. Fix the errors above\n"
    printf "  2. Re-run: ./scripts/install.sh\n"
  else
    printf "  1. Review config: cat config.json\n"
    printf "  2. Test dry run: ./scripts/dispatch.sh --role product-manager --target <name> --task 'test' --dry-run\n"
    printf "  3. Install cron: crontab schedules/crontab\n"
    printf "  4. Monitor: ./scripts/status.sh\n"
  fi
}

# ============================================================================
# Main
# ============================================================================

main() {
  local mode="${1:-}"

  printf "${BOLD}claude-ops installer${RESET}\n"
  printf "====================\n"

  case "$mode" in
    --check)
      check_dependencies
      check_github_auth
      check_claude_auth
      printf "\n"
      if (( ERRORS > 0 )); then
        fail "$ERRORS error(s) found"
        exit 1
      fi
      ok "All dependency checks passed"
      exit 0
      ;;
    --uninstall)
      header "Removing claude-ops cron entries"
      if crontab -l 2>/dev/null | grep -q claude-ops; then
        crontab -l 2>/dev/null | grep -v claude-ops | grep -v "^$" > /tmp/crontab-clean || true
        crontab /tmp/crontab-clean
        rm -f /tmp/crontab-clean
        ok "Removed claude-ops entries from crontab"
      else
        info "No claude-ops entries in crontab"
      fi
      exit 0
      ;;
    "")
      # Full interactive install
      ;;
    *)
      printf "Usage: ./scripts/install.sh [--check | --uninstall]\n"
      exit 1
      ;;
  esac

  # Step 1: Check dependencies
  check_dependencies

  # Step 2: Check auth
  check_github_auth
  check_claude_auth

  # Step 3: Setup directories
  setup_directories

  # Step 4: Generate config
  header "Configuring target repos"
  generate_config

  # Step 5: Generate crontab
  header "Generating crontab"
  generate_crontab

  # Step 6: Optionally install crontab
  header "Cron installation"
  if (( ERRORS > 0 )); then
    warn "Skipping cron installation due to errors above"
  else
    read -rp "Install crontab now? (y/n): " install_cron
    if [[ "$install_cron" == "y" ]]; then
      # Preserve existing non-claude-ops cron entries
      local existing_cron
      existing_cron=$(crontab -l 2>/dev/null | grep -v claude-ops || true)
      local new_cron
      new_cron=$(cat "${OPS_ROOT}/schedules/crontab")
      printf "%s\n%s\n" "$existing_cron" "$new_cron" | crontab -
      ok "Crontab installed (preserved existing entries)"
    else
      info "Skipped — install later: crontab schedules/crontab"
    fi
  fi

  # Summary
  print_summary
}

main "$@"
