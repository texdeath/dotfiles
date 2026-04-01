# Public / Private リポジトリ統合設計

更新日: 2026-04-01

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
| エディタ共通設定 | Cursor 共通設定 | 社内運用向け Claude 設定 |
| 開発環境初期化 | 汎用 install (`brew`, language runtime 等) | private project 固有 setup / sync |
| workspace | なし | `~/workspace` 管理 |
| secrets 取得ロジック | 汎用 secret helper のみ | 実際の社内 secret 復元導線 |

## 4. 統合原則

1. **Public Base / Private Overlay**  
   ベースは `dotfiles`、社内差分は private overlay repo で上書きする。
2. **Contract First**  
   相互依存は「環境変数・読み込みフック・ファイルパス契約」で明示する。
3. **Path Hardcode 最小化**  
   固定パス依存を減らし、`DOTFILES_ROOT`, `PRIVATE_OVERLAY_ROOT`, `PROJECTS_ROOT` を優先する。
4. **Idempotent Install**  
   何度再実行しても同じ最終状態になることを保証する。

## 5. 設定レイヤー設計

### 5.1 zsh

- ベース: `dotfiles/zsh/*.zsh`
- private フック: `~/.zsh/private/*.zsh`（`zshrc` の最後で読み込む）
- ルール:
  - Public 側は private ファイル不在でも正常動作
  - Private 側は追記・上書きのみ（ベースを直接改変しない）

### 5.2 Git

- ベース: `dotfiles/git/gitconfig` → `~/.gitconfig`
- private include: `~/.gitconfig.local`
- ルール:
  - Public では共通設定のみ保持
  - Internal URL rewrite, 社内署名設定などは `.gitconfig.local` に隔離

### 5.3 実行パス契約

- 推奨環境変数:
  - `DOTFILES_ROOT=${DOTFILES_ROOT:-$HOME/ghq/github.com/<user-or-org>/dotfiles}`
  - `PRIVATE_OVERLAY_ROOT=${PRIVATE_OVERLAY_ROOT:-$HOME/ghq/github.com/<private-org>/<private-overlay-repo>}`
  - `PROJECTS_ROOT=${PROJECTS_ROOT:-$HOME/ghq/github.com/<private-org>/<project-group>}`

## 6. インストール責務分離

### Step 1: `dotfiles/install.sh`

- ベース環境のみを構築する。
- `~/.zsh/*`, `~/.gitconfig`, `~/.tool-versions`, 共通 bin, Homebrew, language runtime を担当。
- 社内リポジトリや社内 secret 前提の処理は行わない。

### Step 2: `private-overlay/install.sh`

- `~/.claude/*`, `~/bin/project`, `~/workspace` のリンクを担当。
- 社内プロジェクト依存の setup/sync を担当。
- secret 復元・証明書作成・hosts 更新などの社内処理を担当。

## 7. 移行計画（段階的）

### Phase 0: 設計固定（この文書）

- 境界・禁止事項・契約を確定する。

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

## 8. 運用ルール

- Public に入れてよい情報:
  - OSS ツール名、一般設定、汎用 shell 関数、公開可能メールアドレス
- Public に入れてはいけない情報:
  - 社内ドメイン詳細、社内プロジェクト固有 credential 名、secret の key 名・値、内部運用ログ
- PR チェック観点:
  - `dotfiles` 変更に internal keyword が混入していないか
  - private overlay 変更がベース責務を侵食していないか

## 9. 完了条件

- 新規マシンで以下が成立すること:
  1. `dotfiles/install.sh` 単体で公開可能な開発基盤が立ち上がる
  2. private overlay の install を重ねると社内環境が完成する
  3. 再実行しても差分が暴れない（idempotent）
