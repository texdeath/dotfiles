# shellcheck shell=bash
# Advisory resource locks for heavyweight workspace runtimes.

LOCK_SEP=$'\x1f'

lock_dir() {
  local state_home
  state_home="${XDG_STATE_HOME:-$HOME/.local/state}"
  printf '%s' "${ORCH_RUNTIME_LOCK_DIR:-$state_home/orch-runtime/locks}"
}

lock_digest() {
  local type="$1"
  local id="$2"
  printf '%s:%s' "$type" "$id" | shasum -a 256 | awk '{print $1}'
}

lock_path_for() {
  local type="$1"
  local id="$2"
  printf '%s/%s.lock' "$(lock_dir)" "$(lock_digest "$type" "$id")"
}

lock_read_field() {
  local path="$1"
  local field="$2"
  local file="$path/$field"
  [[ -f "$file" ]] || return 1
  cat "$file"
}

lock_write_field() {
  local path="$1"
  local field="$2"
  local value="$3"
  printf '%s\n' "$value" > "$path/$field"
}

lock_write_metadata() {
  local path="$1"
  local type="$2"
  local id="$3"
  local workspace="$4"
  local profile="$5"
  local worktree="$6"
  local window="$7"
  local now
  now="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  lock_write_field "$path" resource "$type:$id"
  lock_write_field "$path" type "$type"
  lock_write_field "$path" id "$id"
  lock_write_field "$path" workspace "$workspace"
  lock_write_field "$path" profile "$profile"
  lock_write_field "$path" worktree "$worktree"
  lock_write_field "$path" window "$window"
  lock_write_field "$path" pid "$$"
  lock_write_field "$path" user "${USER:-unknown}"
  lock_write_field "$path" host "$(hostname 2>/dev/null || echo unknown)"
  lock_write_field "$path" created_at "$now"
}

lock_resource_name() {
  local path="$1"
  local type id
  type="$(lock_read_field "$path" type 2>/dev/null || true)"
  id="$(lock_read_field "$path" id 2>/dev/null || true)"
  if [[ -n "$type" && -n "$id" ]]; then
    printf '%s:%s' "$type" "$id"
  else
    lock_read_field "$path" resource 2>/dev/null || basename "$path"
  fi
}

lock_tmux_window_exists() {
  local window="$1"
  [[ -n "$window" ]] || return 1
  command -v tmux >/dev/null 2>&1 || return 1
  tmux has-session >/dev/null 2>&1 || return 1
  tmux display-message -p -t "$window" '#{window_id}' >/dev/null 2>&1
}

lock_path_is_under_worktree() {
  local path="$1"
  local worktree="$2"
  [[ -n "$path" && -n "$worktree" ]] || return 1
  [[ "$path" == "$worktree" || "$path" == "$worktree/"* ]]
}

lock_tmux_runtime_evidence() {
  local window="$1"
  local worktree="$2"
  local scope="tmux"
  local pane_count option_worktree pane_path pane_match

  if [[ -z "$window" ]]; then
    printf '%s\tskipped\tno window metadata\n' "$scope"
    return 0
  fi

  if ! lock_tmux_window_exists "$window"; then
    if ! command -v tmux >/dev/null 2>&1; then
      printf '%s\tunknown\ttmux command not found; window=%s\n' "$scope" "$window"
    elif ! tmux has-session >/dev/null 2>&1; then
      printf '%s\tabsent\tno tmux server; window=%s\n' "$scope" "$window"
    else
      printf '%s\tabsent\twindow not found: %s\n' "$scope" "$window"
    fi
    return 0
  fi

  pane_count="$(tmux list-panes -t "$window" -F '.' 2>/dev/null | wc -l | tr -d ' ')"
  if [[ -z "$pane_count" || "$pane_count" -eq 0 ]]; then
    printf '%s\tpresent\twindow=%s panes=unknown\n' "$scope" "$window"
    return 0
  fi

  option_worktree="$(tmux show-option -wv -t "$window" '@workspace_worktree' 2>/dev/null || true)"
  if [[ -n "$option_worktree" && -n "$worktree" && "$option_worktree" != "$worktree" ]]; then
    printf '%s\tsuspicious\twindow=%s panes=%s @workspace_worktree=%s owner_worktree=%s\n' \
      "$scope" "$window" "$pane_count" "$option_worktree" "$worktree"
    return 0
  fi

  pane_match="false"
  if [[ -n "$worktree" ]]; then
    while IFS= read -r pane_path; do
      if lock_path_is_under_worktree "$pane_path" "$worktree"; then
        pane_match="true"
        break
      fi
    done < <(tmux list-panes -t "$window" -F '#{pane_current_path}' 2>/dev/null || true)
  fi

  if [[ -n "$option_worktree" && "$option_worktree" == "$worktree" ]]; then
    printf '%s\tpresent\twindow=%s panes=%s worktree=window-option\n' "$scope" "$window" "$pane_count"
  elif [[ "$pane_match" == "true" ]]; then
    printf '%s\tpresent\twindow=%s panes=%s worktree=pane-path\n' "$scope" "$window" "$pane_count"
  elif [[ -z "$worktree" ]]; then
    printf '%s\tpresent\twindow=%s panes=%s worktree=not-recorded\n' "$scope" "$window" "$pane_count"
  else
    printf '%s\tsuspicious\twindow=%s panes=%s no pane path under owner_worktree=%s\n' \
      "$scope" "$window" "$pane_count" "$worktree"
  fi
}

