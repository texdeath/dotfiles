# shellcheck shell=bash
# Common configuration and helpers for orch-runtime.

DEFAULT_LINES=120
BUFFER_NAME="orch-runtime-share"
ORCH_RUNTIME_DEVBOX_SERVICES_TIMEOUT_DEFAULT=8

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

run_with_timeout() {
  local seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
    return
  fi
  if command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift @ARGV; exec @ARGV' "$seconds" "$@"
    return
  fi

  local command_pid timer_pid rc=0
  "$@" &
  command_pid=$!
  (
    sleep "$seconds"
    kill "$command_pid" 2>/dev/null || true
  ) &
  timer_pid=$!

  wait "$command_pid" || rc=$?
  kill "$timer_pid" 2>/dev/null || true
  return "$rc"
}

strip_ansi() {
  sed -E $'s/\x1B\\[[0-9;?]*[ -/]*[@-~]//g'
}

workspace_process_compose_services() {
  local worktree="$1"
  local compose_file="$worktree/process-compose.yaml"
  [[ -f "$compose_file" ]] || return 0

  ruby -ryaml - "$compose_file" <<'RUBY'
SEP = "\x1f"
begin
  data = YAML.load_file(ARGV[0]) || {}
  processes = data["processes"] || {}
  exit 0 unless processes.is_a?(Hash)
  processes.keys.each do |name|
    value = name.to_s
    next if value.empty? || value.include?(SEP) || value.include?("\n")
    puts value
  end
rescue Psych::SyntaxError => e
  warn "orch-runtime: failed to parse process-compose.yaml: #{e.message}"
  exit 2
end
RUBY
}

workspace_devbox_services_ls_raw() {
  local worktree="$1"
  local timeout_seconds="${ORCH_RUNTIME_DEVBOX_SERVICES_TIMEOUT:-$ORCH_RUNTIME_DEVBOX_SERVICES_TIMEOUT_DEFAULT}"
  local env_file="$worktree/.orchestrate/env"
  local -a cmd=(devbox services ls)

  [[ -d "$worktree" && -f "$worktree/devbox.json" ]] || return 0
  command -v devbox >/dev/null 2>&1 || return 127
  is_positive_int "$timeout_seconds" || timeout_seconds="$ORCH_RUNTIME_DEVBOX_SERVICES_TIMEOUT_DEFAULT"
  [[ -f "$env_file" ]] && cmd+=(--env-file "$env_file")

  (cd "$worktree" && run_with_timeout "$timeout_seconds" "${cmd[@]}")
}

workspace_devbox_services_statuses() {
  local worktree="$1"
  local output rc detail

  rc=0
  output="$(workspace_devbox_services_ls_raw "$worktree" 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    detail="$(printf '%s\n' "$output" | grep -v '^[[:space:]]*$' | tail -1 | one_line)"
    detail="${detail:-devbox services ls exited $rc}"
    printf '__devbox\tunknown\t%s\n' "$detail"
    return 0
  fi

  printf '%s\n' "$output" | strip_ansi | awk '
    function trim(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      return s
    }
    {
      line = trim($0)
      if (line == "") next
      low = tolower(line)
      if (low ~ /^(info|warn|warning|error):/) next
      if (low ~ /^no[[:space:]].*services/) next
      if (low ~ /^(name|service|process)[[:space:]]/) next
      if (low ~ /^[-+|[:space:]]+$/) next
      n = split(line, cols, /[[:space:]]+/)
      name = cols[1]
      status = (n >= 2 ? cols[2] : "unknown")
      gsub(/^[|]+|[|]+$/, "", name)
      gsub(/^[|]+|[|]+$/, "", status)
      gsub(/[^A-Za-z0-9_.-]+$/, "", status)
      if (name !~ /^[A-Za-z0-9_.-]+$/) next
      if (tolower(name) ~ /^(name|service|process)$/) next
      printf "%s\t%s\t%s\n", name, tolower(status), line
    }
  '
}

workspace_devbox_service_snapshot() {
  local worktree="$1"
  local defs statuses def line service tmp_dir devbox_error error_status

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/orch-runtime-devbox-services.XXXXXX")" || return 1
  defs="$tmp_dir/definitions"
  statuses="$tmp_dir/statuses"
  workspace_process_compose_services "$worktree" > "$defs" 2>/dev/null || true
  workspace_devbox_services_statuses "$worktree" > "$statuses"
  devbox_error="$(awk -F '\t' '$1 == "__devbox" { print $3; exit }' "$statuses")"

  if [[ ! -s "$defs" ]]; then
    awk -F '\t' '$1 != "__devbox" { print }' "$statuses"
    rm -rf "$tmp_dir"
    return 0
  fi

  if [[ -n "$devbox_error" ]]; then
    error_status="unknown"
    case "$(lower "$devbox_error")" in
      *"not running"* | *"not started"* | *"no services"* | *"no processes"*)
        error_status="not-started"
        ;;
    esac
    while IFS= read -r def; do
      [[ -n "$def" ]] || continue
      printf '%s\t%s\t%s\n' "$def" "$error_status" "$devbox_error"
    done < "$defs"
    rm -rf "$tmp_dir"
    return 0
  fi

  while IFS= read -r def; do
    [[ -n "$def" ]] || continue
    line="$(awk -F '\t' -v svc="$def" '$1 == svc { print; found = 1; exit }' "$statuses")"
    if [[ -n "$line" ]]; then
      printf '%s\n' "$line"
    else
      printf '%s\tnot-started\tnot started\n' "$def"
    fi
  done < "$defs"

  while IFS=$'\t' read -r service _; do
    [[ -n "$service" && "$service" != "__devbox" ]] || continue
    if ! grep -Fxq "$service" "$defs"; then
      awk -F '\t' -v svc="$service" '$1 == svc { print; exit }' "$statuses"
    fi
  done < "$statuses"

  rm -rf "$tmp_dir"
}

workspace_devbox_service_status_kind() {
  local status="$1"
  case "$(lower "$status")" in
    running|up|healthy|ok|started|starting)
      printf '%s' "ok"
      ;;
    not-started|stopped|disabled)
      printf '%s' "not-started"
      ;;
    unhealthy|exited|dead|failed|failure|error|restarting|crashed)
      printf '%s' "alert"
      ;;
    *)
      printf '%s' "unknown"
      ;;
  esac
}

workspace_devbox_services_summary() {
  local worktree="$1"
  local max="${2:-48}"
  local snapshot service status detail kind running alerts unknown not_started summary

  snapshot="$(workspace_devbox_service_snapshot "$worktree")"
  [[ -n "$snapshot" ]] || { printf '%s' "-"; return; }

  running=""
  alerts=""
  unknown=""
  not_started=""
  while IFS=$'\t' read -r service status detail; do
    [[ -n "$service" ]] || continue
    kind="$(workspace_devbox_service_status_kind "$status")"
    case "$kind" in
      ok) running="${running}${service}," ;;
      alert) alerts="${alerts}${service}:${status}," ;;
      not-started) not_started="${not_started}${service}," ;;
      *) unknown="${unknown}${service}:${status}," ;;
    esac
  done <<< "$snapshot"

  summary=""
  [[ -n "$running" ]] && summary="${summary}running:${running%,} "
  [[ -n "$alerts" ]] && summary="${summary}alert:${alerts%,} "
  [[ -n "$unknown" ]] && summary="${summary}unknown:${unknown%,} "
  [[ -n "$not_started" ]] && summary="${summary}not-started:${not_started%,}"
  summary="$(printf '%s' "$summary" | one_line)"
  [[ -n "$summary" ]] || summary="-"
  truncate_text "$summary" "$max"
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
