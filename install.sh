#!/bin/bash
set -euo pipefail

DOTFILES="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR=$(mktemp -d)
TOTAL_STEPS=9
CURRENT_STEP=0
START_TIME=$SECONDS

step() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  local elapsed=$(( SECONDS - START_TIME ))
  printf '\n\033[1;34m[%d/%d]\033[0m \033[1m%s\033[0m \033[2m(経過 %d分%02d秒)\033[0m\n' \
    "$CURRENT_STEP" "$TOTAL_STEPS" "$1" $((elapsed / 60)) $((elapsed % 60))
}

ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$1"; }
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

echo ""
printf '  \033[1mtexdeath/dotfiles インストーラー\033[0m\n'
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

if xcode-select -p >/dev/null 2>&1; then
  ok "インストール済み"
else
  xcode-select --install
  echo "  インストールダイアログが表示されます。完了後にこのスクリプトを再実行してください。"
  exit 0
fi

# --- 2. シンボリックリンク ---
step "シンボリックリンク"

mkdir -p "$HOME/.zsh" "$HOME/bin"

# zsh
ln -sf "$DOTFILES/zsh/zshrc" "$HOME/.zshrc"
ln -sf "$DOTFILES/zsh/zshenv" "$HOME/.zshenv"
for f in tools plugins completions aliases functions prompt; do
  ln -sf "$DOTFILES/zsh/${f}.zsh" "$HOME/.zsh/${f}.zsh"
done
ok "zsh (zshrc, zshenv, 6 modules)"

# git
ln -sf "$DOTFILES/git/gitconfig" "$HOME/.gitconfig"
ln -sf "$DOTFILES/git/gitignore_global" "$HOME/.gitignore_global"
ok "git (gitconfig, gitignore_global)"

# bin
for d in fileops editor notion claude; do
  ln -sf "$DOTFILES/bin/$d" "$HOME/bin/$d"
done
ok "bin (fileops, editor, notion, claude)"

# secrets
ln -sf "$DOTFILES/secrets/bw-secret.sh" "$HOME/bin/bw-secret.sh"
ok "bin/bw-secret.sh"

# mise (.tool-versions)
ln -sf "$DOTFILES/.tool-versions" "$HOME/.tool-versions"
ok ".tool-versions"

# lazygit
LAZYGIT_DST="$HOME/.config/lazygit"
mkdir -p "$LAZYGIT_DST"
ln -sf "$DOTFILES/lazygit/config.yml" "$LAZYGIT_DST/config.yml"
ok "lazygit"

# --- 3. Homebrew ---
step "Homebrew + アプリ"

if ! command -v brew >/dev/null 2>&1; then
  ok "Homebrew をインストール中..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

brew bundle --file="$DOTFILES/Brewfile" > "$LOG_DIR/brew.log" 2>&1 &
PID_BREW=$!
spin $PID_BREW "brew bundle 実行中..."
wait $PID_BREW && ok "brew bundle 完了" || warn "brew bundle 失敗 (ログ: $LOG_DIR/brew.log)"

# --- 4. 言語ランタイム ---
step "言語ランタイム"

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

# --- 5. Cursor ---
step "Cursor"

if command -v cursor >/dev/null 2>&1; then
  bash "$DOTFILES/cursor/install.sh" > "$LOG_DIR/cursor.log" 2>&1 &
  PID_CURSOR=$!
  spin $PID_CURSOR "拡張機能 + 設定..."
  wait $PID_CURSOR && ok "Cursor 設定完了" || warn "Cursor 失敗 (ログ: $LOG_DIR/cursor.log)"
else
  warn "Cursor 未インストール、スキップ"
fi

# --- 6. アプリ設定 ---
step "アプリ設定"

# Karabiner Elements
KARABINER_DST="$HOME/.config/karabiner"
mkdir -p "$KARABINER_DST"
cp "$DOTFILES/karabiner/karabiner.json" "$KARABINER_DST/karabiner.json"
ok "Karabiner Elements"

# Ghostty
GHOSTTY_DST="$HOME/.config/ghostty"
if [ -d "$DOTFILES/ghostty" ] && [ -f "$DOTFILES/ghostty/config" ]; then
  mkdir -p "$GHOSTTY_DST"
  ln -sf "$DOTFILES/ghostty/config" "$GHOSTTY_DST/config"
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

bash "$DOTFILES/macos/defaults.sh"

# --- 8. Automator ワークフロー ---
step "Automator ワークフロー"

AUTOMATOR_DST="$HOME/Library/Workflows/Applications/Folder Actions"
mkdir -p "$AUTOMATOR_DST"

for wf in "$DOTFILES"/automator/folder-actions/*.workflow; do
  if [ -d "$wf" ]; then
    name=$(basename "$wf")
    cp -R "$wf" "$AUTOMATOR_DST/$name"
    ok "$name"
  fi
done

if [ -z "$(ls -A "$DOTFILES/automator/folder-actions/" 2>/dev/null)" ]; then
  warn "ワークフローなし"
fi

# --- 9. 検証 ---
step "検証"

errors=0
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

TOTAL_ELAPSED=$(( SECONDS - START_TIME ))

echo ""
if [ "$errors" -eq 0 ]; then
  printf '  \033[1;32m✅ セットアップ完了 (%d分%02d秒)\033[0m\n' $((TOTAL_ELAPSED / 60)) $((TOTAL_ELAPSED % 60))
else
  printf '  \033[1;33m⚠️  %d 件の警告あり (%d分%02d秒)\033[0m\n' "$errors" $((TOTAL_ELAPSED / 60)) $((TOTAL_ELAPSED % 60))
  echo "  ログ: $LOG_DIR/"
fi
echo ""
