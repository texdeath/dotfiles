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
