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
  [[ "$value" == http://* || "$value" == https://* || "$value" == ws://* || "$value" == wss://* ]]
}

workspace_report_port_link_allowed() {
  local key="$1"
  case "$key" in
    PORT | WEB_PORT | APP_PORT | DEV_PORT | API_PORT | HTTP_PORT | HTTPS_PORT | \
      HMR_PORT | WEBSOCKET_PORT | MCP_PORT | \
      *_WEB_PORT | *_APP_PORT | *_DEV_PORT | *_API_PORT | *_HTTP_PORT | *_HTTPS_PORT | *_HOST_PORT | \
      *_HMR_PORT | *_WEBSOCKET_PORT | *_MCP_PORT | *_COORDINATOR_PORT | *_ADK_PORT)
      return 0
      ;;
  esac
  return 1
}

workspace_env_value() {
  local worktree="$1"
  local wanted="$2"
  local key value

  while IFS=$'\t' read -r key value; do
    if [[ "$key" == "$wanted" ]]; then
      printf '%s' "$value"
      return 0
    fi
  done < <(workspace_env_lines "$worktree")
  return 1
}

workspace_preview_label_for_key() {
  local key="$1"
  case "$key" in
    FRONTEND_PREVIEW_URL | FRONTEND_URL)
      printf '%s' "frontend"
      ;;
    BACKEND_PREVIEW_URL | BACKEND_API_URL | BACKEND_URL | NEXT_PUBLIC_API_BASE_URL | VITE_BACKEND_URL)
      printf '%s' "backend"
      ;;
    AGENT_PREVIEW_URL | AGENT_URL | AGENT_COORDINATOR_URL)
      printf '%s' "agent"
      ;;
    AGENT_ADK_URL)
      printf '%s' "agent-adk"
      ;;
    AGENT_MCP_URL | MCP_PREVIEW_URL)
      printf '%s' "mcp"
      ;;
    FRONTEND_HMR_URL)
      printf '%s' "hmr"
      ;;
    FRONTEND_WEBSOCKET_URL)
      printf '%s' "websocket"
      ;;
    GCS_PREVIEW_URL)
      printf '%s' "gcs"
      ;;
    GCS_PROXY_URL)
      printf '%s' "gcs-proxy"
      ;;
    PGADMIN_PREVIEW_URL)
      printf '%s' "pgadmin"
      ;;
    *)
      return 1
      ;;
  esac
}

workspace_preview_urls() {
  local worktree="$1"
  local key value label seen
  seen=" "

  while IFS=$'\t' read -r key value; do
    [[ -n "$key" ]] || continue
    workspace_env_key_is_sensitive "$key" && continue
    workspace_report_value_is_url "$value" || continue
    label="$(workspace_preview_label_for_key "$key" 2>/dev/null || true)"
    [[ -n "$label" ]] || continue
    if [[ "$seen" == *" $label "* ]]; then
      continue
    fi
    printf '%s\t%s\t%s\n' "$label" "$key" "$value"
    seen="${seen}${label} "
  done < <(workspace_env_lines "$worktree")
}

workspace_preview_summary() {
  local worktree="$1"
  local max="${2:-80}"
  local label key value summary item
  summary=""

  while IFS=$'\t' read -r label key value; do
    [[ -n "$label" ]] || continue
    case "$label" in
      frontend | backend | agent | mcp)
        item="${label}=${value}"
        if [[ -z "$summary" ]]; then
          summary="$item"
        else
          summary="${summary} ${item}"
        fi
        ;;
    esac
  done < <(workspace_preview_urls "$worktree")

  if [[ -z "$summary" ]]; then
    printf '%s' "-"
    return
  fi
  truncate_text "$summary" "$max"
}

