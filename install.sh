#!/bin/bash
set -euo pipefail

DOTFILES="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR=$(mktemp -d)
TOTAL_STEPS=9
CURRENT_STEP=0
START_TIME=$SECONDS
DRY_RUN=false
DRY_RUN_ERRORS=0
[[ "${1:-}" == "--dry-run" ]] && { DRY_RUN=true; }

step() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  local elapsed=$(( SECONDS - START_TIME ))
  printf '\n\033[1;34m[%d/%d]\033[0m \033[1m%s\033[0m \033[2m(経過 %d分%02d秒)\033[0m\n' \
    "$CURRENT_STEP" "$TOTAL_STEPS" "$1" $((elapsed / 60)) $((elapsed % 60))
}

source "$DOTFILES/steps/lib.sh"

echo ""
printf '  \033[1mtexdeath/dotfiles インストーラー\033[0m\n'
if [ "$DRY_RUN" = true ]; then
  printf '  \033[2mモード: dry-run（ソースファイルの存在チェックのみ）\033[0m\n'
fi
echo ""
echo "  ┌─────────────────────────────────────────────┐"
echo "  │  1. Xcode CLI Tools                         │"
echo "  │  2. シンボリックリンク                       │"
echo "  │  3. Homebrew + アプリ                        │"
echo "  │  4. 言語ランタイム (mise + Volta + Rust)     │"
echo "  │  5. Cursor                                   │"
echo "  │  6. アプリ設定 (Karabiner, Ghostty, lazygit) │"
echo "  │  7. macOS defaults                           │"
echo "  │  8. Automator ワークフロー                    │"
echo "  │  9. 検証                                     │"
echo "  └─────────────────────────────────────────────┘"
echo ""

# --- ステップ実行 ---
for s in "$DOTFILES"/steps/[0-9]*.sh; do
  source "$s"
done

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
