# shellcheck shell=bash
# Workspace-level runtime watch signals.

WORKSPACE_WATCH_DEFAULT_INTERVAL=5
WORKSPACE_WATCH_DEFAULT_STALE_SECONDS=300
WORKSPACE_WATCH_DEFAULT_COMPOSE_TIMEOUT=8

workspace_watch_usage() {
  cat <<'EOF'
Usage:
  orch-runtime workspace watch <workspace> [-n lines] [-i seconds] [--stale-seconds seconds] [--log-file path] [--once]

Continuously inspect a workspace tmux window and print a summary when runtime
signals change. Signals cover AI panes waiting for input, stopped dev/API panes,
test/typecheck failures, docker compose unhealthy/exited services, panes that
disappear or exit, Devbox services that are started and unhealthy/exited, and
stale output for long-running runtime panes.

Options:
  -n, --lines N             captured lines per pane (default: 120)
  -i, --interval seconds    poll interval (default: 5)
  --stale-seconds seconds   unchanged output threshold (default: 300)
  --log-file path           append emitted summaries to a log file
  --once                    print one snapshot and exit
EOF
}

workspace_watch_record_field() {
  local file="$1"
  local key="$2"
  local field="$3"

  [[ -f "$file" ]] || return 0
  awk -F '\t' -v key="$key" -v field="$field" '
    $1 == key {
      print $field
      found = 1
      exit
    }
    END {
      if (!found) print ""
    }
  ' "$file"
}

workspace_watch_hash_text() {
  cksum | awk '{print $1 ":" $2}'
}

workspace_watch_pane_role() {
  local label="$1"
  local command="$2"
  local title="$3"
  local path="$4"
  local screen="$5"
  local haystack

  if [[ "$label" == "claude" || "$label" == "codex" ]]; then
    echo "ai"
    return
  fi

  haystack="$(lower "$command $title $path $(printf '%s\n' "$screen" | tail -80)")"
  case "$haystack" in
    *typecheck* | *"tsc "* | *" tsc"* | *"test "* | *" test"* | *vitest* | *jest* | *pytest* | *"go test"* | *rspec* | *"cargo test"*)
      echo "test"
      ;;
    *"compose logs"* | *"docker logs"* | *" logs"*)
      echo "log"
      ;;
    *"compose up"*)
      echo "compose-up"
      ;;
    *"docker compose"* | *"compose ps"* | *container*)
      echo "compose"
      ;;
    *" run dev"* | *"npm run dev"* | *"pnpm dev"* | *"yarn dev"* | *vite* | *"next dev"* | *"rails s"* | *"rails server"* | *"dev server"* | *" api"* | *"/api"* | *"server listening"* | *"listening on"* | *"localhost:"*)
      echo "dev"
      ;;
    *)
      echo "other"
      ;;
  esac
}

workspace_watch_staleness_enabled() {
  local role="$1"
  local state="$2"
  local screen="$3"
  local haystack

  [[ "$state" != "idle" ]] || return 1

  case "$role" in
    test|compose|compose-up|log)
      return 0
      ;;
    dev)
      [[ "$state" == "working" ]] && return 0
      haystack="$(lower "$screen")"
      if printf '%s\n' "$haystack" | grep -Eq 'starting|building|compiling|waiting|loading'; then
        return 0
      fi
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

workspace_watch_pane_status() {
  local role="$1"
  local label="$2"
  local state="$3"
  local dead="$4"
  local stale="$5"
  local screen="$6"
  local last="$7"
  local recent

  recent="$(printf '%s\n' "$screen" | tail -80)"

  if [[ "$dead" == "1" ]]; then
    printf 'alert\tpane exited'
    return
  fi

  if [[ "$role" == "ai" && "$state" == "asking" ]]; then
    printf 'alert\t%s pane is waiting for input: %s' "$label" "$last"
    return
  fi

  if [[ "$role" == "dev" ]]; then
    if [[ "$state" == "error" ]]; then
      printf 'alert\tdev/API pane shows an error: %s' "$last"
      return
    fi
    if [[ "$state" == "idle" ]]; then
      printf 'alert\tdev/API command appears to have returned to a shell prompt: %s' "$last"
      return
    fi
  fi

  if [[ "$role" == "test" ]] && printf '%s\n' "$recent" | grep -Eiq 'failed|failure|tests? failed|error|exception|traceback|panic:'; then
    printf 'alert\ttest/typecheck failure detected: %s' "$last"
    return
  fi

  if [[ "$role" == "compose" && "$state" == "error" ]]; then
    printf 'alert\tcompose pane shows an error: %s' "$last"
    return
  fi

  if [[ "$role" == "compose-up" && "$state" == "idle" ]]; then
    printf 'alert\tcompose command appears to have returned to a shell prompt: %s' "$last"
    return
  fi

  if [[ "$stale" == "true" ]]; then
    printf 'stale\toutput has not changed: %s' "$last"
    return
  fi

  printf 'ok\t%s pane is %s: %s' "$role" "$state" "$last"
}

