#!/bin/bash
set -euo pipefail

BASE_DIR="$HOME/Pictures/Screenshot"
IMAGE_DIR="$BASE_DIR/images"
MOVIE_DIR="$BASE_DIR/movies"

mkdir -p "$IMAGE_DIR" "$MOVIE_DIR"

find "$BASE_DIR" -maxdepth 1 -type f ! -name 'image_*' -print0 \
| while IFS= read -r -d '' file; do
    base="$(basename "$file")"
    ext="${base##*.}"
    ext="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"

    ts="$(stat -f "%SB" -t "%Y%m%d%H%M%S" "$file")"

    year="${ts:0:4}"
    mmdd="${ts:4:4}"
    today="$(date +%Y%m%d)"

    # 当日のファイルは !MMDD ディレクトリに保存
    if [ "${year}${mmdd}" = "$today" ]; then
      prefix="!"
    else
      prefix=""
    fi

    case "$ext" in
      png|jpg|jpeg|heic)
        dest_dir="$IMAGE_DIR/$year/${prefix}${mmdd}"
        ;;
      mov|mp4|webm)
        dest_dir="$MOVIE_DIR/$year/${prefix}${mmdd}"
        ;;
      *)
        continue
        ;;
    esac

    mkdir -p "$dest_dir"

    dest="$dest_dir/image_${ts}.${ext}"

    # 同一秒衝突回避
    if [[ -e "$dest" ]]; then
      i=1
      while [[ -e "$dest_dir/image_${ts}_${i}.${ext}" ]]; do
        i=$((i+1))
      done
      dest="$dest_dir/image_${ts}_${i}.${ext}"
    fi

    mv "$file" "$dest"
  done

# アーカイブ処理
"$HOME/bin/fileops/archive-screenshots.sh"
