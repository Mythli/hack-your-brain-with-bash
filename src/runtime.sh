#!/usr/bin/env bash

# Configuration stays in hack.sh. Runtime files are data, never sourced as code.
: "${HACK_STATE_DIR:=$script_dir/.hack-state}"
: "${HACK_HOSTS_FILE:=/etc/hosts}"
: "${allow_default_duration:=30}"
: "${allow_max_duration:=60}"
allow_challenges=${allow_challenges-"addition3 addition3 addition3"}

valid_mode() {
    [[ $1 =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] &&
        [[ $(declare -p "$1" 2>/dev/null) == 'declare -A '* ]]
}

runtime_requirements() {
    command -v fswatch >/dev/null || { echo 'Please install fswatch first.' >&2; return 1; }
    command -v screen >/dev/null || { echo 'Please install screen first.' >&2; return 1; }
    command -v flock >/dev/null || command -v shlock >/dev/null || {
        echo 'Runtime locking requires flock (Linux) or shlock (macOS).' >&2; return 1;
    }
    [[ -f $HACK_HOSTS_FILE && -w $HACK_HOSTS_FILE ]] || {
        echo "Cannot write hosts file: $HACK_HOSTS_FILE" >&2; return 1;
    }
}

# Serialize mode changes, grants, and enforcement. The OS lock / PID lock also
# permits recovery after an interrupted command. A subshell scopes the traps.
runtime_locked() (
    umask 077
    mkdir -p "$HACK_STATE_DIR" || exit 1
    if command -v flock >/dev/null; then
        exec 9>"$HACK_STATE_DIR/runtime.lock"
        flock -w 10 9 || { echo 'Runtime is busy.' >&2; exit 1; }
    else
        local attempt
        for ((attempt=0; attempt<100; attempt++)); do
            shlock -p "$BASHPID" -f "$HACK_STATE_DIR/runtime.lock" && break
            sleep 0.1
        done
        (( attempt < 100 )) || { echo 'Runtime is busy.' >&2; exit 1; }
        trap 'rm -f "$HACK_STATE_DIR/runtime.lock"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
    fi
    "$@"
)

read_runtime_state() {
    active_mode= active_session= mode_deadline=
    [[ -f $HACK_STATE_DIR/mode.tsv ]] &&
        IFS=$'\t' read -r active_mode active_session mode_deadline < "$HACK_STATE_DIR/mode.tsv" &&
        valid_mode "$active_mode" && [[ $mode_deadline =~ ^[0-9]+$ && -n $active_session ]]
}

active_allow_patterns() {
    local session=$1 now=$2
    [[ -f $HACK_STATE_DIR/allow.tsv ]] || return 0
    awk -F '\t' -v session="$session" -v now="$now" \
        '$1 == session && $2 > now {print $3}' "$HACK_STATE_DIR/allow.tsv"
}

# index() is literal substring matching: punctuation is never a regex or glob.
filtered_mode_entries() {
    local -n entries_mode=$1
    local field=$2 session=$3 now=${4:-$(date +%s)}
    printf '%s\n' "${entries_mode[$field]}" |
        awk -v allow_file="$HACK_STATE_DIR/allow.tsv" -v session="$session" -v now="$now" '
            BEGIN {
                while ((getline row < allow_file) > 0) {
                    split(row, cols, "\t")
                    if (cols[1] == session && cols[2] > now && cols[3] != "")
                        patterns[++count] = tolower(cols[3])
                }
                close(allow_file)
            }
            { for (i=1; i<=NF; i++) {
                allowed=0
                for (j=1; j<=count; j++)
                    if (index(tolower($i), patterns[j])) { allowed=1; break }
                if (!allowed) print $i
            } }'
}

# Rewrite only our block and compare before writing, so our own fswatch event
# produces no further write. Accept the old uncommented/glued markers too.
replace_in_markers() (
    local file_path=$1 marker=$2 content=$3 tmp_dir
    tmp_dir=$(mktemp -d) || exit 1
    trap 'rm -rf "$tmp_dir"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    cp "$file_path" "$tmp_dir/original" || exit 1
    printf '%s\n' "$content" > "$tmp_dir/content"
    awk -v marker="$marker" -v content_file="$tmp_dir/content" '
        function block( line) {
            print "# START " marker
            while ((getline line < content_file) > 0) if (line != "") print line
            close(content_file)
            print "# END " marker
        }
        FNR == NR { if ($0 ~ ("END " marker "$")) has_end=1; next }
        $0 == "START " marker || $0 == "# START " marker {
            if (!written) { block(); written=1 }
            inside=1; next
        }
        $0 ~ ("END " marker "$") { inside=0; next }
        inside {
            if (has_end) next
            # A legacy write may have lost its end marker. Only discard its
            # generated 0.0.0.0 lines; preserve unrelated mappings/comments.
            if ($0 ~ /^0\.0\.0\.0[ \t]+[^ \t]+[ \t]*$/) next
        }
        { print }
        END { if (!written) block() }
    ' "$tmp_dir/original" "$tmp_dir/original" > "$tmp_dir/next" || exit 1
    cmp -s "$tmp_dir/next" "$file_path" && exit 0
    # Avoid overwriting an edit observed while constructing the replacement.
    cmp -s "$tmp_dir/original" "$file_path" || exit 1
    # Keep the existing inode, owner, and permissions. /etc is not user-writable.
    cat "$tmp_dir/next" > "$file_path"
)

set_mode_hosts() {
    local mode_name=$1 session=$2 now=${3:-$(date +%s)} hosts_content
    hosts_content=$(filtered_mode_entries "$mode_name" hosts "$session" "$now" |
        awk '{print "0.0.0.0 " $0}') || return 1
    replace_in_markers "$HACK_HOSTS_FILE" PRIME_HOSTS "$hosts_content"
}

close_mode_apps() {
    local mode_name=$1 field=$2 session=$3 app
    while IFS= read -r app; do
        [[ -n $app ]] && close_app "$app"
    done < <(filtered_mode_entries "$mode_name" "$field" "$session")
    return 0
}

stop_legacy_workers() {
    # Retire only this project's old screen jobs, never pgrep/kill our callers.
    local screen_id
    while IFS= read -r screen_id; do
        # A legacy timer may be the caller migrating us to this runtime.
        [[ -n $screen_id && $screen_id != "${STY:-}" ]] && screen -S "$screen_id" -X quit
    done < <(screen -ls 2>/dev/null | awk '$1 ~ /^[0-9]+\.hackbrain___/ {print $1}')
    return 0
}

spawn_mode_worker() {
    local name="hackbrain_runtime_$2"
    if screen -ls 2>/dev/null | awk -v name="$name" '$1 ~ /^[0-9]+\./ {sub(/^[0-9]+\./, "", $1); if ($1 == name) found=1} END {exit !found}'; then
        return 0
    fi
    # A detached child must not inherit Linux's state-lock descriptor.
    screen -dmS "$name" "$BASH" "$script_path" enforce_mode "$1" "$2" 9>&-
}

activate_mode_locked() {
    local mode_name=$1 duration=$2 now session deadline tmp
    now=$(date +%s)
    session="$now-$BASHPID-$RANDOM"
    deadline=0
    (( duration > 0 )) && deadline=$((now + duration * 60))
    # Old grants cannot match this new activation, even for the same mode name.
    set_mode_hosts "$mode_name" "$session" "$now" || return 1
    tmp=$(mktemp "$HACK_STATE_DIR/.mode.XXXXXX") || return 1
    printf '%s\t%s\t%s\n' "$mode_name" "$session" "$deadline" > "$tmp"
    mv "$tmp" "$HACK_STATE_DIR/mode.tsv" || return 1
    : > "$HACK_STATE_DIR/allow.tsv"
    stop_legacy_workers
    spawn_mode_worker "$mode_name" "$session" || return 1
    close_mode_apps "$mode_name" closed_apps "$session"
}

execute_mode() {
    runtime_requirements || return 1
    runtime_locked activate_mode_locked "$1" "${2:--1}"
}

switch_to_default_mode_cli() {
    execute_mode "$default_mode" -1
}

switch_mode() {
    local mode_name=${1:-$default_mode} duration max_duration
    valid_mode "$mode_name" || { echo "Mode '$mode_name' does not exist." >&2; return 1; }
    local -n requested_mode=$mode_name
    duration=${2:-${requested_mode[default_duration]}}
    max_duration=${requested_mode[max_duration]}
    [[ $duration == -1 || $duration =~ ^[1-9][0-9]{0,8}$ ]] &&
        [[ $max_duration == -1 || $max_duration =~ ^[1-9][0-9]{0,8}$ ]] || {
        echo 'Duration must be positive whole minutes, or -1 for an unlimited mode.' >&2; return 1;
    }
    if (( max_duration > 0 && (duration == -1 || duration > max_duration) )); then
        duration=$max_duration
    fi
    runtime_requirements || return 1
    execute_function_string "${requested_mode[challenges]}" || {
        echo 'Challenges execution failed. Mode switch aborted.' >&2; return 1;
    }
    execute_mode "$mode_name" "$duration" || return 1
    if (( duration == -1 )); then
        echo "Switched to $mode_name mode indefinitely."
    else
        echo "Switched to $mode_name mode for $duration minutes."
    fi
}

switch_mode_cli() { switch_mode "$@"; }

list_modes_cli() {
    printf 'Available modes:\n'
    printf -- '- %s\n' "${modes[@]}"
}

print_mode_cli() {
    valid_mode "$1" || { echo "Mode '$1' does not exist." >&2; return 1; }
    print_mode "$1"
}

allow_matches() {
    local -n match_mode=$1
    local query=$2 field
    for field in hosts closed_apps suppressed_apps; do
        printf '%s\n' "${match_mode[$field]}" |
            HACK_ALLOW_QUERY="$query" awk -v field="$field" '
                {for (i=1; i<=NF; i++)
                    if (index(tolower($i), tolower(ENVIRON["HACK_ALLOW_QUERY"])))
                        print field ": " $i}'
    done
}

add_allow_locked() {
    local expected_session=$1 query=$2 minutes=$3 now expires tmp backup
    read_runtime_state && [[ $active_session == "$expected_session" ]] || {
        echo 'The mode changed during the challenge. Run hack allow again.' >&2; return 1;
    }
    now=$(date +%s)
    if (( mode_deadline > 0 && now >= mode_deadline )); then
        echo 'This mode has ended. Run hack allow again after the mode changes.' >&2; return 1
    fi
    # A saved mode can outlive its terminal or worker. Restore enforcement
    # before granting so a timer is always present to revoke this allowance.
    spawn_mode_worker "$active_mode" "$active_session" || return 1
    expires=$((now + minutes * 60))
    (( mode_deadline > 0 && expires > mode_deadline )) && expires=$mode_deadline
    tmp=$(mktemp "$HACK_STATE_DIR/.allow.XXXXXX") || return 1
    backup=$(mktemp "$HACK_STATE_DIR/.previous.XXXXXX") || { rm -f "$tmp"; return 1; }
    if ! cat "$HACK_STATE_DIR/allow.tsv" > "$backup" ||
       ! cat "$backup" > "$tmp" ||
       ! printf '%s\t%s\t%s\n' "$active_session" "$expires" "${query,,}" >> "$tmp"; then
        rm -f "$tmp" "$backup"
        return 1
    fi
    mv "$tmp" "$HACK_STATE_DIR/allow.tsv" || { rm -f "$backup"; return 1; }
    if ! set_mode_hosts "$active_mode" "$active_session" "$now"; then
        mv "$backup" "$HACK_STATE_DIR/allow.tsv"
        echo 'Could not apply hosts exceptions; grant cancelled.' >&2
        return 1
    fi
    rm -f "$backup"
    echo "Allowed '$query' for up to $minutes minutes, ending sooner if this mode ends."
}

allow_cli() {
    local query=${1-} minutes=${2:-$allow_default_duration} matches session
    [[ -n ${query//[[:space:]]/} && $query != *$'\t'* && $query != *$'\n'* && $query != *$'\r'* && $# -le 2 ]] || {
        echo 'Usage: hack allow <host-or-app-substring> [minutes]' >&2; return 1;
    }
    [[ $minutes =~ ^[1-9][0-9]{0,8}$ && $allow_max_duration =~ ^[1-9][0-9]{0,8}$ ]] &&
        (( minutes <= allow_max_duration )) || {
        echo "Allow duration must be between 1 and $allow_max_duration whole minutes." >&2; return 1;
    }
    read_runtime_state || { echo 'Activate a mode with hack switch first.' >&2; return 1; }
    session=$active_session
    matches=$(allow_matches "$active_mode" "$query")
    [[ -n $matches ]] || { echo "No blocked hosts or apps contain '$query'." >&2; return 1; }
    execute_function_string "$allow_challenges" || {
        echo 'Allow challenge failed. Nothing changed.' >&2; return 1;
    }
    runtime_locked add_allow_locked "$session" "$query" "$minutes"
}

status_cli() {
    read_runtime_state || { echo 'No recorded mode. Run hack switch to start enforcement.'; return 1; }
    printf 'Mode: %s\n' "$active_mode"
    local now row_session expires query
    now=$(date +%s)
    if (( mode_deadline > 0 )); then
        printf 'Mode time remaining: %s seconds\n' "$((mode_deadline > now ? mode_deadline-now : 0))"
    fi
    printf 'Active allows:\n'
    while IFS=$'\t' read -r row_session expires query; do
        if [[ $row_session == "$active_session" ]] && (( expires > now )); then
            printf '  %s (%s seconds remaining)\n' "$query" "$((expires-now))"
        fi
    done < "$HACK_STATE_DIR/allow.tsv"
}

# Run under the state lock; only the current activation can write hosts or kill
# apps. Deadlines use wall time, including time spent asleep.
enforce_tick_locked() {
    local session=$1 dirty=$2 last_patterns=$3 apps_due=$4 now patterns
    read_runtime_state && [[ $active_session == "$session" ]] || return 20
    now=$(date +%s)
    if (( mode_deadline > 0 && now >= mode_deadline )); then
        activate_mode_locked "$default_mode" -1 || return 1
        return 20
    fi
    patterns=$(active_allow_patterns "$session" "$now")
    if [[ $dirty == true || $patterns != "$last_patterns" ]]; then
        set_mode_hosts "$active_mode" "$session" "$now" || return 1
    fi
    [[ $apps_due == true ]] && close_mode_apps "$active_mode" suppressed_apps "$session"
    printf '%s' "$patterns"
}

enforce_mode_cli() (
    local mode_name=$1 session=$2 watch_dir watcher_pid event_fd event dirty=true
    local patterns='' next_patterns result now last_apps=0 apps_due hosts_parent state_parent
    valid_mode "$mode_name" || exit 1
    watch_dir=$(mktemp -d) || exit 1
    trap '[[ -n ${watcher_pid:-} ]] && kill "$watcher_pid" 2>/dev/null; [[ -n ${watcher_pid:-} ]] && wait "$watcher_pid" 2>/dev/null; rm -rf "$watch_dir"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mkfifo "$watch_dir/events" || exit 1
    exec {event_fd}<>"$watch_dir/events"
    hosts_parent=$(cd "$(dirname "$HACK_HOSTS_FILE")" && pwd -P) || exit 1
    state_parent=$(cd "$HACK_STATE_DIR" && pwd -P) || exit 1
    # Watch parents so editor rename/replacement saves remain visible. Ignore
    # lock/temp-file activity; those are not changes to the desired state.
    local hosts_basename=${HACK_HOSTS_FILE##*/} watch_pattern hosts_root_pattern state_root_pattern
    watch_pattern=$(printf '%s' "$hosts_basename" | sed 's/[][\.^$*+?(){}|\\]/\\&/g')
    hosts_root_pattern=$(printf '%s' "$hosts_parent" | sed 's/[][\.^$*+?(){}|\\]/\\&/g')
    state_root_pattern=$(printf '%s' "$state_parent" | sed 's/[][\.^$*+?(){}|\\]/\\&/g')
    # Older Linux inotify backends apply path filters before registering a
    # watch. Include the parent directories themselves, not just their files.
    # Ignore access/open events so reading hosts cannot trigger a busy loop.
    fswatch -o -l 0.2 -E -e '.*' -i "/($watch_pattern|mode\.tsv|allow\.tsv)$" \
        -i "^($hosts_root_pattern|$state_root_pattern)$" \
        --event=Updated --event=Created --event=Removed --event=Renamed \
        --event=MovedFrom --event=MovedTo --event=AttributeModified \
        "$hosts_parent" "$state_parent" > "$watch_dir/events" &
    watcher_pid=$!
    while true; do
        now=$(date +%s)
        apps_due=false
        (( now - last_apps >= 10 )) && apps_due=true
        next_patterns=$(runtime_locked enforce_tick_locked "$session" "$dirty" "$patterns" "$apps_due")
        result=$?
        (( result == 20 )) && exit 0
        if (( result == 0 )); then
            patterns=$next_patterns
            dirty=false
            [[ $apps_due == true ]] && last_apps=$now
        else
            log 'Enforcement failed; retrying in one second.'
            dirty=true
        fi
        if ! kill -0 "$watcher_pid" 2>/dev/null; then
            log 'fswatch stopped; enforcing once per second until restarted.'
            sleep 1
            dirty=true
        elif IFS= read -r -t 1 -u "$event_fd" event; then
            dirty=true
        fi
    done
)
