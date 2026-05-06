#!/bin/bash
set -euo pipefail

DOTFILES="$(cd "$(dirname "$0")" && pwd)"

# worktree から走らせると symlink target が worktree path に固定され、
# worktree cleanup 後に shell / CLI が "No such file or directory" で失敗する。
# canonical main checkout の install.sh を proxy-exec して main path を使う。
# --dry-run は symlink を作らず worktree のファイル検証が目的なのでバイパスする。
if [[ "${1:-}" != "--dry-run" ]] && git -C "$DOTFILES" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  _git_dir="$(git -C "$DOTFILES" rev-parse --git-dir 2>/dev/null)"
  _git_common_dir="$(git -C "$DOTFILES" rev-parse --git-common-dir 2>/dev/null)"
  if [[ "$_git_dir" != "$_git_common_dir" ]]; then
    if [[ "${ALLOW_WORKTREE_INSTALL:-}" != "1" ]]; then
      _canonical_root="$(dirname "$_git_common_dir")"
      [[ "$_canonical_root" != /* ]] && _canonical_root="$(cd "$DOTFILES" && cd "$(dirname "$_git_common_dir")" && pwd)"
      _canonical_install="$_canonical_root/install.sh"
      if [[ -x "$_canonical_install" ]]; then
        echo "INFO: worktree detected, proxy-exec'ing $_canonical_install" >&2
        exec "$_canonical_install" "$@"
      fi
      echo "ERROR: main worktree 側の install.sh が見つかりません: $_canonical_install" >&2
      echo "       worktree のまま install を強行する場合は ALLOW_WORKTREE_INSTALL=1 を指定してください。" >&2
      exit 2
    fi
    echo "WARN: ALLOW_WORKTREE_INSTALL=1 が指定されたため worktree から続行します" >&2
  fi
fi

LOG_DIR=$(mktemp -d)
CURRENT_STEP=0
START_TIME=$SECONDS
DRY_RUN=false
DRY_RUN_ERRORS=0
[[ "${1:-}" == "--dry-run" ]] && { DRY_RUN=true; }

source "$DOTFILES/steps/lib.sh"

# --- ステップ定義 ---
STEP_NAMES=(
  "Xcode CLI Tools"
  "シンボリックリンク"
  "Homebrew + アプリ"
  "言語ランタイム (mise + Rust)"
  "Cursor"
  "アプリ設定 (Karabiner, Ghostty, lazygit)"
  "macOS defaults"
  "Automator ワークフロー"
  "検証"
)
TOTAL_STEPS=${#STEP_NAMES[@]}
STEP_STATUS=()
STEP_TIME=()
for ((i=0; i<TOTAL_STEPS; i++)); do
  STEP_STATUS+=("pending")
  STEP_TIME+=("")
done

_step_start_time=$SECONDS

# ok/warn/fail にインデントを付ける
ok()   { printf '      \033[1;32m✓\033[0m %s\n' "$1"; }
warn() { printf '      \033[1;33m!\033[0m %s\n' "$1"; }
fail() { printf '      \033[1;31m✗\033[0m %s\n' "$1"; DRY_RUN_ERRORS=$((DRY_RUN_ERRORS + 1)); }

dry_skip() {
  if [ "$DRY_RUN" = true ]; then
    printf '      \033[2m[skip] %s\033[0m\n' "$1"
    return 0
  fi
  return 1
}

step() {
  # 前のステップを完了表示
  if [ "$CURRENT_STEP" -gt 0 ]; then
    local prev=$((CURRENT_STEP - 1))
    local elapsed=$(( SECONDS - _step_start_time ))
    STEP_STATUS[$prev]="done"
    STEP_TIME[$prev]=$(printf '%d:%02d' $((elapsed / 60)) $((elapsed % 60)))
  fi

  CURRENT_STEP=$((CURRENT_STEP + 1))
  local idx=$((CURRENT_STEP - 1))
  STEP_STATUS[$idx]="running"
  _step_start_time=$SECONDS

  # ステップヘッダを表示
  echo ""
  printf '  \033[1;36m▸\033[0m %d. \033[1m%s\033[0m\n' "$CURRENT_STEP" "${STEP_NAMES[$idx]}"
}

echo ""
printf '  \033[1mtexdeath/dotfiles インストーラー\033[0m\n'
if [ "$DRY_RUN" = true ]; then
  printf '  \033[2mモード: dry-run（ソースファイルの存在チェックのみ）\033[0m\n'
fi

# --- ステップ実行 ---
for s in "$DOTFILES"/steps/[0-9]*.sh; do
  source "$s"
done

# 最後のステップを完了にする
if [ "$CURRENT_STEP" -gt 0 ]; then
  _prev=$((CURRENT_STEP - 1))
  _elapsed=$(( SECONDS - _step_start_time ))
  STEP_STATUS[$_prev]="done"
  STEP_TIME[$_prev]=$(printf '%d:%02d' $((_elapsed / 60)) $((_elapsed % 60)))
fi

# --- サマリー ---
TOTAL_ELAPSED=$(( SECONDS - START_TIME ))
total_errors=$((errors + DRY_RUN_ERRORS))

echo ""
echo "  ─────────────────────────────────────"
for ((i=0; i<TOTAL_STEPS; i++)); do
  _num=$((i + 1))
  _name="${STEP_NAMES[$i]}"
  _time="${STEP_TIME[$i]}"
  if [ "${STEP_STATUS[$i]}" = "done" ]; then
    printf '  \033[1;32m✔\033[0m %d. %s \033[2m(%s)\033[0m\n' "$_num" "$_name" "$_time"
  else
    printf '  \033[1;31m✗\033[0m %d. %s\n' "$_num" "$_name"
  fi
done
echo "  ─────────────────────────────────────"

if [ "$total_errors" -eq 0 ]; then
  if [ "$DRY_RUN" = true ]; then
    printf '  \033[1;32m✅ dry-run 完了: 全ソースファイル検証 OK (%d分%02d秒)\033[0m\n' $((TOTAL_ELAPSED / 60)) $((TOTAL_ELAPSED % 60))
  else
    printf '  \033[1;32m✅ セットアップ完了 (%d分%02d秒)\033[0m\n' $((TOTAL_ELAPSED / 60)) $((TOTAL_ELAPSED % 60))
  fi
else
  if [ "$DRY_RUN" = true ]; then
    printf '  \033[1;31m❌ dry-run 完了: %d 件のエラー\033[0m\n' "$total_errors"
  else
    printf '  \033[1;33m⚠️  %d 件の警告あり (%d分%02d秒)\033[0m\n' "$total_errors" $((TOTAL_ELAPSED / 60)) $((TOTAL_ELAPSED % 60))
    echo "  ログ: $LOG_DIR/"
  fi
fi
echo ""
exit "$total_errors"
