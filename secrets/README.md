# Secrets 管理

## bw-secret.sh

Bitwarden CLI のラッパー。`~/bin/bw-secret.sh` にシンボリックリンクされ、PATH 経由で呼び出せる。

### 基本操作

```bash
# 値を取得（password / secure note を自動判別）
bw-secret.sh <key>

# パスワードを登録・更新
bw-secret.sh --set <key>

# ファイルを Secure Note として保存
bw-secret.sh --save <key> <file>

# Secure Note をファイルに復元
bw-secret.sh --restore <key> <dest>

# 登録簿の一覧
bw-secret.sh --list

# 全キーの存在確認
bw-secret.sh --check
```

Bitwarden 上のアイテム名は `dotfiles/<key>` の命名規則。

### Private registry

`REGISTRY_PRIVATE` 環境変数で追加の登録簿を指定すると、`--list` / `--check` が両方を参照する。

```bash
export REGISTRY_PRIVATE=/path/to/registry-private.tsv
bw-secret.sh --list    # public + private の両方を表示
```

## GitHub Secrets の管理

CI で使う Secret のマスターデータは Bitwarden で管理する。

### 更新手順

```bash
# 1. Bitwarden のデータを更新（必要な場合）
bw-secret.sh --save <key> <file>

# 2. GitHub Secrets に同期
bw-secret.sh <key> | gh secret set <SECRET_NAME> --repo texdeath/dotfiles --body -
```

`--body -` は stdin から値を読み取る指定。パイプで `bw-secret.sh` の出力を渡す。

### 登録済み Secret

| GitHub Secret | Bitwarden key | 用途 |
|--------------|---------------|------|
| `BOUNDARY_PATTERNS` | `boundary-patterns` | CI boundary-check のキーワードパターン |
