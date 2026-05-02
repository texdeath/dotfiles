# shellcheck shell=bash
# Markdown runtime reports for workspace tmux windows.

workspace_git_branch() {
  local path="$1"
  local branch
  [[ -d "$path" ]] || { printf '%s' "-"; return; }
  command -v git >/dev/null 2>&1 || { printf '%s' "-"; return; }
  git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf '%s' "-"; return; }
  branch="$(git -C "$path" branch --show-current 2>/dev/null || true)"
  if [[ -n "$branch" ]]; then
    printf '%s' "$branch"
    return
  fi
  branch="$(git -C "$path" rev-parse --short HEAD 2>/dev/null || true)"
  [[ -n "$branch" ]] && printf 'detached:%s' "$branch" || printf '%s' "-"
}

workspace_env_lines() {
  local worktree="$1"
  local env_file="$worktree/.orchestrate/env"
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

workspace_env_key_is_sensitive() {
  local key
  key="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  case "$key" in
    *SECRET* | *TOKEN* | *PASSWORD* | *PASSWD* | *CREDENTIAL* | *PRIVATE* | *API_KEY* | *_KEY | KEY)
      return 0
      ;;
  esac
  return 1
}

workspace_report_value_is_url() {
  local value="$1"
  [[ "$value" == http://* || "$value" == https://* ]]
}

workspace_report_port_link_allowed() {
  local key="$1"
  case "$key" in
    PORT | WEB_PORT | APP_PORT | DEV_PORT | API_PORT | HTTP_PORT | HTTPS_PORT | \
      *_WEB_PORT | *_APP_PORT | *_DEV_PORT | *_API_PORT | *_HTTP_PORT | *_HTTPS_PORT | *_HOST_PORT)
      return 0
      ;;
  esac
  return 1
}

workspace_report_runtime_links() {
  local worktree="$1"
  local found="false"
  local key value scheme

  echo "## Runtime Links"
  while IFS=$'\t' read -r key value; do
    [[ -n "$key" ]] || continue
    workspace_env_key_is_sensitive "$key" && continue
    if workspace_report_value_is_url "$value"; then
      printf -- '- `%s`: %s\n' "$key" "$value"
      found="true"
    elif workspace_report_port_link_allowed "$key" && [[ "$value" =~ ^[0-9]+$ ]]; then
      scheme="http"
      case "$key" in
        HTTPS_PORT | *_HTTPS_PORT) scheme="https" ;;
      esac
      printf -- '- `%s`: %s://localhost:%s\n' "$key" "$scheme" "$value"
      found="true"
    fi
  done < <(workspace_env_lines "$worktree")

  if [[ "$found" == "false" ]]; then
    echo "- none detected from .orchestrate/env"
  fi
  echo
}

workspace_report_runtime_env() {
  local worktree="$1"
  local found="false"
  local key value

  echo "## Runtime Environment"
  while IFS=$'\t' read -r key value; do
    [[ -n "$key" ]] || continue
    workspace_env_key_is_sensitive "$key" && continue
    printf -- '- `%s`: `%s`\n' "$key" "$value"
    found="true"
  done < <(workspace_env_lines "$worktree")

  if [[ "$found" == "false" ]]; then
    echo "- .orchestrate/env not found or no non-sensitive runtime keys detected"
  fi
  echo
}

workspace_report_docker_compose() {
  local worktree="$1"
  local args_file="$worktree/.orchestrate/compose.args"
  local compose_args

  echo "## Docker Compose"

  if [[ ! -f "$args_file" ]]; then
    echo "- .orchestrate/compose.args not found"
    echo
    return
  fi

  compose_args="$(tr '\n' ' ' < "$args_file" | one_line)"
  if [[ -z "$compose_args" ]]; then
    echo "- .orchestrate/compose.args is empty"
    echo
    return
  fi

  printf -- '- command: `docker compose %s ps`\n\n' "$compose_args"

  if ! command -v docker >/dev/null 2>&1; then
    printf '```text\n'
    echo "docker command not found"
    printf '```\n'
    echo
    return
  fi

  printf '```text\n'
  # shellcheck disable=SC2046
  (cd "$worktree" && docker compose $(cat "$args_file") ps 2>&1) || true
  printf '```\n'
  echo
}

workspace_report_state_counts() {
  local window_target="$1"
  local lines="$2"
  local error_count=0 asking_count=0 working_count=0 idle_count=0 unknown_count=0 total_count=0
  local pane screen state

  while IFS= read -r pane; do
    screen="$(capture_pane "$pane" "$lines" 2>/dev/null || true)"
    state="$(pane_state "$screen")"
    total_count=$((total_count + 1))
    case "$state" in
      error) error_count=$((error_count + 1)) ;;
      asking) asking_count=$((asking_count + 1)) ;;
      working) working_count=$((working_count + 1)) ;;
      idle) idle_count=$((idle_count + 1)) ;;
      *) unknown_count=$((unknown_count + 1)) ;;
    esac
  done < <(tmux list-panes -t "$window_target" -F '#{pane_id}' 2>/dev/null)

  printf -- '- total: %s\n' "$total_count"
  printf -- '- error: %s\n' "$error_count"
  printf -- '- asking: %s\n' "$asking_count"
  printf -- '- working: %s\n' "$working_count"
  printf -- '- idle: %s\n' "$idle_count"
  printf -- '- unknown: %s\n' "$unknown_count"
}

