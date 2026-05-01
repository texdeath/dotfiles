# shellcheck shell=bash
# Top-level pane/session commands.

cmd_new() {
  local print_only="false"
  local session=""
  local ghostty_command

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --print|--dry-run)
        print_only="true"
        shift
        ;;
      -h|--help)
        cat <<'EOF'
Usage:
  orch-runtime new [--print] [session]

Open a Ghostty window attached to a tmux session.
If session is omitted, a timestamped work-* session is created.
EOF
        return
        ;;
      -*)
        die "unknown option for new: $1"
        ;;
      *)
        [[ -z "$session" ]] || die "new accepts at most one session name"
        session="$1"
        shift
        ;;
    esac
  done

  need_tmux_binary
  session="${session:-work-$(date +%Y%m%d-%H%M%S)}"
  is_safe_session_name "$session" || die "session name must match [A-Za-z0-9][A-Za-z0-9_.-]*"

  ghostty_command="/bin/zsh -lc 'unset TMUX; exec tmux new-session -A -s $session'"

  if [[ "$print_only" == "true" ]]; then
    printf 'open -na Ghostty.app --args --command=%q\n' "$ghostty_command"
    return
  fi

  if [[ "$(uname -s)" != "Darwin" ]]; then
    die "new currently supports macOS Ghostty via open(1)"
  fi

  command -v open >/dev/null 2>&1 || die "open command is not available"
  open -na Ghostty.app --args --command="$ghostty_command"
}

cmd_panes() {
  local pane
  local target
  local active
  local command
  local title
  local path
  local label

  printf '%-7s %-12s %-7s %-6s %-22s %s\n' "PANE" "TARGET" "AGENT" "ACTIVE" "TITLE" "PATH"
  while IFS=$'\t' read -r pane target active command title path; do
    label="$(detect_label "$pane" "$command" "$title")"
    if [[ "$active" == "1" ]]; then
      active="yes"
    else
      active="no"
    fi
    printf '%-7s %-12s %-7s %-6s %-22s %s\n' "$pane" "$target" "$label" "$active" "$title" "$path"
  done < <(tmux list-panes -a -F '#{pane_id}	#{session_name}:#{window_index}.#{pane_index}	#{pane_active}	#{pane_current_command}	#{pane_title}	#{pane_current_path}')
}

cmd_status() {
  local target="all"
  local pane
  STATUS_LINES="$DEFAULT_LINES"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--lines)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        STATUS_LINES="$2"
        shift 2
        ;;
      *)
        target="$1"
        shift
        ;;
    esac
  done

  is_positive_int "$STATUS_LINES" || die "line count must be a positive integer"
  printf '%-7s %-12s %-7s %-8s %-6s %-22s %s\n' "PANE" "TARGET" "AGENT" "STATE" "ACTIVE" "TITLE" "LAST"

  if [[ "$target" == "all" ]]; then
    while IFS= read -r pane; do
      pane_status_line "$pane"
    done < <(tmux list-panes -a -F '#{pane_id}')
  else
    pane="$(resolve_pane "$target")"
    pane_status_line "$pane"
  fi
}

cmd_watch() {
  local target="all"
  local target_set="false"
  local lines="$DEFAULT_LINES"
  local interval="5"
  local notify="true"
  local once="false"
  local notify_states="asking,error"
  local previous
  local current
  local timestamp
  local pane
  local state
  local label
  local tmux_target
  local title
  local last
  local previous_state
  local message

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
      --states)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        notify_states="$2"
        shift 2
        ;;
      --no-notify)
        notify="false"
        shift
        ;;
      --once)
        once="true"
        shift
        ;;
      -h|--help)
        cat <<'EOF'
Usage:
  orch-runtime watch [pane|claude|codex|all] [-n lines] [-i seconds] [--states asking,error] [--no-notify] [--once]

