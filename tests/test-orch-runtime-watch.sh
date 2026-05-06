#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=../lib/orch-runtime/common.sh
source "$ROOT/lib/orch-runtime/common.sh"
# shellcheck source=../lib/orch-runtime/panes.sh
source "$ROOT/lib/orch-runtime/panes.sh"
# shellcheck source=../lib/orch-runtime/watch.sh
source "$ROOT/lib/orch-runtime/watch.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

role="$(workspace_watch_pane_role "codex" "zsh" "" "$PWD" "Need approval?")"
[[ "$role" == "ai" ]] || fail "codex pane should be ai: $role"

screen=$'vite dev server\nready in 300ms\nhttp://localhost:35110\n$ '
role="$(workspace_watch_pane_role "pane" "zsh" "" "$PWD" "$screen")"
[[ "$role" == "dev" ]] || fail "vite pane should be dev: $role"

status="$(workspace_watch_pane_status "dev" "pane" "idle" "0" "false" "$screen" "$ ")"
[[ "$status" == alert$'\t'* ]] || fail "idle dev pane should alert: $status"

screen=$'running tests\n1 failed, 2 passed'
status="$(workspace_watch_pane_status "test" "pane" "working" "0" "false" "$screen" "1 failed, 2 passed")"
[[ "$status" == alert$'\t'* ]] || fail "failed test pane should alert: $status"

screen=$'docker compose up\nservice api unhealthy'
status="$(workspace_watch_pane_status "compose" "pane" "working" "0" "true" "$screen" "service api unhealthy")"
[[ "$status" == stale$'\t'* ]] || fail "stale compose pane should report stale: $status"

message="$(pane_status_notification_message "sample:1.1" "claude" "working" "Implementing feature" "Hashing... almost done thinking")"
[[ "$message" == "sample:1.1 claude is working [Implementing feature]: Hashing... almost done thinking" ]] || fail "pane notify message mismatch: $message"

message="$(pane_status_notification_message "sample:1.2" "-" "idle" "" "$ ")"
[[ "$message" == "sample:1.2 pane is idle: $ " ]] || fail "generic pane notify message mismatch: $message"

started="$(date '+%s')"
if workspace_watch_run_with_timeout 1 bash -c 'sleep 3' >/dev/null 2>&1; then
  fail "timeout helper unexpectedly succeeded"
fi
elapsed=$(( $(date '+%s') - started ))
[[ "$elapsed" -lt 3 ]] || fail "timeout helper did not stop command quickly"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orch-runtime-watch-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/worktree/.orchestrate"
cat > "$TMP_ROOT/bin/devbox" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "services" && "${2:-}" == "ls" ]]; then
  printf '%b' "${DEVBOX_SERVICES_LS_OUTPUT:-}"
  exit "${DEVBOX_SERVICES_LS_RC:-0}"
fi
echo "unexpected devbox invocation: $*" >&2
exit 1
SH
chmod +x "$TMP_ROOT/bin/devbox"
PATH="$TMP_ROOT/bin:$PATH"

notification_log="$TMP_ROOT/notifications.log"
send_notification() {
  printf 'mac\t%s\t%s\n' "$1" "$2" >> "$notification_log"
}
cat > "$TMP_ROOT/bin/notify-command" <<'SH'
#!/usr/bin/env bash
{
  printf 'command\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$1" "$2" \
    "${ORCH_RUNTIME_NOTIFY_WORKSPACE:-}" \
    "${ORCH_RUNTIME_NOTIFY_WINDOW:-}" \
    "${ORCH_RUNTIME_NOTIFY_KEY:-}" \
    "${ORCH_RUNTIME_NOTIFY_CATEGORY:-}" \
    "${ORCH_RUNTIME_NOTIFY_STATUS:-}" \
    "${ORCH_RUNTIME_NOTIFY_DETAIL:-}"
} >> "$NOTIFICATION_LOG"
SH
chmod +x "$TMP_ROOT/bin/notify-command"
cat > "$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
printf 'webhook\t%s\n' "$*" >> "$NOTIFICATION_LOG"
SH
chmod +x "$TMP_ROOT/bin/curl"

