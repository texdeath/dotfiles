# shellcheck shell=bash
# Multi-repo workspace group commands.

workspace_group_state_root() {
  if [[ -n "${ORCH_RUNTIME_GROUP_DIR:-}" ]]; then
    printf '%s' "$ORCH_RUNTIME_GROUP_DIR"
    return
  fi
  if [[ -n "${XDG_STATE_HOME:-}" ]]; then
    printf '%s/orch-runtime/groups' "$XDG_STATE_HOME"
    return
  fi
  printf '%s/.local/state/orch-runtime/groups' "$HOME"
}

workspace_group_validate_name() {
  local name="$1"
  [[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]] || die "workspace group name must match [A-Za-z0-9_.-]+: $name"
}

workspace_group_validate_field() {
  local label="$1"
  local value="$2"
  case "$value" in
    *$'\t'* | *$'\n'* | *$'\r'*)
      die "workspace group $label must not contain tabs or newlines"
      ;;
  esac
}

workspace_group_dir() {
  local group="$1"
  workspace_group_validate_name "$group"
  printf '%s/%s' "$(workspace_group_state_root)" "$group"
}

workspace_group_members_file() {
  local group="$1"
  printf '%s/members.tsv' "$(workspace_group_dir "$group")"
}

workspace_group_env_file() {
  local group="$1"
  printf '%s/env' "$(workspace_group_dir "$group")"
}

workspace_group_require() {
  local group="$1"
  local dir
  dir="$(workspace_group_dir "$group")"
  [[ -d "$dir" ]] || die "workspace group not found: $group (run 'orch-runtime workspace group create $group')"
}

workspace_group_create_dir() {
  local group="$1"
  local dir
  dir="$(workspace_group_dir "$group")"
  mkdir -p "$dir"
  touch "$dir/members.tsv" "$dir/env"
}

workspace_group_upsert_env() {
  local group="$1"
  local pair="$2"
  local key="${pair%%=*}"
  local value="${pair#*=}"
  [[ "$pair" == *=* ]] || die "workspace group env must be KEY=VALUE: $pair"
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "workspace group env key must match [A-Za-z_][A-Za-z0-9_]*: $key"
  workspace_group_validate_field "env value" "$value"

  local env_file tmp
  env_file="$(workspace_group_env_file "$group")"
  tmp="${env_file}.tmp.$$"
  if [[ -f "$env_file" ]]; then
    awk -F= -v key="$key" '$1 != key { print }' "$env_file" > "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$env_file"
}

workspace_group_upsert_member() {
  local group="$1"
  local role="$2"
  local workspace="$3"
  local profile="$4"
  local worktree="$5"
  local members tmp

  [[ -n "$workspace" ]] || die "workspace group member workspace is required"
  [[ -n "$role" ]] || role="$workspace"
  workspace_group_validate_field "role" "$role"
  workspace_group_validate_field "workspace" "$workspace"
  workspace_group_validate_field "profile" "$profile"
  workspace_group_validate_field "worktree" "$worktree"

  members="$(workspace_group_members_file "$group")"
  tmp="${members}.tmp.$$"
  if [[ -f "$members" ]]; then
    awk -F '\t' -v workspace="$workspace" '$2 != workspace { print }' "$members" > "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s\t%s\t%s\t%s\n' "$role" "$workspace" "$profile" "$worktree" >> "$tmp"
  mv "$tmp" "$members"
}

workspace_group_each_member() {
  local group="$1"
  local members
  members="$(workspace_group_members_file "$group")"
  [[ -f "$members" ]] || return 0
  awk -F '\t' 'NF >= 2 && $2 != "" { print }' "$members"
}

workspace_group_resolve_window() {
  local needle="$1"
  local -a matches=()
  local window_target name session_name

  command -v tmux >/dev/null 2>&1 || return 3
  tmux list-windows -a -F '#{session_name}:#{window_index}	#{window_name}	#{session_name}' >/dev/null 2>&1 || return 3

  while IFS=$'\t' read -r window_target name session_name; do
    if [[ "$name" == "$needle" || "$window_target" == "$needle" ]]; then
      matches+=("$window_target")
    fi
  done < <(tmux list-windows -a -F '#{session_name}:#{window_index}	#{window_name}	#{session_name}' 2>/dev/null)

  case "${#matches[@]}" in
    0) return 1 ;;
    1) printf '%s' "${matches[0]}"; return 0 ;;
    *) return 2 ;;
  esac
}

