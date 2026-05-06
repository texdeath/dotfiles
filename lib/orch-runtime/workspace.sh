# shellcheck shell=bash
# Workspace runtime supervisor commands.

workspace_resolve_loader() {
  # Resolve the orchestrate profile loader path, in priority order:
  #   1. $ORCHESTRATE_LOAD_PROFILE  (env override, absolute path)
  #   2. command -v load-profile.sh (PATH discovery)
  #   3. ~/.claude/orchestrate/bin/load-profile.sh (canonical install location)
  #   4. ~/bin/orchestrate/load-profile.sh (local user install)
  # Echoes the resolved path on success, returns 1 on failure.
  if [[ -n "${ORCHESTRATE_LOAD_PROFILE:-}" ]]; then
    if [[ -x "$ORCHESTRATE_LOAD_PROFILE" ]]; then
      printf '%s' "$ORCHESTRATE_LOAD_PROFILE"
      return 0
    fi
    return 1
  fi

  local resolved
  resolved="$(command -v load-profile.sh 2>/dev/null || true)"
  if [[ -n "$resolved" && -x "$resolved" ]]; then
    printf '%s' "$resolved"
    return 0
  fi

  local default_path="$HOME/.claude/orchestrate/bin/load-profile.sh"
  if [[ -x "$default_path" ]]; then
    printf '%s' "$default_path"
    return 0
  fi

  default_path="$HOME/bin/orchestrate/load-profile.sh"
  if [[ -x "$default_path" ]]; then
    printf '%s' "$default_path"
    return 0
  fi

  return 1
}

workspace_resolve_preflight_processor() {
  # Resolve the orchestrate preflight-processor.sh path. Returns 0 with the
  # path on stdout when found, 1 otherwise. The caller decides whether
  # absence is fatal or skipped (current behaviour: skip with warning so
  # non-processor environments are unaffected).
  if [[ -n "${ORCHESTRATE_PREFLIGHT_PROCESSOR:-}" ]]; then
    if [[ -x "$ORCHESTRATE_PREFLIGHT_PROCESSOR" ]]; then
      printf '%s' "$ORCHESTRATE_PREFLIGHT_PROCESSOR"
      return 0
    fi
    return 1
  fi

  local resolved
  resolved="$(command -v preflight-processor.sh 2>/dev/null || true)"
  if [[ -n "$resolved" && -x "$resolved" ]]; then
    printf '%s' "$resolved"
    return 0
  fi

  local default_path="$HOME/.claude/orchestrate/bin/preflight-processor.sh"
  if [[ -x "$default_path" ]]; then
    printf '%s' "$default_path"
    return 0
  fi

  default_path="$HOME/bin/orchestrate/preflight-processor.sh"
  if [[ -x "$default_path" ]]; then
    printf '%s' "$default_path"
    return 0
  fi

  return 1
}

workspace_resolve_profiles_dir() {
  # Resolve the profile yaml directory used when the loader's default
  # ~/.claude/orchestrate/profiles has not been installed yet.
  if [[ -n "${ORCHESTRATE_PROFILES_DIR:-}" && -d "$ORCHESTRATE_PROFILES_DIR" ]]; then
    printf '%s' "$ORCHESTRATE_PROFILES_DIR"
    return 0
  fi

  local default_path
  default_path="$HOME/.claude/orchestrate/profiles"
  if [[ -d "$default_path" ]]; then
    printf '%s' "$default_path"
    return 0
  fi

  return 1
}