workspace_watch_root_from_window() {
  local window_target="$1"
  local pane_path path

  while IFS= read -r pane_path; do
    [[ -n "$pane_path" && -d "$pane_path" ]] || continue
    path="$pane_path"
    while [[ "$path" != "/" && -n "$path" ]]; do
      if [[ -d "$path/.orchestrate" ]]; then
        printf '%s' "$path"
        return
      fi
      path="$(dirname "$path")"
    done
  done < <(tmux list-panes -t "$window_target" -F '#{pane_current_path}' 2>/dev/null)
}

workspace_watch_run_with_timeout() {
  run_with_timeout "$@"
}

workspace_watch_compose_signal() {
  local worktree="$1"
  local args_file="$worktree/.orchestrate/compose.args"
  local compose_output compose_rc status detail timeout_seconds

  [[ -n "$worktree" && -f "$args_file" ]] || return 0

  if ! command -v docker >/dev/null 2>&1; then
    printf 'compose\tcompose\tunknown\tdocker command not found\t-\t0\n'
    return
  fi

  timeout_seconds="${ORCH_RUNTIME_WATCH_COMPOSE_TIMEOUT:-$WORKSPACE_WATCH_DEFAULT_COMPOSE_TIMEOUT}"
  is_positive_int "$timeout_seconds" || timeout_seconds="$WORKSPACE_WATCH_DEFAULT_COMPOSE_TIMEOUT"

  compose_rc=0
  compose_output="$(
    workspace_watch_run_with_timeout "$timeout_seconds" bash -c '
      cd "$1" || exit 1
      # shellcheck disable=SC2046
      docker compose $(cat "$2") ps
    ' _ "$worktree" "$args_file" 2>&1
  )" || compose_rc=$?
  if [[ "$compose_rc" -ne 0 && -z "$compose_output" ]]; then
    compose_output="docker compose ps timed out after ${timeout_seconds}s or exited with $compose_rc"
  fi

  if [[ "$compose_rc" -ne 0 ]]; then
    status="alert"
    detail="$(printf '%s\n' "$compose_output" | grep -v '^[[:space:]]*$' | tail -1 | one_line)"
    detail="${detail:-docker compose ps exited $compose_rc}"
    printf 'compose\tcompose\t%s\tcompose ps failed: %s\t-\t0\n' "$status" "$(truncate_text "$detail" 120)"
    return
  fi

  detail="$(printf '%s\n' "$compose_output" | grep -Ei 'unhealthy|exited|dead|restarting' | one_line)"
  if [[ -n "$detail" ]]; then
    status="alert"
    detail="compose service unhealthy/exited: $(truncate_text "$detail" 120)"
  else
    status="ok"
    detail="$(printf '%s\n' "$compose_output" | grep -v '^[[:space:]]*$' | tail -1 | one_line)"
    detail="${detail:-compose ps returned no services}"
    detail="compose services ok: $(truncate_text "$detail" 120)"
  fi

  printf 'compose\tcompose\t%s\t%s\t-\t0\n' "$status" "$detail"
}

workspace_watch_devbox_services_signal() {
  local worktree="$1"
  local service status detail kind watch_status watch_detail

  [[ -n "$worktree" && -d "$worktree" ]] || return 0
  [[ -f "$worktree/process-compose.yaml" || -f "$worktree/devbox.json" ]] || return 0

  while IFS=$'\t' read -r service status detail; do
    [[ -n "$service" ]] || continue
    kind="$(workspace_devbox_service_status_kind "$status")"
    [[ "$kind" != "not-started" ]] || continue

    case "$kind" in
      alert)
        watch_status="alert"
        watch_detail="devbox service ${service} is ${status}: $(truncate_text "$detail" 120)"
        ;;
      ok)
        watch_status="ok"
        watch_detail="devbox service ${service} is ${status}"
        ;;
      *)
        watch_status="unknown"
        watch_detail="devbox service ${service} status is ${status}: $(truncate_text "$detail" 120)"
        ;;
    esac
    printf 'devbox:%s\tdevbox-service\t%s\t%s\t-\t0\n' "$service" "$watch_status" "$watch_detail"
  done < <(workspace_devbox_service_snapshot "$worktree")
}

