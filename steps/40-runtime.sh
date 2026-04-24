#!/bin/bash
# Step 4: 言語ランタイム

step "言語ランタイム"

if dry_skip "mise / rustup"; then
  [ -f "$DOTFILES/.tool-versions" ] && ok ".tool-versions が存在します" || fail ".tool-versions が見つかりません"
else
  # Go / Python / Node.js / Yarn (mise)
  if command -v mise >/dev/null 2>&1; then
    mise install > "$LOG_DIR/mise.log" 2>&1 &
    PID_MISE=$!
    spin $PID_MISE "mise install (Go, Python, Node.js, Yarn)..."
    wait $PID_MISE && ok "mise install 完了" || warn "mise install 失敗 (ログ: $LOG_DIR/mise.log)"
  else
    warn "mise が見つかりません。brew bundle を確認してください"
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
