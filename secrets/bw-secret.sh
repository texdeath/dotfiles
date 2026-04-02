#!/usr/bin/env bash
set -euo pipefail

# Bitwarden CLI ヘルパー
# Usage:
#   bw-secret.sh <key>                    # パスワードを取得（stdout）
#   bw-secret.sh --set <key>              # パスワードを登録/更新
#   bw-secret.sh --save <key> <file>      # ファイルを Secure Note として保存
#   bw-secret.sh --restore <key> <file>   # Secure Note をファイルに復元
#   bw-secret.sh --list                   # 登録簿の一覧
#   bw-secret.sh --check                  # 全キーの存在確認
#
# Bitwarden のアイテム名は "dotfiles/<key>" の命名規則を使用する。

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REGISTRY="$SCRIPT_DIR/registry.tsv"
REGISTRY_PRIVATE="${REGISTRY_PRIVATE:-}"
BW_FOLDER="dotfiles"

err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$1" >&2; }
info() { printf '\033[1;34m[INFO]\033[0m  %s\n' "$1" >&2; }
ok()   { printf '\033[1;32m[OK]\033[0m    %s\n' "$1" >&2; }

# --- bw コマンドの存在確認 ---
ensure_bw() {
  if ! command -v bw >/dev/null 2>&1; then
    err "bitwarden-cli (bw) が見つかりません。brew install bitwarden-cli を実行してください。"
    exit 1
  fi
}

# --- セッション管理 ---
ensure_session() {
  if [ -n "${BW_SESSION:-}" ]; then
    return
  fi

  local status
  status=$(bw status 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "unauthenticated")

  case "$status" in
    unauthenticated)
      info "Bitwarden にログインしてください"
      BW_SESSION=$(bw login --raw)
      export BW_SESSION
      ;;
    locked)
      info "Bitwarden をアンロックしてください"
      BW_SESSION=$(bw unlock --raw)
      export BW_SESSION
      ;;
    unlocked)
      BW_SESSION=$(bw unlock --raw 2>/dev/null || echo "")
      export BW_SESSION
      ;;
  esac
}

# --- シークレット取得（type 自動判別） ---
get_secret() {
  local key="$1"
  local item_name="${BW_FOLDER}/${key}"

  ensure_bw
  ensure_session

  local item_json
  item_json=$(bw get item "$item_name" 2>/dev/null) || {
    err "\"${item_name}\" が見つかりません。Bitwarden に登録してください。"
    return 1
  }

  local item_type
  item_type=$(echo "$item_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['type'])")

  case "$item_type" in
    1) # login → パスワードを返す
      echo "$item_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['login']['password'])"
      ;;
    2) # secure note → notes を返す
      echo "$item_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('notes',''))"
      ;;
    *)
      err "未対応のアイテムタイプ: $item_type"
      return 1
      ;;
  esac
}