workspace_profile_panes() {
  # Emit pane specifications for the given profile id, sourced from the
  # orchestrate profile loader's `runtime.panes` array. Each pane is emitted
  # as a single line of four fields separated by ASCII US (0x1f, "unit
  # separator"). The US char never appears in normal shell text, so it is
  # safe to use with `IFS=$'\x1f' read` without the whitespace-collapse
  # behaviour that consecutive tabs / spaces trigger.
  #   <name>\x1f<cwd-or-empty>\x1f<env-pairs-or-empty>\x1f<command>
  # env-pairs: empty, or one or more `KEY=VALUE` entries joined by ASCII GS
  # (0x1d). GS is used as a sub-separator so values may contain commas,
  # equals, or whitespace transparently; the Ruby block below rejects any
  # entry that embeds US / GS / newline so the parsing contract is safe.
  # Returns:
  #   0  pane specs printed (may be empty if runtime.panes is absent)
  #   1  loader missing or profile not resolved (caller should die)
  #   2  yaml parse error or invalid runtime.panes shape (caller should die)
  local profile="$1"
  local worktree="$2"
  local loader
  local profiles_dir
  loader="$(workspace_resolve_loader)" || return 1
  profiles_dir="$(workspace_resolve_profiles_dir 2>/dev/null || true)"

  local profile_json
  if [[ -n "$profiles_dir" && -z "${ORCHESTRATE_PROFILES_DIR:-}" ]]; then
    if ! profile_json="$(ORCHESTRATE_PROFILES_DIR="$profiles_dir" "$loader" "$profile" --feature-path "$worktree" 2>/dev/null)"; then
      return 1
    fi
  else
    if ! profile_json="$("$loader" "$profile" --feature-path "$worktree" 2>/dev/null)"; then
      return 1
    fi
  fi

  ruby -rjson - "$profile_json" "$worktree" <<'RUBY'
SEP = "\x1f"      # ASCII US, separates the four top-level pane fields per line.
ENV_SEP = "\x1d"  # ASCII GS, separates KEY=VALUE entries inside the env field.
                  # Using a control char that does not appear in normal shell
                  # text lets env values contain commas, equals, or whitespace
                  # transparently. We still validate that env keys / values do
                  # not embed SEP / ENV_SEP / newline.

data = JSON.parse(ARGV[0])
unless data["resolved"]
  warn "orch-runtime: profile loader could not resolve '#{data["query"]}'"
  exit 1
end
profile = data["profile"] || {}
runtime = profile["runtime"] || {}
panes = runtime["panes"]

# panes 不在は graceful fallback (caller が warning + exit 0)
exit 0 if panes.nil?

unless panes.is_a?(Array)
  warn "orch-runtime: runtime.panes must be an array (got #{panes.class.name})"
  exit 2
end

# Load `<worktree>/.orchestrate/env` (if present) into a Hash<String, String>.
# Lines may be `KEY=VALUE` or `# comment`. Empty / comment / malformed lines
# are skipped silently because this file is hand-edited (not authored by the
# loader) and we tolerate reasonable noise.
def load_generic_env(worktree_path)
  return {} unless worktree_path.is_a?(String) && !worktree_path.empty?
  env_file = File.join(worktree_path, ".orchestrate", "env")
  return {} unless File.file?(env_file)
  generic = {}
  File.foreach(env_file) do |raw_line|
    line = raw_line.strip
    next if line.empty? || line.start_with?("#")
    if line =~ /\A([A-Za-z_][A-Za-z0-9_]*)=(.*)\z/
      generic[$1] = $2
    end
  end
  generic
end

worktree_path = ARGV[1] || ""
generic_env = load_generic_env(worktree_path)

panes.each_with_index do |pane, idx|
  unless pane.is_a?(Hash)
    warn "orch-runtime: runtime.panes[#{idx}] must be a mapping"
    exit 2
  end
  name = pane["name"]
  command = pane["command"]
  unless name.is_a?(String) && !name.empty?
    warn "orch-runtime: runtime.panes[#{idx}].name must be a non-empty string"
    exit 2
  end
  unless command.is_a?(String) && !command.empty?
    warn "orch-runtime: runtime.panes[#{idx}].command must be a non-empty string"
    exit 2
  end
  cwd = pane["cwd"]
  cwd = "" if cwd.nil?
  unless cwd.is_a?(String)
    warn "orch-runtime: runtime.panes[#{idx}].cwd must be a string when present"
    exit 2
  end
  pane_env = pane["env"]
  pane_env_hash = {}
  unless pane_env.nil?
    unless pane_env.is_a?(Hash)
      warn "orch-runtime: runtime.panes[#{idx}].env must be a mapping when present"
      exit 2
    end
    pane_env.each do |k, v|
      # Enforce POSIX/C identifier shape so the eventual `export $key=...`
      # cannot be reinterpreted as additional shell syntax. Non-empty alone
      # would let `FOO-BAR` or names with metacharacters slip through.
      unless k.is_a?(String) && k.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
        warn "orch-runtime: runtime.panes[#{idx}].env keys must match [A-Za-z_][A-Za-z0-9_]*"
        exit 2
      end
      pane_env_hash[k] = v.to_s
    end
  end
  # Merge generic env (low priority) with pane.env (high priority). Entries
  # are joined with ENV_SEP (GS, 0x1d) so KEY / VALUE may contain comma,
  # equals, or whitespace transparently. SEP / ENV_SEP / newline must still
  # be rejected to preserve the parsing contract; we validate every entry
  # (both generic and pane-overridden) so the contract holds regardless of
  # source.
  merged_env = generic_env.merge(pane_env_hash)
  env_pairs = []
  merged_env.each do |k, v_str|
    [k, v_str].each do |s|
      if s.include?(SEP) || s.include?(ENV_SEP) || s.include?("\n")
        warn "orch-runtime: runtime.panes[#{idx}].env entry contains unsupported character (US 0x1f / GS 0x1d / newline)"
        exit 2
      end
    end
    env_pairs << "#{k}=#{v_str}"
  end
  env_str = env_pairs.join(ENV_SEP)
  # SEP / newline must not appear in name / cwd / command (they break the
  # parsing contract). env_str is already validated entry-by-entry above.
  [name, cwd, command].each do |field|
    if field.include?(SEP) || field.include?("\n")
      warn "orch-runtime: runtime.panes[#{idx}] field contains an unsupported character (newline or US 0x1f)"
      exit 2
    end
  end
  puts "#{name}#{SEP}#{cwd}#{SEP}#{env_str}#{SEP}#{command}"
end
RUBY
}

workspace_window_target() {
  local session="$1"
  local window_name="$2"
  printf '%s:%s' "$session" "$window_name"
}

workspace_session_for_window() {
  local window_target="$1"
  printf '%s' "${window_target%%:*}"
}

workspace_default_session() {
  local current
  current="$(tmux display-message -p '#{session_name}' 2>/dev/null || true)"
  if [[ -n "$current" ]]; then
    echo "$current"
    return
  fi
  current="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | head -n 1)"
  [[ -n "$current" ]] || die "no tmux session is running; create one with 'orch-runtime new' first"
  echo "$current"
}