workspace_preview_primary_url() {
  local worktree="$1"
  local repo desired label key value first_http
  repo="$(workspace_env_value "$worktree" ORCH_REPO 2>/dev/null || true)"
  case "$repo" in
    frontend | backend | agent)
      desired="$repo"
      ;;
    *)
      desired=""
      ;;
  esac

  first_http=""
  while IFS=$'\t' read -r label key value; do
    [[ -n "$label" ]] || continue
    if [[ "$value" != http://* && "$value" != https://* ]]; then
      continue
    fi
    [[ -n "$first_http" ]] || first_http="$value"
    if [[ -n "$desired" && "$label" == "$desired" ]]; then
      printf '%s' "$value"
      return 0
    fi
  done < <(workspace_preview_urls "$worktree")

  if [[ -n "$first_http" ]]; then
    printf '%s' "$first_http"
    return 0
  fi
  return 1
}

workspace_report_preview_urls() {
  local worktree="$1"
  local found="false"
  local label key value

  echo "## Preview URLs"
  while IFS=$'\t' read -r label key value; do
    [[ -n "$label" ]] || continue
    printf -- '- `%s` (`%s`): %s\n' "$label" "$key" "$value"
    found="true"
  done < <(workspace_preview_urls "$worktree")

  if [[ "$found" == "false" ]]; then
    echo "- none detected from .orchestrate/env"
  fi
  echo
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
        HMR_PORT | WEBSOCKET_PORT | *_HMR_PORT | *_WEBSOCKET_PORT) scheme="ws" ;;
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

workspace_report_devbox_services() {
  local worktree="$1"
  local found="false"
  local service status detail

  echo "## Devbox Services"

  if [[ ! -f "$worktree/process-compose.yaml" && ! -f "$worktree/devbox.json" ]]; then
    echo "- process-compose.yaml / devbox.json not found"
    echo
    return
  fi

  echo "| Service | Status | Detail |"
  echo "|---|---|---|"
  while IFS=$'\t' read -r service status detail; do
    [[ -n "$service" ]] || continue
    printf '| `%s` | `%s` | %s |\n' \
      "$(markdown_cell "$service" 48)" \
      "$(markdown_cell "$status" 24)" \
      "$(markdown_cell "$detail" 96)"
    found="true"
  done < <(workspace_devbox_service_snapshot "$worktree")

  if [[ "$found" == "false" ]]; then
    echo "| - | `not-started` | no services detected |"
  fi
  echo
}

workspace_terraform_summary_line_is_sensitive() {
  local line
  line="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$line" in
    *secret* | *token* | *password* | *passwd* | *credential* | *private* | *api_key* | *sensitive*)
      return 0
      ;;
  esac
  return 1
}

workspace_report_terraform_plan() {
  local worktree="$1"
  local summary_file="$worktree/.orchestrate/terraform/summary.md"
  local found="false"
  local line

  echo "## Terraform Plan"

  if [[ ! -f "$summary_file" ]]; then
    echo "- .orchestrate/terraform/summary.md not found"
    echo
    return
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    if workspace_terraform_summary_line_is_sensitive "$line"; then
      continue
    fi
    printf '%s\n' "$line"
    found="true"
  done < "$summary_file"

  if [[ "$found" == "false" ]]; then
    echo "- summary contained no non-sensitive lines"
  fi
  echo
}

