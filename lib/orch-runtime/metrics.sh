# shellcheck shell=bash
# Lightweight JSONL metrics for orch-runtime workspaces.

metrics_enabled() {
  [[ "${ORCH_RUNTIME_METRICS:-enabled}" != "disabled" ]]
}

metrics_events_file() {
  local worktree="$1"
  [[ -n "$worktree" ]] || return 1
  printf '%s/.orchestrate/events.jsonl' "$worktree"
}

metrics_append_line() {
  local file="$1"
  local line="$2"
  local lock_dir="${file}.lock"
  local acquired="false"
  local _

  for _ in {1..50}; do
    if mkdir "$lock_dir" 2>/dev/null; then
      acquired="true"
      break
    fi
    sleep 0.05
  done

  [[ "$acquired" == "true" ]] || return 0
  printf '%s\n' "$line" >> "$file" 2>/dev/null || true
  rmdir "$lock_dir" 2>/dev/null || true
}

metrics_emit_event() {
  [[ $# -ge 3 ]] || return 0
  local worktree="$1"
  local workspace="$2"
  local event="$3"
  shift 3

  metrics_enabled || return 0
  [[ -n "$worktree" && -n "$workspace" && -n "$event" ]] || return 0
  [[ -d "$worktree" ]] || return 0

  local orchestrate_dir file ts payload
  orchestrate_dir="$worktree/.orchestrate"
  file="$(metrics_events_file "$worktree")" || return 0
  command -v ruby >/dev/null 2>&1 || return 0
  mkdir -p "$orchestrate_dir" 2>/dev/null || return 0
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  payload="$(
    ruby -rjson - "$ts" "$workspace" "$event" "$@" <<'RUBY'
ts = ARGV.shift
workspace = ARGV.shift
event = ARGV.shift
data = {}

ARGV.each do |arg|
  key, value = arg.split("=", 2)
  next if key.nil? || key.empty? || value.nil?
  data[key] = value
end

puts JSON.generate({
  "ts" => ts,
  "workspace" => workspace,
  "event" => event,
  "data" => data
})
RUBY
  )" || return 0
  [[ -n "$payload" ]] || return 0
  metrics_append_line "$file" "$payload"
  return 0
}

metrics_hash_text() {
  cksum | awk '{print $1 ":" $2}'
}

metrics_watch_event_kind() {
  [[ $# -ge 3 ]] || return 1
  local category="$1"
  local status="$2"
  local detail="$3"

  [[ "$status" == "alert" ]] || return 1
  case "$category" in
    ai)
      printf '%s' "ai_asking"
      ;;
    dev)
      printf '%s' "dev_server_crash"
      ;;
    test)
      printf '%s' "test_failure"
      ;;
    *)
      case "$(lower "$detail")" in
        *"waiting for input"*)
          printf '%s' "ai_asking"
          ;;
        *"test"*failure* | *"test"*failed* | *typecheck*failure* | *typecheck*failed*)
          printf '%s' "test_failure"
          ;;
        *"dev/"*error* | *"dev/"*returned* | *"api"*error* | *"api"*returned*)
          printf '%s' "dev_server_crash"
          ;;
        *)
          return 1
          ;;
      esac
      ;;
  esac
}

metrics_emit_watch_signal() {
  [[ $# -ge 7 ]] || return 0
  local worktree="$1"
  local workspace="$2"
  local window_target="$3"
  local key="$4"
  local category="$5"
  local status="$6"
  local detail="$7"

  local event
  local detail_hash detail_bytes
  event="$(metrics_watch_event_kind "$category" "$status" "$detail")" || return 0
  detail_hash="$(printf '%s' "$detail" | metrics_hash_text)"
  detail_bytes="$(printf '%s' "$detail" | wc -c | tr -d ' ')"
  metrics_emit_event "$worktree" "$workspace" "$event" \
    "window=$window_target" \
    "signal_key=$key" \
    "category=$category" \
    "status=$status" \
    "detail_hash=$detail_hash" \
    "detail_bytes=$detail_bytes"
}
