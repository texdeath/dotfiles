#!/bin/bash
set -euo pipefail

DOTFILES="$(cd "$(dirname "$0")" && pwd)"
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
  "言語ランタイム (mise + Volta + Rust)"
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

# --- 進捗表示 ---
_progress_drawn=false

draw_progress() {
  # 2回目以降は前の表示を消す
  if [ "$_progress_drawn" = true ]; then
    printf '\033[%dA' "$((TOTAL_STEPS + 1))"
  fi
  _progress_drawn=true

  for ((i=0; i<TOTAL_STEPS; i++)); do
    local num=$((i + 1))
    local name="${STEP_NAMES[$i]}"
    local status="${STEP_STATUS[$i]}"
    local time="${STEP_TIME[$i]}"

    case "$status" in
      done)
        printf '  \033[1;32m✔\033[0m %d. %s' "$num" "$name"
        [ -n "$time" ] && printf ' \033[2m(%s)\033[0m' "$time"
        ;;
      running)
        printf '  \033[1;36m▸\033[0m %d. \033[1m%s\033[0m' "$num" "$name"
        ;;
      pending)
        printf '  \033[2m☐ %d. %s\033[0m' "$num" "$name"
        ;;
      skip)
        printf '  \033[2m─ %d. %s (skip)\033[0m' "$num" "$name"
        ;;
    esac
    printf '\033[K\n'
  done
  printf '\033[K'
}

step() {
  local step_start=$SECONDS

  # 前のステップを完了にする
  if [ "$CURRENT_STEP" -gt 0 ]; then
    local prev=$((CURRENT_STEP - 1))
    if [ "${STEP_STATUS[$prev]}" = "running" ]; then
      STEP_STATUS[$prev]="done"
      local elapsed=$(( SECONDS - _step_start_time ))
      STEP_TIME[$prev]=$(printf '%d:%02d' $((elapsed / 60)) $((elapsed % 60)))
    fi
  fi

  CURRENT_STEP=$((CURRENT_STEP + 1))
  local idx=$((CURRENT_STEP - 1))
  STEP_STATUS[$idx]="running"
  _step_start_time=$SECONDS

  draw_progress
}

_step_start_time=$SECONDS

echo ""
printf '  \033[1mtexdeath/dotfiles インストーラー\033[0m\n'
if [ "$DRY_RUN" = true ]; then
  printf '  \033[2mモード: dry-run（ソースファイルの存在チェックのみ）\033[0m\n'
fi
echo ""

# 初期表示
draw_progress

# --- ステップ実行 ---
for s in "$DOTFILES"/steps/[0-9]*.sh; do
  source "$s"
done

# 最後のステップを完了にする
if [ "$CURRENT_STEP" -gt 0 ]; then
  _prev=$((CURRENT_STEP - 1))
  STEP_STATUS[$_prev]="done"
  _elapsed=$(( SECONDS - _step_start_time ))
  STEP_TIME[$_prev]=$(printf '%d:%02d' $((_elapsed / 60)) $((_elapsed % 60)))
  draw_progress
fi

# --- 結果表示 ---
TOTAL_ELAPSED=$(( SECONDS - START_TIME ))
total_errors=$((errors + DRY_RUN_ERRORS))

echo ""
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