lock_devbox_runtime_evidence() {
  local worktree="$1"
  local scope="devbox"
  local snapshot service status detail kind
  local present_count=0 alert_count=0 unknown_count=0 not_started_count=0
  local present_items="" alert_items="" unknown_items="" not_started_items=""

  if [[ -z "$worktree" || ! -d "$worktree" ]]; then
    printf '%s\tskipped\tworktree unavailable\n' "$scope"
    return 0
  fi
  if [[ ! -f "$worktree/process-compose.yaml" && ! -f "$worktree/devbox.json" ]]; then
    printf '%s\tskipped\tno process-compose.yaml or devbox.json\n' "$scope"
    return 0
  fi
  if ! command -v devbox >/dev/null 2>&1; then
    printf '%s\tunknown\tdevbox command not found\n' "$scope"
    return 0
  fi

  snapshot="$(workspace_devbox_service_snapshot "$worktree" 2>/dev/null || true)"
  if [[ -z "$snapshot" ]]; then
    printf '%s\tabsent\tno services reported\n' "$scope"
    return 0
  fi

  while IFS=$'\t' read -r service status detail; do
    [[ -n "$service" ]] || continue
    kind="$(workspace_devbox_service_status_kind "$status")"
    case "$kind" in
      ok)
        present_count=$((present_count + 1))
        present_items="${present_items}${service}:${status},"
        ;;
      alert)
        alert_count=$((alert_count + 1))
        alert_items="${alert_items}${service}:${status},"
        ;;
      unknown)
        unknown_count=$((unknown_count + 1))
        unknown_items="${unknown_items}${service}:${status},"
        ;;
      not-started)
        not_started_count=$((not_started_count + 1))
      not_started_items="${not_started_items}${service},"
        ;;
    esac
  done <<< "$snapshot"

  if [[ "$alert_count" -gt 0 ]]; then
    printf '%s\tsuspicious\tservices=%s\n' "$scope" "${alert_items%,}"
  elif [[ "$present_count" -gt 0 ]]; then
    printf '%s\tpresent\tservices=%s\n' "$scope" "${present_items%,}"
  elif [[ "$unknown_count" -gt 0 ]]; then
    printf '%s\tunknown\tservices=%s\n' "$scope" "${unknown_items%,}"
  else
    printf '%s\tsuspicious\tservices not started=%s\n' "$scope" "${not_started_items%,}"
  fi
}

lock_docker_runtime_evidence() {
  local worktree="$1"
  local scope="docker"
  local project line count=0 first=""

  if [[ -z "$worktree" || ! -d "$worktree" ]]; then
    printf '%s\tskipped\tworktree unavailable\n' "$scope"
    return 0
  fi

  project="$(workspace_compose_project_from_env "$worktree" 2>/dev/null || true)"
  if [[ -z "$project" ]]; then
    printf '%s\tskipped\tno ORCH_PROJECT in .orchestrate/env\n' "$scope"
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    printf '%s\tunknown\tdocker command not found; project=%s\n' "$scope" "$project"
    return 0
  fi

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    count=$((count + 1))
    [[ -n "$first" ]] || first="$line"
  done < <(workspace_docker_residuals_for_project "$project" 2>/dev/null || true)

  if [[ "$count" -gt 0 ]]; then
    printf '%s\tpresent\tproject=%s resources=%s first=%s\n' "$scope" "$project" "$count" "$first"
  else
    printf '%s\tsuspicious\tproject=%s resources=0\n' "$scope" "$project"
  fi
}

