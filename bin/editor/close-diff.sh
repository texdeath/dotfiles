#!/bin/bash
set -euo pipefail

# Zed の diff タブを閉じる（Cmd+W）
osascript <<'APPLESCRIPT'
tell application "System Events"
  if not (exists process "Zed") then return
  tell process "Zed"
    set frontmost to true
    delay 0.3
    -- Cmd+W でアクティブタブを閉じる
    keystroke "w" using command down
  end tell
end tell
APPLESCRIPT

# フォーカスを Ghostty に戻す
sleep 0.3
osascript -e 'tell application "Ghostty" to activate' 2>/dev/null

# 一時ファイルの削除
if [ -f /tmp/zed-diff-session ]; then
  tmpdir=$(cat /tmp/zed-diff-session)
  if [ -d "$tmpdir" ]; then
    rm -rf "$tmpdir"
  fi
  rm -f /tmp/zed-diff-session
fi

echo "diff を閉じました"
