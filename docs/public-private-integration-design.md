# Public / Private リポジトリ統合設計

更新日: 2026-04-02

## 1. 目的

- `dotfiles` を公開可能な共通基盤として維持する。
- private リポジトリを社内専用オーバーレイとして維持する。
- 2 リポジトリを「責務分離 + 契約」で統合し、重複と運用コストを下げる。

## 2. セキュリティ前提

- 本設計書にはクレデンシャル情報（キー、トークン、パスワード、証明書実体、セッション値）を記載しない。
- Public 側 (`dotfiles`) に Internal/Secret 情報を置かない。
- コマンド例はプレースホルダのみを使用する。
- 組織名・社内リポジトリ名・内部ドメインなど、識別情報は記載しない。

## 3. リポジトリ責務

| 領域 | `dotfiles` (public) | private overlay repo (private) |
| --- | --- | --- |
| OS / CLI 基盤 | Xcode CLI Tools, Homebrew, 共通 CLI | なし |
| シェル共通設定 | `~/.zshrc`, `~/.zshenv`, 共通 aliases/functions | 社内専用 zsh 拡張 |
| Git 共通設定 | pager, diff, global ignore, 公開可能 user 設定 | 社内専用 include 設定 |
| エディタ・ツール設定 | Cursor, Ghostty, Karabiner, Raycast, lazygit | 社内運用向け Claude rules/hooks/skills |
| 開発環境初期化 | 汎用 install (`brew`, language runtime 等) | private project 固有 setup / sync |
| workspace | なし | `~/workspace` 管理 |
| secrets 取得ロジック | 汎用 secret helper のみ | 実際の社内 secret 復元導線 |

## 4. 統合原則

1. **Public Base / Private Overlay**  
   ベースは `dotfiles`、社内差分は private overlay repo で上書きする。
2. **Contract First**  
   相互依存は「環境変数・読み込みフック・ファイルパス契約」で明示する。
3. **Path Hardcode 最小化**  
   固定パス依存を減らし、`DEV_ROOT`, `DOTFILES_ROOT`, `PRIVATE_OVERLAY_ROOT` を優先する。
4. **Idempotent Install**  
   何度再実行しても同じ最終状態になることを保証する。

## 5. 設定レイヤー設計

### 5.1 zsh

- ベース: `dotfiles/zsh/*.zsh`
- private フック: `~/.zsh/private/*.zsh`（`zshrc` の最後で glob 読み込み）
- Phase 1 では読み込み導線のみ追加。private 側のファイルは必要になった時点で作成する。
- ルール:
  - Public 側は private ファイル不在でも正常動作（glob が空なら何も起きない）
  - Private 側は追記・上書きのみ（ベースを直接改変しない）
- 想定される private 拡張の例:
  - 社内固有の環境変数（`PRIVATE_OVERLAY_ROOT` のデフォルト値、社内 registry URL）
  - 社内ツールの alias/function
  - `~/bin/project` 等の PATH 追加

### 5.2 Git

- ベース: `dotfiles/git/gitconfig` → `~/.gitconfig`
- private include: `~/.gitconfig.local`（`include.path` で読み込み）
- Phase 1 では include 導線のみ追加。private 側のファイルは必要になった時点で作成する。
- ルール:
  - Public では共通設定のみ保持
  - Internal URL rewrite, 社内署名設定などは `.gitconfig.local` に隔離

### 5.3 実行パス契約

- 推奨環境変数:
  - `DEV_ROOT=${DEV_ROOT:-$HOME/ghq}`
  - `DOTFILES_ROOT=${DOTFILES_ROOT:-$DEV_ROOT/github.com/<user-or-org>/dotfiles}`
  - `PRIVATE_OVERLAY_ROOT=${PRIVATE_OVERLAY_ROOT:-$DEV_ROOT/github.com/<private-org>/<private-overlay-repo>}`
- `DEV_ROOT` は全リポジトリの親ディレクトリ（ghq のルート）。組織やプロジェクトをまたいで使える。
- `DOTFILES_ROOT` / `PRIVATE_OVERLAY_ROOT` は `DEV_ROOT` から導出されるショートカット。

## 6. インストール責務分離

### Step 1: `dotfiles/install.sh`

- ベース環境のみを構築する。
- `~/.zsh/*`, `~/.gitconfig`, `~/.tool-versions`, 共通 bin, Homebrew, language runtime を担当。
- 社内リポジトリや社内 secret 前提の処理は行わない。

### Step 2: `private-overlay` セットアップ（Makefile がエントリポイント）

- `make install`: 以下を一括実行するオーケストレーター
  - `install.sh`: `~/.claude/*`, `~/bin/project`, `~/workspace` のシンボリックリンク配置
  - `make setup`: 社内プロジェクト依存の並列セットアップ（6リポジトリ）
  - `make setup-env`: secret 復元・証明書作成・Docker 設定
- 個別実行も可能（`make setup` のみ、`make setup-env` のみ）

## 7. 実装前チェックリスト（必須）

Phase 1（`zsh` / `git` フック追加）に入る前に、以下を確定する。

### P0-1: パス契約の統一

- private overlay の実行スクリプトで使うルート変数を統一する。
- 最低限の契約:
  - `DEV_ROOT`（全リポジトリの親、デフォルト: `$HOME/ghq`）
  - `DOTFILES_ROOT`（`$DEV_ROOT` から導出）
  - `PRIVATE_OVERLAY_ROOT`（`$DEV_ROOT` から導出）
