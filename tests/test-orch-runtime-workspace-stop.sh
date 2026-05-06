#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=../lib/orch-runtime/common.sh
source "$ROOT/lib/orch-runtime/common.sh"
# shellcheck source=../lib/orch-runtime/panes.sh
source "$ROOT/lib/orch-runtime/panes.sh"
# shellcheck source=../lib/orch-runtime/locks.sh
source "$ROOT/lib/orch-runtime/locks.sh"
# shellcheck source=../lib/orch-runtime/workspace.sh
source "$ROOT/lib/orch-runtime/workspace.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label: expected '$expected', got '$actual'"
}

RAW_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orch-runtime-workspace-stop-test.XXXXXX" 2>/dev/null || true)"
[[ -n "$RAW_TMP_ROOT" && -d "$RAW_TMP_ROOT" ]] || { echo "FAIL: mktemp failed" >&2; exit 1; }
TMP_ROOT="$(cd "$RAW_TMP_ROOT" && pwd)"
[[ -n "$TMP_ROOT" && -d "$TMP_ROOT" && "$TMP_ROOT" != "$PWD" ]] || { echo "FAIL: temp root unsafe ($TMP_ROOT)" >&2; exit 1; }
trap 'rm -rf "$TMP_ROOT"' EXIT

export ORCH_RUNTIME_LOCK_DIR="$TMP_ROOT/locks"

# ─── workspace_archive_logs ───────────────────────────────────────
# Case 1: missing logs directory is a no-op
worktree_missing="$TMP_ROOT/wt-missing"
mkdir -p "$worktree_missing"
workspace_archive_logs "$worktree_missing" >/dev/null
[[ ! -d "$worktree_missing/.orchestrate/logs/archive" ]] \
  || fail "archive dir created when logs dir is missing"

# Case 2: empty logs directory is a no-op (no archive subdir created)
worktree_empty="$TMP_ROOT/wt-empty"
mkdir -p "$worktree_empty/.orchestrate/logs"
workspace_archive_logs "$worktree_empty" >/dev/null
[[ ! -d "$worktree_empty/.orchestrate/logs/archive" ]] \
  || fail "archive dir created when logs dir is empty"

# Case 3: *.log files are moved to archive/<timestamp>/
worktree_logs="$TMP_ROOT/wt-logs"
mkdir -p "$worktree_logs/.orchestrate/logs"
echo "worker output" > "$worktree_logs/.orchestrate/logs/worker.log"
echo "queue output" > "$worktree_logs/.orchestrate/logs/queue-status.log"
output="$(workspace_archive_logs "$worktree_logs")"
echo "$output" | grep -q "archived 2 log(s)" \
  || fail "archive did not report 2 logs (got: $output)"
remaining="$(find "$worktree_logs/.orchestrate/logs" -maxdepth 1 -name '*.log' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "0" "$remaining" "logs remaining after archive"
archived_count="$(find "$worktree_logs/.orchestrate/logs/archive" -name '*.log' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "2" "$archived_count" "logs moved into archive subtree"

# Case 4: existing archive/ subtree is not re-archived (only top-level *.log
#         files are picked up).
echo "new round" > "$worktree_logs/.orchestrate/logs/worker.log"
workspace_archive_logs "$worktree_logs" >/dev/null
archive_dirs="$(find "$worktree_logs/.orchestrate/logs/archive" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
[[ "$archive_dirs" -ge 2 ]] || fail "second archive run should add another timestamp dir, got $archive_dirs"
top_logs="$(find "$worktree_logs/.orchestrate/logs" -maxdepth 1 -name '*.log' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "0" "$top_logs" "no top-level logs remain after second archive"

# ─── workspace_clean_residuals_report ─────────────────────────────
# Locks owned by the worktree should appear in the report.
worktree_residual="$TMP_ROOT/wt-residual"
mkdir -p "$worktree_residual/.orchestrate/logs"
echo "stray" > "$worktree_residual/.orchestrate/logs/stray.log"
lock_path="$(lock_acquire_one "gpu" "0" "ws-residual" "processor" "$worktree_residual" "")"
[[ -d "$lock_path" ]] || fail "lock not created for residual test"
report="$(workspace_clean_residuals_report "$worktree_residual")"
echo "$report" | grep -q "lock: gpu:0 (active)" \
  || fail "residual report missing active lock (got: $report)"
echo "$report" | grep -q "log: $worktree_residual/.orchestrate/logs/stray.log" \
  || fail "residual report missing stray log (got: $report)"
cmd_lock release gpu 0 --worktree "$worktree_residual" >/dev/null

# Empty residual report: locks: none / logs: none
worktree_clean="$TMP_ROOT/wt-clean"
mkdir -p "$worktree_clean"
clean_report="$(workspace_clean_residuals_report "$worktree_clean")"
echo "$clean_report" | grep -q "locks: none" \
  || fail "residual report should say 'locks: none' (got: $clean_report)"
