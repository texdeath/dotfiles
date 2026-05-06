# shellcheck shell=bash
# CLI dispatch for orch-runtime.

main() {
  local command="${1:-help}"
  if [[ $# -gt 0 ]]; then
    shift
  fi

  if [[ "$command" == "help" || "$command" == "-h" || "$command" == "--help" ]]; then
    usage
    return
  fi

  case "$command" in
    new)
      cmd_new "$@"
      ;;
    panes|list|ls)
      need_tmux
      cmd_panes "$@"
      ;;
    status|observe)
      need_tmux
      cmd_status "$@"
      ;;
    notify)
      cmd_notify "$@"
      ;;
    watch)
      cmd_watch "$@"
      ;;
    digest)
      need_tmux
      cmd_digest "$@"
      ;;
    focus|attach|jump)
      need_tmux
      cmd_focus "$@"
      ;;
    capture|cat)
      need_tmux
      cmd_capture "$@"
      ;;
    send)
      need_tmux
      cmd_send "$@"
      ;;
    handoff|sync)
      need_tmux
      cmd_handoff "context" "$@"
      ;;
    review|implement|design)
      need_tmux
      cmd_handoff "$command" "$@"
      ;;
    workspace|ws)
      cmd_workspace "$@"
      ;;
    lock|locks)
      cmd_lock "$@"
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}
