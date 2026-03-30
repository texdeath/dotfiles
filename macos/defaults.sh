#!/usr/bin/env bash
set -euo pipefail

# macOS のシステム設定をスクリプトで適用する
# 適用後、一部の設定は再ログインまたは再起動が必要

ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$1"; }
info() { printf '  \033[1;34mℹ\033[0m %s\n' "$1"; }

echo ""
info "macOS defaults を適用中..."
echo ""

# --- キーボード ---
# 値は小さいほど速い（Backspace の連続削除速度にも反映）
defaults write NSGlobalDomain KeyRepeat -int 2
defaults write NSGlobalDomain InitialKeyRepeat -int 10
ok "キーリピート: 速度=2, 開始=10"

# --- Dock ---
defaults write com.apple.dock tilesize -int 35
defaults write com.apple.dock autohide -bool true
defaults write com.apple.dock orientation -string "left"
defaults write com.apple.dock show-recents -bool false
ok "Dock: サイズ=35, 自動非表示, 左配置, 最近の項目非表示"

# --- スクロール ---
defaults write NSGlobalDomain com.apple.swipescrolldirection -bool false
ok "スクロール方向: ナチュラル無効（従来方向）"

# --- スクリーンショット ---
defaults write com.apple.screencapture location -string "~/Pictures/Screenshot"
mkdir -p ~/Pictures/Screenshot
ok "スクリーンショット保存先: ~/Pictures/Screenshot"

# --- Finder ---
defaults write com.apple.finder ShowPathbar -bool true
defaults write com.apple.finder ShowStatusBar -bool true
ok "Finder: パスバー表示, ステータスバー表示"

# --- 変更を反映 ---
killall Dock 2>/dev/null || true
killall Finder 2>/dev/null || true

echo ""
ok "macOS defaults 適用完了"
info "一部の設定は再ログイン後に反映されます"
echo ""
