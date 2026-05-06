#!/bin/bash
# Step 2: シンボリックリンク

step "シンボリックリンク"

dry_mkdir "$HOME/.zsh" "$HOME/bin"

# zsh
dry_link "$DOTFILES/zsh/zshrc" "$HOME/.zshrc"
dry_link "$DOTFILES/zsh/zshenv" "$HOME/.zshenv"
for f in tools plugins completions aliases functions prompt; do
  dry_link "$DOTFILES/zsh/${f}.zsh" "$HOME/.zsh/${f}.zsh"
done
ok "zsh (zshrc, zshenv, 6 modules)"

# git
dry_link "$DOTFILES/git/gitconfig" "$HOME/.gitconfig"
dry_link "$DOTFILES/git/gitignore_global" "$HOME/.gitignore_global"
ok "git (gitconfig, gitignore_global)"

# bin
for d in fileops editor notion claude; do
  dry_link "$DOTFILES/bin/$d" "$HOME/bin/$d"
done
# 旧名 symlink (~/bin/ai-tmux) が dotfiles-owned (= $DOTFILES/bin/ai-tmux か
# rename 後の $DOTFILES/bin/orch-runtime を指す) の場合のみ削除する。
# user 自身が作った別ターゲットへの symlink は触らない。
if [ -L "$HOME/bin/ai-tmux" ]; then
  STALE_TARGET="$(readlink "$HOME/bin/ai-tmux" 2>/dev/null || true)"
  if [ "$STALE_TARGET" = "$DOTFILES/bin/ai-tmux" ] || [ "$STALE_TARGET" = "$DOTFILES/bin/orch-runtime" ]; then
    if [ "$DRY_RUN" = true ]; then
      ok "remove stale symlink ~/bin/ai-tmux -> $STALE_TARGET (dry-run)"
    else
      rm -f "$HOME/bin/ai-tmux"
    fi
  else
    ok "skip ~/bin/ai-tmux (target=$STALE_TARGET, not dotfiles-owned)"
  fi
fi
# orch-runtime は texdeath/orchestrate 側へ移管されたため、dotfiles-owned
# な古い symlink だけを掃除する。orchestrate など別ターゲットへの symlink
# は user 管理として触らない。
if [ -L "$HOME/bin/orch-runtime" ]; then
  STALE_TARGET="$(readlink "$HOME/bin/orch-runtime" 2>/dev/null || true)"
  if [ "$STALE_TARGET" = "$DOTFILES/bin/orch-runtime" ]; then
    if [ "$DRY_RUN" = true ]; then
      ok "remove stale symlink ~/bin/orch-runtime -> $STALE_TARGET (dry-run)"
    else
      rm -f "$HOME/bin/orch-runtime"
    fi
  else
    ok "skip ~/bin/orch-runtime (target=$STALE_TARGET, not dotfiles-owned)"
  fi
fi
ok "bin (fileops, editor, notion, claude)"

# secrets
dry_link "$DOTFILES/secrets/bw-secret.sh" "$HOME/bin/bw-secret.sh"
ok "bin/bw-secret.sh"

# mise (.tool-versions)
dry_link "$DOTFILES/.tool-versions" "$HOME/.tool-versions"
ok ".tool-versions"

# lazygit
LAZYGIT_DST="$HOME/.config/lazygit"
dry_mkdir "$LAZYGIT_DST"
dry_link "$DOTFILES/lazygit/config.yml" "$LAZYGIT_DST/config.yml"
ok "lazygit"

# tmux
dry_link "$DOTFILES/tmux/tmux.conf" "$HOME/.tmux.conf"
ok "tmux"

# git hooks
if [ "$DRY_RUN" = true ]; then
  ok "git hooks (.githooks/)"
else
  git -C "$DOTFILES" config core.hooksPath .githooks
  ok "git hooks (.githooks/)"
fi
