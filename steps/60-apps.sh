#!/bin/bash
# Step 6: アプリ設定

step "アプリ設定"

# Karabiner Elements
KARABINER_DST="$HOME/.config/karabiner"
dry_mkdir "$KARABINER_DST"
dry_cp "$DOTFILES/karabiner/karabiner.json" "$KARABINER_DST/karabiner.json"
ok "Karabiner Elements"

# Ghostty
GHOSTTY_DST="$HOME/.config/ghostty"
if [ -d "$DOTFILES/ghostty" ] && [ -f "$DOTFILES/ghostty/config" ]; then
  dry_mkdir "$GHOSTTY_DST"
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
