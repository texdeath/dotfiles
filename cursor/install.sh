#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CURSOR_USER_DIR="$HOME/Library/Application Support/Cursor/User"

mkdir -p "$CURSOR_USER_DIR"

# 設定ファイルをコピー
cp "$SCRIPT_DIR/settings.json" "$CURSOR_USER_DIR/settings.json"
cp "$SCRIPT_DIR/keybindings.json" "$CURSOR_USER_DIR/keybindings.json"

# 拡張機能をインストール
while IFS= read -r ext; do
  [[ -z "$ext" ]] && continue
  echo "Installing: $ext"
  cursor --install-extension "$ext" || echo "  SKIP: $ext (インストール失敗)"
done < "$SCRIPT_DIR/extensions.txt"

echo ""
echo "完了"