workspace_watch_snapshot() {
  local window_target="$1"
  local lines="$2"
  local stale_seconds="$3"
  local previous="$4"
  local now="$5"
  local worktree="$6"

  local pane command title path dead screen state label role last hash previous_hash previous_changed_at changed_at stale status detail status_detail
  while IFS=$'\t' read -r pane command title path dead; do
    [[ -n "$pane" ]] || continue
    screen="$(capture_pane "$pane" "$lines" 2>/dev/null || true)"
    state="$(pane_state "$screen")"
    label="$(detect_label "$pane" "$command" "$title")"
    role="$(workspace_watch_pane_role "$label" "$command" "$title" "$path" "$screen")"
    last="$(printf '%s\n' "$screen" | last_nonempty_line | one_line)"
    last="$(truncate_text "$last" 100)"
    hash="$(printf '%s' "$screen" | workspace_watch_hash_text)"
    previous_hash="$(workspace_watch_record_field "$previous" "pane:$pane" 5)"
    previous_changed_at="$(workspace_watch_record_field "$previous" "pane:$pane" 6)"

    if [[ -z "$previous_hash" || "$previous_hash" != "$hash" || -z "$previous_changed_at" ]]; then
      changed_at="$now"
    else
      changed_at="$previous_changed_at"
    fi

    stale="false"
    if workspace_watch_staleness_enabled "$role" "$state" "$screen" && (( now - changed_at >= stale_seconds )); then
      stale="true"
    fi

    status_detail="$(workspace_watch_pane_status "$role" "$label" "$state" "$dead" "$stale" "$screen" "$last")"
    status="${status_detail%%$'\t'*}"
    detail="${status_detail#*$'\t'}"
    printf 'pane:%s\t%s\t%s\t%s\t%s\t%s\n' "$pane" "$role" "$status" "$detail" "$hash" "$changed_at"
  done < <(tmux list-panes -t "$window_target" -F '#{pane_id}	#{pane_current_command}	#{pane_title}	#{pane_current_path}	#{pane_dead}' 2>/dev/null)

  workspace_watch_compose_signal "$worktree"
  workspace_watch_devbox_services_signal "$worktree"
}

workspace_watch_append_missing_panes() {
  local previous="$1"
  local current="$2"
  local previous_key

  [[ -f "$previous" ]] || return 0
  while IFS=$'\t' read -r previous_key _; do
    [[ "$previous_key" == pane:* ]] || continue
    if ! awk -F '\t' -v key="$previous_key" '$1 == key { found = 1 } END { exit(found ? 0 : 1) }' "$current"; then
      printf '%s\tpane\talert\tpane disappeared from workspace\t-\t0\n' "$previous_key" >> "$current"
    fi
  done < "$previous"
}

workspace_watch_record_changed() {
  local previous="$1"
  local key="$2"
  local status="$3"
  local detail="$4"
  local previous_status previous_detail

  previous_status="$(workspace_watch_record_field "$previous" "$key" 3)"
  previous_detail="$(workspace_watch_record_field "$previous" "$key" 4)"
  [[ "$previous_status" != "$status" || "$previous_detail" != "$detail" ]]
}