echo "$clean_report" | grep -q "logs (outside archive/): none" \
  || fail "residual report should say 'logs (outside archive/): none' (got: $clean_report)"

# ─── workspace_release_locks_for_worktree ─────────────────────────
worktree_release="$TMP_ROOT/wt-release"
mkdir -p "$worktree_release"
lock_a="$(lock_acquire_one "pubsub-topic" "processor-jobs" "ws-release" "processor" "$worktree_release" "")"
lock_b="$(lock_acquire_one "emulator-port" "8085" "ws-release" "processor" "$worktree_release" "")"
[[ -d "$lock_a" && -d "$lock_b" ]] || fail "locks not created for release test"
release_output="$(workspace_release_locks_for_worktree "$worktree_release")"
echo "$release_output" | grep -q "released: pubsub-topic:processor-jobs" \
  || fail "release output missing pubsub lock (got: $release_output)"
echo "$release_output" | grep -q "released: emulator-port:8085" \
  || fail "release output missing emulator lock (got: $release_output)"
[[ ! -d "$lock_a" ]] || fail "pubsub lock dir still exists after release"
[[ ! -d "$lock_b" ]] || fail "emulator lock dir still exists after release"

# Worktree with no locks: release reports a friendly message instead of failing.
worktree_no_locks="$TMP_ROOT/wt-no-locks"
mkdir -p "$worktree_no_locks"
no_lock_output="$(workspace_release_locks_for_worktree "$worktree_no_locks")"
echo "$no_lock_output" | grep -q "no active locks for worktree:" \
  || fail "release should report 'no active locks' message (got: $no_lock_output)"

# Stale locks must be preserved (decision_record contract: release-stale only).
worktree_stale_owner="$TMP_ROOT/wt-stale-owner"
mkdir -p "$worktree_stale_owner"
stale_lock="$(lock_acquire_one "gpu" "9" "ws-stale" "processor" "$worktree_stale_owner" "")"
[[ -d "$stale_lock" ]] || fail "stale lock not created"
# Removing the worktree directory makes lock_status report 'stale'.
# We deliberately do NOT recreate it before calling release; the helper
# must keep the stale lock untouched.
rmdir "$worktree_stale_owner"
assert_eq "stale" "$(lock_status "$stale_lock")" "owner-removed lock should be stale"
stale_release_output="$(workspace_release_locks_for_worktree "$worktree_stale_owner")"
[[ -d "$stale_lock" ]] || fail "stale lock should NOT be removed by workspace_release"
echo "$stale_release_output" | grep -q "no active locks for worktree:" \
  || fail "stale-only release should report 'no active locks' (got: $stale_release_output)"
# Cleanup the stale lock manually for the rest of the suite.
cmd_lock release-stale gpu 9 >/dev/null
[[ ! -d "$stale_lock" ]] || fail "stale lock not cleared by release-stale"

# Window-scoped release must not release sibling locks owned by the same
# worktree. The test overrides tmux window existence so synthetic @window-*
# targets are considered active without depending on a real tmux session.
lock_tmux_window_exists() {
  case "$1" in
    @window-a|@window-b) return 0 ;;
    *) return 1 ;;
  esac
}

worktree_window_release="$TMP_ROOT/wt-window-release"
mkdir -p "$worktree_window_release"
lock_window_a="$(lock_acquire_one "gpu" "7" "ws-window-a" "processor" "$worktree_window_release" "@window-a")"
lock_window_b="$(lock_acquire_one "gpu" "8" "ws-window-b" "processor" "$worktree_window_release" "@window-b")"
[[ -d "$lock_window_a" && -d "$lock_window_b" ]] || fail "locks not created for window release test"
window_release_output="$(workspace_release_locks_for_window "$worktree_window_release" "@window-a")"
echo "$window_release_output" | grep -q "released: gpu:7" \
  || fail "window release output missing target lock (got: $window_release_output)"
[[ ! -d "$lock_window_a" ]] || fail "target window lock still exists after release"
[[ -d "$lock_window_b" ]] || fail "sibling window lock should not be released"
cmd_lock release gpu 8 --worktree "$worktree_window_release" >/dev/null
[[ ! -d "$lock_window_b" ]] || fail "sibling window lock cleanup failed"

# ─── workspace_stop_docker_compose ────────────────────────────────
# Without a compose.project marker the helper is a no-op.
worktree_no_compose="$TMP_ROOT/wt-no-compose"
mkdir -p "$worktree_no_compose"
workspace_stop_docker_compose "$worktree_no_compose"

# ─── workspace_stop_devbox_services ───────────────────────────────
# Non-existent worktree path is a no-op.
workspace_stop_devbox_services "$TMP_ROOT/does-not-exist"

echo "OK: workspace stop helpers"
