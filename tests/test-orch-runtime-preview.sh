#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=../lib/orch-runtime/common.sh
source "$ROOT/lib/orch-runtime/common.sh"
# shellcheck source=../lib/orch-runtime/panes.sh
source "$ROOT/lib/orch-runtime/panes.sh"
# shellcheck source=../lib/orch-runtime/report.sh
source "$ROOT/lib/orch-runtime/report.sh"
# shellcheck source=../lib/orch-runtime/workspace.sh
source "$ROOT/lib/orch-runtime/workspace.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orch-runtime-preview-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

worktree="$TMP_ROOT/worktree"
mkdir -p "$worktree/.orchestrate"
cat > "$worktree/.orchestrate/env" <<'ENV'
ORCH_REPO=backend
FRONTEND_PREVIEW_URL=http://localhost:35110
FRONTEND_HMR_URL=ws://localhost:35111
BACKEND_PREVIEW_URL=http://localhost:35120
AGENT_PREVIEW_URL=http://localhost:35130
AGENT_MCP_URL=http://localhost:35132
SECRET_TOKEN=hidden
ENV

primary="$(workspace_preview_primary_url "$worktree")"
[[ "$primary" == "http://localhost:35120" ]] || fail "backend primary preview URL mismatch: $primary"

summary="$(workspace_preview_summary "$worktree" 200)"
[[ "$summary" == *"frontend=http://localhost:35110"* ]] || fail "frontend summary missing: $summary"
[[ "$summary" == *"backend=http://localhost:35120"* ]] || fail "backend summary missing: $summary"
[[ "$summary" == *"agent=http://localhost:35130"* ]] || fail "agent summary missing: $summary"

workspace_report_preview_urls "$worktree" > "$TMP_ROOT/preview-report.md"
grep -q 'frontend.*http://localhost:35110' "$TMP_ROOT/preview-report.md" || fail "frontend report URL missing"
grep -q 'backend.*http://localhost:35120' "$TMP_ROOT/preview-report.md" || fail "backend report URL missing"
grep -q 'hmr.*ws://localhost:35111' "$TMP_ROOT/preview-report.md" || fail "HMR report URL missing"
if grep -q 'SECRET_TOKEN' "$TMP_ROOT/preview-report.md"; then
  fail "sensitive key leaked into preview report"
fi

need_tmux() {
  :
}

workspace_resolve_window() {
  [[ "$1" == "sample" ]] || fail "unexpected workspace lookup: $1"
  printf '%s' "test:1"
}

tmux() {
  if [[ "$1" == "list-panes" ]]; then
    printf '%s\n' "$MOCK_PANE_PATH"
    return 0
  fi
  return 1
}

open() {
  printf '%s\n' "$1" > "$TMP_ROOT/opened.url"
}

MOCK_PANE_PATH="$worktree"
cmd_workspace_open sample --print > "$TMP_ROOT/open-print.out"
grep -qx 'http://localhost:35120' "$TMP_ROOT/open-print.out" || fail "workspace open --print returned wrong URL"

cmd_workspace_open sample
grep -qx 'http://localhost:35120' "$TMP_ROOT/opened.url" || fail "workspace open did not call open with primary URL"

missing_worktree="$TMP_ROOT/missing-preview"
mkdir -p "$missing_worktree/.orchestrate"
MOCK_PANE_PATH="$missing_worktree"
if (cmd_workspace_open sample --print) > "$TMP_ROOT/open-missing.out" 2> "$TMP_ROOT/open-missing.err"; then
  fail "workspace open unexpectedly succeeded without preview URL"
fi
grep -q "workspace open: no preview URL found" "$TMP_ROOT/open-missing.err" || fail "workspace open missing-url error not reported"

echo "ok"
