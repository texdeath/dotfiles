#!/bin/bash

set -euo pipefail

DOWNLOADS_DIR="$HOME/Downloads"

find "$DOWNLOADS_DIR" -maxdepth 1 -type f | while IFS= read -r f; do
  [ -f "$f" ] || continue

  filename=$(basename "$f")
  ext="${filename##*.}"
  ext=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')

  year=$(date -r "$f" +"%Y")
  month=$(date -r "$f" +"%m")

  base="$DOWNLOADS_DIR/$year/$month"

  case "$ext" in
    jpg|jpeg|png|gif|webp|bmp|tif|tiff|svg|heic)
      target="$base/images"
      ;;
    pdf|doc|docx|xls|xlsx|ppt|pptx|txt|rtf|md|pages|numbers|key)
      target="$base/documents"
      ;;
    zip|rar|7z|tar|gz|bz2|xz)
      target="$base/archives"
      ;;
    mp4|mov|mkv|avi|webm|mp3|wav|m4a|flac|aac)
      target="$base/media"
      ;;
    js|ts|jsx|tsx|py|go|java|rb|php|c|cpp|h|hpp|rs|swift|kt|scala|sh|bash|zsh|fish|json|yaml|yml|toml|xml|ini|conf|config)
      target="$base/code"
      ;;
    csv|tsv|sql|db|sqlite)
      target="$base/data"
      ;;
    dmg|pkg|app|command|bat|exe|msi)
      target="$base/executables"
      ;;
    *)
      target="$base/others"
      ;;
  esac

  mkdir -p "$target"
  mv "$f" "$target/"
done
