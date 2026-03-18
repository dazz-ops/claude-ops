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
MISSING_BREW=()       # brew package names for missing required deps
MISSING_BREW_OPT=()   # brew package names for missing optional deps
MISSING_NPM=()        # npm packages for missing deps

# ============================================================================
# Dependency Checks
# ============================================================================

check_command() {
  local cmd="$1"
  local purpose="$2"
  local install_hint="${3:-}"
  local brew_pkg="${4:-}"   # brew package name (empty = not brew-installable)
  local npm_pkg="${5:-}"    # npm package name (empty = not npm-installable)

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
    if [[ -n "$brew_pkg" ]]; then
      MISSING_BREW+=("$brew_pkg")
    fi
    if [[ -n "$npm_pkg" ]]; then
      MISSING_NPM+=("$npm_pkg")
    fi
    ERRORS=$(( ERRORS + 1 ))
    return 1
  fi
}

check_dependencies() {
  header "Checking dependencies"

  check_command "bash" "Shell (script runner)" "" "" "" || true
  check_command "jq" "JSON parsing (state management)" "brew install jq / apt install jq" "jq" "" || true
  check_command "git" "Version control" "brew install git / apt install git" "git" "" || true
  check_command "claude" "Claude Code CLI (agent runtime)" "npm install -g @anthropic-ai/claude-code" "" "@anthropic-ai/claude-code" || true
  check_command "gh" "GitHub CLI (issue/PR operations)" "brew install gh / apt install gh" "gh" "" || true
  check_command "yq" "YAML parsing (role config frontmatter)" "brew install yq" "yq" "" || true

  # Verify yq is mikefarah/yq v4+ (not the Python wrapper)
  if command -v yq &>/dev/null; then
    local yq_version
    yq_version=$(yq --version 2>/dev/null) || true
    if echo "$yq_version" | grep -q "github.com/mikefarah/yq"; then
      local yq_major
      yq_major=$(echo "$yq_version" | grep -oE 'v[0-9]+' | head -1 | tr -d 'v')
      if [[ -n "$yq_major" ]] && (( yq_major >= 4 )); then
        ok "yq is mikefarah/yq v${yq_major} (required)"
      else
        fail "yq must be mikefarah/yq v4+, found: $yq_version"
        ERRORS=$(( ERRORS + 1 ))
      fi
    else
      fail "yq must be mikefarah/yq (found different yq implementation)"
      printf "    Install: brew install yq (provides mikefarah/yq)\n"
      ERRORS=$(( ERRORS + 1 ))
    fi
  fi

  check_command "bats" "Bash test framework (dev/test only)" "brew install bats-core" "bats-core" "" || {
    # bats is optional — move it from required (MISSING_BREW) to optional (MISSING_BREW_OPT)
    MISSING_BREW=("${MISSING_BREW[@]/$'bats-core'}")
    MISSING_BREW_OPT+=("bats-core")
    warn "bats-core is optional (only needed for running tests)"
    ERRORS=$(( ERRORS - 1 ))  # undo the error increment from check_command
    WARNINGS=$(( WARNINGS + 1 ))
  }

  # Optional: timeout command
  if command -v timeout &>/dev/null; then
    ok "timeout — available (GNU coreutils)"
  elif command -v gtimeout &>/dev/null; then
    ok "gtimeout — available (will be used as timeout)"
  else
    warn "timeout/gtimeout — not found (will use fallback polling)"
    printf "    Optional: brew install coreutils (for gtimeout)\n"
    MISSING_BREW_OPT+=("coreutils")
    WARNINGS=$(( WARNINGS + 1 ))
  fi

  # Optional: terminal-notifier
  if command -v terminal-notifier &>/dev/null; then
    ok "terminal-notifier — available"
  else
    warn "terminal-notifier — not found (notifications will use osascript fallback)"
    printf "    Optional: brew install terminal-notifier\n"
    MISSING_BREW_OPT+=("terminal-notifier")
    WARNINGS=$(( WARNINGS + 1 ))
  fi
}

# ============================================================================
# Auto-Install Missing Dependencies
# ============================================================================

