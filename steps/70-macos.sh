#!/bin/bash
# Step 7: macOS defaults

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