lock_runtime_evidence_lines() {
  local path="$1"
  local worktree window
  worktree="$(lock_read_field "$path" worktree 2>/dev/null || true)"
  window="$(lock_read_field "$path" window 2>/dev/null || true)"
  lock_tmux_runtime_evidence "$window" "$worktree"
  lock_devbox_runtime_evidence "$worktree"
  lock_docker_runtime_evidence "$worktree"
}

lock_runtime_evidence_summary() {
  local path="$1"
  local scope state detail summary=""
  while IFS=$'\t' read -r scope state detail; do
    [[ -n "$scope" ]] || continue
    detail="$(printf '%s' "$detail" | one_line)"
    if [[ -z "$summary" ]]; then
      summary="${scope}=${state} (${detail})"
    else
      summary="${summary}; ${scope}=${state} (${detail})"
    fi
  done < <(lock_runtime_evidence_lines "$path")
  printf '%s' "${summary:--}"
}

lock_status() {
  local path="$1"
  local worktree scope state detail
  local has_runtime_metadata="false"
  local has_present="false"
  local has_unknown="false"
  local has_suspicious="false"
  local has_absent="false"
  [[ -d "$path" ]] || { printf '%s' "missing"; return; }

  worktree="$(lock_read_field "$path" worktree 2>/dev/null || true)"
  if [[ -z "$worktree" || ! -d "$worktree" ]]; then
    printf '%s' "stale"
    return
  fi

  while IFS=$'\t' read -r scope state detail; do
    [[ -n "$scope" ]] || continue
    case "$state" in
      present)
        has_runtime_metadata="true"
        has_present="true"
        ;;
      suspicious)
        has_runtime_metadata="true"
        has_suspicious="true"
        ;;
      unknown)
        has_runtime_metadata="true"
        has_unknown="true"
        ;;
      absent)
        has_runtime_metadata="true"
        has_absent="true"
        ;;
      skipped)
        ;;
    esac
  done < <(lock_runtime_evidence_lines "$path")

  if [[ "$has_suspicious" == "true" ]]; then
    printf '%s' "suspicious"
  elif [[ "$has_absent" == "true" && "$has_present" == "true" ]]; then
    printf '%s' "suspicious"
  elif [[ "$has_present" == "true" ]]; then
    printf '%s' "active"
  elif [[ "$has_unknown" == "true" ]]; then
    printf '%s' "suspicious"
  elif [[ "$has_runtime_metadata" == "true" && "$has_absent" == "true" ]]; then
    printf '%s' "stale"
  else
    printf '%s' "active"
  fi
}

lock_owner_summary() {
  local path="$1"
  local workspace profile worktree
  workspace="$(lock_read_field "$path" workspace 2>/dev/null || true)"
  profile="$(lock_read_field "$path" profile 2>/dev/null || true)"
  worktree="$(lock_read_field "$path" worktree 2>/dev/null || true)"
  printf 'workspace=%s profile=%s worktree=%s' "${workspace:--}" "${profile:--}" "${worktree:--}"
}

lock_acquire_one() {
  local type="$1"
  local id="$2"
  local workspace="${3:-}"
  local profile="${4:-}"
  local worktree="${5:-}"
  local window="${6:-}"
  local root path created_path=""

  [[ -n "$type" ]] || die "lock acquire: type is required"
  [[ -n "$id" ]] || die "lock acquire: id is required"
  if [[ -n "$worktree" && -d "$worktree" ]]; then
    worktree="$(cd "$worktree" && pwd)"
  fi
  root="$(lock_dir)"
  path="$(lock_path_for "$type" "$id")"
  mkdir -p "$root"

  if mkdir "$path" 2>/dev/null; then
    created_path="$path"
    lock_write_metadata "$path" "$type" "$id" "$workspace" "$profile" "$worktree" "$window"
    printf '%s\n' "$path"
    return 0
  fi

  local owner_worktree state
  owner_worktree="$(lock_read_field "$path" worktree 2>/dev/null || true)"
  if [[ -n "$worktree" && "$owner_worktree" == "$worktree" ]]; then
    lock_write_metadata "$path" "$type" "$id" "$workspace" "$profile" "$worktree" "$window"
    printf '%s\n' "$path"
    return 0
  fi

  state="$(lock_status "$path")"
  printf 'resource lock conflict: %s:%s is held by %s (%s)\n' "$type" "$id" "$(lock_owner_summary "$path")" "$state" >&2
  printf 'release explicitly with: orch-runtime lock release %q %q --worktree <owner-worktree>\n' "$type" "$id" >&2
  [[ -z "$created_path" ]] || rm -rf -- "$created_path"
  return 1
}

