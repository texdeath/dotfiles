# shellcheck shell=bash
# Pane discovery, capture, state detection, and tmux paste helpers.

pane_id_for_target() {
  tmux display-message -p -t "$1" '#{pane_id}' 2>/dev/null || true
}

detect_label() {
  local pane="$1"
  local command="${2:-}"
  local title="${3:-}"
  local haystack
  local screen

  haystack="$(lower "$command $title")"
  case "$haystack" in
    *codex*) echo "codex"; return ;;
    *claude*) echo "claude"; return ;;
  esac

  screen="$(tmux capture-pane -p -t "$pane" -S -20 2>/dev/null || true)"
  if printf '%s\n' "$screen" | grep -Eiq 'Claude Code|Opus|Sonnet|Haiku|Ctx:'; then
    echo "claude"
    return
  fi
  if printf '%s\n' "$screen" | grep -Eiq 'codex|gpt-5|apply_patch|functions\.exec_command'; then
    echo "codex"
    return
  fi
  echo "-"
}

resolve_pane() {
  local target="${1:-current}"
  local pane_id
  local pane
  local command
  local title
  local label
  local -a matches=()

  if [[ "$target" == "current" || "$target" == "." ]]; then
    pane_id="$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)"
    [[ -n "$pane_id" ]] || die "current pane is unavailable outside tmux; pass an explicit target"
    echo "$pane_id"
    return
  fi

  pane_id="$(pane_id_for_target "$target")"
  if [[ -n "$pane_id" ]]; then
    echo "$pane_id"
    return
  fi

  if [[ "$target" != "claude" && "$target" != "codex" ]]; then
    die "unknown pane target: $target"
  fi

  while IFS=$'\t' read -r pane command title; do
    label="$(detect_label "$pane" "$command" "$title")"
    if [[ "$label" == "$target" ]]; then
      matches+=("$pane")
    fi
  done < <(tmux list-panes -a -F '#{pane_id}	#{pane_current_command}	#{pane_title}')

  case "${#matches[@]}" in
    0) die "no pane matching '$target' was found; run 'orch-runtime panes' and use a pane id" ;;
    1) echo "${matches[0]}" ;;
    *) die "multiple '$target' panes found: ${matches[*]}; use a pane id" ;;
  esac
}

pane_label() {
  local pane="$1"
  local command
  local title
  command="$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null || true)"
  title="$(tmux display-message -p -t "$pane" '#{pane_title}' 2>/dev/null || true)"
  detect_label "$pane" "$command" "$title"
}

capture_pane() {
  local pane="$1"
  local lines="$2"
  tmux capture-pane -p -t "$pane" -S "-$lines" | tail -n "$lines"
}

one_line() {
  sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'
}

truncate_text() {
  local text="$1"
  local max="${2:-72}"

  if [[ "${#text}" -le "$max" ]]; then
    printf '%s' "$text"
  else
    printf '%s...' "${text:0:$((max - 3))}"
  fi
}

last_nonempty_line() {
  awk 'NF { line = $0 } END { print line }'
}

pane_active_text() {
  if [[ "$1" == "1" ]]; then
    echo "yes"
  else
    echo "no"
  fi
}

pane_state() {
  local screen="$1"
  local recent
  local bottom

  recent="$(printf '%s\n' "$screen" | tail -60)"
  bottom="$(printf '%s\n' "$screen" | tail -16)"

  if printf '%s\n' "$recent" | grep -Eiq 'error|failed|failure|exception|traceback|panic:|command not found|permission denied|tests? failed|[✗❌]'; then
    echo "error"
    return
  fi

  if printf '%s\n' "$bottom" | grep -Eiq 'working|running|actualizing|thinking|concocting|cooking|cooked|brewing|brewed|baking|baked|esc to interrupt|処理中|実行中'; then
    echo "working"
    return
  fi

  if printf '%s\n' "$recent" | grep -Eiq '承認|確認|質問|選択肢|どうしますか|良いですか|いいですか|よろしいですか|do you want|proceed|continue\?|approve|approval|required|waiting for'; then
    echo "asking"
    return
  fi

  if printf '%s\n' "$bottom" | grep -Eq '(^|[[:space:]])[❯›][[:space:]]|[$#][[:space:]]*$'; then
    echo "idle"
    return
  fi

  echo "unknown"
}

pane_status_line() {
  local pane="$1"
  local target
  local active
  local command
  local title
  local path
  local label
  local screen
  local state
  local last

  target="$(tmux display-message -p -t "$pane" '#{session_name}:#{window_index}.#{pane_index}')"
  active="$(pane_active_text "$(tmux display-message -p -t "$pane" '#{pane_active}')")"
  command="$(tmux display-message -p -t "$pane" '#{pane_current_command}')"
  title="$(tmux display-message -p -t "$pane" '#{pane_title}')"
  path="$(tmux display-message -p -t "$pane" '#{pane_current_path}')"
  label="$(detect_label "$pane" "$command" "$title")"
  screen="$(capture_pane "$pane" "$STATUS_LINES")"
  state="$(pane_state "$screen")"
  last="$(printf '%s\n' "$screen" | last_nonempty_line | one_line)"
  last="$(truncate_text "$last" 78)"

  printf '%-7s %-12s %-7s %-8s %-6s %-22s %s\n' "$pane" "$target" "$label" "$state" "$active" "$title" "$last"
}

watch_row_for_pane() {
  local pane="$1"
  local lines="$2"
  local screen
  local state
  local label
  local target
  local title
  local last

  screen="$(capture_pane "$pane" "$lines" 2>/dev/null || true)"
  state="$(pane_state "$screen")"
  label="$(pane_label "$pane")"
  target="$(tmux display-message -p -t "$pane" '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)"
  title="$(tmux display-message -p -t "$pane" '#{pane_title}' 2>/dev/null || true)"
  last="$(printf '%s\n' "$screen" | last_nonempty_line | one_line)"
  last="$(truncate_text "$last" 90)"

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$pane" "$state" "$label" "$target" "$title" "$last"
}

watch_rows() {
  local target="$1"
  local lines="$2"
  local pane

  if [[ "$target" == "all" ]]; then
    while IFS= read -r pane; do
      watch_row_for_pane "$pane" "$lines"
    done < <(tmux list-panes -a -F '#{pane_id}')
  else
    pane="$(resolve_pane "$target")"
    watch_row_for_pane "$pane" "$lines"
  fi
}

previous_watch_state() {
  local file="$1"
  local pane="$2"

  awk -F '\t' -v pane="$pane" '$1 == pane { print $2; found = 1 } END { if (!found) print "" }' "$file"
}

send_notification() {
  local title
  local message

  [[ "$(uname -s)" == "Darwin" ]] || return 0
  [[ -x /usr/bin/osascript ]] || return 0

  title="$(osascript_escape "$1")"
  message="$(osascript_escape "$2")"
  /usr/bin/osascript -e "display notification \"$message\" with title \"$title\"" >/dev/null 2>&1 || true
}

paste_to_pane() {
  local pane="$1"
  local payload="$2"
  local enter="$3"

  printf '%s' "$payload" | tmux load-buffer -b "$BUFFER_NAME" -
  tmux paste-buffer -b "$BUFFER_NAME" -t "$pane"
  if [[ "$enter" == "true" ]]; then
    tmux send-keys -t "$pane" Enter
  fi
}