- 既存の `AISCREAM` / `AISCREAM_ROOT` は `DEV_ROOT` ベースに統一する。
- 受け入れ条件:
  - 固定組織名・固定リポジトリ名・固定ユーザー名を前提にしない。
  - どのスクリプトも上記環境変数で実行先を上書きできる。

### P0-2: 絶対パス依存の排除

- private 設定（エディタ設定・ツール設定・hook設定）から `/Users/...` 形式の固定パスを排除する。
- `$HOME` と契約済み環境変数で解決する。
- 対象範囲と方針:
  - `claude/`（スキル・ルール・設定）: 優先対応。スクリプト内は `$HOME`、ドキュメント内は `~` を使用。JSON は `$HOME` 展開不可のため個別判断。
  - `workspace/logbook/`, `workspace/sandbox/`: `/Users/<username>` → `~` に一括置換。
  - Claude のメモリルールに「パスは `~` 形式で記述する」旨を追記する。
- 受け入れ条件:
  - 別ユーザー名の macOS 環境でも設定をそのまま再利用できる。
  - `rg '/Users/' --sort path` でヒット数が 0 になる。

### P0-3: リポジトリ一覧・ブランチ定義の一元化

- setup/sync/pull/status で参照する対象リポジトリ一覧を共通定義ファイル（例: `repos.conf`）に集約する。
- Makefile / setup.sh / sync.sh はこの定義ファイルを参照するように改修する。
- worktree スクリプト（`setup-*-worktree.sh`）は統合しないが、共通部分（環境変数フォールバック、worktree 作成ロジック）を共通関数に抽出し、各スクリプトはリポジトリ固有の差分のみ持つようにする。
- 受け入れ条件:
  - リポジトリの追加・削除・デフォルトブランチ変更時に編集箇所が 1 箇所で済む。
  - worktree スクリプト間の重複コードが共通関数に集約されている。

### P0-4: Public 側から Private 参照を分離

- `dotfiles` の alias / function / script から private 専用コマンドの直接参照を分離する。
- 必要な場合は「存在チェック付き」に落とす（存在すれば実行、なければ何もしない）。
- 対象:
  - `zsh/aliases.zsh`: `alias psync='~/bin/project/sync.sh'` → 存在チェック付きに変更
  - `bin/claude/claude-metric`: `~/.claude/hooks/metrics-analyze.sh` → 存在チェック付きに変更
  - `secrets/registry.tsv`: 社内プロジェクト固有エントリ（`REDACTED_PROJECT/*`）を private 側の `registry-private.tsv` に分離
- 受け入れ条件:
  - `dotfiles` 単体導入環境で、private コマンド未存在によるエラーが発生しない。
  - `secrets/registry.tsv` に社内固有のキーが含まれない。

### P0-5: secret 取得インターフェース契約化

- `dotfiles/secrets/bw-secret.sh` を `~/bin/` にシンボリックリンクし、PATH 経由で `bw-secret.sh` として呼べるようにする。
- private overlay 側は `bw-secret.sh <key>` で呼び出し、dotfiles の内部パスに依存しない。
- dotfiles の `install.sh` でリンク作成を追加する。
- 受け入れ条件:
  - private overlay のスクリプトから `$DOTFILES_ROOT/secrets/...` 形式の直接参照がなくなる。
  - `which bw-secret.sh` で解決できる。

### P1-1: private フックの運用ポリシー

- `~/.zsh/private/*.zsh` と `~/.gitconfig.local` の責務・命名規約・レビュー対象を決める。
- 受け入れ条件:
  - private 側の変更が「ベース改変なし」で完結する。

## 8. 移行計画（段階的）

### Phase 0: 設計固定（この文書）

- 境界・禁止事項・契約を確定する。
- 上記 P0 チェックリストを満たすための差分範囲を確定する。

### Phase 1: フック追加（dotfiles）

- `zshrc` に `~/.zsh/private/*.zsh` 読み込み導線を追加。
- `gitconfig` に `includeIf` または `include.path` で `.gitconfig.local` 導線を追加。

### Phase 2: private 側移設（overlay）

- 社内専用 shell/git 設定を private overlay 管理下に移動。
- private overlay の install スクリプトで private フック配置を実施。

### Phase 3: 依存契約統一

- private overlay の `bin/project/*` にある `dotfiles` 参照を環境変数優先に揃える。
- 固定パス依存の検出を `rg` で定期チェック可能にする。

### Phase 4: ドキュメント統合

- 両 README に「Public/Private 境界」と「導入順序」を同期記載する。

## 9. 運用ルール

- Public に入れてよい情報:
  - OSS ツール名、一般設定、汎用 shell 関数、公開可能メールアドレス
- Public に入れてはいけない情報:
  - 社内ドメイン詳細、社内プロジェクト固有 credential 名、secret の key 名・値、内部運用ログ
- PR チェック観点:
  - `dotfiles` 変更に internal keyword が混入していないか
  - private overlay 変更がベース責務を侵食していないか

## 10. 完了条件

- 新規マシンで以下が成立すること:
  1. `dotfiles/install.sh` 単体で公開可能な開発基盤が立ち上がる
  2. private overlay の install を重ねると社内環境が完成する
  3. 再実行しても差分が暴れない（idempotent）
