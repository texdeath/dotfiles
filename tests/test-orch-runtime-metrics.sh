#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=../lib/orch-runtime/common.sh
source "$ROOT/lib/orch-runtime/common.sh"
# shellcheck source=../lib/orch-runtime/metrics.sh
source "$ROOT/lib/orch-runtime/metrics.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required for JSONL parse checks"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orch-runtime-metrics-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

worktree="$TMP_ROOT/worktree"
mkdir -p "$worktree"
events="$worktree/.orchestrate/events.jsonl"

metrics_emit_event "$worktree" "feature-a" "workspace_start" \
  "profile=frontend" \
  "window=@1" \
  "pane_count=3"
metrics_emit_event "$worktree" "feature-a" "workspace_stop" \
  "window=@1" \
  "archive_logs=true" \
  "keep_window=false"

[[ -f "$events" ]] || fail "events.jsonl was not created"
jq -s -e '
  length == 2 and
  .[0].event == "workspace_start" and
  .[0].workspace == "feature-a" and
  .[0].data.profile == "frontend" and
  .[0].data.pane_count == "3" and
  .[1].event == "workspace_stop" and
  .[1].data.archive_logs == "true"
' "$events" >/dev/null || fail "workspace start/stop events did not parse as expected"

before_count="$(wc -l < "$events" | tr -d ' ')"
ORCH_RUNTIME_METRICS=disabled metrics_emit_event "$worktree" "feature-a" "workspace_report" "lines=80"
after_count="$(wc -l < "$events" | tr -d ' ')"
[[ "$after_count" == "$before_count" ]] || fail "disabled metrics should not append events"

metrics_emit_watch_signal "$worktree" "feature-a" "@1" "pane:%2" "ai" "alert" "codex pane is waiting for input: approve?"
metrics_emit_watch_signal "$worktree" "feature-a" "@1" "pane:%3" "dev" "alert" "dev/API command appears to have returned to a shell prompt: $"
metrics_emit_watch_signal "$worktree" "feature-a" "@1" "pane:%4" "test" "alert" "test/typecheck failure detected: 1 failed"
metrics_emit_watch_signal "$worktree" "feature-a" "@1" "pane:%5" "dev" "ok" "dev pane is working"

jq -s -e '
  length == 5 and
  .[2].event == "ai_asking" and
  .[2].data.signal_key == "pane:%2" and
  .[3].event == "dev_server_crash" and
  .[4].event == "test_failure" and
  all(.[]; (.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")))
' "$events" >/dev/null || fail "watch signal events did not parse as expected"

echo "ok"