workspace_resolve_pane_cwd() {
  # Resolve a pane.cwd value into an absolute path.
  # Args: <worktree-abs-path> <pane-cwd-or-empty>
  # Empty cwd -> worktree path; absolute path -> as-is; relative path ->
  # joined to worktree path. We do not require the resolved path to exist
  # at dispatch time (the pane command may create it), but we normalise
  # with realpath -m when available so tmux split-window can use the value.
  local worktree="$1"
  local cwd="$2"
  if [[ -z "$cwd" ]]; then
    printf '%s' "$worktree"
    return
  fi
  if [[ "$cwd" == /* ]]; then
    printf '%s' "$cwd"
    return
  fi
  printf '%s/%s' "$worktree" "$cwd"
}

workspace_compose_pane_command() {
  # Compose a shell command string that exports pane.env entries before
  # invoking pane.command. Best-effort failure handling is delegated to
  # tmux: a failed command exits the pane shell; remaining panes are
  # unaffected (tmux send-keys is fire-and-forget).
  # Args: <env-pairs-or-empty> <command>
  # env-pairs format: KEY=VAL entries joined by ASCII GS (0x1d).
  # Values may contain commas, equals, or whitespace transparently because
  # GS is reserved as a sub-separator and never appears in normal shell text;
  # workspace_profile_panes rejects entries that embed US (0x1f) / GS (0x1d)
  # / newline so the parsing contract is safe.
  local env_pairs="$1"
  local cmd="$2"
  if [[ -z "$env_pairs" ]]; then
    printf '%s' "$cmd"
    return
  fi
  local exports=""
  local pair
  IFS=$'\x1d' read -ra pairs <<<"$env_pairs"
  for pair in "${pairs[@]}"; do
    [[ -z "$pair" ]] && continue
    local key="${pair%%=*}"
    local val="${pair#*=}"
    # Quote value via printf %q for safe shell embedding.
    local quoted_val
    quoted_val="$(printf '%q' "$val")"
    # Use `export KEY=val; ...; cmd` form so env applies to the entire pane
    # command, including compound shells (`if ...; then ... fi`) and chained
    # commands (`cd app && pnpm dev`). The legacy inline `KEY=val cmd` form
    # is invalid before reserved-word commands and would only scope env to
    # the first simple command in a chain. Each pane runs in its own tmux
    # shell, so `export` does not leak across panes.
    exports+="export $key=$quoted_val; "
  done
  printf '%s%s' "$exports" "$cmd"
}

cmd_workspace_start() {
  local profile=""
  local worktree=""
  local session=""
  local window_name=""
  local dry_run="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        session="$2"
        shift 2
        ;;
      --name|--window)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        window_name="$2"
        shift 2
        ;;
      --dry-run)
        dry_run="true"
        shift
        ;;
      -h|--help)
        cat <<'EOF'
Usage:
  orch-runtime workspace start <profile-id> <worktree-path> [--session name] [--name window] [--dry-run]

Create a tmux window for a worktree and launch panes declared in the matched
profile's runtime.panes section. The orchestrate profile loader
(`load-profile.sh`) resolves <profile-id> via the standard discovery order
(see `orch-runtime --help`).

Behaviour:
  - panes are dispatched in declaration order; each pane runs in its own
    tmux split. Once started, panes run in parallel as usual.
  - per-pane cwd defaults to <worktree-path>; pane.cwd may be absolute or
    relative to the worktree.
  - per-pane env entries are exported inline and take precedence over any
    generic env defined in <worktree-path>/.orchestrate/env.
  - if the resolved profile has no `runtime.panes` section, this command
    emits a stderr warning and exits 0 without creating a window
    (graceful fallback for profiles that do not need a runtime supervisor).
  - per-pane command failures are best-effort; one pane exiting non-zero
    does not abort the dispatch loop for the remaining panes.

Options:
  --session name   target tmux session (default: current session)
  --name window    window name (default: worktree basename)
  --dry-run        print commands without executing tmux

Resource locks:
  If the resolved profile declares runtime.locks, or <worktree>/.orchestrate/env
  declares ORCH_RESOURCE_LOCKS, workspace start acquires those advisory locks
  before dispatching pane commands. Existing locks are reported as conflicts,
  including stale locks; stale locks are never removed automatically. Use
  `orch-runtime lock release-stale <type> <id>` explicitly.
  By default ORCH_RESOURCE_LOCKS is merged with profile locks. Set
  ORCH_RESOURCE_LOCKS_MODE=overlay to treat ORCH_RESOURCE_LOCKS as a
  subset-start overlay; an empty value suppresses all profile locks.
EOF
        return
        ;;
      -*)
        die "unknown option for workspace start: $1"
        ;;
      *)
        if [[ -z "$profile" ]]; then
          profile="$1"
        elif [[ -z "$worktree" ]]; then
          worktree="$1"
        else
          die "workspace start takes <profile-id> <worktree-path>; extra arg: $1"
        fi
        shift
        ;;
    esac
  done

  [[ -n "$profile" ]] || die "workspace start: <profile-id> is required"
  [[ -n "$worktree" ]] || die "workspace start: <worktree-path> is required"

  if [[ "$dry_run" != "true" ]]; then
    [[ -d "$worktree" ]] || die "worktree path does not exist: $worktree"
    worktree="$(cd "$worktree" && pwd)"
  fi

  if [[ -z "$window_name" ]]; then
    window_name="$(basename "$worktree")"
  fi

  local window_target
  if [[ "$dry_run" == "true" ]]; then
    if [[ -z "$session" ]]; then
      session="<current-session>"
    fi
    window_target="<window-id>"
  else
    need_tmux
    [[ -n "$session" ]] || session="$(workspace_default_session)"
  fi

  # Load runtime.panes via the orchestrate profile loader. The function
  # exits 0 with no output when the profile has no runtime.panes section
  # (graceful fallback). Non-zero exit indicates loader failure or invalid
  # pane spec; we propagate as a hard error.
  #
  # NOTE: declaring `local pane_specs` and assigning it on a single line
  # would mask the command substitution's exit status (local always exits 0).
  # We split the declaration from the assignment so $? reflects the real
  # workspace_profile_panes return code.
  local pane_specs rc
  pane_specs=""
  rc=0
  pane_specs="$(workspace_profile_panes "$profile" "$worktree")" || rc=$?
  if [[ "$rc" -eq 1 ]]; then
    die "workspace start: could not resolve profile '$profile' via orchestrate loader"
  fi
  if [[ "$rc" -eq 2 ]]; then
    die "workspace start: profile '$profile' has invalid runtime.panes (see stderr above)"
  fi
  # Any other non-zero rc (e.g. ruby missing → 127, unexpected parser failure)
  # must not fall through to the empty-pane_specs graceful-fallback branch:
  # that would silently turn a real load failure into a no-op exit 0.
  if [[ "$rc" -ne 0 ]]; then
    die "workspace start: failed to load runtime.panes for profile '$profile' (rc=$rc)"
  fi

  if [[ -z "$pane_specs" ]]; then
    printf 'orch-runtime: profile %s has no runtime.panes; skipping window creation (graceful fallback)\n' "$profile" >&2
    return 0
  fi

  local -a names=()
  local -a cwds=()
  local -a env_csvs=()
  local -a commands=()
  local name cwd env_csv cmd
  # Field separator is ASCII US (0x1f), set by workspace_profile_panes.
  # We avoid tab here because IFS-whitespace chars (tab/space/newline) cause
  # bash `read` to collapse consecutive separators, which would silently
  # drop empty cwd / env fields.
  while IFS=$'\x1f' read -r name cwd env_csv cmd; do
    [[ -z "$name" ]] && continue
    names+=("$name")
    cwds+=("$cwd")
    env_csvs+=("$env_csv")
    commands+=("$cmd")
  done <<<"$pane_specs"

  local pane_count="${#names[@]}"
  [[ "$pane_count" -ge 1 ]] || die "profile $profile produced no panes"

  # Resolve effective per-pane cwd and composed command (env-prefixed) up
  # front so dry-run output matches live execution exactly.
  local -a effective_cwds=()
  local -a effective_commands=()
  local i
  for (( i=0; i<pane_count; i++ )); do
    effective_cwds+=("$(workspace_resolve_pane_cwd "$worktree" "${cwds[$i]}")")
    effective_commands+=("$(workspace_compose_pane_command "${env_csvs[$i]}" "${commands[$i]}")")
  done

  local lock_specs lock_rc
  lock_specs=""
  lock_rc=0
  lock_specs="$(workspace_profile_locks "$profile" "$worktree")" || lock_rc=$?
  if [[ "$lock_rc" -eq 1 ]]; then
    die "workspace start: could not resolve profile '$profile' runtime.locks via orchestrate loader"
  fi
  if [[ "$lock_rc" -eq 2 ]]; then
    die "workspace start: profile '$profile' has invalid runtime.locks (see stderr above)"
  fi
  if [[ "$lock_rc" -ne 0 ]]; then
    die "workspace start: failed to load runtime.locks for profile '$profile' (rc=$lock_rc)"
  fi

  # Resolve tmux pane-base-index so the final select-pane target matches the
  # user's tmux config (default 0; 1 if `set -g pane-base-index 1`). Without
  # this, environments with pane-base-index 1 hit "can't find pane: 0".
  local pane_base_index
  pane_base_index="$(tmux show-options -gv pane-base-index 2>/dev/null || echo 0)"

  if [[ "$dry_run" == "true" ]]; then
    printf '# orch-runtime workspace start %s %s (dry-run)\n' "$profile" "$worktree"
    printf '# session=%s window=%s panes=%d\n' "$session" "$window_name" "$pane_count"
    lock_print_dry_run_plan "$lock_specs"
    printf 'window_target="$(tmux new-window -d -P -F %s -t %q -n %q -c %q)"\n' "'#{window_id}'" "$session" "$window_name" "${effective_cwds[0]}"
    printf 'tmux set-option -w -t %q %s %q\n' "$window_target" "@workspace_profile" "$profile"
    printf 'tmux set-option -w -t %q %s %q\n' "$window_target" "@workspace_worktree" "$worktree"
    if [[ -n "$lock_specs" ]]; then
      printf 'tmux set-option -w -t %q %s %q\n' "$window_target" "@workspace_locks" "$(lock_specs_inline "$lock_specs")"
    fi
    case "$profile" in
      *-processor)
        printf '# preflight-processor.sh %q (dry-run; would hard-fail if required env is missing)\n' "$worktree"
        ;;
    esac
    printf 'tmux send-keys -t %q %q Enter\n' "$window_target" "# pane 0: ${names[0]} (cwd=${effective_cwds[0]})"
    printf 'tmux send-keys -t %q %q Enter\n' "$window_target" "${effective_commands[0]}"
    for (( i=1; i<pane_count; i++ )); do
      printf 'tmux split-window -t %q -c %q\n' "$window_target" "${effective_cwds[$i]}"
      printf 'tmux send-keys -t %q %q Enter\n' "$window_target" "# pane $i: ${names[$i]} (cwd=${effective_cwds[$i]})"
      printf 'tmux send-keys -t %q %q Enter\n' "$window_target" "${effective_commands[$i]}"
    done
    printf 'tmux select-layout -t %q tiled\n' "$window_target"
    printf 'tmux select-pane -t %q.%s\n' "$window_target" "$pane_base_index"
    return
  fi

  window_target="$(tmux new-window -d -P -F '#{window_id}' -t "$session" -n "$window_name" -c "${effective_cwds[0]}")"
  if [[ -n "$lock_specs" ]]; then
    if ! workspace_acquire_locks_from_specs "$lock_specs" "$profile" "$worktree" "$window_name" "$window_target"; then
      tmux kill-window -t "$window_target" 2>/dev/null || true
      return 1
    fi
    tmux set-option -w -t "$window_target" '@workspace_locks' "$(lock_specs_inline "$lock_specs")"
  fi
  tmux set-option -w -t "$window_target" '@workspace_profile' "$profile"
  tmux set-option -w -t "$window_target" '@workspace_worktree' "$worktree"

  # Processor profiles must pass preflight before any pane runs `devbox services
  # up`. We resolve preflight-processor.sh via the orchestrate helper search
  # path (env override → PATH → ~/.claude/orchestrate/bin → ~/bin/orchestrate).
  # On failure we release the locks acquired above and kill the empty window so
  # the operator can retry cleanly. When the script is missing entirely (e.g.
  # mismatched orchestrate install), we warn and skip rather than die so
  # non-processor environments are unaffected.
  case "$profile" in
    *-processor)
      local preflight_bin
      preflight_bin="$(workspace_resolve_preflight_processor 2>/dev/null || true)"
      if [[ -n "$preflight_bin" ]]; then
        if ! "$preflight_bin" "$worktree"; then
          if [[ -n "$lock_specs" ]]; then
            workspace_release_locks_for_worktree "$worktree" >&2 || true
          fi
          tmux kill-window -t "$window_target" 2>/dev/null || true
          die "workspace start: preflight-processor.sh failed for profile '$profile' (see stderr above)"
        fi
      else
        printf 'orch-runtime: preflight-processor.sh not found; skipping preflight check for %s\n' "$profile" >&2
      fi
      ;;
  esac

  tmux send-keys -t "$window_target" "# pane 0: ${names[0]}" Enter
  tmux send-keys -t "$window_target" "${effective_commands[0]}" Enter
  for (( i=1; i<pane_count; i++ )); do
    tmux split-window -t "$window_target" -c "${effective_cwds[$i]}"
    tmux send-keys -t "$window_target" "# pane $i: ${names[$i]}" Enter
    tmux send-keys -t "$window_target" "${effective_commands[$i]}" Enter
  done
  tmux select-layout -t "$window_target" tiled
  tmux select-pane -t "${window_target}.${pane_base_index}"

  metrics_emit_event "$worktree" "$window_name" "workspace_start" \
    "profile=$profile" \
    "session=$session" \
    "window=$window_target" \
    "pane_count=$pane_count"

  printf 'workspace started: %s (%s) at %s\n' "$window_name" "$profile" "$worktree"
}

workspace_window_profile_from_meta() {
  local window="$1"
  local profile
  profile="$(tmux show-option -wv -t "$window" '@workspace_profile' 2>/dev/null)"
  if [[ -n "$profile" ]]; then
    printf '%s' "$profile"
  else
    printf '%s' "-"
  fi
}

cmd_workspace_status() {
  local lines="$DEFAULT_LINES"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--lines)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        lines="$2"
        shift 2
        ;;
      -h|--help)
        cat <<'EOF'
Usage:
  orch-runtime workspace status [-n lines]

List tmux windows in the current/all sessions and inspect each pane.
EOF
        return
        ;;
      *)
        die "unknown option for workspace status: $1"
        ;;
    esac
  done

  is_positive_int "$lines" || die "line count must be a positive integer"
  need_tmux

  printf '%-20s %-9s %-5s %-12s %-18s %-32s %-15s %-72s %s\n' "WORKSPACE" "PROFILE" "PANES" "SESSION" "LOCKS" "DEVBOX_SERVICES" "CURRENT_CMD" "PREVIEW_URLS" "PATH"
  local window_target name session_name profile pane_total current_cmd first_path locks_summary services_summary preview_summary
  while IFS=$'\t' read -r window_target name session_name; do
    profile="$(workspace_window_profile_from_meta "$window_target")"
    [[ "$profile" == "-" ]] && continue
    pane_total="$(tmux list-panes -t "$window_target" -F '.' 2>/dev/null | wc -l | tr -d ' ')"
    current_cmd="$(tmux list-panes -t "$window_target" -F '#{pane_current_command}' 2>/dev/null | grep -v '^$' | head -n 1)"
    current_cmd="${current_cmd:--}"
    first_path="$(tmux list-panes -t "$window_target" -F '#{pane_current_path}' 2>/dev/null | head -n 1)"
    locks_summary="$(lock_summary_for_worktree "$first_path")"
    services_summary="$(workspace_devbox_services_summary "$first_path" 32)"
    preview_summary="$(workspace_preview_summary "$first_path" 72)"
    printf '%-20s %-9s %-5s %-12s %-18s %-32s %-15s %-72s %s\n' "$name" "$profile" "$pane_total" "$session_name" "$locks_summary" "$services_summary" "$current_cmd" "$preview_summary" "$first_path"
  done < <(tmux list-windows -a -F '#{session_name}:#{window_index}	#{window_name}	#{session_name}' 2>/dev/null)
}

workspace_resolve_window() {
  local needle="$1"
  local -a matches=()
  local window_target name session_name
  while IFS=$'\t' read -r window_target name session_name; do
    if [[ "$name" == "$needle" || "$window_target" == "$needle" ]]; then
      matches+=("$window_target")
    fi
  done < <(tmux list-windows -a -F '#{session_name}:#{window_index}	#{window_name}	#{session_name}' 2>/dev/null)
  case "${#matches[@]}" in
    0) die "workspace not found: $needle (run 'orch-runtime workspace status' to list)" ;;
    1) printf '%s' "${matches[0]}" ;;
    *) die "workspace name is ambiguous: $needle (use session:index): ${matches[*]}" ;;
  esac
}

cmd_workspace_report() {
  local needle=""
  local lines=80

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--lines)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        lines="$2"
        shift 2
        ;;
      -h|--help)
        cat <<'EOF'
Usage:
  orch-runtime workspace report <workspace> [-n lines]

Emit a Markdown report for the given workspace (window name or session:index)
that summarizes context and recent pane output. Default lines per pane: 80.
EOF
        return
        ;;
      -*)
        die "unknown option for workspace report: $1"
        ;;
      *)
        [[ -z "$needle" ]] || die "workspace report takes a single workspace argument"
        needle="$1"
        shift
        ;;
    esac
  done

  [[ -n "$needle" ]] || die "workspace report: workspace name is required"
  is_positive_int "$lines" || die "line count must be a positive integer"
  need_tmux

  local window_target name session_name profile pane_total first_path timestamp metrics_worktree
  local branch
  window_target="$(workspace_resolve_window "$needle")"
  name="$(tmux display-message -p -t "$window_target" '#{window_name}')"
  session_name="$(tmux display-message -p -t "$window_target" '#{session_name}')"
  profile="$(workspace_window_profile_from_meta "$window_target")"
  pane_total="$(tmux list-panes -t "$window_target" -F '.' 2>/dev/null | wc -l | tr -d ' ')"
  first_path="$(tmux list-panes -t "$window_target" -F '#{pane_current_path}' 2>/dev/null | head -n 1)"
  metrics_worktree="$(workspace_window_canonical_worktree "$window_target" 2>/dev/null || true)"
  metrics_worktree="${metrics_worktree:-$first_path}"
  branch="$(workspace_git_branch "$first_path")"
  timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"

  metrics_emit_event "$metrics_worktree" "$name" "workspace_report" \
    "profile=$profile" \
    "session=$session_name" \
    "window=$window_target" \
    "pane_count=$pane_total" \
    "lines=$lines"

  cat <<EOF
# Runtime Report: $name

## Summary

- workspace: $name
- profile: $profile
- session: $session_name
- window: $window_target
- pane_count: $pane_total
- worktree: $first_path
- branch: $branch
- lines_per_pane: $lines
- generated_at: $timestamp

## Agent Handoff

- Treat this report as the runtime snapshot for implementation or review.
- Start with panes in \`error\` or \`asking\` state, then inspect related URLs and logs.
- After a fix, run this command again and compare the Summary, Pane Summary, and Recent Error Signals sections.

EOF

  workspace_report_preview_urls "$first_path"
  workspace_report_runtime_links "$first_path"
  workspace_report_runtime_env "$first_path"
  workspace_report_resource_locks "$first_path"
  workspace_report_docker_compose "$first_path"
  workspace_report_devbox_services "$first_path"
  workspace_report_terraform_plan "$first_path"
  workspace_report_processor_section "$first_path"
  workspace_report_pane_summary "$window_target" "$lines"
  workspace_report_error_signals "$window_target" "$lines"
  workspace_report_pane_details "$window_target" "$lines"
}

cmd_workspace_open() {
  local needle=""
  local print_only="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --print)
        print_only="true"
        shift
        ;;
      -h|--help)
        cat <<'EOF'
Usage:
  orch-runtime workspace open <workspace> [--print]

Open the primary localhost preview URL recorded in <worktree>/.orchestrate/env.
The primary URL is selected from ORCH_REPO when available: frontend ->
FRONTEND_PREVIEW_URL, backend -> BACKEND_PREVIEW_URL, agent ->
AGENT_PREVIEW_URL. Without ORCH_REPO, the first http(s) preview URL is used.

Options:
  --print   print the URL instead of opening it
EOF
        return
        ;;
      -*)
        die "unknown option for workspace open: $1"
        ;;
      *)
        [[ -z "$needle" ]] || die "workspace open takes a single workspace argument"
        needle="$1"
        shift
        ;;
    esac
  done

  [[ -n "$needle" ]] || die "workspace open: workspace name is required"
  need_tmux

  local window_target first_path url
  window_target="$(workspace_resolve_window "$needle")"
  first_path="$(tmux list-panes -t "$window_target" -F '#{pane_current_path}' 2>/dev/null | head -n 1)"
  url="$(workspace_preview_primary_url "$first_path" 2>/dev/null || true)"
  [[ -n "$url" ]] || die "workspace open: no preview URL found in $first_path/.orchestrate/env"

  if [[ "$print_only" == "true" ]]; then
    printf '%s\n' "$url"
    return
  fi

  if command -v open >/dev/null 2>&1; then
    open "$url"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url"
  else
    die "workspace open: neither open nor xdg-open is available; URL: $url"
  fi
}

workspace_window_canonical_worktree() {
  # Return the worktree path stored at workspace start time
  # (`@workspace_worktree` window option). Empty if not set or tmux unavailable.
  local window_target="$1"
  command -v tmux >/dev/null 2>&1 || return 0
  tmux show-option -wv -t "$window_target" '@workspace_worktree' 2>/dev/null || true
}

workspace_compose_project_from_env() {
  # Read ORCH_PROJECT from <worktree>/.orchestrate/env (populated by
  # bin/project/worktree/override.sh `--prepare`). Empty if absent.
  local worktree="$1"
  local env_file="$worktree/.orchestrate/env"
  [[ -f "$env_file" ]] || return 0
  awk -F= '/^ORCH_PROJECT=/ {sub(/^ORCH_PROJECT=/,""); print; exit}' "$env_file" 2>/dev/null || true
}

workspace_devbox_running_service_names() {
  # Print running service names (one per line) for the given worktree.
  # `devbox services ls` prints `<name>  <status>` lines; running services are
  # those with a non-empty status that does not start with "Stopped"/"Exited".
  local worktree="$1"
  [[ -d "$worktree" ]] || return 0
  command -v devbox >/dev/null 2>&1 || return 0

  (cd "$worktree" && devbox services ls 2>/dev/null) | awk '
    NR == 1 && /[Nn]ame.*[Ss]tatus/ { next }
    NF == 0 { next }
    {
      name=$1
      status=""
      for (i=2; i<=NF; i++) { status=(status?status" ":"") $i }
      if (status == "" ) next
      if (tolower(status) ~ /^(stopped|exited|completed|disabled)/) next
      print name
    }
  '
}

workspace_stop_devbox_services() {
  # Stop running process-compose services for the worktree, targeting only the
  # running subset (subset-start contract). Unstarted services are not touched.
  local worktree="$1"
  [[ -d "$worktree" ]] || return 0
  command -v devbox >/dev/null 2>&1 || return 0

  local -a running=()
  while IFS= read -r name; do
    [[ -n "$name" ]] && running+=("$name")
  done < <(workspace_devbox_running_service_names "$worktree")

  if [[ "${#running[@]}" -eq 0 ]]; then
    return 0
  fi

  if ! (cd "$worktree" && devbox services stop "${running[@]}" 2>&1); then
    printf 'orch-runtime: devbox services stop %s returned non-zero (some services may already be stopped)\n' "${running[*]}" >&2
  fi
}

workspace_stop_docker_compose() {
  # Stop the per-worktree docker compose project resolved from
  # <worktree>/.orchestrate/env (`ORCH_PROJECT`, generated by override.sh).
  # Absence of the env file or ORCH_PROJECT means there is nothing
  # worktree-specific to stop.
  local worktree="$1"
  command -v docker >/dev/null 2>&1 || return 0

  local project
  project="$(workspace_compose_project_from_env "$worktree")"
  [[ -n "$project" ]] || return 0

  if ! docker compose -p "$project" stop 2>&1; then
    printf 'orch-runtime: docker compose -p %s stop returned non-zero\n' "$project" >&2
  fi
}

workspace_docker_residuals_for_project() {
  # Print docker resources (containers / networks / volumes) tagged with the
  # given compose project, one per line: "<kind>: <name>". Empty when nothing
  # remains or docker is unavailable.
  local project="$1"
  [[ -n "$project" ]] || return 0
  command -v docker >/dev/null 2>&1 || return 0
  local id
  while IFS= read -r id; do
    [[ -n "$id" ]] && printf 'container: %s\n' "$id"
  done < <(docker compose -p "$project" ps -q 2>/dev/null || true)
  while IFS= read -r id; do
    [[ -n "$id" ]] && printf 'network: %s\n' "$id"
  done < <(docker network ls --filter "label=com.docker.compose.project=$project" --format '{{.Name}}' 2>/dev/null || true)
  while IFS= read -r id; do
    [[ -n "$id" ]] && printf 'volume: %s\n' "$id"
  done < <(docker volume ls --filter "label=com.docker.compose.project=$project" --format '{{.Name}}' 2>/dev/null || true)
}

workspace_release_locks_for_worktree() {
  # Release active locks owned by the worktree. Stale locks are intentionally
  # left in place; callers must release them explicitly via release-stale.
  local worktree="$1"
  local released=0 path owner status resource
  while IFS= read -r path; do
    owner="$(lock_read_field "$path" worktree 2>/dev/null || true)"
    [[ "$owner" == "$worktree" ]] || continue
    status="$(lock_status "$path")"
    [[ "$status" == "active" ]] || continue
    resource="$(lock_resource_name "$path")"
    if lock_release_path "$path"; then
      printf '  released: %s\n' "$resource"
      released=$((released + 1))
    fi
  done < <(lock_each_path)
  if [[ "$released" -eq 0 ]]; then
    printf '  no active locks for worktree: %s\n' "$worktree"
  fi
}

workspace_archive_logs() {
  # Move *.log files under <worktree>/.orchestrate/logs/ to a timestamped
  # archive subdirectory. The archive/ subtree is excluded so repeated archive
  # runs do not nest. The destination directory is created with `mkdir`
  # (atomic) inside a retry loop so two concurrent runs in the same second
  # don't share a directory.
  local worktree="$1"
  local logs_dir="$worktree/.orchestrate/logs"
  [[ -d "$logs_dir" ]] || return 0

  local has_logs=0 log
  shopt -s nullglob
  for log in "$logs_dir"/*.log; do
    [[ -f "$log" ]] || continue
    has_logs=1
    break
  done
  if [[ "$has_logs" -eq 0 ]]; then
    shopt -u nullglob
    return 0
  fi

  mkdir -p "$logs_dir/archive"
  local timestamp archive_dir suffix=0 moved=0
  timestamp="$(date '+%Y%m%dT%H%M%S')"
  archive_dir="$logs_dir/archive/$timestamp"
  # Atomic mkdir loop so two parallel cleans in the same second don't share
  # a directory and overwrite each other's logs.
  while ! mkdir "$archive_dir" 2>/dev/null; do
    suffix=$((suffix + 1))
    archive_dir="$logs_dir/archive/${timestamp}-${suffix}"
    if [[ "$suffix" -gt 1000 ]]; then
      printf 'orch-runtime: archive suffix exhausted under %s\n' "$logs_dir/archive" >&2
      shopt -u nullglob
      return 1
    fi
  done

  for log in "$logs_dir"/*.log; do
    [[ -f "$log" ]] || continue
    # `mv -n` refuses to overwrite if the destination already exists, so
    # concurrent runs that race on a file leave it for the slower run to
    # archive on a subsequent invocation rather than silently dropping data.
    if mv -n "$log" "$archive_dir/" 2>/dev/null; then
      moved=$((moved + 1))
    fi
  done
  shopt -u nullglob

  if [[ "$moved" -gt 0 ]]; then
    printf '  archived %d log(s) to %s\n' "$moved" "$archive_dir"
  fi
}

workspace_clean_residuals_report() {
  # Emit residual resources so the operator can decide whether they need
  # follow-up. Sections covered:
  #   - locks owned by the worktree (active or stale)
  #   - log files left outside the archive/ subtree
  #   - docker compose containers / networks / volumes for the worktree's
  #     ORCH_PROJECT (generated by override.sh)
  #   - process-compose services still running under devbox
  local worktree="$1"
  if [[ -d "$worktree" ]]; then
    worktree="$(cd "$worktree" && pwd)"
  fi
  printf '\n# residual scan: %s\n' "$worktree"

  local lock_count=0 path owner status resource
  while IFS= read -r path; do
    owner="$(lock_read_field "$path" worktree 2>/dev/null || true)"
    [[ "$owner" == "$worktree" ]] || continue
    status="$(lock_status "$path")"
    resource="$(lock_resource_name "$path")"
    printf '  lock: %s (%s)\n' "$resource" "$status"
    lock_count=$((lock_count + 1))
  done < <(lock_each_path)
  if [[ "$lock_count" -eq 0 ]]; then
    printf '  locks: none\n'
  fi

  local log_count=0 log
  shopt -s nullglob
  for log in "$worktree/.orchestrate/logs"/*.log; do
    [[ -f "$log" ]] || continue
    printf '  log: %s\n' "$log"
    log_count=$((log_count + 1))
  done
  shopt -u nullglob
  if [[ "$log_count" -eq 0 ]]; then
    printf '  logs (outside archive/): none\n'
  fi

  local project docker_count=0 line
  project="$(workspace_compose_project_from_env "$worktree")"
  if [[ -n "$project" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      printf '  %s\n' "$line"
      docker_count=$((docker_count + 1))
    done < <(workspace_docker_residuals_for_project "$project")
    if [[ "$docker_count" -eq 0 ]]; then
      printf '  docker (project=%s): none\n' "$project"
    fi
  else
    printf '  docker: skipped (no ORCH_PROJECT in .orchestrate/env)\n'
  fi

  local svc_count=0 svc
  while IFS= read -r svc; do
    [[ -n "$svc" ]] || continue
    printf '  devbox service: %s (running)\n' "$svc"
    svc_count=$((svc_count + 1))
  done < <(workspace_devbox_running_service_names "$worktree")
  if [[ "$svc_count" -eq 0 ]]; then
    printf '  devbox services: none running\n'
  fi
}

workspace_resolve_worktree_for_stop() {
  # Resolve the canonical worktree path for stop / clean.
  # Args:
  #   $1 window_target  tmux window id
  #   $2 force          "true" to allow drift between canonical and pane path
  # Returns 0 with the resolved path on stdout, or 1 on refusal.
  #
  # Resolution order:
  #   1. `@workspace_worktree` window option (set by workspace start). When
  #      present this is authoritative.
  #   2. Fallback to the first pane's current path (legacy / external windows).
  # When (1) is present we cross-check against the first pane's current path.
  # If they disagree the function refuses unless `--force` was given, because
  # that means panes have cd'd elsewhere and stop would target the wrong
  # worktree.
  local window_target="$1"
  local force="$2"

  local canonical pane_path
  canonical="$(workspace_window_canonical_worktree "$window_target")"
  pane_path="$(tmux list-panes -t "$window_target" -F '#{pane_current_path}' 2>/dev/null | head -n 1)"

  if [[ -n "$canonical" ]]; then
    if [[ -n "$pane_path" && "$pane_path" != "$canonical" && "$force" != "true" ]]; then
      printf 'orch-runtime: workspace worktree drift detected\n  canonical: %s\n  pane[0]:   %s\nuse --force to override.\n' \
        "$canonical" "$pane_path" >&2
      return 1
    fi
    printf '%s' "$canonical"
    return 0
  fi

  if [[ -z "$pane_path" ]]; then
    printf 'orch-runtime: cannot resolve worktree (no @workspace_worktree, no pane path)\n' >&2
    return 1
  fi
  printf '%s' "$pane_path"
}

cmd_workspace_stop() {
  local needle=""
  local archive_logs="false"
  local keep_window="false"
  local force="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --archive-logs)
        archive_logs="true"
        shift
        ;;
      --keep-window)
        keep_window="true"
        shift
        ;;
      --force)
        force="true"
        shift
        ;;
      -h|--help)
        cat <<'EOF'
Usage:
  orch-runtime workspace stop <workspace> [--archive-logs] [--keep-window] [--force]

Stop runtime processes attached to <workspace> (window name or session:index)
and release active resource locks held by its worktree.

Worktree resolution:
  - `@workspace_worktree` (set by workspace start) is authoritative. When
    panes have cd'd elsewhere stop refuses unless --force is given.
  - When the option is missing (legacy windows / externally-created tmux
    windows), pane[0] current path is used as a fallback.

Steps:
  - stop running process-compose services via `devbox services stop <name>...`.
    Only services reported as running by `devbox services ls` are targeted
    (subset-start contract).
  - stop the per-worktree docker compose project when ORCH_PROJECT is present
    in <worktree>/.orchestrate/env (generated by override.sh).
  - release **active** resource locks owned by the worktree. Stale locks are
    NOT released here; use `orch-runtime lock release-stale <type> <id>`.
  - kill the tmux window unless --keep-window is given.

Logs in <worktree>/.orchestrate/logs/ are kept by default. Pass --archive-logs
to move them under .orchestrate/logs/archive/<timestamp>/.
EOF
        return
        ;;
      -*)
        die "unknown option for workspace stop: $1"
        ;;
      *)
        [[ -z "$needle" ]] || die "workspace stop takes a single workspace argument"
        needle="$1"
        shift
        ;;
    esac
  done

  [[ -n "$needle" ]] || die "workspace stop: workspace name is required"
  need_tmux

  local window_target worktree workspace_name
  window_target="$(workspace_resolve_window "$needle")"
  workspace_name="$(tmux display-message -p -t "$window_target" '#{window_name}' 2>/dev/null || true)"
  workspace_name="${workspace_name:-$needle}"
  worktree="$(workspace_resolve_worktree_for_stop "$window_target" "$force")" \
    || die "workspace stop: refusing to stop $needle (use --force to override)"
  [[ -n "$worktree" ]] || die "workspace stop: cannot resolve worktree for $needle"
  if [[ -d "$worktree" ]]; then
    worktree="$(cd "$worktree" && pwd)"
  fi

  printf 'workspace stop: %s (worktree=%s)\n' "$needle" "$worktree"

  workspace_stop_devbox_services "$worktree"
  workspace_stop_docker_compose "$worktree"
  workspace_release_locks_for_worktree "$worktree"

  if [[ "$archive_logs" == "true" ]]; then
    workspace_archive_logs "$worktree"
  fi

  if [[ "$keep_window" != "true" ]]; then
    tmux kill-window -t "$window_target" 2>/dev/null || true
    printf '  tmux window killed: %s\n' "$window_target"
  else
    printf '  tmux window kept: %s\n' "$window_target"
  fi

  metrics_emit_event "$worktree" "$workspace_name" "workspace_stop" \
    "window=$window_target" \
    "archive_logs=$archive_logs" \
    "keep_window=$keep_window" \
    "force=$force"
}

cmd_workspace_clean() {
  local needle=""
  local detect_only="false"
  local force="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --detect-only)
        detect_only="true"
        shift
        ;;
      --force)
        force="true"
        shift
        ;;
      -h|--help)
        cat <<'EOF'
Usage:
  orch-runtime workspace clean <workspace> [--detect-only] [--force]

Stop the workspace runtime (delegating to `workspace stop --archive-logs`)
and report residuals that may need manual attention:
  - active or stale locks remaining for the worktree (after the release step)
  - log files left outside the archive subtree
  - docker compose containers / networks / volumes for the worktree's
    ORCH_PROJECT (resolved from <worktree>/.orchestrate/env)
  - process-compose services still reported as running by `devbox services ls`

`--detect-only` skips the stop step and only emits the residual report.
`--force` is propagated to `workspace stop` to override worktree drift.

Generated env (.orchestrate/env), overlay copies, and the worktree directory
itself are left intact. Remove them manually after confirming the workspace is
no longer needed; this command never deletes worktree contents.
EOF
        return
        ;;
      -*)
        die "unknown option for workspace clean: $1"
        ;;
      *)
        [[ -z "$needle" ]] || die "workspace clean takes a single workspace argument"
        needle="$1"
        shift
        ;;
    esac
  done

  [[ -n "$needle" ]] || die "workspace clean: workspace name is required"
  need_tmux

  local window_target worktree workspace_name
  window_target="$(workspace_resolve_window "$needle")"
  workspace_name="$(tmux display-message -p -t "$window_target" '#{window_name}' 2>/dev/null || true)"
  workspace_name="${workspace_name:-$needle}"
  worktree="$(workspace_resolve_worktree_for_stop "$window_target" "$force")" \
    || die "workspace clean: refusing to clean $needle (use --force to override)"
  [[ -n "$worktree" ]] || die "workspace clean: cannot resolve worktree for $needle"
  if [[ -d "$worktree" ]]; then
    worktree="$(cd "$worktree" && pwd)"
  fi

  if [[ "$detect_only" != "true" ]]; then
    if [[ "$force" == "true" ]]; then
      cmd_workspace_stop "$needle" --archive-logs --force
    else
      cmd_workspace_stop "$needle" --archive-logs
    fi
  fi

  workspace_clean_residuals_report "$worktree"
  metrics_emit_event "$worktree" "$workspace_name" "workspace_clean" \
    "detect_only=$detect_only" \
    "force=$force"
}

cmd_workspace() {
  local sub="${1:-}"
  if [[ -z "$sub" || "$sub" == "-h" || "$sub" == "--help" ]]; then
    cat <<'EOF'
Usage:
  orch-runtime workspace start <profile-id> <worktree-path> [--session name] [--name window] [--dry-run]
  orch-runtime workspace status [-n lines]
  orch-runtime workspace report <workspace> [-n lines]
  orch-runtime workspace open <workspace> [--print]
  orch-runtime workspace watch <workspace> [-n lines] [-i seconds] [--stale-seconds seconds] [--once]
  orch-runtime workspace stop <workspace> [--archive-logs] [--keep-window] [--force]
  orch-runtime workspace clean <workspace> [--detect-only] [--force]

Profiles may declare advisory heavy-runtime locks under runtime.locks; worktree
env files may also declare ORCH_RESOURCE_LOCKS. Locks are acquired by workspace
start, shown by status/report, and released by workspace stop / clean (active
locks only) or `orch-runtime lock release-stale ...` (stale locks).
EOF
    return
  fi
  shift
  case "$sub" in
    start)
      cmd_workspace_start "$@"
      ;;
    status)
      cmd_workspace_status "$@"
      ;;
    report)
      cmd_workspace_report "$@"
      ;;
    open)
      cmd_workspace_open "$@"
      ;;
    watch)
      cmd_workspace_watch "$@"
      ;;
    stop)
      cmd_workspace_stop "$@"
      ;;
    clean)
      cmd_workspace_clean "$@"
      ;;
    *)
      die "unknown workspace subcommand: $sub (expected: start, status, report, open, watch, stop, clean)"
      ;;
  esac
}