Watch tmux panes and notify on state changes into asking or error.
EOF
        return
        ;;
      -*)
        die "unknown option for watch: $1"
        ;;
      *)
        [[ "$target_set" == "false" ]] || die "watch accepts at most one target"
        target="$1"
        target_set="true"
        shift
        ;;
    esac
  done

  is_positive_int "$lines" || die "line count must be a positive integer"
  is_positive_int "$interval" || die "interval must be a positive integer"
  need_tmux

  previous="$(mktemp "${TMPDIR:-/tmp}/orch-runtime-watch-prev.XXXXXX")"
  current="$(mktemp "${TMPDIR:-/tmp}/orch-runtime-watch-current.XXXXXX")"
  ORCH_RUNTIME_WATCH_PREVIOUS="$previous"
  ORCH_RUNTIME_WATCH_CURRENT="$current"
  trap 'rm -f "$ORCH_RUNTIME_WATCH_PREVIOUS" "$ORCH_RUNTIME_WATCH_CURRENT"' EXIT

  printf 'Watching %s every %ss. Notifications: %s (%s). Press Ctrl-C to stop.\n' "$target" "$interval" "$notify" "$notify_states"

  while true; do
    watch_rows "$target" "$lines" > "$current"

    while IFS=$'\t' read -r pane state label tmux_target title last; do
      previous_state="$(previous_watch_state "$previous" "$pane")"
      if [[ "$previous_state" != "$state" ]]; then
        timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
        printf '%s %-7s %-12s %-7s %s -> %s  %s\n' "$timestamp" "$pane" "$tmux_target" "$label" "${previous_state:-new}" "$state" "$last"

        if [[ -n "$previous_state" && "$notify" == "true" ]] && state_in_list "$state" "$notify_states"; then
          message="$tmux_target $label is $state"
          if [[ -n "$last" ]]; then
            message="$message: $last"
          fi
          send_notification "orch-runtime: $state" "$message"
        fi
      fi
    done < "$current"

    cp "$current" "$previous"
    [[ "$once" == "true" ]] && break
    sleep "$interval"
  done
}

cmd_focus() {
  local target="${1:-}"
  local pane
  local window

  [[ -n "$target" ]] || die "focus requires a target"
  pane="$(resolve_pane "$target")"
  window="$(tmux display-message -p -t "$pane" '#{session_name}:#{window_index}')"
  tmux select-window -t "$window"
  tmux select-pane -t "$pane"

  if [[ -z "${TMUX:-}" ]]; then
    tmux attach-session -t "$window"
  fi
}

cmd_capture() {
  local target="current"
  local lines="$DEFAULT_LINES"
  local pane

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--lines)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        lines="$2"
        shift 2
        ;;
      *)
        target="$1"
        shift
        ;;
    esac
  done

  is_positive_int "$lines" || die "line count must be a positive integer"
  pane="$(resolve_pane "$target")"
  capture_pane "$pane" "$lines"
}