markdown_cell() {
  local text="$1"
  local max="${2:-80}"
  text="$(printf '%s' "$text" | tr '\n' ' ' | sed 's/|/\\|/g')"
  truncate_text "$text" "$max"
}

workspace_report_pane_summary() {
  local window_target="$1"
  local lines="$2"
  local pane screen state label target active command title path last

  echo "## Pane Summary"
  workspace_report_state_counts "$window_target" "$lines"
  echo
  echo "| Pane | Target | State | Agent | Active | Command | Title | Path | Last Output |"
  echo "|---|---|---|---|---|---|---|---|---|"

  while IFS= read -r pane; do
    screen="$(capture_pane "$pane" "$lines" 2>/dev/null || true)"
    state="$(pane_state "$screen")"
    command="$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null || true)"
    title="$(tmux display-message -p -t "$pane" '#{pane_title}' 2>/dev/null || true)"
    path="$(tmux display-message -p -t "$pane" '#{pane_current_path}' 2>/dev/null || true)"
    target="$(tmux display-message -p -t "$pane" '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)"
    active="$(pane_active_text "$(tmux display-message -p -t "$pane" '#{pane_active}' 2>/dev/null || true)")"
    label="$(detect_label "$pane" "$command" "$title")"
    last="$(printf '%s\n' "$screen" | last_nonempty_line | one_line)"

    printf '| `%s` | `%s` | %s | %s | %s | `%s` | %s | `%s` | %s |\n' \
      "$pane" \
      "$(markdown_cell "$target" 32)" \
      "$(markdown_cell "$state" 16)" \
      "$(markdown_cell "$label" 16)" \
      "$(markdown_cell "$active" 8)" \
      "$(markdown_cell "$command" 32)" \
      "$(markdown_cell "$title" 36)" \
      "$(markdown_cell "$path" 64)" \
      "$(markdown_cell "$last" 96)"
  done < <(tmux list-panes -t "$window_target" -F '#{pane_id}' 2>/dev/null)
  echo
}

workspace_report_error_signals() {
  local window_target="$1"
  local lines="$2"
  local found="false"
  local pane screen state target

  echo "## Recent Error Signals"

  while IFS= read -r pane; do
    screen="$(capture_pane "$pane" "$lines" 2>/dev/null || true)"
    state="$(pane_state "$screen")"
    if [[ "$state" != "error" ]] && ! printf '%s\n' "$screen" | grep -Eiq 'error|failed|failure|exception|traceback|panic:|command not found|permission denied|tests? failed'; then
      continue
    fi
    target="$(tmux display-message -p -t "$pane" '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)"
    printf '### Pane %s (%s)\n\n' "$pane" "$target"
    printf '```text\n'
    printf '%s\n' "$screen" | grep -Ein 'error|failed|failure|exception|traceback|panic:|command not found|permission denied|tests? failed' | tail -20 || true
    printf '```\n'
    echo
    found="true"
  done < <(tmux list-panes -t "$window_target" -F '#{pane_id}' 2>/dev/null)

  if [[ "$found" == "false" ]]; then
    echo "- none detected in captured pane output"
    echo
  fi
}

workspace_report_pane_details() {
  local window_target="$1"
  local lines="$2"
  local pane screen command title path target active label state

  echo "## Pane Captures"

  while IFS= read -r pane; do
    screen="$(capture_pane "$pane" "$lines" 2>/dev/null || true)"
    command="$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null || true)"
    title="$(tmux display-message -p -t "$pane" '#{pane_title}' 2>/dev/null || true)"
    path="$(tmux display-message -p -t "$pane" '#{pane_current_path}' 2>/dev/null || true)"
    target="$(tmux display-message -p -t "$pane" '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)"
    active="$(pane_active_text "$(tmux display-message -p -t "$pane" '#{pane_active}' 2>/dev/null || true)")"
    label="$(detect_label "$pane" "$command" "$title")"
    state="$(pane_state "$screen")"

    cat <<EOF
### Pane $pane

- target: $target
- agent: $label
- state: $state
- active: $active
- command: $command
- title: $title
- path: $path

Recent output:
\`\`\`text
$screen
\`\`\`

EOF
  done < <(tmux list-panes -t "$window_target" -F '#{pane_id}' 2>/dev/null)
}