# --- パスワード登録/更新 ---
set_password() {
  local key="$1"
  local item_name="${BW_FOLDER}/${key}"

  ensure_bw
  ensure_session

  local password password_confirm
  read -rsp "パスワードを入力 (${item_name}): " password
  echo ""
  read -rsp "確認のためもう一度入力: " password_confirm
  echo ""

  if [ "$password" != "$password_confirm" ]; then
    err "パスワードが一致しません"
    return 1
  fi

  local item_id
  item_id=$(bw get item "$item_name" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")

  if [ -n "$item_id" ]; then
    bw get item "$item_name" | python3 -c "
import sys, json
item = json.load(sys.stdin)
item['login']['password'] = '''${password}'''
print(json.dumps(item))
" | bw encode | bw edit item "$item_id" >/dev/null
    ok "$item_name を更新しました"
  else
    bw get template item | python3 -c "
import sys, json
item = json.load(sys.stdin)
item['name'] = '${item_name}'
item['type'] = 1
item['login'] = {'username': None, 'password': '''${password}'''}
item['notes'] = 'Managed by dotfiles/secrets'
print(json.dumps(item))
" | bw encode | bw create item >/dev/null
    ok "$item_name を登録しました"
  fi

  bw sync >/dev/null 2>&1 || true
}

# --- ファイルを Secure Note として保存 ---
save_file() {
  local key="$1"
  local file="$2"
  local item_name="${BW_FOLDER}/${key}"

  if [ ! -f "$file" ]; then
    err "ファイルが見つかりません: $file"
    return 1
  fi

  ensure_bw
  ensure_session

  local content
  content=$(cat "$file")
  local filename
  filename=$(basename "$file")

  local item_id
  item_id=$(bw get item "$item_name" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")

  if [ -n "$item_id" ]; then
    bw get item "$item_name" | python3 -c "
import sys, json
item = json.load(sys.stdin)
item['notes'] = sys.stdin.read() if False else open('${file}').read()
item['fields'] = [{'name': 'filename', 'value': '${filename}', 'type': 0}]
print(json.dumps(item))
" | bw encode | bw edit item "$item_id" >/dev/null
    ok "$item_name を更新しました (${filename})"
  else
    bw get template item | python3 -c "
import sys, json
item = json.load(sys.stdin)
item['name'] = '${item_name}'
item['type'] = 2  # secure note
item['secureNote'] = {'type': 0}
item['notes'] = open('${file}').read()
item['fields'] = [{'name': 'filename', 'value': '${filename}', 'type': 0}]
print(json.dumps(item))
" | bw encode | bw create item >/dev/null
    ok "$item_name を保存しました (${filename})"
  fi

  bw sync >/dev/null 2>&1 || true
}

# --- Secure Note をファイルに復元 ---
restore_file() {
  local key="$1"
  local dest="$2"
  local item_name="${BW_FOLDER}/${key}"

  ensure_bw
  ensure_session

  local notes
  notes=$(bw get notes "$item_name" 2>/dev/null) || {
    err "\"${item_name}\" が見つかりません。"
    return 1
  }

  if [ -z "$notes" ]; then
    err "\"${item_name}\" の内容が空です。"
    return 1
  fi

  if [ -f "$dest" ]; then
    info "既存ファイルをバックアップ: ${dest}.bak"
    cp "$dest" "${dest}.bak"
  fi

  echo "$notes" > "$dest"
  ok "$item_name → $dest に復元しました"
}

# --- 登録簿ファイルの列挙 ---
_registry_files() {
  local files=()
  [ -f "$REGISTRY" ] && files+=("$REGISTRY")
  if [ -n "$REGISTRY_PRIVATE" ] && [ -f "$REGISTRY_PRIVATE" ]; then
    files+=("$REGISTRY_PRIVATE")
  fi
  if [ ${#files[@]} -eq 0 ]; then
    err "登録簿が見つかりません: $REGISTRY"
    exit 1
  fi
  echo "${files[@]}"
}

# --- 登録簿一覧 ---
list_registry() {
  local files
  read -ra files <<< "$(_registry_files)"

  printf '\033[1m%-30s %-10s %-40s\033[0m\n' "BITWARDEN ITEM" "TYPE" "USAGE"
  for f in "${files[@]}"; do
    while IFS=$'\t' read -r key type usage; do
      [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
      printf "%-30s %-10s %-40s\n" "${BW_FOLDER}/${key}" "$type" "$usage"
    done < "$f"
  done
}

# --- 全キーの存在確認 ---
check_registry() {
  local files
  read -ra files <<< "$(_registry_files)"

  ensure_bw
  ensure_session

  local errors=0
  for f in "${files[@]}"; do
    while IFS=$'\t' read -r key type usage; do
      [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
      local item_name="${BW_FOLDER}/${key}"
      if bw get item "$item_name" >/dev/null 2>&1; then
        ok "$item_name ($type)"
      else
        err "$item_name — 未登録"
        errors=$((errors + 1))
      fi
    done < "$f"
  done

  if [ "$errors" -eq 0 ]; then
    echo ""
    ok "全てのシークレットが Bitwarden に登録されています"
  else
    echo ""
    err "${errors} 件のシークレットが未登録です"
    return 1
  fi
}

# --- Main ---
case "${1:-}" in
  --list)
    list_registry
    ;;
  --check)
    check_registry
    ;;
  --set)
    [ -z "${2:-}" ] && { err "Usage: $(basename "$0") --set <key>"; exit 1; }
    set_password "$2"
    ;;
  --save)
    [ -z "${2:-}" ] || [ -z "${3:-}" ] && { err "Usage: $(basename "$0") --save <key> <file>"; exit 1; }
    save_file "$2" "$3"
    ;;
  --restore)
    [ -z "${2:-}" ] || [ -z "${3:-}" ] && { err "Usage: $(basename "$0") --restore <key> <dest>"; exit 1; }
    restore_file "$2" "$3"
    ;;
  --help|-h|"")
    echo "Usage: $(basename "$0") <command>"
    echo ""
    echo "Password:"
    echo "  <key>                    dotfiles/<key> の値を取得（password/secure note 自動判別）"
    echo "  --set <key>              dotfiles/<key> のパスワードを登録/更新"
    echo ""
    echo "File (Secure Note):"
    echo "  --save <key> <file>      ファイルを Secure Note として保存"
    echo "  --restore <key> <dest>   Secure Note をファイルに復元"
    echo ""
    echo "Registry:"
    echo "  --list                   登録簿の一覧を表示"
    echo "  --check                  全キーが Bitwarden に登録されているか確認"
    ;;
  *)
    get_secret "$1"
    ;;
esac
