#!/bin/bash
set -euo pipefail

# --- anyenv ---
if ! command -v anyenv >/dev/null 2>&1; then
  echo "anyenv が見つかりません。先に brew bundle を実行してください"
  exit 1
fi

# goenv
echo "--- Go ---"
anyenv install goenv -s
goenv install 1.24.6 -s
goenv global 1.24.6

# pyenv
echo "--- Python ---"
anyenv install pyenv -s
pyenv install 3.13.11 -s
pyenv global 3.13.11

# nodenv
echo "--- Node.js (via volta) ---"
if command -v volta >/dev/null 2>&1; then
  volta install node@24
  volta install yarn@4
else
  echo "volta が見つかりません。brew bundle を実行してください"
fi

# --- Rust ---
echo "--- Rust ---"
if command -v rustup >/dev/null 2>&1; then
  rustup update stable
else
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi

echo ""
echo "完了"
