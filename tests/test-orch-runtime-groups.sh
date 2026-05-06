#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=../lib/orch-runtime/common.sh
source "$ROOT/lib/orch-runtime/common.sh"
# shellcheck source=../lib/orch-runtime/panes.sh
source "$ROOT/lib/orch-runtime/panes.sh"
# shellcheck source=../lib/orch-runtime/metrics.sh
source "$ROOT/lib/orch-runtime/metrics.sh"
# shellcheck source=../lib/orch-runtime/locks.sh
source "$ROOT/lib/orch-runtime/locks.sh"
# shellcheck source=../lib/orch-runtime/report.sh
source "$ROOT/lib/orch-runtime/report.sh"
# shellcheck source=../lib/orch-runtime/watch.sh
source "$ROOT/lib/orch-runtime/watch.sh"
# shellcheck source=../lib/orch-runtime/workspace.sh
source "$ROOT/lib/orch-runtime/workspace.sh"
# shellcheck source=../lib/orch-runtime/groups.sh
source "$ROOT/lib/orch-runtime/groups.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

RAW_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orch-runtime-groups-test.XXXXXX" 2>/dev/null || true)"
[[ -n "$RAW_TMP_ROOT" && -d "$RAW_TMP_ROOT" ]] || fail "mktemp failed"
TMP_ROOT="$(cd "$RAW_TMP_ROOT" && pwd)"
[[ -n "$TMP_ROOT" && -d "$TMP_ROOT" && "$TMP_ROOT" != "$PWD" ]] || fail "temp root unsafe ($TMP_ROOT)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export ORCH_RUNTIME_GROUP_DIR="$TMP_ROOT/groups"

frontend_wt="$TMP_ROOT/frontend"
backend_wt="$TMP_ROOT/backend"
mkdir -p "$frontend_wt/.orchestrate" "$backend_wt/.orchestrate"
cat > "$frontend_wt/.orchestrate/env" <<EOF
ORCH_REPO=frontend
FRONTEND_PREVIEW_URL=http://localhost:3000
BACKEND_URL=http://localhost:8080
EOF
cat > "$backend_wt/.orchestrate/env" <<EOF
ORCH_REPO=backend
BACKEND_PREVIEW_URL=http://localhost:8080
AGENT_COORDINATOR_URL=http://localhost:9000
EOF

create_output="$(cmd_workspace_group create feature-demo --env BACKEND_URL=http://localhost:8080 --env AGENT_COORDINATOR_URL=http://localhost:9000)"
echo "$create_output" | grep -q "workspace group created: feature-demo" \
  || fail "group create output unexpected: $create_output"

cmd_workspace_group add feature-demo frontend-ws --role frontend --profile sample-frontend --worktree "$frontend_wt" >/dev/null
cmd_workspace_group add feature-demo backend-ws --role backend --profile sample-backend --worktree "$backend_wt" >/dev/null

members_file="$ORCH_RUNTIME_GROUP_DIR/feature-demo/members.tsv"
[[ -f "$members_file" ]] || fail "members.tsv not created"
member_count="$(wc -l < "$members_file" | tr -d ' ')"
[[ "$member_count" == "2" ]] || fail "expected 2 group members, got $member_count"

status_output="$(cmd_workspace_group status feature-demo)"
echo "$status_output" | grep -q "frontend-ws" \
  || fail "group status missing frontend workspace: $status_output"
echo "$status_output" | grep -Eq "missing|tmux-unavailable" \
  || fail "group status should mark offline test workspaces as unavailable: $status_output"
echo "$status_output" | grep -q "frontend=http://localhost:3000" \
  || fail "group status missing preview URL summary: $status_output"
echo "$status_output" | grep -q "sample-backend" \
  || fail "group status missing stored backend profile: $status_output"

report_output="$(cmd_workspace_group report feature-demo -n 20)"
echo "$report_output" | grep -q "# Workspace Group Report: feature-demo" \
  || fail "group report missing title"
echo "$report_output" | grep -q 'Group Environment' \
  || fail "group report missing env section"
echo "$report_output" | grep -q 'BACKEND_URL' \
  || fail "group report missing non-sensitive env"
echo "$report_output" | grep -q 'Workspace: frontend-ws' \
  || fail "group report missing per-workspace section"
echo "$report_output" | grep -Eq 'workspace state is `(missing|tmux-unavailable)`' \
  || fail "group report should skip unavailable workspaces"

# Re-adding the same workspace should upsert instead of duplicating.
cmd_workspace_group add feature-demo frontend-ws --role web --profile custom-frontend --worktree "$frontend_wt" >/dev/null
frontend_count="$(awk -F '\t' '$2 == "frontend-ws" { c++ } END { print c+0 }' "$members_file")"
[[ "$frontend_count" == "1" ]] || fail "group add duplicated frontend member"
grep -q $'web\tfrontend-ws\tcustom-frontend' "$members_file" \
  || fail "group add did not update existing member"

echo "OK: workspace groups"