export NOTIFICATION_LOG="$notification_log"
export ORCH_RUNTIME_WORKSPACE_WATCH_NOTIFY_COMMAND="$TMP_ROOT/bin/notify-command"
export ORCH_RUNTIME_WORKSPACE_WATCH_WEBHOOK_URL="https://example.invalid/workspace-watch"
cat > "$TMP_ROOT/watch-prev.tsv" <<'EOF'
devbox:worker	devbox-service	ok	devbox service worker is running	-	0
pane:%1	dev	working	dev pane is working	-	0
EOF
cat > "$TMP_ROOT/watch-current.tsv" <<'EOF'
devbox:worker	devbox-service	alert	devbox service worker is unhealthy	-	0
pane:%1	dev	stale	output has not changed	-	0
pane:%2	ai	ok	ai pane is working	-	0
EOF
workspace_watch_notify_changed "sample-workspace" "sample:1" "$TMP_ROOT/watch-current.tsv" "$TMP_ROOT/watch-prev.tsv" "alert,stale"
grep -q $'command\torch-runtime workspace: alert' "$notification_log" || fail "notify command did not receive alert"
grep -q $'command\torch-runtime workspace: stale' "$notification_log" || fail "notify command did not receive stale"
grep -q $'sample-workspace\tsample:1\tdevbox:worker\tdevbox-service\talert' "$notification_log" || fail "notify command env missing alert context"
grep -q 'webhook\t.*workspace-watch' "$notification_log" || fail "webhook notification was not attempted"
grep -q $'mac\torch-runtime workspace: alert' "$notification_log" || fail "mac notification fallback was not called"
before_count="$(wc -l < "$notification_log" | tr -d ' ')"
: > "$TMP_ROOT/watch-empty-prev.tsv"
workspace_watch_notify_changed "sample-workspace" "sample:1" "$TMP_ROOT/watch-current.tsv" "$TMP_ROOT/watch-empty-prev.tsv" "alert,stale"
after_count="$(wc -l < "$notification_log" | tr -d ' ')"
[[ "$before_count" == "$after_count" ]] || fail "initial snapshot should not notify"
unset ORCH_RUNTIME_WORKSPACE_WATCH_NOTIFY_COMMAND ORCH_RUNTIME_WORKSPACE_WATCH_WEBHOOK_URL NOTIFICATION_LOG

cat > "$TMP_ROOT/worktree/devbox.json" <<'JSON'
{"packages":[]}
JSON
cat > "$TMP_ROOT/worktree/process-compose.yaml" <<'YAML'
version: "0.5"
processes:
  worker:
    command: "echo worker"
  queue-status:
    command: "echo queue"
  gpu-status:
    command: "echo gpu"
YAML
: > "$TMP_ROOT/worktree/.orchestrate/env"

export DEVBOX_SERVICES_LS_OUTPUT=""
snapshot="$(workspace_devbox_service_snapshot "$TMP_ROOT/worktree")"
printf '%s\n' "$snapshot" | grep -q $'worker\tnot-started' || fail "empty services should mark worker not-started: $snapshot"
printf '%s\n' "$snapshot" | grep -q $'queue-status\tnot-started' || fail "empty services should mark queue-status not-started: $snapshot"
signals="$(workspace_watch_devbox_services_signal "$TMP_ROOT/worktree")"
[[ -z "$signals" ]] || fail "not-started services should not emit watch signals: $signals"

export DEVBOX_SERVICES_LS_OUTPUT=$'Name          Status\nqueue-status  Running\n'
snapshot="$(workspace_devbox_service_snapshot "$TMP_ROOT/worktree")"
printf '%s\n' "$snapshot" | grep -q $'queue-status\trunning' || fail "partial services should include running queue-status: $snapshot"
printf '%s\n' "$snapshot" | grep -q $'gpu-status\tnot-started' || fail "partial services should mark gpu-status not-started: $snapshot"
signals="$(workspace_watch_devbox_services_signal "$TMP_ROOT/worktree")"
printf '%s\n' "$signals" | grep -q $'devbox:queue-status\tdevbox-service\tok' || fail "running queue-status should emit ok signal: $signals"
if printf '%s\n' "$signals" | grep -q 'gpu-status'; then
  fail "not-started gpu-status should not emit a watch signal: $signals"
fi

export DEVBOX_SERVICES_LS_OUTPUT=$'Name          Status\nworker        Running\nqueue-status  Running\ngpu-status    Unhealthy\n'
signals="$(workspace_watch_devbox_services_signal "$TMP_ROOT/worktree")"
printf '%s\n' "$signals" | grep -q $'devbox:worker\tdevbox-service\tok' || fail "running worker should emit ok signal: $signals"
printf '%s\n' "$signals" | grep -q $'devbox:gpu-status\tdevbox-service\talert' || fail "unhealthy gpu-status should emit alert signal: $signals"
summary="$(workspace_devbox_services_summary "$TMP_ROOT/worktree" 120)"
[[ "$summary" == *"running:worker,queue-status"* ]] || fail "summary should include running services: $summary"
[[ "$summary" == *"alert:gpu-status:unhealthy"* ]] || fail "summary should include alert service: $summary"

echo "ok"