cmd_send() {
  local enter="true"
  local target
  local pane
  local payload

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-enter)
        enter="false"
        shift
        ;;
      *)
        break
        ;;
    esac
  done

  target="${1:-}"
  [[ -n "$target" ]] || die "send requires a target"
  shift || true

  if [[ $# -gt 0 ]]; then
    payload="$*"
  elif [[ -t 0 ]]; then
    die "send requires a message or stdin"
  else
    payload="$(cat)"
  fi

  pane="$(resolve_pane "$target")"
  paste_to_pane "$pane" "$payload" "$enter"
}

digest_pane() {
  local pane="$1"
  local lines="$2"
  local screen
  local command
  local title
  local path
  local target
  local active
  local label
  local state

  screen="$(capture_pane "$pane" "$lines")"
  command="$(tmux display-message -p -t "$pane" '#{pane_current_command}')"
  title="$(tmux display-message -p -t "$pane" '#{pane_title}')"
  path="$(tmux display-message -p -t "$pane" '#{pane_current_path}')"
  target="$(tmux display-message -p -t "$pane" '#{session_name}:#{window_index}.#{pane_index}')"
  active="$(pane_active_text "$(tmux display-message -p -t "$pane" '#{pane_active}')")"
  label="$(detect_label "$pane" "$command" "$title")"
  state="$(pane_state "$screen")"

  cat <<EOF
## Pane $pane

- target: $target
- agent: $label
- state: $state
- active: $active
- title: $title
- path: $path

Recent output:
\`\`\`
$screen
\`\`\`

EOF
}

cmd_digest() {
  local target="all"
  local target_set="false"
  local lines="$DEFAULT_LINES"
  local -a notes=()
  local pane
  local timestamp

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--lines)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        lines="$2"
        shift 2
        ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do
          notes+=("$1")
          shift
        done
        ;;
      *)
        if [[ "$target_set" == "false" && ( "$1" == "all" || "$1" == "current" || "$1" == "." || "$1" == "claude" || "$1" == "codex" || "$1" == %* || "$1" == *:* ) ]]; then
          target="$1"
          target_set="true"
        else
          notes+=("$1")
        fi
        shift
        ;;
    esac
  done

  is_positive_int "$lines" || die "line count must be a positive integer"
  timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"

  cat <<EOF
# AI tmux digest

Timestamp: $timestamp
Lines per pane: $lines
Note: ${notes[*]:-none}

EOF

  if [[ "$target" == "all" ]]; then
    while IFS= read -r pane; do
      if [[ "$(pane_label "$pane")" != "-" ]]; then
        digest_pane "$pane" "$lines"
      fi
    done < <(tmux list-panes -a -F '#{pane_id}')
  else
    pane="$(resolve_pane "$target")"
    digest_pane "$pane" "$lines"
  fi
}

task_description() {
  case "$1" in
    review)
      echo "Review the source pane's current work. Prioritize bugs, regressions, missing tests, and unclear assumptions. Do not edit files unless explicitly requested."
      ;;
    implement)
      echo "Implement the source pane's design or plan. Inspect the repo first, keep changes scoped, and run focused verification."
      ;;
    design)
      echo "Turn the source pane's context into a concise design or spec. Identify decisions, constraints, and implementation risks."
      ;;
    context|sync)
      echo "Read the source pane's context and be ready to collaborate. Summarize what you understand and ask for the next step if needed."
      ;;
    *)
      die "unknown task: $1"
      ;;
  esac
}

build_handoff_prompt() {
  local task="$1"
  local from_target="$2"
  local from_pane="$3"
  local to_target="$4"
  local to_pane="$5"
  local lines="$6"
  local note="$7"
  local captured
  local description
  local timestamp

  captured="$(capture_pane "$from_pane" "$lines")"
  description="$(task_description "$task")"
  timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"

  cat <<EOF
Context handoff from tmux.

Task:
$description

Source:
- requested: $from_target
- pane: $from_pane
- detected agent: $(pane_label "$from_pane")

Target:
- requested: $to_target
- pane: $to_pane
- detected agent: $(pane_label "$to_pane")

Timestamp:
$timestamp

Additional note:
${note:-none}

Recent source pane output:
\`\`\`
$captured
\`\`\`
EOF
}

cmd_handoff() {
  local task="$1"
  shift
  local from_target="current"
  local to_target=""
  local lines="$DEFAULT_LINES"
  local dry_run="false"
  local enter="true"
  local -a notes=()
  local from_pane
  local to_pane
  local payload

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--from)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        from_target="$2"
        shift 2
        ;;
      -t|--to)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        to_target="$2"
        shift 2
        ;;
      --task)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        task="$2"
        shift 2
        ;;
      -n|--lines)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        lines="$2"
        shift 2
        ;;
      --dry-run)
        dry_run="true"
        shift
        ;;
      --no-enter)
        enter="false"
        shift
        ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do
          notes+=("$1")
          shift
        done
        ;;
      *)
        notes+=("$1")
        shift
        ;;
    esac
  done

  is_positive_int "$lines" || die "line count must be a positive integer"
  from_pane="$(resolve_pane "$from_target")"

  if [[ -z "$to_target" ]]; then
    case "$(pane_label "$from_pane")" in
      claude) to_target="codex" ;;
      codex) to_target="claude" ;;
      *) die "--to is required when the source pane is not detected as claude or codex" ;;
    esac
  fi

  to_pane="$(resolve_pane "$to_target")"
  [[ "$from_pane" != "$to_pane" ]] || die "source and target resolved to the same pane: $from_pane"

  payload="$(build_handoff_prompt "$task" "$from_target" "$from_pane" "$to_target" "$to_pane" "$lines" "${notes[*]:-}")"

  if [[ "$dry_run" == "true" ]]; then
    printf '%s\n' "$payload"
  else
    paste_to_pane "$to_pane" "$payload" "$enter"
  fi
}