offer_auto_install() {
  # Nothing to install
  if [[ ${#MISSING_BREW[@]} -eq 0 && ${#MISSING_NPM[@]} -eq 0 && ${#MISSING_BREW_OPT[@]} -eq 0 ]]; then
    return 0
  fi

  local did_install=false

  # Filter out empty entries (from array element removal)
  local brew_required=()
  local brew_optional=()
  for pkg in "${MISSING_BREW[@]}"; do
    [[ -n "$pkg" ]] && brew_required+=("$pkg")
  done
  for pkg in "${MISSING_BREW_OPT[@]}"; do
    [[ -n "$pkg" ]] && brew_optional+=("$pkg")
  done

  local has_brew=false
  if command -v brew &>/dev/null; then
    has_brew=true
  fi

  local has_npm=false
  if command -v npm &>/dev/null; then
    has_npm=true
  fi

  # Report what can be auto-installed
  header "Auto-install missing dependencies"

  if [[ "$has_brew" == "false" && ( ${#brew_required[@]} -gt 0 || ${#brew_optional[@]} -gt 0 ) ]]; then
    fail "Homebrew not found — cannot auto-install brew packages"
    info "Install Homebrew first: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    info "Then re-run: ./scripts/install.sh"
    if [[ ${#brew_required[@]} -gt 0 ]]; then
      return 1  # required deps can't be installed without brew
    fi
  fi

  # Install required brew packages
  if [[ "$has_brew" == "true" && ${#brew_required[@]} -gt 0 ]]; then
    printf "\n"
    info "Required packages to install via Homebrew: ${brew_required[*]}"
    read -rp "Install now? (y/n): " do_install
    if [[ "$do_install" == "y" ]]; then
      for pkg in "${brew_required[@]}"; do
        info "Installing $pkg..."
        if brew install "$pkg" 2>&1; then
          ok "Installed $pkg"
          did_install=true
        else
          fail "Failed to install $pkg"
        fi
      done
    fi
  fi

  # Install npm packages
  if [[ "$has_npm" == "true" && ${#MISSING_NPM[@]} -gt 0 ]]; then
    printf "\n"
    info "Required packages to install via npm: ${MISSING_NPM[*]}"
    read -rp "Install now? (y/n): " do_install
    if [[ "$do_install" == "y" ]]; then
      for pkg in "${MISSING_NPM[@]}"; do
        info "Installing $pkg globally..."
        if npm install -g "$pkg" 2>&1; then
          ok "Installed $pkg"
          did_install=true
        else
          fail "Failed to install $pkg — may need: sudo npm install -g $pkg"
        fi
      done
    fi
  elif [[ "$has_npm" == "false" && ${#MISSING_NPM[@]} -gt 0 ]]; then
    warn "npm not found — cannot auto-install: ${MISSING_NPM[*]}"
    info "Install Node.js (includes npm): brew install node / https://nodejs.org"
  fi

  # Offer optional packages
  if [[ "$has_brew" == "true" && ${#brew_optional[@]} -gt 0 ]]; then
    printf "\n"
    info "Optional packages available: ${brew_optional[*]}"
    read -rp "Install optional packages too? (y/n): " do_install_opt
    if [[ "$do_install_opt" == "y" ]]; then
      for pkg in "${brew_optional[@]}"; do
        info "Installing $pkg..."
        if brew install "$pkg" 2>&1; then
          ok "Installed $pkg"
          did_install=true
        else
          warn "Failed to install $pkg (optional — continuing)"
        fi
      done
    fi
  fi

  # Re-verify all dependencies after any installation
  if [[ "$did_install" == "true" ]]; then
    printf "\n"
    info "Re-checking dependencies after install..."
    ERRORS=0
    WARNINGS=0
    MISSING_BREW=()
    MISSING_BREW_OPT=()
    MISSING_NPM=()
    check_dependencies
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

# SYNC: schedule entries here must match CLAUDE.md "Fallback: Cron" section
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

  # Paths must be expanded before the heredoc; the quoted delimiter ('CRONTAB')
  # prevents any further variable/command expansion inside the body.
  local _cron_path="$cron_path"
  local _jobs_dir="$jobs_dir"
  local _log_file="$log_file"
  local _ops_root="$OPS_ROOT"
  local _home="$HOME"
  cat > "$crontab_file" <<'CRONTAB_TEMPLATE'
SHELL=/bin/bash
HOME=HOME_PLACEHOLDER
PATH=CRON_PATH_PLACEHOLDER

# PM: Morning triage — categorize and prioritize open issues
0 9 * * *    JOBS_DIR_PLACEHOLDER/pm-triage.sh >> LOG_FILE_PLACEHOLDER 2>&1

# PM: Enhance — flesh out needs_refinement issues with acceptance criteria
0 10 * * *   JOBS_DIR_PLACEHOLDER/pm-enhance.sh >> LOG_FILE_PLACEHOLDER 2>&1

# Developer: Implement — 3 slots per day for throughput
0 11 * * *   JOBS_DIR_PLACEHOLDER/dev-implement.sh >> LOG_FILE_PLACEHOLDER 2>&1
0 15 * * *   JOBS_DIR_PLACEHOLDER/dev-implement.sh >> LOG_FILE_PLACEHOLDER 2>&1
0 19 * * *   JOBS_DIR_PLACEHOLDER/dev-implement.sh >> LOG_FILE_PLACEHOLDER 2>&1

# Code Reviewer: Fresh-eyes review open PRs — 2h after each dev slot
0 13 * * *   JOBS_DIR_PLACEHOLDER/dev-review-prs.sh >> LOG_FILE_PLACEHOLDER 2>&1
0 17 * * *   JOBS_DIR_PLACEHOLDER/dev-review-prs.sh >> LOG_FILE_PLACEHOLDER 2>&1
0 21 * * *   JOBS_DIR_PLACEHOLDER/dev-review-prs.sh >> LOG_FILE_PLACEHOLDER 2>&1

# PM: Explore codebase + ideate new features (Monday)
0 8 * * 1    JOBS_DIR_PLACEHOLDER/pm-explore.sh >> LOG_FILE_PLACEHOLDER 2>&1

# Tech Lead: Architecture review (Friday)
0 15 * * 5   JOBS_DIR_PLACEHOLDER/tech-lead-review.sh >> LOG_FILE_PLACEHOLDER 2>&1

# Log cleanup (Sunday 03:00)
0 3 * * 0    OPS_ROOT_PLACEHOLDER/scripts/log-cleanup.sh >> LOG_FILE_PLACEHOLDER 2>&1
CRONTAB_TEMPLATE
  # Substitute the placeholders with the actual expanded values
  sed -i.bak \
    -e "s|HOME_PLACEHOLDER|${_home}|g" \
    -e "s|CRON_PATH_PLACEHOLDER|${_cron_path}|g" \
    -e "s|JOBS_DIR_PLACEHOLDER|${_jobs_dir}|g" \
    -e "s|LOG_FILE_PLACEHOLDER|${_log_file}|g" \
    -e "s|OPS_ROOT_PLACEHOLDER|${_ops_root}|g" \
    "$crontab_file"
  rm -f "${crontab_file}.bak"

  ok "Generated crontab: $crontab_file"
}

# ============================================================================
# Crontab Installation (sentinel-based, idempotent)
# ============================================================================

SENTINEL_BEGIN="# BEGIN claude-ops managed block — do not edit manually"
SENTINEL_END="# END claude-ops managed block"

# Read cron_enabled from config (explicit null-check — jq // treats false as falsy)
read_cron_enabled() {
  local config_file="${OPS_ROOT}/config.json"
  if [[ ! -f "$config_file" ]]; then
    echo "true"  # default if no config
    return
  fi
  # SC2155: local and assignment are split so jq exit status is not masked
  local val
  val=$(jq -r 'if .defaults.cron_enabled == null then "true" else (.defaults.cron_enabled | tostring) end' "$config_file")
  echo "$val"
}

# Backup existing crontab to state directory
backup_crontab() {
  local backup_dir="${OPS_ROOT}/state"
  mkdir -p "$backup_dir"

  # Capture stderr separately so we can distinguish "no crontab" from real errors
  # without mixing stdout and stderr (which would corrupt the backup content).
  local stderr_tmp
  stderr_tmp=$(mktemp)
  local crontab_content
  crontab_content=$(crontab -l 2>"$stderr_tmp") || true
  local crontab_stderr
  crontab_stderr=$(cat "$stderr_tmp")
  rm -f "$stderr_tmp"

  if echo "$crontab_stderr" | grep -qi "no crontab for"; then
    # No existing crontab — nothing to back up
    return 0
  elif [[ -n "$crontab_stderr" ]]; then
    # Real error (permission denied, etc.)
    fail "crontab -l failed: $crontab_stderr"
    return 1
  fi

  # Epoch seconds timestamp is intentionally sortable (human-readable date not needed for ordering)
  local backup_file="${backup_dir}/crontab.backup.$(date +%s)"
  # Note: backup files in state/ are cleaned by log-cleanup.sh
  printf '%s\n' "$crontab_content" > "$backup_file"
  if [[ $? -ne 0 ]]; then
    fail "Failed to write crontab backup to $backup_file"
    return 1
  fi
  chmod 600 "$backup_file"
  ok "Backed up existing crontab to $backup_file"
}

# Strip claude-ops sentinel block from crontab content (stdin → stdout)
strip_sentinel_block() {
  sed '/^# BEGIN claude-ops managed block/,/^# END claude-ops managed block/d'
}

# Install or remove crontab entries based on cron_enabled flag
install_crontab() {
  local cron_enabled
  cron_enabled=$(read_cron_enabled)

  # Backup before any modification
  # TOCTOU note: backup and install are not atomic. Acceptable for a single-user dev tool
  # where concurrent crontab modification is not expected.
  if ! backup_crontab; then
    fail "Aborting crontab modification — backup failed"
    return 1
  fi

  # Get existing crontab content, then strip our managed block from it.
  # Validation must happen here (before piping to strip_sentinel_block) because
  # strip_sentinel_block reads from stdin and cannot validate before processing.
  local existing_cron=""
  local crontab_stderr_tmp
  crontab_stderr_tmp=$(mktemp)
  local raw_cron
  raw_cron=$(crontab -l 2>"$crontab_stderr_tmp") || true
  local crontab_stderr
  crontab_stderr=$(cat "$crontab_stderr_tmp")
  rm -f "$crontab_stderr_tmp"

  if echo "$crontab_stderr" | grep -qi "no crontab for"; then
    existing_cron=""
  elif [[ -n "$crontab_stderr" ]]; then
    fail "crontab -l failed: $crontab_stderr"
    return 1
  else
    # Validate sentinel integrity before stripping: a dangling BEGIN without END
    # would cause sed to delete from BEGIN to EOF, silently destroying unrelated entries.
    if echo "$raw_cron" | grep -qF "$SENTINEL_BEGIN" && \
       ! echo "$raw_cron" | grep -qF "$SENTINEL_END"; then
      fail "Crontab has $SENTINEL_BEGIN but no matching $SENTINEL_END — aborting to avoid data loss"
      fail "Fix manually: crontab -e"
      return 1
    fi
    existing_cron=$(echo "$raw_cron" | strip_sentinel_block)
  fi

  # Remove trailing blank lines from existing cron
  existing_cron=$(echo "$existing_cron" | sed -e :a -e '/^\n*$/{$d;N;ba}')

  if [[ "$cron_enabled" == "false" ]]; then
    # Disabled: install stripped crontab (preserves non-claude-ops entries)
    if [[ -z "$existing_cron" ]]; then
      crontab -r 2>/dev/null || true
    else
      echo "$existing_cron" | crontab - || { fail "ERROR: crontab install failed"; return 1; }
    fi
    ok "Cron disabled. Event-driven triggers only."
    return 0
  fi

  # Enabled: generate fresh entries and append sentinel block
  local crontab_file="${OPS_ROOT}/schedules/crontab"
  if [[ ! -f "$crontab_file" ]]; then
    fail "No generated crontab file at $crontab_file — run generate_crontab first"
    return 1
  fi

  local new_entries
  new_entries=$(cat "$crontab_file")
  local entry_count
  entry_count=$(echo "$new_entries" | grep -cE '^[0-9*]' || true)

  # Build combined crontab with sentinel block
  local combined=""
  if [[ -n "$existing_cron" ]]; then
    combined="${existing_cron}"$'\n'$'\n'
  fi
  combined+="${SENTINEL_BEGIN}"$'\n'
  combined+="${new_entries}"$'\n'
  combined+="${SENTINEL_END}"$'\n'

  echo "$combined" | crontab - || { fail "ERROR: crontab install failed"; return 1; }
  ok "Cron schedule installed (${entry_count} entries)"
}

# ============================================================================
# GitHub Actions Self-Hosted Runner Setup
# ============================================================================

setup_runner() {
  local runner_dir="${HOME}/actions-runner"

  if [[ -d "$runner_dir" && -f "${runner_dir}/run.sh" ]]; then
    ok "GitHub Actions runner already installed at $runner_dir"
    read -rp "  Reconfigure? (y/n): " reconfigure
    if [[ "$reconfigure" != "y" ]]; then
      info "Skipping runner setup"
      info "Start the runner with: ./scripts/start-runner.sh"
      return 0
    fi
  else
    read -rp "Set up GitHub Actions self-hosted runner? (y/n): " do_setup_runner
    if [[ "$do_setup_runner" != "y" ]]; then
      info "Skipping runner setup"
      info "Set up later: https://github.com/actions/runner/releases"
      return 0
    fi
  fi

  # Detect architecture
  local arch
  arch=$(uname -m)
  local runner_arch
  case "$arch" in
    arm64|aarch64) runner_arch="arm64" ;;
    x86_64)        runner_arch="x64" ;;
    *)
      fail "Unsupported architecture: $arch"
      return 1
      ;;
  esac

  local os
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  case "$os" in
    darwin) os="osx" ;;
    linux)  os="linux" ;;
    *)
      fail "Unsupported OS: $os"
      return 1
      ;;
  esac

  ok "Detected platform: ${os}-${runner_arch}"

  # Get target repo URL for runner registration
  printf "\n"
  read -rp "  GitHub repo URL for runner registration (e.g., https://github.com/owner/repo): " repo_url
  if [[ -z "$repo_url" ]]; then
    fail "Repo URL is required for runner registration"
    return 1
  fi

  # Validate URL format and extract owner/repo
  local owner_repo
  owner_repo=$(echo "$repo_url" | sed -n 's|.*github\.com/\([^/]*/[^/]*\).*|\1|p')
  if [[ -z "$owner_repo" ]]; then
    fail "Could not parse owner/repo from URL: $repo_url"
    return 1
  fi

  # Get registration token via gh API
  info "Getting runner registration token for $owner_repo..."
  local token_response
  if ! token_response=$(gh api "repos/${owner_repo}/actions/runners/registration-token" --method POST 2>&1); then
    fail "Failed to get registration token: $token_response"
    info "Ensure gh is authenticated with admin:repo scope"
    return 1
  fi

  local reg_token
  reg_token=$(echo "$token_response" | jq -r '.token // empty')
  if [[ -z "$reg_token" ]]; then
    fail "Registration token is empty — check your permissions"
    return 1
  fi

  ok "Got registration token"

  # Determine latest runner version
  info "Fetching latest runner release..."
  local latest_version
  latest_version=$(gh api repos/actions/runner/releases/latest --jq '.tag_name' 2>/dev/null | sed 's/^v//') || true
  if [[ -z "$latest_version" ]]; then
    # Fallback to a known version
    latest_version="2.321.0"
    warn "Could not fetch latest version — using fallback: $latest_version"
  fi

  local tarball="actions-runner-${os}-${runner_arch}-${latest_version}.tar.gz"
  local download_url="https://github.com/actions/runner/releases/download/v${latest_version}/${tarball}"

  # Download and extract
  mkdir -p "$runner_dir"
  info "Downloading runner v${latest_version} (${os}-${runner_arch})..."
  if ! curl -sL "$download_url" -o "${runner_dir}/${tarball}"; then
    fail "Download failed: $download_url"
    return 1
  fi

  info "Extracting..."
  if ! tar -xzf "${runner_dir}/${tarball}" -C "$runner_dir"; then
    fail "Extraction failed"
    return 1
  fi
  rm -f "${runner_dir}/${tarball}"

  ok "Runner extracted to $runner_dir"

  # Configure
  info "Configuring runner..."
  local runner_name
  runner_name="$(hostname)-claude-ops"

  if (cd "$runner_dir" && ./config.sh --unattended \
    --url "$repo_url" \
    --token "$reg_token" \
    --name "$runner_name" \
    --labels "claude-ops,self-hosted" \
    --replace 2>&1); then
    ok "Runner configured as '$runner_name'"
  else
    fail "Runner configuration failed"
    info "Try configuring manually: cd $runner_dir && ./config.sh --url $repo_url --token <token>"
    return 1
  fi

  printf "\n"
  ok "Runner setup complete"
  info "Start the runner with: ./scripts/start-runner.sh"
  info "The runner MUST run in a tmux session (not launchd) for keychain access."
  info "See: docs/solutions/launchd-keychain-access.md"
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
  printf "  %-20s %-12s %s\n" "developer" "read-write" "git commit/push, gh pr create, /fresh-eyes-review (no merge)"
  printf "  %-20s %-12s %s\n" "code-reviewer" "read-only" "gh pr review/comment, git checkout PRs, /fresh-eyes-review"
  printf "  %-20s %-12s %s\n" "tech-lead" "read-only" "gh issue create/comment, git log (no code changes)"

  printf "\n"
  info "Daily schedule:"
  printf "  09:00  PM triage — categorize and prioritize issues\n"
  printf "  10:00  PM enhance — flesh out needs_refinement issues\n"
  printf "  11:00  Developer — implement, self-review, create PR (slot 1/3)\n"
  printf "  13:00  Code Reviewer — fresh-eyes review open PRs (slot 1/3)\n"
  printf "  15:00  Developer — implement (slot 2/3)\n"
  printf "  17:00  Code Reviewer — review PRs (slot 2/3)\n"
  printf "  19:00  Developer — implement (slot 3/3)\n"
  printf "  21:00  Code Reviewer — review PRs (slot 3/3)\n"
  printf "  Weekly: PM explore/ideate (Mon 08:00), Tech Lead review (Fri 15:00)\n"

  printf "\n"
  info "Next steps:"
  if (( ERRORS > 0 )); then
    printf "  1. Fix the errors above\n"
    printf "  2. Re-run: ./scripts/install.sh\n"
  else
    printf "  1. Review config: cat config.json\n"
    printf "  2. Start the runner: ./scripts/start-runner.sh\n"
    printf "  3. Test dry run: ./scripts/dispatch.sh --role product-manager --target <name> --task 'test' --dry-run\n"
    printf "  4. Install cron: crontab schedules/crontab\n"
    printf "  5. Monitor: ./scripts/status.sh\n"
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
      offer_auto_install || true
      check_github_auth
      check_claude_auth

      # Report cron_enabled status
      header "Cron toggle"
      local config_file="${OPS_ROOT}/config.json"
      if [[ -f "$config_file" ]]; then
        # Use explicit null-check — jq // treats false as falsy, so "false // empty" → empty
        local cron_val
        cron_val=$(jq -r 'if .defaults.cron_enabled == null then "" else (.defaults.cron_enabled | tostring) end' "$config_file" 2>/dev/null) || true
        if [[ -z "$cron_val" ]]; then
          ok "cron_enabled: true (defaulted — key not in config)"
        else
          local resolved
          resolved=$(read_cron_enabled)
          if [[ "$resolved" == "false" ]]; then
            ok "cron_enabled: false (from config) — cron jobs will not be installed"
          else
            ok "cron_enabled: true (from config)"
          fi
        fi
      else
        warn "config.json not found — cron_enabled defaults to true"
      fi

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
      if ! backup_crontab; then
        fail "Aborting — could not backup crontab"
        exit 1
      fi
      local current_cron
      current_cron=$(crontab -l 2>/dev/null) || true
      if echo "$current_cron" | grep -qF "$SENTINEL_BEGIN"; then
        local stripped
        stripped=$(echo "$current_cron" | strip_sentinel_block | sed -e :a -e '/^\n*$/{$d;N;ba}')
        if [[ -z "$stripped" ]]; then
          crontab -r 2>/dev/null || true
        else
          echo "$stripped" | crontab -
        fi
        ok "Removed claude-ops sentinel block from crontab"
      else
        info "No claude-ops sentinel block in crontab"
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

  # Step 1b: Offer to install missing deps
  offer_auto_install || true

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
  local cron_enabled
  cron_enabled=$(read_cron_enabled)
  if (( ERRORS > 0 )); then
    warn "Skipping cron installation due to errors above"
  elif [[ "$cron_enabled" == "false" ]]; then
    info "cron_enabled is false in config — skipping cron installation"
    info "Event-driven triggers only. Set cron_enabled: true to enable fallback cron."
  else
    read -rp "Install crontab now? (y/n): " install_cron
    if [[ "$install_cron" == "y" ]]; then
      install_crontab
    else
      info "Skipped — install later with: ./scripts/install.sh (and choose y)"
    fi
  fi

  # Step 7: Runner setup
  header "GitHub Actions runner"
  if (( ERRORS > 0 )); then
    warn "Skipping runner setup due to errors above"
  else
    setup_runner || true
  fi

  # Summary
  print_summary
}

# Guard: only run main() when executed directly, not when sourced for testing.
# if/fi is required here — [[ ]] && main "$@" fails under set -e when sourced,
# because the [[ ]] condition evaluates to false (non-zero exit) and set -e aborts.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
