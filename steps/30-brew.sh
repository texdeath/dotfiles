#!/bin/bash
# Step 3: Homebrew + アプリ

step "Homebrew + アプリ"

if dry_skip "brew bundle (Brewfile の存在チェックのみ)"; then
  if [ -f "$DOTFILES/Brewfile" ]; then
    ok "Brewfile が存在します"
  else
    fail "Brewfile が見つかりません: $DOTFILES/Brewfile"
  fi
else
  if ! command -v brew >/dev/null 2>&1; then
    ok "Homebrew をインストール中..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi

  brew bundle --file="$DOTFILES/Brewfile" > "$LOG_DIR/brew.log" 2>&1 &
  PID_BREW=$!
  spin $PID_BREW "brew bundle 実行中..."
  wait $PID_BREW && ok "brew bundle 完了" || warn "brew bundle 失敗 (ログ: $LOG_DIR/brew.log)"
fi
