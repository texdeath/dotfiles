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

_detail_lines=0
_step_start_time=$SECONDS

# ok/warn/fail を上書きして詳細行数をカウント
_orig_ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$1"; }
_orig_warn() { printf '  \033[1;33m!\033[0m %s\n' "$1"; }
_orig_fail() { printf '  \033[1;31m✗\033[0m %s\n' "$1"; DRY_RUN_ERRORS=$((DRY_RUN_ERRORS + 1)); }

ok()   { printf '      \033[1;32m✓\033[0m %s\n' "$1"; _detail_lines=$((_detail_lines + 1)); }
warn() { printf '      \033[1;33m!\033[0m %s\n' "$1"; _detail_lines=$((_detail_lines + 1)); }
fail() { printf '      \033[1;31m✗\033[0m %s\n' "$1"; DRY_RUN_ERRORS=$((DRY_RUN_ERRORS + 1)); _detail_lines=$((_detail_lines + 1)); }

# dry_skip も詳細行数カウント
dry_skip() {
  if [ "$DRY_RUN" = true ]; then
    printf '      \033[2m[skip] %s\033[0m\n' "$1"
    _detail_lines=$((_detail_lines + 1))
    return 0
  fi
  return 1
}

# ステップ行を1行描画
_draw_step_line() {
  local i=$1
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
  esac
  printf '\033[K\n'
}

step() {
  # 前のステップを完了にして詳細行をクリア
  if [ "$CURRENT_STEP" -gt 0 ]; then
    local prev=$((CURRENT_STEP - 1))
    STEP_STATUS[$prev]="done"
    local elapsed=$(( SECONDS - _step_start_time ))
    STEP_TIME[$prev]=$(printf '%d:%02d' $((elapsed / 60)) $((elapsed % 60)))

    # 詳細行 + 残りのペンディング行を巻き戻す
    local remaining=$((TOTAL_STEPS - CURRENT_STEP))
    local up=$((_detail_lines + remaining))
    [ "$up" -gt 0 ] && printf '\033[%dA' "$up"

    # 完了したステップ行を再描画
    _draw_step_line "$prev"

    # 詳細行をクリア
    for ((i=0; i<_detail_lines; i++)); do
      printf '\033[K\n'
    done

    # 残りのペンディング行をクリア（位置を詰める）
    for ((i=0; i<remaining; i++)); do
      printf '\033[K\n'
    done

    # 全部戻って正しい位置から再描画
    local back=$((_detail_lines + remaining))
    [ "$back" -gt 0 ] && printf '\033[%dA' "$back"

    _detail_lines=0
  fi

  CURRENT_STEP=$((CURRENT_STEP + 1))
  local idx=$((CURRENT_STEP - 1))
  STEP_STATUS[$idx]="running"
  _step_start_time=$SECONDS

  # 現在のステップ行
  _draw_step_line "$idx"

  # 残りのペンディング行
  for ((i=idx+1; i<TOTAL_STEPS; i++)); do
    _draw_step_line "$i"
  done
  # 詳細出力は残りステップの下に出る
}

echo ""
printf '  \033[1mtexdeath/dotfiles インストーラー\033[0m\n'
if [ "$DRY_RUN" = true ]; then
  printf '  \033[2mモード: dry-run（ソースファイルの存在チェックのみ）\033[0m\n'
fi
echo ""

# 初期リスト描画
for ((i=0; i<TOTAL_STEPS; i++)); do
  _draw_step_line "$i"
done

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

  _remaining=$((TOTAL_STEPS - CURRENT_STEP))
  _up=$((_detail_lines + _remaining))
  [ "$_up" -gt 0 ] && printf '\033[%dA' "$_up"
  _draw_step_line "$_prev"
  for ((i=0; i<_detail_lines; i++)); do
    printf '\033[K\n'
  done
  for ((i=0; i<_remaining; i++)); do
    printf '\033[K\n'
  done
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
