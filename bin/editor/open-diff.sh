#!/bin/bash
set -uo pipefail

# オプション: -s <summary_file> でサマリーファイルを指定
summary_file=""
while getopts "s:" opt; do
  case "$opt" in
    s) summary_file="$OPTARG" ;;
    *) ;;
  esac
done
shift $((OPTIND - 1))

# git リポジトリのルートに移動
repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$repo_root" ]; then
  echo "Error: not in a git repository" >&2
  exit 1
fi
cd "$repo_root"

# 変更ファイル一覧（unstaged + staged）
files=$(git diff --name-only HEAD 2>/dev/null || git diff --name-only)
if [ -z "$files" ]; then
  echo "変更ファイルなし"
  exit 0
fi

tmpdir="/tmp/zed-diff-$$"
mkdir -p "$tmpdir/old" "$tmpdir/new"

# セッション記録（close-diff.sh で削除用）
echo "$tmpdir" > /tmp/zed-diff-session

# 変更ファイルの HEAD 版と現在版を一時ディレクトリにコピー
opened=0
while IFS= read -r file; do
  [ -f "$repo_root/$file" ] || continue

  # ディレクトリ構造を維持
  mkdir -p "$tmpdir/old/$(dirname "$file")" "$tmpdir/new/$(dirname "$file")"
  git show "HEAD:$file" > "$tmpdir/old/$file" 2>/dev/null || touch "$tmpdir/old/$file"
  cp "$repo_root/$file" "$tmpdir/new/$file"
  opened=$((opened + 1))
  echo "  $file"
done <<< "$files"

# Zed でディレクトリ diff を開く
zed --diff "$tmpdir/old" "$tmpdir/new" </dev/null >/dev/null 2>&1 &
sleep 2

# サマリーファイルがあれば右ペインにプレビューで開く
if [ -n "$summary_file" ] && [ -f "$summary_file" ]; then
  zed -a "$summary_file" </dev/null >/dev/null 2>&1 &
  sleep 1
  osascript <<'APPLESCRIPT'
  tell application "System Events"
    tell process "Zed"
      set frontmost to true
      delay 0.5
      -- Markdown プレビュー (Cmd+Shift+V)
      keystroke "v" using {command down, shift down}
      delay 0.5
      -- ソースタブを閉じる (Diff タブの右隣にあるので、そこに移動して閉じる)
      -- Cmd+Shift+[ で前のタブに移動
      keystroke "[" using {command down, shift down}
      delay 0.2
      keystroke "w" using command down
    end tell
  end tell
APPLESCRIPT
fi

# フォーカスを Ghostty に戻す
sleep 1
osascript -e 'tell application "Ghostty" to activate' 2>/dev/null

echo "Zed で ${opened} ファイルの diff を開きました"