workspace_group_runtime_fields() {
  local workspace="$1"
  local stored_profile="$2"
  local stored_worktree="$3"
  local window_target rc profile session_name worktree pane_total state preview_summary

  rc=0
  window_target="$(workspace_group_resolve_window "$workspace")" || rc=$?
  profile="$stored_profile"
  worktree="$stored_worktree"
  pane_total="-"
  session_name="-"
  preview_summary="-"

  case "$rc" in
    0)
      state="running"
      session_name="$(tmux display-message -p -t "$window_target" '#{session_name}' 2>/dev/null || true)"
      pane_total="$(tmux list-panes -t "$window_target" -F '.' 2>/dev/null | wc -l | tr -d ' ')"
      if [[ -z "$profile" ]]; then
        profile="$(workspace_window_profile_from_meta "$window_target")"
        [[ "$profile" == "-" ]] && profile=""
      fi
      if [[ -z "$worktree" ]]; then
        worktree="$(workspace_window_canonical_worktree "$window_target" 2>/dev/null || true)"
      fi
      if [[ -z "$worktree" ]]; then
        worktree="$(tmux list-panes -t "$window_target" -F '#{pane_current_path}' 2>/dev/null | head -n 1)"
      fi
      ;;
    1)
      state="missing"
      ;;
    2)
      state="ambiguous"
      ;;
    *)
      state="tmux-unavailable"
      ;;
  esac

  [[ -n "$profile" ]] || profile="-"
  [[ -n "$worktree" ]] || worktree="-"
  if [[ "$worktree" != "-" ]]; then
    preview_summary="$(workspace_preview_summary "$worktree" 72)"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$state" "${window_target:-"-"}" "$session_name" "$profile" "$pane_total" "$preview_summary" "$worktree"
}

workspace_group_env_lines() {
  local group="$1"
  local env_file
  env_file="$(workspace_group_env_file "$group")"
  [[ -f "$env_file" ]] || return 0
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    /^[A-Za-z_][A-Za-z0-9_]*=/ {
      key = $0
      sub(/=.*/, "", key)
      value = $0
      sub(/^[^=]*=/, "", value)
      print key "\t" value
    }
  ' "$env_file"
}

workspace_group_report_env() {
  local group="$1"
  local found="false"
  local key value

  echo "## Group Environment"
  while IFS=$'\t' read -r key value; do
    [[ -n "$key" ]] || continue
    workspace_env_key_is_sensitive "$key" && continue
    printf -- '- `%s`: `%s`\n' "$key" "$value"
    found="true"
  done < <(workspace_group_env_lines "$group")
  if [[ "$found" == "false" ]]; then
    echo "- no non-sensitive group env recorded"
  fi
  echo
}

workspace_group_print_status_table() {
  local group="$1"
  local role workspace stored_profile stored_worktree state window session profile panes preview worktree

  printf '%-14s %-24s %-16s %-12s %-9s %-16s %-72s %s\n' "ROLE" "WORKSPACE" "STATE" "SESSION" "PANES" "PROFILE" "PREVIEW_URLS" "WORKTREE"
  while IFS=$'\t' read -r role workspace stored_profile stored_worktree; do
    [[ -n "$workspace" ]] || continue
    IFS=$'\t' read -r state window session profile panes preview worktree \
      <<<"$(workspace_group_runtime_fields "$workspace" "$stored_profile" "$stored_worktree")"
    printf '%-14s %-24s %-16s %-12s %-9s %-16s %-72s %s\n' \
      "$role" "$workspace" "$state" "$session" "$panes" "$profile" "$preview" "$worktree"
  done < <(workspace_group_each_member "$group")
}

cmd_workspace_group_create() {
  local group=""
  local -a env_pairs=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        env_pairs+=("$2")
        shift 2
        ;;
      -h|--help)
        cat <<'EOF'
Usage:
  orch-runtime workspace group create <feature-name> [--env KEY=VALUE ...]

Create a multi-repo workspace group. Group metadata is stored under
${ORCH_RUNTIME_GROUP_DIR:-$XDG_STATE_HOME/orch-runtime/groups}.
EOF
        return
        ;;
      -*)
        die "unknown option for workspace group create: $1"
        ;;
      *)
        [[ -z "$group" ]] || die "workspace group create takes a single feature name"
        group="$1"
        shift
        ;;
    esac
  done

  [[ -n "$group" ]] || die "workspace group create: <feature-name> is required"
  workspace_group_create_dir "$group"
  local pair
  for pair in "${env_pairs[@]}"; do
    workspace_group_upsert_env "$group" "$pair"
  done
  printf 'workspace group created: %s\n' "$group"
}

