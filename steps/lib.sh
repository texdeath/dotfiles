#!/bin/bash
# install.sh 共通ヘルパー
# 各ステップスクリプトから source される

ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$1"; }
fail() { printf '  \033[1;31m✗\033[0m %s\n' "$1"; DRY_RUN_ERRORS=$((DRY_RUN_ERRORS + 1)); }

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

dry_skip() {
  if [ "$DRY_RUN" = true ]; then
    printf '  \033[2m[skip] %s\033[0m\n' "$1"
    return 0
  fi
  return 1
}

dry_mkdir() {
  if [ "$DRY_RUN" != true ]; then
    mkdir -p "$@"
  fi
}
