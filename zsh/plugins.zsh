# zinit
if [[ ! -f $HOME/.zinit/bin/zinit.zsh ]]; then
  mkdir -p "$HOME/.zinit"
  git clone https://github.com/zdharma-continuum/zinit.git "$HOME/.zinit/bin"
fi

source "$HOME/.zinit/bin/zinit.zsh"
unalias zi 2>/dev/null  # zoxide の zi と競合するため

# プラグイン
zinit light zsh-users/zsh-completions
zinit light Aloxaf/fzf-tab
zstyle ':completion:*' menu no
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'
zstyle ':fzf-tab:*' switch-group 'ctrl-h' 'ctrl-l'

zinit light zsh-users/zsh-autosuggestions
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'

# syntax highlighting — 必ず最後に
zinit light zsh-users/zsh-syntax-highlighting

# compinit はプラグイン読み込み後に実行
autoload -Uz compinit
compinit -u
