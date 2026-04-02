#!/bin/bash
set -euo pipefail

DOTFILES="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR=$(mktemp -d)
TOTAL_STEPS=9
CURRENT_STEP=0
START_TIME=$SECONDS
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && { DRY_RUN=true; }

step() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  local elapsed=$(( SECONDS - START_TIME ))
  printf '\n\033[1;34m[%d/%d]\033[0m \033[1m%s\033[0m \033[2m(経過 %d分%02d秒)\033[0m\n' \
    "$CURRENT_STEP" "$TOTAL_STEPS" "$1" $((elapsed / 60)) $((elapsed % 60))
}

ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$1"; }
fail() { printf '  \033[1;31m✗\033[0m %s\n' "$1"; DRY_RUN_ERRORS=$((DRY_RUN_ERRORS + 1)); }
DRY_RUN_ERRORS=0

spin() {
  local pid=$1 label=$2
  local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    local elapsed=$(( SECONDS - START_TIME ))
    printf '\r  \033[1;36m%s\033[0m %s \033[2m(%d分%02d秒)\033[0m  ' \
      "${chars:i%${#chars}:1}" "$label" $((elapsed / 60)) $((elapsed % 60))
    i=$((i + 1))
    sleep 0.1
  done
  printf '\r\033[K'
}

# dry-run: ソースファイルの存在を検証してリンク先を表示
# 通常: シンボリックリンクを作成
dry_link() {
  local src="$1" dest="$2"
  if [ "$DRY_RUN" = true ]; then
    if [ -e "$src" ]; then
      ok "$(basename "$dest") → $src"
    else
      fail "$(basename "$dest") — ソースが見つかりません: $src"
    fi
  else
    ln -sf "$src" "$dest"
  fi
}

# dry-run: ソースファイルの存在を検証してコピー先を表示
# 通常: ファイルをコピー
dry_cp() {
  local src="$1" dest="$2"
  if [ "$DRY_RUN" = true ]; then
    if [ -e "$src" ]; then
      ok "$(basename "$dest") ← $src"
    else
      fail "$(basename "$dest") — ソースが見つかりません: $src"
    fi
  else
    cp "$src" "$dest"
  fi
}

dry_cp_r() {
  local src="$1" dest="$2"
  if [ "$DRY_RUN" = true ]; then
    if [ -d "$src" ]; then
      ok "$(basename "$dest") ← $src"
    else
      fail "$(basename "$dest") — ソースが見つかりません: $src"
    fi
  else
    cp -R "$src" "$dest"
  fi
}

# dry-run: スキップするがログ出力
dry_skip() {
  if [ "$DRY_RUN" = true ]; then
    printf '  \033[2m[skip] %s\033[0m\n' "$1"
    return 0
  fi
  return 1
}

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

# --- 1. Xcode Command Line Tools ---
step "Xcode Command Line Tools"

if dry_skip "xcode-select"; then
  :
elif xcode-select -p >/dev/null 2>&1; then
  ok "インストール済み"
else
  xcode-select --install
  echo "  インストールダイアログが表示されます。完了後にこのスクリプトを再実行してください。"
  exit 0
fi

# --- 2. シンボリックリンク ---
step "シンボリックリンク"

[ "$DRY_RUN" != true ] && mkdir -p "$HOME/.zsh" "$HOME/bin"

# zsh
dry_link "$DOTFILES/zsh/zshrc" "$HOME/.zshrc"
dry_link "$DOTFILES/zsh/zshenv" "$HOME/.zshenv"
for f in tools plugins completions aliases functions prompt; do
  dry_link "$DOTFILES/zsh/${f}.zsh" "$HOME/.zsh/${f}.zsh"
done
ok "zsh (zshrc, zshenv, 6 modules)"

# git
dry_link "$DOTFILES/git/gitconfig" "$HOME/.gitconfig"
dry_link "$DOTFILES/git/gitignore_global" "$HOME/.gitignore_global"
ok "git (gitconfig, gitignore_global)"

# bin
for d in fileops editor notion claude; do
  dry_link "$DOTFILES/bin/$d" "$HOME/bin/$d"
done
ok "bin (fileops, editor, notion, claude)"

# secrets
dry_link "$DOTFILES/secrets/bw-secret.sh" "$HOME/bin/bw-secret.sh"
ok "bin/bw-secret.sh"

# mise (.tool-versions)
dry_link "$DOTFILES/.tool-versions" "$HOME/.tool-versions"
ok ".tool-versions"

# lazygit
LAZYGIT_DST="$HOME/.config/lazygit"
[ "$DRY_RUN" != true ] && mkdir -p "$LAZYGIT_DST"
dry_link "$DOTFILES/lazygit/config.yml" "$LAZYGIT_DST/config.yml"
ok "lazygit"

# --- 3. Homebrew ---
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

# --- 4. 言語ランタイム ---
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

# --- 5. Cursor ---
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

# --- 6. アプリ設定 ---
step "アプリ設定"

# Karabiner Elements
KARABINER_DST="$HOME/.config/karabiner"
[ "$DRY_RUN" != true ] && mkdir -p "$KARABINER_DST"
dry_cp "$DOTFILES/karabiner/karabiner.json" "$KARABINER_DST/karabiner.json"
ok "Karabiner Elements"

# Ghostty
GHOSTTY_DST="$HOME/.config/ghostty"
if [ -d "$DOTFILES/ghostty" ] && [ -f "$DOTFILES/ghostty/config" ]; then
  [ "$DRY_RUN" != true ] && mkdir -p "$GHOSTTY_DST"
  dry_link "$DOTFILES/ghostty/config" "$GHOSTTY_DST/config"
  ok "Ghostty"
