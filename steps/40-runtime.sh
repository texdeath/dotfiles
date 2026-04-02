#!/bin/bash
# Step 4: 言語ランタイム

step "言語ランタイム"

if dry_skip "mise / volta / rustup"; then
  [ -f "$DOTFILES/.tool-versions" ] && ok ".tool-versions が存在します" || fail ".tool-versions が見つかりません"
else
  # Go / Python (mise)
  if command -v mise >/dev/null 2>&1; then
    mise install > "$LOG_DIR/mise.log" 2>&1 &
    PID_MISE=$!
    spin $PID_MISE "mise install (Go, Python)..."
    wait $PID_MISE && ok "mise install 完了" || warn "mise install 失敗 (ログ: $LOG_DIR/mise.log)"
  else
    warn "mise が見つかりません。brew bundle を確認してください"
  fi

  # Node.js (Volta)
  if command -v volta >/dev/null 2>&1; then
    volta install node@24 > "$LOG_DIR/volta.log" 2>&1
    volta install yarn@4 >> "$LOG_DIR/volta.log" 2>&1
    ok "Volta: node@24, yarn@4"
  else
    warn "volta が見つかりません。brew bundle を確認してください"
  fi

  # Rust
  if command -v rustup >/dev/null 2>&1; then
    rustup update stable > "$LOG_DIR/rust.log" 2>&1
    ok "Rust: stable 更新済み"
  else
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y > "$LOG_DIR/rust.log" 2>&1
    ok "Rust: 新規インストール"
  fi
fi
