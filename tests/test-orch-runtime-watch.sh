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

started="$(date '+%s')"
if workspace_watch_run_with_timeout 1 bash -c 'sleep 3' >/dev/null 2>&1; then
  fail "timeout helper unexpectedly succeeded"
fi
elapsed=$(( $(date '+%s') - started ))
[[ "$elapsed" -lt 3 ]] || fail "timeout helper did not stop command quickly"

echo "ok"
