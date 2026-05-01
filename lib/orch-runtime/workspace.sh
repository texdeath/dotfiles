# shellcheck shell=bash
# Workspace runtime supervisor commands.

workspace_resolve_loader() {
  # Resolve the orchestrate profile loader path, in priority order:
  #   1. $ORCHESTRATE_LOAD_PROFILE  (env override, absolute path)
  #   2. command -v load-profile.sh (PATH discovery)
  #   3. ~/.claude/orchestrate/bin/load-profile.sh (canonical install location)
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
  loader="$(workspace_resolve_loader)" || return 1

  local profile_json
  if ! profile_json="$("$loader" "$profile" --feature-path "$worktree" 2>/dev/null)"; then
    return 1
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

  # Resolve tmux pane-base-index so the final select-pane target matches the
  # user's tmux config (default 0; 1 if `set -g pane-base-index 1`). Without
  # this, environments with pane-base-index 1 hit "can't find pane: 0".
  local pane_base_index
  pane_base_index="$(tmux show-options -gv pane-base-index 2>/dev/null || echo 0)"

  if [[ "$dry_run" == "true" ]]; then
    printf '# orch-runtime workspace start %s %s (dry-run)\n' "$profile" "$worktree"
    printf '# session=%s window=%s panes=%d\n' "$session" "$window_name" "$pane_count"
    printf 'window_target="$(tmux new-window -d -P -F %s -t %q -n %q -c %q)"\n' "'#{window_id}'" "$session" "$window_name" "${effective_cwds[0]}"
    printf 'tmux set-option -w -t %q %s %q\n' "$window_target" "@workspace_profile" "$profile"
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
  tmux set-option -w -t "$window_target" '@workspace_profile' "$profile"
  tmux send-keys -t "$window_target" "# pane 0: ${names[0]}" Enter
  tmux send-keys -t "$window_target" "${effective_commands[0]}" Enter
  for (( i=1; i<pane_count; i++ )); do
    tmux split-window -t "$window_target" -c "${effective_cwds[$i]}"
    tmux send-keys -t "$window_target" "# pane $i: ${names[$i]}" Enter
    tmux send-keys -t "$window_target" "${effective_commands[$i]}" Enter
  done
  tmux select-layout -t "$window_target" tiled
  tmux select-pane -t "${window_target}.${pane_base_index}"

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

  printf '%-20s %-9s %-5s %-12s %-15s %s\n' "WORKSPACE" "PROFILE" "PANES" "SESSION" "CURRENT_CMD" "PATH"
  local window_target name session_name profile pane_total current_cmd first_path
  while IFS=$'\t' read -r window_target name session_name; do
    profile="$(workspace_window_profile_from_meta "$window_target")"
    [[ "$profile" == "-" ]] && continue
    pane_total="$(tmux list-panes -t "$window_target" -F '.' 2>/dev/null | wc -l | tr -d ' ')"
    current_cmd="$(tmux list-panes -t "$window_target" -F '#{pane_current_command}' 2>/dev/null | grep -v '^$' | head -n 1)"
    current_cmd="${current_cmd:--}"
    first_path="$(tmux list-panes -t "$window_target" -F '#{pane_current_path}' 2>/dev/null | head -n 1)"
    printf '%-20s %-9s %-5s %-12s %-15s %s\n' "$name" "$profile" "$pane_total" "$session_name" "$current_cmd" "$first_path"
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

  local window_target name session_name profile pane_total first_path timestamp
  window_target="$(workspace_resolve_window "$needle")"
  name="$(tmux display-message -p -t "$window_target" '#{window_name}')"
  session_name="$(tmux display-message -p -t "$window_target" '#{session_name}')"
  profile="$(workspace_window_profile_from_meta "$window_target")"
  pane_total="$(tmux list-panes -t "$window_target" -F '.' 2>/dev/null | wc -l | tr -d ' ')"
  first_path="$(tmux list-panes -t "$window_target" -F '#{pane_current_path}' 2>/dev/null | head -n 1)"
  timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"

  cat <<EOF
# Workspace report: $name

- workspace: $name
- profile: $profile
- session: $session_name
- window: $window_target
- pane count: $pane_total
- cwd: $first_path
- lines per pane: $lines
- generated: $timestamp

EOF

  local pane
  while IFS= read -r pane; do
    digest_pane "$pane" "$lines"
  done < <(tmux list-panes -t "$window_target" -F '#{pane_id}' 2>/dev/null)
}

cmd_workspace() {
  local sub="${1:-}"
  if [[ -z "$sub" || "$sub" == "-h" || "$sub" == "--help" ]]; then
    cat <<'EOF'
Usage:
  orch-runtime workspace start <profile-id> <worktree-path> [--session name] [--name window] [--dry-run]
  orch-runtime workspace status [-n lines]
  orch-runtime workspace report <workspace> [-n lines]
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
    *)
      die "unknown workspace subcommand: $sub (expected: start, status, report)"
      ;;
  esac
}