else
  warn "Ghostty: 設定ファイルなし ($DOTFILES/ghostty/config)"
fi

# Raycast
if [ -d "$DOTFILES/raycast" ] && ls "$DOTFILES"/raycast/*.rayconfig >/dev/null 2>&1; then
  ok "Raycast: 手動インポートが必要です"
  ok "  Raycast > Settings > Advanced > Import"
  ok "  ファイル: $(ls "$DOTFILES"/raycast/*.rayconfig)"
else
  warn "Raycast: .rayconfig なし"
fi

# --- 7. macOS defaults ---
step "macOS defaults"

if dry_skip "macOS defaults"; then
  if [ -f "$DOTFILES/macos/defaults.sh" ]; then
    ok "macos/defaults.sh が存在します"
  else
    fail "macos/defaults.sh が見つかりません"
  fi
else
  bash "$DOTFILES/macos/defaults.sh"
fi

# --- 8. Automator ワークフロー ---
step "Automator ワークフロー"

AUTOMATOR_DST="$HOME/Library/Workflows/Applications/Folder Actions"
[ "$DRY_RUN" != true ] && mkdir -p "$AUTOMATOR_DST"

for wf in "$DOTFILES"/automator/folder-actions/*.workflow; do
  if [ -d "$wf" ]; then
    name=$(basename "$wf")
    dry_cp_r "$wf" "$AUTOMATOR_DST/$name"
    ok "$name"
  fi
done

if [ -z "$(ls -A "$DOTFILES/automator/folder-actions/" 2>/dev/null)" ]; then
  warn "ワークフローなし"
fi

# --- 9. 検証 ---
step "検証"

errors=0
if [ "$DRY_RUN" = true ]; then
  # dry-run: リンク元ファイルの存在チェック
  SOURCES=(
    "$DOTFILES/zsh/zshrc"
    "$DOTFILES/zsh/zshenv"
    "$DOTFILES/zsh/tools.zsh"
    "$DOTFILES/zsh/plugins.zsh"
    "$DOTFILES/zsh/completions.zsh"
    "$DOTFILES/zsh/aliases.zsh"
    "$DOTFILES/zsh/functions.zsh"
    "$DOTFILES/zsh/prompt.zsh"
    "$DOTFILES/git/gitconfig"
    "$DOTFILES/git/gitignore_global"
    "$DOTFILES/bin/fileops"
    "$DOTFILES/bin/editor"
    "$DOTFILES/bin/notion"
    "$DOTFILES/bin/claude"
    "$DOTFILES/secrets/bw-secret.sh"
    "$DOTFILES/.tool-versions"
    "$DOTFILES/lazygit/config.yml"
    "$DOTFILES/karabiner/karabiner.json"
    "$DOTFILES/macos/defaults.sh"
    "$DOTFILES/Brewfile"
    "$DOTFILES/VERSION"
  )
  for src in "${SOURCES[@]}"; do
    if [ -e "$src" ]; then
      ok "$(echo "$src" | sed "s|$DOTFILES/||")"
    else
      fail "$(echo "$src" | sed "s|$DOTFILES/||") — 見つかりません"
      errors=$((errors + 1))
    fi
  done
else
  command -v brew >/dev/null 2>&1     && ok "brew"   || { warn "brew が見つかりません"; errors=$((errors + 1)); }
  command -v mise >/dev/null 2>&1     && ok "mise"   || { warn "mise が見つかりません"; errors=$((errors + 1)); }
  command -v go >/dev/null 2>&1       && ok "go $(go version | awk '{print $3}')" || { warn "go が見つかりません"; errors=$((errors + 1)); }
  command -v python3 >/dev/null 2>&1  && ok "python $(python3 --version 2>&1 | awk '{print $2}')" || { warn "python3 が見つかりません"; errors=$((errors + 1)); }
  command -v node >/dev/null 2>&1     && ok "node $(node --version)" || { warn "node が見つかりません"; errors=$((errors + 1)); }
  command -v volta >/dev/null 2>&1    && ok "volta"  || { warn "volta が見つかりません"; errors=$((errors + 1)); }
  command -v rustc >/dev/null 2>&1    && ok "rustc $(rustc --version | awk '{print $2}')" || { warn "rustc が見つかりません"; errors=$((errors + 1)); }
  command -v delta >/dev/null 2>&1    && ok "delta"  || { warn "delta が見つかりません"; errors=$((errors + 1)); }
  command -v lazygit >/dev/null 2>&1  && ok "lazygit" || { warn "lazygit が見つかりません"; errors=$((errors + 1)); }
  command -v direnv >/dev/null 2>&1   && ok "direnv" || { warn "direnv が見つかりません"; errors=$((errors + 1)); }
  command -v zoxide >/dev/null 2>&1   && ok "zoxide" || { warn "zoxide が見つかりません"; errors=$((errors + 1)); }
  [ -L "$HOME/.zshrc" ]              && ok ".zshrc リンク済み" || { warn ".zshrc 未リンク"; errors=$((errors + 1)); }
  [ -L "$HOME/.gitconfig" ]          && ok ".gitconfig リンク済み" || { warn ".gitconfig 未リンク"; errors=$((errors + 1)); }
  [ -L "$HOME/.tool-versions" ]      && ok ".tool-versions リンク済み" || { warn ".tool-versions 未リンク"; errors=$((errors + 1)); }
fi

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
