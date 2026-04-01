# dotfiles

macOS 環境のセットアップを自動化する dotfiles リポジトリ。

## セットアップ

```bash
git clone https://github.com/texdeath/dotfiles.git
cd dotfiles
./install.sh
```

`install.sh` は以下を実行する:

1. zsh 設定ファイルのシンボリックリンクを作成
2. ~/bin スクリプトのシンボリックリンクを作成
3. Homebrew パッケージの一括インストール (`brew bundle`)
4. 言語ランタイムのインストール (Go, Python, Node.js, Rust)
5. Cursor 拡張機能・設定のインストール

## 構成

```
├── install.sh          # 全体セットアップスクリプト
├── Brewfile            # Homebrew パッケージ一覧
├── languages.sh        # 言語ランタイムのインストール
├── zsh/
│   ├── zshrc           # → ~/.zshrc
│   ├── zshenv          # → ~/.zshenv
│   ├── tools.zsh       # anyenv, fzf, gcloud 等
│   ├── plugins.zsh     # zinit + プラグイン
│   ├── completions.zsh # fzf キーバインド, gcloud completion
│   ├── aliases.zsh     # エイリアス
│   ├── functions.zsh   # ghq, git fzf 関数
│   └── prompt.zsh      # プロンプト設定
├── bin/
│   ├── fileops/        # → ~/bin/fileops (スクリーンショット・ダウンロード整理)
│   ├── editor/         # → ~/bin/editor (diff ビュー操作)
│   ├── notion/         # → ~/bin/notion (Markdown → Notion 変換)
│   └── claude/         # → ~/bin/claude (メトリクス)
└── cursor/
    ├── install.sh      # Cursor 単体セットアップ
    ├── extensions.txt  # 拡張機能一覧
    ├── settings.json   # ユーザー設定
    └── keybindings.json # キーバインド
```

## 設計ドキュメント

- [Public / Private リポジトリ統合設計](docs/public-private-integration-design.md)

Public / Private の責務分離と、段階的な統合方針は上記ドキュメントを参照。

## 更新方法

### Brewfile

```bash
brew bundle dump --file=Brewfile --force
```

### Cursor 拡張機能

```bash
cursor --list-extensions > cursor/extensions.txt
```

### 言語ランタイム

`languages.sh` 内のバージョンを更新して再実行する。

### zsh

シンボリックリンクなので、ファイルを編集すれば即反映される。
