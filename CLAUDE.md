# dotfiles — Claude Code ルール

## リポジトリの性質

- **Public リポジトリ**。社内キーワード、組織名、プロジェクト名、内部ドメインを一切含めない
- Private overlay と統合設計されている。詳細は `docs/public-private-integration-design.md`

## コミットルール

- Conventional Commits 形式: `<type>(<scope>): <subject>`
- Co-Authored-By は付けない

## リリースルール

- バージョン管理: `VERSION` ファイル（semver）
- リリースは GitHub Actions の Release ワークフロー（workflow_dispatch）で実行
- リリースタイトル: `v1.2.0 — 変更内容の要約`。ツール名やレビュー対応元の名前は含めない
- bump type の判断基準:
  - **patch**: バグ修正、ドキュメント更新、設定微調整
  - **minor**: 機能追加、ステップ追加、構造変更
  - **major**: 破壊的変更（private overlay 側の対応が必要な変更）

## Public 境界

- CI が `BOUNDARY_PATTERNS`（GitHub Secret）と絶対パスの混入を検出する
- `docs/` と `.github/` は CI チェック対象外
- README やコメントにも社内キーワードを書かない（説明文であっても）

## install.sh の構造

- `install.sh` はオーケストレーター。ステップの実装は `steps/*.sh` に分離
- 共通ヘルパーは `steps/lib.sh`
- `--dry-run` でソースファイルの存在チェックのみ実行（CI で使用）
- 新しいステップを追加する場合: `steps/` にファイル追加 + `install.sh` の `STEP_NAMES` 配列に追加

## secrets

- Bitwarden でマスターデータを管理
- GitHub Secrets への同期手順は `secrets/README.md` を参照