lock_release_path() {
  local path="$1"
  [[ -d "$path" ]] || return 1
  rm -rf -- "$path"
}

lock_each_path() {
  local root path
  root="$(lock_dir)"
  [[ -d "$root" ]] || return 0
  for path in "$root"/*.lock; do
    [[ -d "$path" ]] || continue
    printf '%s\n' "$path"
  done
}

lock_specs_inline() {
  local specs="$1"
  local first="true" type id
  while IFS=$'\x1f' read -r type id; do
    [[ -n "$type" && -n "$id" ]] || continue
    if [[ "$first" == "true" ]]; then
      first="false"
    else
      printf ','
    fi
    printf '%s:%s' "$type" "$id"
  done <<< "$specs"
}

lock_window_declared_specs() {
  local window="$1"
  local inline entry type id rest
  [[ -n "$window" ]] || return 0
  command -v tmux >/dev/null 2>&1 || return 0
  inline="$(tmux show-option -wv -t "$window" '@workspace_locks' 2>/dev/null || true)"
  [[ -n "$inline" ]] || return 0

  rest="$inline"
  while true; do
    if [[ "$rest" == *,* ]]; then
      entry="${rest%%,*}"
      rest="${rest#*,}"
    else
      entry="$rest"
      rest=""
    fi
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    if [[ -n "$entry" && "$entry" == *:* ]]; then
      type="${entry%%:*}"
      id="${entry#*:}"
      [[ -n "$type" && -n "$id" ]] && printf '%s%s%s\n' "$type" "$LOCK_SEP" "$id"
    fi
    [[ -n "$rest" ]] || break
  done
}

lock_declared_discrepancies_for_window() {
  local window="$1"
  local worktree="$2"
  local type id path owner resource
  [[ -n "$window" ]] || return 0
  if [[ -n "$worktree" && -d "$worktree" ]]; then
    worktree="$(cd "$worktree" && pwd)"
  fi

  while IFS=$'\x1f' read -r type id; do
    [[ -n "$type" && -n "$id" ]] || continue
    path="$(lock_path_for "$type" "$id")"
    resource="$type:$id"
    if [[ ! -d "$path" ]]; then
      printf '%s\tmissing\tdeclared by tmux @workspace_locks but no lock file exists\n' "$resource"
      continue
    fi
    owner="$(lock_read_field "$path" worktree 2>/dev/null || true)"
    if [[ -n "$worktree" && "$owner" != "$worktree" ]]; then
      printf '%s\towner-mismatch\tdeclared by window but lock owner is %s\n' "$resource" "${owner:--}"
    fi
  done < <(lock_window_declared_specs "$window")
}

lock_print_dry_run_plan() {
  local specs="$1"
  local type id path status count=0
  [[ -n "$specs" ]] || {
    printf '# resource_locks=0\n'
    return 0
  }
  while IFS=$'\x1f' read -r type id; do
    [[ -n "$type" && -n "$id" ]] || continue
    count=$((count + 1))
  done <<< "$specs"
  printf '# resource_locks=%d\n' "$count"
  while IFS=$'\x1f' read -r type id; do
    [[ -n "$type" && -n "$id" ]] || continue
    path="$(lock_path_for "$type" "$id")"
    status="$(lock_status "$path")"
    if [[ "$status" == "missing" ]]; then
      status="available"
    fi
    printf '# lock %s:%s -> %s\n' "$type" "$id" "$status"
  done <<< "$specs"
}

lock_env_specs() {
  local worktree="$1"
  local env_file="$worktree/.orchestrate/env"
  local value token type id rest
  [[ -f "$env_file" ]] || return 0

  while IFS= read -r value; do
    value="${value#ORCH_RESOURCE_LOCKS=}"
    value="${value#ORCH_HEAVY_RESOURCE_LOCKS=}"
    rest="$value"
    while true; do
      if [[ "$rest" == *,* ]]; then
        token="${rest%%,*}"
        rest="${rest#*,}"
      else
        token="$rest"
        rest=""
      fi
      token="${token#"${token%%[![:space:]]*}"}"
      token="${token%"${token##*[![:space:]]}"}"
      if [[ -z "$token" ]]; then
        [[ -n "$rest" ]] || break
        continue
      fi
      if [[ "$token" == *=* ]]; then
        type="${token%%=*}"
        id="${token#*=}"
      elif [[ "$token" == *:* ]]; then
        type="${token%%:*}"
        id="${token#*:}"
      else
        [[ -n "$rest" ]] || break
        continue
      fi
      if [[ -z "$type" || -z "$id" ]]; then
        [[ -n "$rest" ]] || break
        continue
      fi
      printf '%s%s%s\n' "$type" "$LOCK_SEP" "$id"
      [[ -n "$rest" ]] || break
    done
  done < <(grep -E '^(ORCH_RESOURCE_LOCKS|ORCH_HEAVY_RESOURCE_LOCKS)=' "$env_file" 2>/dev/null || true)
}

lock_env_locks_declared() {
  local worktree="$1"
  local env_file="$worktree/.orchestrate/env"
  [[ -f "$env_file" ]] || return 1
  grep -Eq '^(ORCH_RESOURCE_LOCKS|ORCH_HEAVY_RESOURCE_LOCKS)=' "$env_file"
}

lock_env_locks_mode() {
  local worktree="$1"
  local env_file="$worktree/.orchestrate/env"
  local mode

  [[ -f "$env_file" ]] || { printf '%s' "merge"; return 0; }
  mode="$(
    awk -F '=' '
      $1 == "ORCH_RESOURCE_LOCKS_MODE" {
        value = $0
        sub(/^[^=]*=/, "", value)
        print value
        found = 1
        exit
      }
      END {
        if (!found) print ""
      }
    ' "$env_file" 2>/dev/null
  )"
  mode="$(lower "$mode")"
  case "$mode" in
    ""|merge|append)
      printf '%s' "merge"
      ;;
    overlay|replace|override)
      printf '%s' "overlay"
      ;;
    *)
      printf 'orch-runtime: invalid ORCH_RESOURCE_LOCKS_MODE: %s (expected merge or overlay)\n' "$mode" >&2
      return 2
      ;;
  esac
}

workspace_profile_locks() {
  local profile="$1"
  local worktree="$2"
  local loader profiles_dir profile_json env_specs env_mode env_declared profile_specs rc

  env_specs="$(lock_env_specs "$worktree")"
  env_mode="$(lock_env_locks_mode "$worktree")" || return 2
  env_declared="false"
  lock_env_locks_declared "$worktree" && env_declared="true"
  loader="$(workspace_resolve_loader)" || {
    printf '%s' "$env_specs"
    return 0
  }
  profiles_dir="$(workspace_resolve_profiles_dir 2>/dev/null || true)"

  rc=0
  if [[ -n "$profiles_dir" && -z "${ORCHESTRATE_PROFILES_DIR:-}" ]]; then
    profile_json="$(ORCHESTRATE_PROFILES_DIR="$profiles_dir" "$loader" "$profile" --feature-path "$worktree" 2>/dev/null)" || rc=$?
  else
    profile_json="$("$loader" "$profile" --feature-path "$worktree" 2>/dev/null)" || rc=$?
  fi
  [[ "$rc" -eq 0 ]] || return 1

  profile_specs="$(ruby -rjson - "$profile_json" <<'RUBY'
SEP = "\x1f"
data = JSON.parse(ARGV[0])
unless data["resolved"]
  warn "orch-runtime: profile loader could not resolve '#{data["query"]}'"
  exit 1
end
profile = data["profile"] || {}
runtime = profile["runtime"] || {}
locks = runtime["locks"]
exit 0 if locks.nil?
unless locks.is_a?(Array)
  warn "orch-runtime: runtime.locks must be an array (got #{locks.class.name})"
  exit 2
end

def lock_id_for(lock)
  return lock["id"] if lock.key?("id")
  case lock["type"]
  when "gpu"
    lock["index"] || lock["device"] || lock["name"]
  when "pubsub-topic"
    lock["topic"] || lock["name"]
  when "pubsub-subscription"
    lock["subscription"] || lock["name"]
  when "emulator-port", "port"
    lock["port"]
  when "model-cache-write", "model-cache"
    lock["path"] || lock["name"] || "default"
  else
    lock["name"] || lock["key"] || lock["value"]
  end
end

locks.each_with_index do |lock, idx|
  unless lock.is_a?(Hash)
    warn "orch-runtime: runtime.locks[#{idx}] must be a mapping"
    exit 2
  end
  type = lock["type"]
  id = lock_id_for(lock)
  unless type.is_a?(String) && !type.empty?
    warn "orch-runtime: runtime.locks[#{idx}].type must be a non-empty string"
    exit 2
  end
  if id.nil? || id.to_s.empty?
    warn "orch-runtime: runtime.locks[#{idx}] must declare id/index/topic/subscription/port/path/name"
    exit 2
  end
  [type, id.to_s].each do |field|
    if field.include?(SEP) || field.include?("\n")
      warn "orch-runtime: runtime.locks[#{idx}] contains an unsupported character (newline or US 0x1f)"
      exit 2
    end
  end
  puts "#{type}#{SEP}#{id}"
end
RUBY
)" || rc=$?

  if [[ "$rc" -eq 1 ]]; then
    return 1
  fi
  if [[ "$rc" -eq 2 ]]; then
    return 2
  fi
  [[ "$rc" -eq 0 ]] || return "$rc"

  if [[ "$env_mode" == "overlay" && "$env_declared" == "true" ]]; then
    printf '%s\n' "$env_specs" | sed '/^$/d' | awk '!seen[$0]++'
    return 0
  fi

  {
    printf '%s\n' "$profile_specs"
    printf '%s\n' "$env_specs"
  } | sed '/^$/d' | awk '!seen[$0]++'
}

workspace_acquire_locks_from_specs() {
  local specs="$1"
  local profile="$2"
  local worktree="$3"
  local workspace="$4"
  local window="$5"
  local -a created=()
  local type id path before_exists

  [[ -n "$specs" ]] || return 0
  while IFS=$'\x1f' read -r type id; do
    [[ -n "$type" && -n "$id" ]] || continue
    path="$(lock_path_for "$type" "$id")"
    before_exists="false"
    [[ -d "$path" ]] && before_exists="true"
    if ! lock_acquire_one "$type" "$id" "$workspace" "$profile" "$worktree" "$window" >/dev/null; then
      for path in "${created[@]}"; do
        lock_release_path "$path" || true
      done
      return 1
    fi
    if [[ "$before_exists" == "false" ]]; then
      created+=("$path")
    fi
  done <<< "$specs"
}

lock_summary_for_worktree() {
  local worktree="$1"
  local window="${2:-}"
  local active=0 stale=0 suspicious=0 total=0 missing=0 declared_conflict=0 path owner state resource discrepancy detail
  [[ -n "$worktree" ]] || { printf '%s' "-"; return; }
  if [[ -d "$worktree" ]]; then
    worktree="$(cd "$worktree" && pwd)"
  fi
  while IFS= read -r path; do
    owner="$(lock_read_field "$path" worktree 2>/dev/null || true)"
    [[ "$owner" == "$worktree" ]] || continue
    total=$((total + 1))
    state="$(lock_status "$path")"
    case "$state" in
      active) active=$((active + 1)) ;;
      stale) stale=$((stale + 1)) ;;
      suspicious) suspicious=$((suspicious + 1)) ;;
    esac
  done < <(lock_each_path)

  while IFS=$'\t' read -r resource discrepancy detail; do
    [[ -n "$resource" ]] || continue
    case "$discrepancy" in
      missing) missing=$((missing + 1)) ;;
      owner-mismatch) declared_conflict=$((declared_conflict + 1)) ;;
    esac
  done < <(lock_declared_discrepancies_for_window "$window" "$worktree")

  if [[ "$total" -eq 0 && "$missing" -eq 0 && "$declared_conflict" -eq 0 ]]; then
    printf '%s' "-"
  else
    local summary=""
    [[ "$active" -gt 0 ]] && summary="${summary}active:$active "
    [[ "$stale" -gt 0 ]] && summary="${summary}stale:$stale "
    [[ "$suspicious" -gt 0 ]] && summary="${summary}suspicious:$suspicious "
    [[ "$missing" -gt 0 ]] && summary="${summary}missing:$missing "
    [[ "$declared_conflict" -gt 0 ]] && summary="${summary}owner-mismatch:$declared_conflict "
    printf '%s' "$(printf '%s' "$summary" | one_line)"
  fi
}

workspace_report_resource_locks() {
  local worktree="$1"
  local window="${2:-}"
  local path owner state resource created workspace profile evidence any="false"
  local missing_any="false" discrepancy detail
  if [[ -n "$worktree" && -d "$worktree" ]]; then
    worktree="$(cd "$worktree" && pwd)"
  fi

  cat <<'EOF'
## Resource Locks

EOF

  cat <<'EOF'
Active locks are released by `orch-runtime workspace stop` / `workspace clean`.
Stale locks require `orch-runtime lock release-stale <type> <id>`. Suspicious
locks need manual inspection; after confirming the runtime is gone, release with
`orch-runtime lock release <type> <id> --worktree <owner-worktree>`.

| Resource | Status | Owner | Created | Runtime Evidence |
|---|---|---|---|---|
EOF

  while IFS= read -r path; do
    owner="$(lock_read_field "$path" worktree 2>/dev/null || true)"
    [[ "$owner" == "$worktree" ]] || continue
    any="true"
    resource="$(lock_resource_name "$path")"
    state="$(lock_status "$path")"
    created="$(lock_read_field "$path" created_at 2>/dev/null || true)"
    workspace="$(lock_read_field "$path" workspace 2>/dev/null || true)"
    profile="$(lock_read_field "$path" profile 2>/dev/null || true)"
    evidence="$(lock_runtime_evidence_summary "$path")"
    printf "| \`%s\` | \`%s\` | workspace=%s profile=%s | \`%s\` | %s |\n" \
      "$resource" \
      "$state" \
      "$(markdown_cell "${workspace:--}" 32)" \
      "$(markdown_cell "${profile:--}" 32)" \
      "$(markdown_cell "${created:--}" 32)" \
      "$(markdown_cell "$evidence" 160)"
  done < <(lock_each_path)

  if [[ "$any" != "true" ]]; then
    printf "%s\n" "| - | \`none\` | - | - | - |"
  fi

  while IFS=$'\t' read -r resource discrepancy detail; do
    [[ -n "$resource" ]] || continue
    if [[ "$missing_any" != "true" ]]; then
      printf '\n### Runtime-Declared Lock Discrepancies\n\n'
      missing_any="true"
    fi
    printf -- "- \`%s\`: \`%s\` (%s)\n" "$resource" "$discrepancy" "$(printf '%s' "$detail" | one_line)"
  done < <(lock_declared_discrepancies_for_window "$window" "$worktree")

  if [[ "$missing_any" == "true" ]]; then
    printf '\nRestart the workspace or acquire the missing lock before using the guarded resource.\n'
  fi
  printf '\n'
}

cmd_lock_list() {
  local worktree_filter=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --worktree)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        worktree_filter="$(cd "$2" 2>/dev/null && pwd || printf '%s' "$2")"
        shift 2
        ;;
      -h|--help)
        cat <<'EOF'
Usage:
  orch-runtime lock list [--worktree path]
EOF
        return
        ;;
      *)
        die "unknown option for lock list: $1"
        ;;
    esac
  done

  printf '%-28s %-11s %-20s %-12s %-64s %s\n' "RESOURCE" "STATUS" "WORKSPACE" "PROFILE" "EVIDENCE" "WORKTREE"
  local path resource status workspace profile worktree evidence
  while IFS= read -r path; do
    worktree="$(lock_read_field "$path" worktree 2>/dev/null || true)"
    [[ -z "$worktree_filter" || "$worktree" == "$worktree_filter" ]] || continue
    resource="$(lock_resource_name "$path")"
    status="$(lock_status "$path")"
    workspace="$(lock_read_field "$path" workspace 2>/dev/null || true)"
    profile="$(lock_read_field "$path" profile 2>/dev/null || true)"
    evidence="$(truncate_text "$(lock_runtime_evidence_summary "$path")" 64)"
    printf '%-28s %-11s %-20s %-12s %-64s %s\n' "$resource" "$status" "${workspace:--}" "${profile:--}" "$evidence" "${worktree:--}"
  done < <(lock_each_path)
}

cmd_lock_check() {
  [[ $# -eq 2 ]] || die "lock check takes <type> <id>"
  local type="$1"
  local id="$2"
  local path status
  path="$(lock_path_for "$type" "$id")"
  status="$(lock_status "$path")"
  printf '%s:%s %s\n' "$type" "$id" "$status"
  [[ "$status" == "missing" ]]
}

cmd_lock_acquire() {
  local type=""
  local id=""
  local workspace=""
  local profile=""
  local worktree=""
  local path
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --workspace)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        workspace="$2"
        shift 2
        ;;
      --profile)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        profile="$2"
        shift 2
        ;;
      --worktree)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        worktree="$(cd "$2" 2>/dev/null && pwd || printf '%s' "$2")"
        shift 2
        ;;
      -*)
        die "unknown option for lock acquire: $1"
        ;;
      *)
        if [[ -z "$type" ]]; then
          type="$1"
        elif [[ -z "$id" ]]; then
          id="$1"
        else
          die "lock acquire takes <type> <id>"
        fi
        shift
        ;;
    esac
  done
  [[ -n "$type" && -n "$id" ]] || die "lock acquire takes <type> <id>"
  path="$(lock_acquire_one "$type" "$id" "$workspace" "$profile" "$worktree" "")"
  printf 'acquired: %s:%s (%s)\n' "$type" "$id" "$path"
}

cmd_lock_release() {
  local type=""
  local id=""
  local worktree=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --worktree)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        worktree="$(cd "$2" 2>/dev/null && pwd || printf '%s' "$2")"
        shift 2
        ;;
      -*)
        die "unknown option for lock release: $1"
        ;;
      *)
        if [[ -z "$type" ]]; then
          type="$1"
        elif [[ -z "$id" ]]; then
          id="$1"
        else
          die "lock release takes optional <type> <id> plus --worktree"
        fi
        shift
        ;;
    esac
  done
  [[ -n "$worktree" ]] || die "lock release requires --worktree"

  local path owner resource released=0
  if [[ -n "$type" || -n "$id" ]]; then
    [[ -n "$type" && -n "$id" ]] || die "lock release needs both <type> and <id>"
    path="$(lock_path_for "$type" "$id")"
    [[ -d "$path" ]] || die "lock not found: $type:$id"
    owner="$(lock_read_field "$path" worktree 2>/dev/null || true)"
    [[ "$owner" == "$worktree" ]] || die "lock owner mismatch for $type:$id: $owner"
    lock_release_path "$path"
    printf 'released: %s:%s\n' "$type" "$id"
    return
  fi

  while IFS= read -r path; do
    owner="$(lock_read_field "$path" worktree 2>/dev/null || true)"
    [[ "$owner" == "$worktree" ]] || continue
    resource="$(lock_resource_name "$path")"
    lock_release_path "$path"
    printf 'released: %s\n' "$resource"
    released=$((released + 1))
  done < <(lock_each_path)

  [[ "$released" -gt 0 ]] || printf 'no locks for worktree: %s\n' "$worktree"
}

cmd_lock_release_stale() {
  [[ $# -eq 2 ]] || die "lock release-stale takes <type> <id>"
  local type="$1"
  local id="$2"
  local path status
  path="$(lock_path_for "$type" "$id")"
  [[ -d "$path" ]] || die "lock not found: $type:$id"
  status="$(lock_status "$path")"
  [[ "$status" == "stale" ]] || die "lock is not stale: $type:$id ($status)"
  lock_release_path "$path"
  printf 'released stale: %s:%s\n' "$type" "$id"
}

cmd_lock() {
  local sub="${1:-}"
  if [[ -z "$sub" || "$sub" == "-h" || "$sub" == "--help" ]]; then
    cat <<'EOF'
Usage:
  orch-runtime lock list [--worktree path]
  orch-runtime lock check <type> <id>
  orch-runtime lock acquire <type> <id> [--workspace name] [--profile id] [--worktree path]
  orch-runtime lock release [<type> <id>] --worktree <path>
  orch-runtime lock release-stale <type> <id>
EOF
    return
  fi
  shift
  case "$sub" in
    list) cmd_lock_list "$@" ;;
    check) cmd_lock_check "$@" ;;
    acquire) cmd_lock_acquire "$@" ;;
    release) cmd_lock_release "$@" ;;
    release-stale) cmd_lock_release_stale "$@" ;;
    *) die "unknown lock subcommand: $sub (expected: list, check, acquire, release, release-stale)" ;;
  esac
}
