autoload -Uz vcs_info
precmd() { vcs_info }

setopt PROMPT_SUBST
PROMPT='%F{cyan}%n@texdeath%f %F{yellow}%~%f ${vcs_info_msg_0_}
$ '

zstyle ':vcs_info:git:*' formats '(%b)'
zstyle ':vcs_info:*' enable git
