# ファイル操作
alias ls='eza --group-directories-first'
alias ll='eza -l --group-directories-first --git'
alias la='eza -la --group-directories-first --git'
alias tree='eza --tree'
alias ..='cd ..'
alias ...='cd ../..'

# Git
alias gst='git status'
alias ga='git add'
alias gaa='git add .'
alias gc='git commit'
alias gcmsg='git commit -m'
alias gco='git checkout'
alias gsw='git switch'
alias gl='git log --oneline --graph --decorate'
alias gp='git push'
alias gpl='git pull'

# プロジェクト（private overlay 導入時のみ有効）
[ -x "$HOME/bin/project/sync.sh" ] && alias psync='~/bin/project/sync.sh'