cmd_workspace_group_add() {
  local group=""
  local workspace=""
  local role=""
  local profile=""
  local worktree=""
  local window_target rc

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        role="$2"
        shift 2
        ;;
      --profile)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        profile="$2"
        shift 2
        ;;
      --worktree)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        worktree="$2"
        shift 2
        ;;
      -h|--help)
        cat <<'EOF'
Usage:
  orch-runtime workspace group add <feature-name> <workspace> [--role name] [--profile id] [--worktree path]

Attach an existing workspace window to a group. When tmux metadata is
available, profile/worktree are inferred from the workspace window; explicit
--profile/--worktree values are useful for pre-registering or tests.
EOF
        return
        ;;
      -*)
        die "unknown option for workspace group add: $1"
        ;;
      *)
        if [[ -z "$group" ]]; then
          group="$1"
        elif [[ -z "$workspace" ]]; then
          workspace="$1"
        else
          die "workspace group add takes <feature-name> <workspace>; extra arg: $1"
        fi
        shift
        ;;
    esac
  done

  [[ -n "$group" ]] || die "workspace group add: <feature-name> is required"
  [[ -n "$workspace" ]] || die "workspace group add: <workspace> is required"
  workspace_group_require "$group"

  rc=0
  window_target="$(workspace_group_resolve_window "$workspace")" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    if [[ -z "$profile" ]]; then
      profile="$(workspace_window_profile_from_meta "$window_target")"
      [[ "$profile" == "-" ]] && profile=""
    fi
    if [[ -z "$worktree" ]]; then
      worktree="$(workspace_window_canonical_worktree "$window_target" 2>/dev/null || true)"
    fi
    if [[ -z "$worktree" ]]; then
      worktree="$(tmux list-panes -t "$window_target" -F '#{pane_current_path}' 2>/dev/null | head -n 1)"
    fi
  elif [[ "$rc" -eq 2 ]]; then
    die "workspace group add: workspace name is ambiguous: $workspace (use session:index)"
  elif [[ -z "$profile" && -z "$worktree" ]]; then
    die "workspace group add: workspace not found: $workspace (or pass --profile/--worktree to pre-register)"
  fi

  workspace_group_upsert_member "$group" "$role" "$workspace" "$profile" "$worktree"
  printf 'workspace group member added: %s -> %s\n' "$group" "$workspace"
}

cmd_workspace_group_status() {
  local group=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        cat <<'EOF'
Usage:
  orch-runtime workspace group status <feature-name>

List the runtime state of every workspace registered in a group.
EOF
        return
        ;;
      -*)
        die "unknown option for workspace group status: $1"
        ;;
      *)
        [[ -z "$group" ]] || die "workspace group status takes a single feature name"
        group="$1"
        shift
        ;;
    esac
  done

  [[ -n "$group" ]] || die "workspace group status: <feature-name> is required"
  workspace_group_require "$group"
  workspace_group_print_status_table "$group"
}

cmd_workspace_group_report() {
  local group=""
  local lines=80

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--lines)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        lines="$2"
        shift 2
        ;;
      -h|--help)
        cat <<'EOF'
Usage:
  orch-runtime workspace group report <feature-name> [-n lines]

Emit a Markdown report for a multi-repo feature workspace. The report includes
group env, member runtime state, and per-workspace runtime reports for running
members.
EOF
        return
        ;;
      -*)
        die "unknown option for workspace group report: $1"
        ;;
      *)
        [[ -z "$group" ]] || die "workspace group report takes a single feature name"
        group="$1"
        shift
        ;;
    esac
  done

  [[ -n "$group" ]] || die "workspace group report: <feature-name> is required"
  is_positive_int "$lines" || die "line count must be a positive integer"
  workspace_group_require "$group"

  local timestamp role workspace stored_profile stored_worktree state window session profile panes preview worktree
  timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"

  cat <<EOF
# Workspace Group Report: $group

## Summary

- group: $group
- generated_at: $timestamp
- lines_per_workspace: $lines

