#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=../lib/orch-runtime/common.sh
source "$ROOT/lib/orch-runtime/common.sh"
# shellcheck source=../lib/orch-runtime/report.sh
source "$ROOT/lib/orch-runtime/report.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orch-runtime-terraform-report-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

worktree="$TMP_ROOT/worktree"
mkdir -p "$worktree/.orchestrate/terraform"

workspace_report_terraform_plan "$worktree" > "$TMP_ROOT/missing.md"
grep -q '.orchestrate/terraform/summary.md not found' "$TMP_ROOT/missing.md" \
  || fail "missing summary message not reported"

cat > "$worktree/.orchestrate/terraform/summary.md" <<'SUMMARY'
- latest_target: dev/app
- result: changes
- counts: add=1 change=2 destroy=0
- artifact: .orchestrate/terraform/dev/app/plan.txt
- GOOGLE_APPLICATION_CREDENTIALS: /tmp/secret.json
- secret_token: should-not-leak
SUMMARY

workspace_report_terraform_plan "$worktree" > "$TMP_ROOT/report.md"
grep -q 'latest_target: dev/app' "$TMP_ROOT/report.md" \
  || fail "terraform summary target missing"
grep -q 'counts: add=1 change=2 destroy=0' "$TMP_ROOT/report.md" \
  || fail "terraform summary counts missing"
if grep -Eiq 'credential|secret|token|/tmp/secret' "$TMP_ROOT/report.md"; then
  fail "sensitive terraform summary line leaked"
fi

echo "ok"
