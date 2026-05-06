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

  # Global pnpm packages
  if command -v pnpm >/dev/null 2>&1; then
    : "${PNPM_HOME:=$HOME/Library/pnpm}"
    export PNPM_HOME
    mkdir -p "$PNPM_HOME"
    case ":$PATH:" in
      *":$PNPM_HOME:"*) ;;
      *) export PATH="$PNPM_HOME:$PATH" ;;
    esac

    PNPM_GLOBAL_PACKAGES=(
    )
    for pkg in "${PNPM_GLOBAL_PACKAGES[@]}"; do
      if pnpm list -g "$pkg" 2>/dev/null | grep -q "^$pkg "; then
        ok "pnpm: $pkg は既にインストール済み"
      else
        pnpm add -g "$pkg" > "$LOG_DIR/pnpm-$pkg.log" 2>&1 &
        PID_PNPM=$!
        spin $PID_PNPM "pnpm add -g $pkg..."
        wait $PID_PNPM && ok "pnpm add -g $pkg 完了" || warn "pnpm add -g $pkg 失敗 (ログ: $LOG_DIR/pnpm-$pkg.log)"
      fi
    done
  else
    warn "pnpm が見つかりません (Brewfile を確認してください)"
  fi
fi