workspace_watch_emit_summary() {
  local workspace="$1"
  local window_target="$2"
  local worktree="$3"
  local current="$4"
  local previous="$5"
  local log_file="$6"
  local now_text="$7"
  local tmp_out="$8"

  local total=0 alert_count=0 stale_count=0 unknown_count=0 ok_count=0
  local key category status detail hash changed_at
  local changed="false"

  while IFS=$'\t' read -r key category status detail hash changed_at; do
    [[ -n "$key" ]] || continue
    total=$((total + 1))
    case "$status" in
      alert) alert_count=$((alert_count + 1)) ;;
      stale) stale_count=$((stale_count + 1)) ;;
      unknown) unknown_count=$((unknown_count + 1)) ;;
      ok) ok_count=$((ok_count + 1)) ;;
    esac
    if workspace_watch_record_changed "$previous" "$key" "$status" "$detail"; then
      changed="true"
    fi
  done < "$current"

  [[ "$changed" == "true" ]] || return 1

  {
    printf '%s workspace=%s window=%s total=%s ok=%s alert=%s stale=%s unknown=%s\n' \
      "$now_text" "$workspace" "$window_target" "$total" "$ok_count" "$alert_count" "$stale_count" "$unknown_count"
    while IFS=$'\t' read -r key category status detail hash changed_at; do
      [[ -n "$key" ]] || continue
      if workspace_watch_record_changed "$previous" "$key" "$status" "$detail"; then
        metrics_emit_watch_signal "$worktree" "$workspace" "$window_target" "$key" "$category" "$status" "$detail"
        printf '  - %-12s %-8s %-7s %s\n' "$key" "$category" "$status" "$detail"
      fi
    done < "$current"
  } > "$tmp_out"

  cat "$tmp_out"
  if [[ -n "$log_file" ]]; then
    cat "$tmp_out" >> "$log_file"
  fi
}

cmd_workspace_watch() {
  local workspace=""
  local lines="$DEFAULT_LINES"
  local interval="$WORKSPACE_WATCH_DEFAULT_INTERVAL"
  local stale_seconds="$WORKSPACE_WATCH_DEFAULT_STALE_SECONDS"
  local once="false"
  local log_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--lines)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        lines="$2"
        shift 2
        ;;
      -i|--interval)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        interval="$2"
        shift 2
        ;;
      --stale-seconds)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        stale_seconds="$2"
        shift 2
        ;;
      --log-file)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        log_file="$2"
        shift 2
        ;;
      --once)
        once="true"
        shift
        ;;
      -h|--help)
        workspace_watch_usage
        return
        ;;
      -*)
        die "unknown option for workspace watch: $1"
        ;;
      *)
        [[ -z "$workspace" ]] || die "workspace watch takes a single workspace argument"
        workspace="$1"
        shift
        ;;
    esac
  done

  [[ -n "$workspace" ]] || die "workspace watch: workspace name is required"
  is_positive_int "$lines" || die "line count must be a positive integer"
  is_positive_int "$interval" || die "interval must be a positive integer"
  is_positive_int "$stale_seconds" || die "stale seconds must be a positive integer"
  need_tmux

  local window_target worktree previous current tmp_out now now_text
  window_target="$(workspace_resolve_window "$workspace")"
  worktree="$(workspace_watch_root_from_window "$window_target")"

  if [[ -n "$log_file" ]]; then
    : >> "$log_file" || die "workspace watch: cannot write log file: $log_file"
  fi

  previous="$(mktemp "${TMPDIR:-/tmp}/orch-runtime-workspace-watch-prev.XXXXXX")"
  current="$(mktemp "${TMPDIR:-/tmp}/orch-runtime-workspace-watch-current.XXXXXX")"
  tmp_out="$(mktemp "${TMPDIR:-/tmp}/orch-runtime-workspace-watch-out.XXXXXX")"
  ORCH_RUNTIME_WORKSPACE_WATCH_PREVIOUS="$previous"
  ORCH_RUNTIME_WORKSPACE_WATCH_CURRENT="$current"
  ORCH_RUNTIME_WORKSPACE_WATCH_OUT="$tmp_out"
  trap 'rm -f "$ORCH_RUNTIME_WORKSPACE_WATCH_PREVIOUS" "$ORCH_RUNTIME_WORKSPACE_WATCH_CURRENT" "$ORCH_RUNTIME_WORKSPACE_WATCH_OUT"' EXIT

  printf 'Watching workspace %s (%s) every %ss; stale threshold %ss. Press Ctrl-C to stop.\n' \
    "$workspace" "$window_target" "$interval" "$stale_seconds"

  while true; do
    now="$(date '+%s')"
    now_text="$(date '+%Y-%m-%d %H:%M:%S')"
    : > "$current"
    workspace_watch_snapshot "$window_target" "$lines" "$stale_seconds" "$previous" "$now" "$worktree" > "$current"
    workspace_watch_append_missing_panes "$previous" "$current"
    workspace_watch_emit_summary "$workspace" "$window_target" "$worktree" "$current" "$previous" "$log_file" "$now_text" "$tmp_out" || true
    cp "$current" "$previous"
    [[ "$once" == "true" ]] && break
    sleep "$interval"
  done
}
