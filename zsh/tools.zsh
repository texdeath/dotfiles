# anyenv (キャッシュで高速化)
export GOENV_GOPATH_PREFIX="$HOME/.go"
ANYENV_CACHE="$HOME/.zsh/.anyenv-cache.zsh"
if [[ ! -f "$ANYENV_CACHE" || "$HOME/.anyenv" -nt "$ANYENV_CACHE" ]]; then
  anyenv init - > "$ANYENV_CACHE"
fi
source "$ANYENV_CACHE"

# ghq
export GHQ_ROOT="$HOME/ghq"

# fzf
if command -v rg >/dev/null 2>&1; then
  export FZF_DEFAULT_COMMAND='rg --files --hidden --follow --glob "!.git" 2>/dev/null'
fi

if command -v bat >/dev/null 2>&1; then
  export FZF_DEFAULT_OPTS='--height=40% --border --reverse --preview "bat --style=numbers --color=always --line-range=:200 {}"'
else
  export FZF_DEFAULT_OPTS='--height=40% --border --reverse'
fi

# Google Cloud SDK (PATH のみ。completion は plugins 後に読み込む)
if [ -f "$HOME/.google-cloud-sdk/path.zsh.inc" ]; then . "$HOME/.google-cloud-sdk/path.zsh.inc"; fi