EOF

  workspace_group_report_env "$group"

  echo "## Member Status"
  echo
  echo "| Role | Workspace | State | Session | Panes | Profile | Preview URLs | Worktree |"
  echo "|---|---|---|---|---|---|---|---|"
  while IFS=$'\t' read -r role workspace stored_profile stored_worktree; do
    [[ -n "$workspace" ]] || continue
    IFS=$'\t' read -r state window session profile panes preview worktree \
      <<<"$(workspace_group_runtime_fields "$workspace" "$stored_profile" "$stored_worktree")"
    printf '| `%s` | `%s` | `%s` | `%s` | `%s` | `%s` | %s | `%s` |\n' \
      "$(markdown_cell "$role" 32)" \
      "$(markdown_cell "$workspace" 48)" \
      "$(markdown_cell "$state" 24)" \
      "$(markdown_cell "$session" 24)" \
      "$(markdown_cell "$panes" 8)" \
      "$(markdown_cell "$profile" 32)" \
      "$(markdown_cell "$preview" 96)" \
      "$(markdown_cell "$worktree" 96)"
  done < <(workspace_group_each_member "$group")
  echo

  echo "## Workspace Reports"
  echo
  while IFS=$'\t' read -r role workspace stored_profile stored_worktree; do
    [[ -n "$workspace" ]] || continue
    IFS=$'\t' read -r state window session profile panes preview worktree \
      <<<"$(workspace_group_runtime_fields "$workspace" "$stored_profile" "$stored_worktree")"
    printf '## Workspace: %s (%s)\n\n' "$workspace" "$role"
    if [[ "$state" != "running" ]]; then
      printf -- '- skipped: workspace state is `%s`\n\n' "$state"
      continue
    fi
    (cmd_workspace_report "$window" -n "$lines") || printf -- '- report failed for `%s`\n\n' "$workspace"
  done < <(workspace_group_each_member "$group")
}

cmd_workspace_group_stop() {
  local group=""
  local archive_logs="false"
  local force="false"
  local failures=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --archive-logs)
        archive_logs="true"
        shift
        ;;
      --force)
        force="true"
        shift
        ;;
      -h|--help)
        cat <<'EOF'
Usage:
  orch-runtime workspace group stop <feature-name> [--archive-logs] [--force]

Stop every running workspace registered in a group. Missing members are
reported and skipped. Group metadata is kept for later status/report runs.
EOF
        return
        ;;
      -*)
        die "unknown option for workspace group stop: $1"
        ;;
      *)
        [[ -z "$group" ]] || die "workspace group stop takes a single feature name"
        group="$1"
        shift
        ;;
    esac
  done

  [[ -n "$group" ]] || die "workspace group stop: <feature-name> is required"
  workspace_group_require "$group"

  local role workspace stored_profile stored_worktree state window session profile panes preview worktree
  while IFS=$'\t' read -r role workspace stored_profile stored_worktree; do
    [[ -n "$workspace" ]] || continue
    IFS=$'\t' read -r state window session profile panes preview worktree \
      <<<"$(workspace_group_runtime_fields "$workspace" "$stored_profile" "$stored_worktree")"
    if [[ "$state" != "running" ]]; then
      printf 'workspace group stop: skipped %s (%s)\n' "$workspace" "$state" >&2
      failures=$((failures + 1))
      continue
    fi
    local -a stop_args=("$window")
    [[ "$archive_logs" == "true" ]] && stop_args+=(--archive-logs)
    [[ "$force" == "true" ]] && stop_args+=(--force)
    if ! (cmd_workspace_stop "${stop_args[@]}"); then
      failures=$((failures + 1))
    fi
  done < <(workspace_group_each_member "$group")

  [[ "$failures" -eq 0 ]]
}

cmd_workspace_group() {
  local sub="${1:-}"
  if [[ -z "$sub" || "$sub" == "-h" || "$sub" == "--help" ]]; then
    cat <<'EOF'
Usage:
  orch-runtime workspace group create <feature-name> [--env KEY=VALUE ...]
  orch-runtime workspace group add <feature-name> <workspace> [--role name] [--profile id] [--worktree path]
  orch-runtime workspace group status <feature-name>
  orch-runtime workspace group report <feature-name> [-n lines]
  orch-runtime workspace group stop <feature-name> [--archive-logs] [--force]
EOF
    return
  fi
  shift
  case "$sub" in
    create)
      cmd_workspace_group_create "$@"
      ;;
    add)
      cmd_workspace_group_add "$@"
      ;;
    status)
      cmd_workspace_group_status "$@"
      ;;
    report)
      cmd_workspace_group_report "$@"
      ;;
    stop)
      cmd_workspace_group_stop "$@"
      ;;
    *)
      die "unknown workspace group subcommand: $sub (expected: create, add, status, report, stop)"
      ;;
  esac
}
