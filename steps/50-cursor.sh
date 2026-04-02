#!/bin/bash
# Step 5: Cursor

step "Cursor"

if dry_skip "Cursor 設定"; then
  if [ -f "$DOTFILES/cursor/install.sh" ]; then
    ok "cursor/install.sh が存在します"
  else
    fail "cursor/install.sh が見つかりません"
  fi
else
  if command -v cursor >/dev/null 2>&1; then
    bash "$DOTFILES/cursor/install.sh" > "$LOG_DIR/cursor.log" 2>&1 &
    PID_CURSOR=$!
    spin $PID_CURSOR "拡張機能 + 設定..."
    wait $PID_CURSOR && ok "Cursor 設定完了" || warn "Cursor 失敗 (ログ: $LOG_DIR/cursor.log)"
  else
    warn "Cursor 未インストール、スキップ"
  fi
fi