workspace_report_processor_section() {
  # Surface processor watcher state from .orchestrate/logs/<service>.log.
  # The 4 watchers (worker / queue-status / gpu-status / model-cache-check)
  # emit one structured JSON line per cycle. We tail the last non-empty line
  # per watcher and surface key metrics (state + service-specific numbers).
  #
  # Section is silent when no watcher log is present (graceful fallback for
  # non-processor worktrees and processor worktrees that have not yet started
  # services). Worker is reported as "running" with the latest ERROR / Traceback
  # line if any; the watchers are reported with their declared state field.
  local worktree="$1"
  local logs_dir="$worktree/.orchestrate/logs"
  local has_any="false"
  local svc

  for svc in queue-status gpu-status model-cache-check worker; do
    if [[ -f "$logs_dir/$svc.log" ]]; then
      has_any="true"
      break
    fi
  done
  [[ "$has_any" == "true" ]] || return 0

  echo "## Processor Watchers"
  echo
  echo "| Service | State | Latest |"
  echo "|---|---|---|"

  local log_file last_line last_line_unwrapped state metric_summary last_error
  for svc in worker queue-status gpu-status model-cache-check; do
    log_file="$logs_dir/$svc.log"
    if [[ ! -f "$log_file" ]]; then
      printf '| `%s` | `not-started` | log not found |\n' "$svc"
      continue
    fi
    # Last non-empty line. tac is GNU; macOS uses tail -r. Fallback to a
    # bounded tail+grep to keep the helper portable.
    if command -v tac >/dev/null 2>&1; then
      last_line="$(tac "$log_file" 2>/dev/null | grep -m 1 -v '^[[:space:]]*$' || true)"
    elif command -v tail >/dev/null 2>&1; then
      last_line="$(tail -n 50 "$log_file" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 1 || true)"
    else
      last_line=""
    fi

    if [[ -z "$last_line" ]]; then
      printf '| `%s` | `idle` | no output yet |\n' "$svc"
      continue
    fi

    # When started via `devbox services up` (process-compose), each watcher
    # JSON line is wrapped as {"level":"info","process":"<svc>","replica":0,
    # "message":"<raw watcher JSON>"}. We unwrap the message field so
    # downstream parsers see the watcher's own schema. When the watcher is
    # invoked directly (no process-compose wrapper), the line is already the
    # raw JSON and we pass it through unchanged.
    last_line_unwrapped="$(printf '%s' "$last_line" | ruby -rjson -e '
input = STDIN.read
begin
  d = JSON.parse(input)
  if d.is_a?(Hash) && d.key?("message") && d.key?("level") && d.key?("process")
    print d["message"]
  else
    print input
  end
rescue
  print input
end
' 2>/dev/null)"

    case "$svc" in
      worker)
        # worker emits free-form log lines (gpu_processor.main); surface the
        # most recent ERROR / Traceback / CRITICAL marker if any. The watcher
        # itself does not emit JSON, so we cannot extract a state field; we
        # default to "running" when the log has any output.
        if command -v tac >/dev/null 2>&1; then
          last_error="$(tac "$log_file" 2>/dev/null | grep -m 1 -E "ERROR|Traceback|CRITICAL" || true)"
        else
          last_error="$(tail -n 200 "$log_file" 2>/dev/null | grep -E "ERROR|Traceback|CRITICAL" | tail -n 1 || true)"
        fi
        if [[ -n "$last_error" ]]; then
          printf '| `%s` | `%s` | %s |\n' \
            "$svc" "running" \
            "latest_error: $(markdown_cell "$last_error" 96)"
        else
          printf '| `%s` | `%s` | %s |\n' "$svc" "running" "no recent ERROR"
        fi
        ;;
      queue-status|gpu-status|model-cache-check)
        state="$(printf '%s' "$last_line_unwrapped" | ruby -rjson -e 'begin; d = JSON.parse(STDIN.read); puts d["state"] || "unknown"; rescue; puts "parse-error"; end' 2>/dev/null)"
        case "$svc" in
          queue-status)
            metric_summary="$(printf '%s' "$last_line_unwrapped" | ruby -rjson -e 'begin; d = JSON.parse(STDIN.read); um = d["undelivered_messages"]; age = d["oldest_unacked_age_seconds"]; printf("undelivered=%s oldest_age=%s", um.nil? ? "?" : um, age.nil? ? "null" : age); rescue; print "n/a"; end' 2>/dev/null)"
            ;;
          gpu-status)
            metric_summary="$(printf '%s' "$last_line_unwrapped" | ruby -rjson -e 'begin; d = JSON.parse(STDIN.read); used = d["memory_used_mib"]; total = d["memory_total_mib"]; util = d["utilization_percent"]; dev = d["device"]; printf("device=%s mem=%s/%sMiB util=%s", dev || "?", used.nil? ? "?" : used, total.nil? ? "?" : total, util.nil? ? "?" : util); rescue; print "n/a"; end' 2>/dev/null)"
            ;;
          model-cache-check)
            metric_summary="$(printf '%s' "$last_line_unwrapped" | ruby -rjson -e 'begin; d = JSON.parse(STDIN.read); size = d["total_size_bytes"]; free = d["free_space_bytes"]; count = d["model_count"]; dups = d["duplicate_warnings"]; dup_count = (dups.is_a?(Array) ? dups.size : 0); printf("models=%s size=%sB free=%sB dups=%s", count.nil? ? "?" : count, size.nil? ? "?" : size, free.nil? ? "?" : free, dup_count); rescue; print "n/a"; end' 2>/dev/null)"
            ;;
        esac
        printf '| `%s` | `%s` | %s |\n' \
          "$svc" \
          "${state:-unknown}" \
          "$(markdown_cell "$metric_summary" 96)"
        ;;
    esac
  done
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
