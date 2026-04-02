#!/bin/bash
# Step 8: Automator ワークフロー

step "Automator ワークフロー"

AUTOMATOR_DST="$HOME/Library/Workflows/Applications/Folder Actions"
dry_mkdir "$AUTOMATOR_DST"

for wf in "$DOTFILES"/automator/folder-actions/*.workflow; do
  if [ -d "$wf" ]; then
    name=$(basename "$wf")
    dry_cp_r "$wf" "$AUTOMATOR_DST/$name"
    ok "$name"
  fi
done

if [ -z "$(ls -A "$DOTFILES/automator/folder-actions/" 2>/dev/null)" ]; then
  warn "ワークフローなし"
fi
