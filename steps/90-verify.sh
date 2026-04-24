#!/bin/bash
# Step 9: 検証

step "検証"

errors=0
if [ "$DRY_RUN" = true ]; then
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
    "$DOTFILES/ghostty/config"
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
  command -v yarn >/dev/null 2>&1     && ok "yarn $(yarn --version)" || { warn "yarn が見つかりません"; errors=$((errors + 1)); }
  command -v codex >/dev/null 2>&1    && ok "codex"  || { warn "codex が見つかりません"; errors=$((errors + 1)); }
  command -v rustc >/dev/null 2>&1    && ok "rustc $(rustc --version | awk '{print $2}')" || { warn "rustc が見つかりません"; errors=$((errors + 1)); }
  command -v delta >/dev/null 2>&1    && ok "delta"  || { warn "delta が見つかりません"; errors=$((errors + 1)); }
  command -v lazygit >/dev/null 2>&1  && ok "lazygit" || { warn "lazygit が見つかりません"; errors=$((errors + 1)); }
  command -v direnv >/dev/null 2>&1   && ok "direnv" || { warn "direnv が見つかりません"; errors=$((errors + 1)); }
  command -v zoxide >/dev/null 2>&1   && ok "zoxide" || { warn "zoxide が見つかりません"; errors=$((errors + 1)); }
  [ -L "$HOME/.zshrc" ]              && ok ".zshrc リンク済み" || { warn ".zshrc 未リンク"; errors=$((errors + 1)); }
  [ -L "$HOME/.gitconfig" ]          && ok ".gitconfig リンク済み" || { warn ".gitconfig 未リンク"; errors=$((errors + 1)); }
  [ -L "$HOME/.tool-versions" ]      && ok ".tool-versions リンク済み" || { warn ".tool-versions 未リンク"; errors=$((errors + 1)); }
fi
