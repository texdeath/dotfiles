# mise (Go / Python ランタイム管理)
if command -v mise >/dev/null 2>&1; then
  eval "$(mise activate zsh)"
fi

# Volta (Node.js 管理)
export VOLTA_HOME="$HOME/.volta"
export PATH="$VOLTA_HOME/bin:$PATH"

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

# direnv
if command -v direnv >/dev/null 2>&1; then
  eval "$(direnv hook zsh)"
fi

# zoxide
if command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init zsh)"
fi

# Google Cloud SDK
if [ -f "$HOME/.google-cloud-sdk/path.zsh.inc" ]; then . "$HOME/.google-cloud-sdk/path.zsh.inc"; fi
