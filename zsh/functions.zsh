# ghq + fzf リポジトリジャンプ
function ghq-fzf() {
  local selected_dir
  selected_dir=$(ghq list -p | fzf --prompt="ghq> ")
  if [[ -n "$selected_dir" ]]; then
    cd "$selected_dir"
  fi
}
alias gcd='ghq-fzf'

# clone してそのまま移動
function gget() {
  ghq get "$1" && cd "$(ghq list -p | grep "$1$")"
}

# ブランチ切り替え: gbr でローカル+リモートから選択
function gbr() {
  local branch
  branch=$(git branch -a --sort=-committerdate \
    | sed 's/^[* ]*//' \
    | sed 's|remotes/origin/||' \
    | sort -u \
    | fzf --prompt="branch> " --preview="git log --oneline -20 {}")
  [[ -n "$branch" ]] && git switch "$branch" 2>/dev/null || git switch -c "$branch" --track "origin/$branch"
}

# ログ閲覧: glf で fzf プレビュー付き
function glf() {
  git log --oneline --graph --decorate --color=always \
    | fzf --ansi --no-sort --prompt="log> " \
        --preview="echo {} | grep -o '[a-f0-9]\{7,\}' | head -1 | xargs git show --color=always" \
        --bind="enter:execute(echo {} | grep -o '[a-f0-9]\{7,\}' | head -1 | xargs git show --color=always | less -R)"
}

# stash 管理: gss で選択して apply/drop
function gss() {
  local stash
  stash=$(git stash list \
    | fzf --prompt="stash> " \
        --preview="echo {} | cut -d: -f1 | xargs git stash show -p --color=always" \
    | cut -d: -f1)
  [[ -z "$stash" ]] && return

  echo "選択: $stash"
  echo "  a) apply  d) drop  p) pop  q) cancel"
  read -k1 "action?"
  echo
  case "$action" in
    a) git stash apply "$stash" ;;
    d) git stash drop "$stash" ;;
    p) git stash pop "$stash" ;;
    *) echo "キャンセル" ;;
  esac
}
