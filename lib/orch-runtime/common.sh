# shellcheck shell=bash
# Common configuration and helpers for orch-runtime.

DEFAULT_LINES=120
BUFFER_NAME="orch-runtime-share"

die() {
  echo "orch-runtime: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  orch-runtime new [--print] [session]
  orch-runtime panes
  orch-runtime status [pane|claude|codex|all] [-n lines]
  orch-runtime watch [pane|claude|codex|all] [-n lines] [-i seconds] [--states asking,error] [--no-notify] [--once]
  orch-runtime digest [pane|claude|codex|all] [-n lines] [note...]
  orch-runtime focus <pane|claude|codex>
  orch-runtime capture [pane|claude|codex] [-n lines]
  orch-runtime send [--no-enter] <pane|claude|codex> [message...]
  orch-runtime handoff --from <pane|claude|codex> --to <pane|claude|codex> [--task context|review|implement|design] [-n lines] [--dry-run] [note...]
  orch-runtime review --from <pane|claude|codex> --to <pane|claude|codex> [-n lines] [note...]
  orch-runtime implement --from <pane|claude|codex> --to <pane|claude|codex> [-n lines] [note...]
  orch-runtime design --from <pane|claude|codex> --to <pane|claude|codex> [-n lines] [note...]
  orch-runtime workspace start <profile-id> <worktree-path> [--session name] [--name window] [--dry-run]
  orch-runtime workspace status [-n lines]
  orch-runtime workspace report <workspace> [-n lines]
  orch-runtime workspace open <workspace> [--print]
  orch-runtime workspace watch <workspace> [-n lines] [-i seconds] [--stale-seconds seconds] [--once]
  orch-runtime lock list [--worktree path]
  orch-runtime lock check <type> <id>
  orch-runtime lock acquire <type> <id> [--workspace name] [--profile id] [--worktree path]
  orch-runtime lock release [<type> <id>] --worktree <path>
  orch-runtime lock release-stale <type> <id>

Targets:
  current   current pane
  claude    first pane that looks like Claude Code
  codex     first pane that looks like Codex
  %1        tmux pane id
  main:1.2  tmux session:window.pane target

Workspace profiles:
  Profile dispatch is driven by the orchestrate profile loader. The pane layout
  comes from the matched profile's `runtime.panes` array (see
  texdeath/orchestrate `config/profile.schema.yaml`). Profiles without a
  `runtime.panes` section trigger a graceful no-op: stderr warning, no window
  is created, exit 0.

  The loader is resolved in this order:
    1. $ORCHESTRATE_LOAD_PROFILE (env override, absolute path)
    2. `command -v load-profile.sh` (must be on PATH)
    3. ~/.claude/orchestrate/bin/load-profile.sh (canonical install location)

Examples:
  orch-runtime new sample-session
  orch-runtime new --print scratch
  orch-runtime panes
  orch-runtime status
  orch-runtime watch all
  orch-runtime digest claude -n 80 "Summarize where Claude is blocked."
  orch-runtime focus claude
  orch-runtime review --from claude --to codex "Review this plan before implementation."
  orch-runtime implement --from claude --to codex "Implement only the MVP scope."
  orch-runtime handoff --from codex --to claude --task design --dry-run
  orch-runtime workspace start <profile-id> /path/to/worktree --dry-run
  orch-runtime workspace start <profile-id> /path/to/worktree
  orch-runtime workspace status
  orch-runtime workspace report <workspace> -n 100
  orch-runtime workspace open <workspace> --print
  orch-runtime workspace watch <workspace>
  orch-runtime lock list
EOF
}

need_tmux() {
  command -v tmux >/dev/null 2>&1 || die "tmux is not installed"
  tmux has-session >/dev/null 2>&1 || die "no tmux server is running"
}

need_tmux_binary() {
  command -v tmux >/dev/null 2>&1 || die "tmux is not installed"
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

is_positive_int() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

is_safe_session_name() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]
}

state_in_list() {
  local state="$1"
  local list="$2"
  [[ ",$list," == *",$state,"* ]]
}

osascript_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}
