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

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orch-runtime-lock-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

export ORCH_RUNTIME_LOCK_DIR="$TMP_ROOT/locks"
worktree_a="$TMP_ROOT/worktree-a"
worktree_b="$TMP_ROOT/worktree-b"
mkdir -p "$worktree_a" "$worktree_b"

path="$(lock_acquire_one "gpu" "0" "workspace-a" "processor" "$worktree_a" "")"
[[ -d "$path" ]] || fail "lock directory was not created"
assert_eq "active" "$(lock_status "$path")" "new lock status"

if lock_acquire_one "gpu" "0" "workspace-b" "processor" "$worktree_b" "" >/dev/null 2>"$TMP_ROOT/conflict.err"; then
  fail "second acquire unexpectedly succeeded"
fi
grep -q "resource lock conflict: gpu:0" "$TMP_ROOT/conflict.err" || fail "conflict message missing target"

cmd_lock release gpu 0 --worktree "$worktree_a" >"$TMP_ROOT/release.out"
[[ ! -d "$path" ]] || fail "lock directory still exists after release"
grep -q "released: gpu:0" "$TMP_ROOT/release.out" || fail "release output missing target"

path="$(lock_acquire_one "gpu" "1" "workspace-a" "processor" "$worktree_a" "@missing-window")"
assert_eq "stale" "$(lock_status "$path")" "missing-window lock status"
same_path="$(lock_acquire_one "gpu" "1" "workspace-a" "processor" "$worktree_a" "")"
assert_eq "$path" "$same_path" "same-worktree reacquire path"
assert_eq "active" "$(lock_status "$same_path")" "same-worktree reacquire status"
assert_eq "" "$(lock_read_field "$same_path" window)" "same-worktree reacquire window metadata"
cmd_lock release gpu 1 --worktree "$worktree_a" >/dev/null

stale_worktree="$TMP_ROOT/stale-worktree"
mkdir -p "$stale_worktree"
stale_path="$(lock_acquire_one "emulator-port" "8086" "stale-workspace" "backend" "$stale_worktree" "")"
rmdir "$stale_worktree"
assert_eq "stale" "$(lock_status "$stale_path")" "stale lock status"
cmd_lock release-stale emulator-port 8086 >"$TMP_ROOT/release-stale.out"
[[ ! -d "$stale_path" ]] || fail "stale lock directory still exists after release-stale"

mkdir -p "$TMP_ROOT/bin"
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

runtime_worktree="$TMP_ROOT/runtime-worktree"
mkdir -p "$runtime_worktree"
cat > "$runtime_worktree/devbox.json" <<'JSON'
{"packages":[]}
JSON
cat > "$runtime_worktree/process-compose.yaml" <<'YAML'
version: "0.5"
processes:
  worker:
    command: "echo worker"
YAML
export DEVBOX_SERVICES_LS_OUTPUT=$'Name     Status\nworker   Stopped\n'
runtime_path="$(lock_acquire_one "runtime-slot" "worker" "runtime-workspace" "worker" "$runtime_worktree" "")"
assert_eq "suspicious" "$(lock_status "$runtime_path")" "not-started devbox lock status"
runtime_evidence="$(lock_runtime_evidence_summary "$runtime_path")"
[[ "$runtime_evidence" == *"devbox=suspicious"* ]] || fail "runtime evidence should include suspicious devbox state: $runtime_evidence"
cmd_lock release runtime-slot worker --worktree "$runtime_worktree" >/dev/null

loader="$TMP_ROOT/load-profile.sh"
cat > "$loader" <<'SH'
#!/usr/bin/env sh
cat <<'JSON'
{
  "resolved": true,
  "query": "processor",
  "profile": {
    "runtime": {
      "panes": [
        {"name": "dev", "command": "echo dev"}
      ],
      "locks": [
        {"type": "gpu", "index": 0},
        {"type": "pubsub-topic", "topic": "local-jobs"},
        {"type": "pubsub-subscription", "subscription": "local-worker"},
        {"type": "emulator-port", "port": 8086},
        {"type": "model-cache-write", "path": "/tmp/model-cache"}
      ]
    }
  }
}
JSON
SH
chmod +x "$loader"
export ORCHESTRATE_LOAD_PROFILE="$loader"

specs="$(workspace_profile_locks processor "$worktree_a")"
count="$(printf '%s\n' "$specs" | sed '/^$/d' | wc -l | tr -d ' ')"
assert_eq "5" "$count" "profile lock count"
printf '%s\n' "$specs" | grep -q $'gpu\x1f0' || fail "gpu lock declaration missing"
printf '%s\n' "$specs" | grep -q $'model-cache-write\x1f/tmp/model-cache' || fail "model cache lock declaration missing"

mkdir -p "$worktree_a/.orchestrate"
cat > "$worktree_a/.orchestrate/env" <<'EOF'
ORCH_RESOURCE_LOCKS=emulator-port:9999
EOF
specs="$(workspace_profile_locks processor "$worktree_a")"
count="$(printf '%s\n' "$specs" | sed '/^$/d' | wc -l | tr -d ' ')"
assert_eq "6" "$count" "default env lock merge count"
printf '%s\n' "$specs" | grep -q $'emulator-port\x1f9999' || fail "merged env lock declaration missing"

