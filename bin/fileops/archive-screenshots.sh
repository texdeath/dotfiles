#!/bin/bash
set -euo pipefail

BASE_DIR="$HOME/Pictures/Screenshot"
TODAY=$(date +%m%d)
THRESHOLD=$(date -v-1m +%Y%m%d)

for category_dir in "$BASE_DIR/images" "$BASE_DIR/movies"; do
  [ -d "$category_dir" ] || continue

  for year_dir in "$category_dir"/[0-9][0-9][0-9][0-9]; do
    [ -d "$year_dir" ] || continue

    year="$(basename "$year_dir")"

    # 前日以前の !MMDD を MMDD にリネーム
    for prefixed_dir in "$year_dir"/\![0-9][0-9][0-9][0-9]; do
      [ -d "$prefixed_dir" ] || continue

      mmdd="$(basename "$prefixed_dir" | sed 's/^!//')"

      # 当日の !MMDD はそのまま残す
      [ "$mmdd" = "$TODAY" ] && continue

      # リネーム先が既にある場合は中身をマージ
      if [ -d "$year_dir/$mmdd" ]; then
        mv "$prefixed_dir"/* "$year_dir/$mmdd/" 2>/dev/null || true
        rmdir "$prefixed_dir" 2>/dev/null || true
      else
        mv "$prefixed_dir" "$year_dir/$mmdd"
      fi
    done

    # 1ヶ月以上前の MMDD を archives に移動
    for mmdd_dir in "$year_dir"/[0-9][0-9][0-9][0-9]; do
      [ -d "$mmdd_dir" ] || continue

      mmdd="$(basename "$mmdd_dir")"
      dir_date="${year}${mmdd}"

      if [ "$dir_date" -lt "$THRESHOLD" ] 2>/dev/null; then
        archive_dir="$year_dir/archives"
        mkdir -p "$archive_dir"
        mv "$mmdd_dir" "$archive_dir/$mmdd"
      fi
    done
  done
done
