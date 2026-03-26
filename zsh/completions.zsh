# fzf キーバインド（plugins.zsh の後に読み込む）
for f in \
  "$HOME/.fzf.zsh" \
  "/usr/share/fzf/key-bindings.zsh" \
  "/usr/local/opt/fzf/shell/key-bindings.zsh"
do
  [[ -f "$f" ]] && source "$f" && break
done

# Google Cloud SDK completion
if [ -f "$HOME/.google-cloud-sdk/completion.zsh.inc" ]; then . "$HOME/.google-cloud-sdk/completion.zsh.inc"; fi