cat > "$worktree_a/.orchestrate/env" <<'EOF'
ORCH_RESOURCE_LOCKS_MODE=overlay
ORCH_RESOURCE_LOCKS=
EOF
specs="$(workspace_profile_locks processor "$worktree_a")"
count="$(printf '%s\n' "$specs" | sed '/^$/d' | wc -l | tr -d ' ')"
assert_eq "0" "$count" "overlay empty lock count"

cat > "$worktree_a/.orchestrate/env" <<'EOF'
ORCH_RESOURCE_LOCKS_MODE=overlay
ORCH_RESOURCE_LOCKS=gpu:0,pubsub-topic:local-jobs
EOF
specs="$(workspace_profile_locks processor "$worktree_a")"
count="$(printf '%s\n' "$specs" | sed '/^$/d' | wc -l | tr -d ' ')"
assert_eq "2" "$count" "overlay partial lock count"
printf '%s\n' "$specs" | grep -q $'gpu\x1f0' || fail "overlay gpu declaration missing"
printf '%s\n' "$specs" | grep -q $'pubsub-topic\x1flocal-jobs' || fail "overlay pubsub-topic declaration missing"
if printf '%s\n' "$specs" | grep -q 'model-cache-write'; then
  fail "overlay partial should not include profile model-cache lock"
fi

cat > "$worktree_a/.orchestrate/env" <<'EOF'
ORCH_RESOURCE_LOCKS_MODE=overlay
ORCH_HEAVY_RESOURCE_LOCKS=model-cache-write:/tmp/model-cache
EOF
specs="$(workspace_profile_locks processor "$worktree_a")"
count="$(printf '%s\n' "$specs" | sed '/^$/d' | wc -l | tr -d ' ')"
assert_eq "1" "$count" "legacy overlay alias lock count"
printf '%s\n' "$specs" | grep -q $'model-cache-write\x1f/tmp/model-cache' || fail "legacy overlay alias declaration missing"

cat > "$worktree_a/.orchestrate/env" <<'EOF'
ORCH_RESOURCE_LOCKS_MODE=append
ORCH_RESOURCE_LOCKS=emulator-port:9999
EOF
specs="$(workspace_profile_locks processor "$worktree_a")"
count="$(printf '%s\n' "$specs" | sed '/^$/d' | wc -l | tr -d ' ')"
assert_eq "6" "$count" "append mode should keep merge behaviour"

rm -f "$worktree_a/.orchestrate/env"

preflight="$TMP_ROOT/preflight-processor.sh"
cat > "$preflight" <<'SH'
#!/usr/bin/env sh
exit 0
SH
chmod +x "$preflight"
ORCHESTRATE_PREFLIGHT_PROCESSOR="$preflight" cmd_workspace_start test-processor "$worktree_a" --dry-run >"$TMP_ROOT/workspace-dry-run.out"
grep -q "# resource_locks=5" "$TMP_ROOT/workspace-dry-run.out" || fail "workspace dry-run did not report lock declarations"
grep -q "# lock gpu:0 -> available" "$TMP_ROOT/workspace-dry-run.out" || fail "workspace dry-run did not check gpu lock"
grep -q "# preflight:" "$TMP_ROOT/workspace-dry-run.out" || fail "workspace dry-run did not report resolved preflight"

if ( ORCHESTRATE_PREFLIGHT_PROCESSOR="$TMP_ROOT/missing-preflight" cmd_workspace_start test-processor "$worktree_a" --dry-run ) >"$TMP_ROOT/workspace-dry-run-invalid.out" 2>"$TMP_ROOT/workspace-dry-run-invalid.err"; then
  fail "workspace dry-run should hard-fail when ORCHESTRATE_PREFLIGHT_PROCESSOR is invalid"
fi
grep -q "ORCHESTRATE_PREFLIGHT_PROCESSOR is set but not executable" "$TMP_ROOT/workspace-dry-run-invalid.err" \
  || fail "workspace dry-run invalid override error missing"
unset ORCHESTRATE_PREFLIGHT_PROCESSOR

workspace_acquire_locks_from_specs "$specs" "processor" "$worktree_a" "workspace-a" "@missing-window" || fail "workspace lock acquire failed"
summary="$(lock_summary_for_worktree "$worktree_a")"
[[ "$summary" == *"stale"* ]] || fail "workspace summary did not include stale tmux-window-backed locks: $summary"
cmd_lock release --worktree "$worktree_a" >"$TMP_ROOT/release-all.out"
grep -q "released: gpu:0" "$TMP_ROOT/release-all.out" || fail "release --worktree did not release profile locks"

cat > "$TMP_ROOT/bin/tmux" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "show-option" && "$*" == *"@workspace_locks"* ]]; then
  printf '%s\n' "${TMUX_WORKSPACE_LOCKS_OUTPUT:-}"
  exit 0
fi
exit 1
SH
chmod +x "$TMP_ROOT/bin/tmux"
export TMUX_WORKSPACE_LOCKS_OUTPUT="gpu:42,emulator-port:4040"
declared_missing="$(lock_declared_discrepancies_for_window "sample:1" "$worktree_a")"
printf '%s\n' "$declared_missing" | grep -q $'gpu:42\tmissing' || fail "declared missing gpu lock not reported: $declared_missing"
printf '%s\n' "$declared_missing" | grep -q $'emulator-port:4040\tmissing' || fail "declared missing port lock not reported: $declared_missing"
summary="$(lock_summary_for_worktree "$worktree_a" "sample:1")"
[[ "$summary" == *"missing:2"* ]] || fail "workspace summary did not include declared missing locks: $summary"

echo "ok"
