#!/bin/bash
# Step 1: Xcode Command Line Tools

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
