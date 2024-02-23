#!/usr/bin/env bash

log() {
        local message="$1"
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

        # Log the message with a timestamp to the console
        #echo "${timestamp} ${message}"

        # Log the message with a timestamp to the debug.log file
        echo "${timestamp} ${message}" >> "${log_file}"
}

log "log initialised"

print_mode() {
        local -n mode=$1
        echo "Mode: $1"
        for key in "${!mode[@]}"; do
                echo "$key: ${mode[$key]}"
        done
        echo
}

random_number() {
        min=$1
        max=$2
        seed=$RANDOM$RANDOM
        awk -v min="$min" -v max="$max" -v seed="$seed" 'BEGIN{srand(seed); print int(min+rand()*(max-min+1))}'
}

generate_math_challenge() {
        local digits=${1:-2}  # Default to 2 digits if not specified
        local tries=${2:-3}   # Default to 3 tries if not specified
        local operator=$3

        # Ensure the number of tries is a positive integer
        if ! [[ "$tries" =~ ^[1-9][0-9]*$ ]]; then
                echo "Error: Number of tries must be a positive integer."
                return 1
        fi

        # If no operator is specified, pick an operator at random
        if [[ -z "$operator" ]]; then
                echo "Error: operator must be specified."
                return 1
        fi

        # Generate random numbers based on the number of digits
        local min=$((10**(digits - 1)))
        local max=$((10**digits - 1))
        local num1=$(random_number $min $max)
        local num2=$(random_number $min $max)

        # Avoid division by zero
        if [[ "$operator" == "/" ]]; then
                while [[ $num2 -eq 0 ]]; do
                        num2=$(random_number $min $max)
                done
        fi

        # Calculate the correct answer
        local correct_answer=$(echo "scale=2; $num1 $operator $num2" | bc -l | awk '{printf "%.2f", $0}')

        # Present the challenge to the user and check for correct answer
        local user_answer
        local attempt=1
        echo "Solve the following math problem:"
        echo "$num1 $operator $num2 = ?"
        while [[ $attempt -le $tries ]]; do
                read -p "Attempt $attempt/$tries: " user_answer
                # Check if user answer is numeric
                if ! [[ "$user_answer" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
                        echo "Please enter a valid numeric answer."
                        ((attempt++))
                        continue
                fi
                # Normalize user answer for comparison
                user_answer=$(echo "$user_answer" | awk '{printf "%.2f", $0}')
                if (( $(echo "$user_answer == $correct_answer" | bc -l) )); then
                        echo "Correct! Well done."
                        return 0
                else
                        echo "Incorrect. Try again."
                fi
                ((attempt++))
        done

        echo "The correct answer was $correct_answer. Better luck next time!"
        return 1
}

do_stuff() {
        if [ -z "$1" ]; then
                echo "Error: The first parameter (question) is required."
                return 1
        fi

        local question=$1
        local timer
        local follow_up_question
        local expected_answer
        local answer

        while true; do
                timer=${2:-0}
                follow_up_question=${3:-"Did you do ${question//\?/}?"}
                expected_answer=${4:-"y"}

                # Ask the initial question
                echo "$question"

                # If a timer is provided, count down
                if [ "$timer" -gt 0 ]; then
                        while [ "$timer" -gt 0 ]; do
                                echo -ne "You have $timer seconds left...\033[0K\r"
                                sleep 1
                                ((timer--))
                        done
                        echo -ne "\033[0K\r" # Clear the line
                fi

                # Ask the follow-up question and wait for the correct response
                read -p "$follow_up_question " answer
                if [ "$answer" = "$expected_answer" ] || ([ "$expected_answer" = "y" ] && [ "$answer" = "yes" ]); then
                        echo "Great job!"
                        break
                else
                        echo "Incorrect response, let's start over."
                fi
        done
}

complete_mantra() {
        local num_words=$1    # Number of words to pick
        local -a mantras=("${@:2}") # Reconstruct the array of mantras

        # Pick a random mantra from the array
        local random_index=$(random_number 0 $((${#mantras[@]} - 1)))
        local selected_mantra="${mantras[$random_index]}"

        # Function to pick random words from the mantra in the original order
        pick_random_words() {
                local -a words=($1)
                local -a selected_words=()
                local word_count=$2
                local max_start_index=$((${#words[@]} - word_count))
                local start_index=$(random_number 0 $max_start_index)
                selected_words=("${words[@]:$start_index:$word_count}")
                echo "${selected_words[@]}"
        }

        # Main loop
        while true; do
                # Pick random words from the selected mantra
                local random_words=$(pick_random_words "$selected_mantra" $num_words)
                echo "Complete the mantra: $random_words"

                # Read user input
                read -p "Type the full mantra. If you dont know it, just press enter to get another hint. " user_input

                # Check if the user input matches the selected mantra
                if [[ "$user_input" == "$selected_mantra" ]]; then
                        echo "Correct!"
                        break
                else
                        echo "Incorrect. Let's try with more words."
                        num_words=$((num_words *2))
                        if [ $num_words -gt $(wc -w <<< "$selected_mantra") ]; then
                                num_words=$(wc -w <<< "$selected_mantra")
                        fi
                fi
        done
}

execute_functions() {
        local func_name
        local -a func_list=("$@") # Capture all arguments into an array

        for func_name in "${func_list[@]}"; do
                if ! command -v "$func_name" &> /dev/null; then
                        echo "Function $func_name does not exist."
                        return 1
                fi

                if ! "$func_name"; then
                        echo "Function $func_name returned non-zero status."
                        return 1
                fi
        done
}

pick_random_words() {
    local input_string="$1"
    local number_of_words="$2"
    local -a words=($input_string) # Split input string into an array
    local -a selected_words=()
    local word_count=${#words[@]}
    local random_index
    local i

    for (( i=0; i<number_of_words; i++ )); do
        random_index=$(random_number 0 $((word_count-1)))
        selected_words+=("${words[$random_index]}")
    done

    # Join the selected words into a string
    local result=$(IFS=" "; echo "${selected_words[*]}")
    echo "$result"
}

execute_function_string() {
        local function_string="$1"
        IFS=' ' read -r -a function_array <<< "$function_string" # Split string into array
        execute_functions "${function_array[@]}"
}

close_app() {
    local app="$1"
    log "looking for $app to close it asap"

    local own_pid=$$
    local pids=$(pgrep -i -f "$app" | grep -v $own_pid)

    log "Closing ($pids)"

    if [ -n "$pids" ]; then
        # First loop for graceful killing
        for pid in $pids; do
            if [ "$pid" != "$own_pid" ] && kill -0 $pid 2>/dev/null; then
                log "Attempting to close PID $pid of $app gracefully..."
                kill -15 $pid 2>/dev/null
            fi
        done

        # Wait for 100ms
        sleep 0.1

        # Second loop for forceful killing
        for pid in $pids; do
            if [ "$pid" != "$own_pid" ] && kill -0 $pid 2>/dev/null; then
                log "PID $pid of $app did not close gracefully, forcing shutdown..."
                kill -9 $pid 2>/dev/null
            else
                log "PID $pid of $app closed successfully."
            fi
        done
    fi
}

close_mode_apps() {
        local mode_name=$1
        local -n mode=$mode_name
        local app
        for app in ${mode[$2]}; do
                close_app "$app"
        done
}

suppress_mode_apps_cli() {
        local mode_name=$1
        while true; do
                close_mode_apps "$mode_name" "suppressed_apps"
                sleep 10
        done
}

replace_in_markers() {
    local file_path="$1"
    local marker="$2"
    local content="$3"
    local start_marker="START ${marker}"
    local end_marker="END ${marker}"
    local in_block=false
    local new_content=()

    # Check if the file exists
    if [ ! -f "$file_path" ]; then
        echo "Error: File does not exist."
        return 1
    fi

    # Read the file line by line and construct new content
    while IFS= read -r line; do
        if [[ $line == "$start_marker" ]]; then
            in_block=true
            new_content+=("$line")
            new_content+=("$content")
        elif [[ $line == "$end_marker" ]]; then
            in_block=false
            new_content+=("$line")
        else
            if ! $in_block; then
                new_content+=("$line")
            fi
        fi
    done < "$file_path"

    # Check if the markers were found, if not, append them
    if ! grep -q "$start_marker" "$file_path"; then
        new_content+=("$start_marker")
        new_content+=("$content")
    fi
    if ! grep -q "$end_marker" "$file_path"; then
        new_content+=("$end_marker")
    fi

    # Overwrite the file with the new content
    printf "%s\n" "${new_content[@]}" > "$file_path"
}

set_mode_hosts() {
        local mode_name=$1
        local -n mode=$mode_name
        local hosts_content=""

        log "$(cat /etc/hosts)"

        # Build the content for the PRIME section of the hosts file
        for host in ${mode[hosts]}; do
                hosts_content+="0.0.0.0 $host"$'\n'
        done

        # Call set_hosts_section with the new content
        replace_in_markers "/etc/hosts" "PRIME_HOSTS" "$hosts_content"
}

suppress_mode_hosts_cli() {
        local mode_name=$1
        while true; do
                set_mode_hosts "$mode_name"
                sleep 10
        done
}

spawn_suppress_mode_apps() {
        log "spawn_suppress_mode_apps"

        local mode_name=$1
        # Start a background process using screen to suppress hosts for the given mode
        screen -dmS "hackbrain___suppress_apps_$mode_name" bash -c "$script_path suppress_mode_apps $mode_name"
}

spawn_suppress_mode_hosts() {
        local mode_name=$1
        set_mode_hosts "$mode_name"
}

execute_mode() {
        log "execute_mode $1"

        local mode_name=$1
        local -n mode=$mode_name
        reset_modes

        log "execute_mode close_mode_apps"
        close_mode_apps "$mode_name" "closed_apps"

        if [ -n "${mode[suppressed_apps]}" ]; then
                spawn_suppress_mode_apps "$mode_name"
                log "spawned spawn_suppress_mode_apps"
        fi
        if [ -n "${mode[hosts]}" ]; then
                spawn_suppress_mode_hosts "$mode_name"
                log "spawned spawn_suppress_mode_hosts"
        fi
}

reset_modes() {
        # Kill all processes
        close_app "$script_path"
        close_app "hackbrain___"
}

# Function to list all available modes
list_modes_cli() {
        echo "Available modes:"
        for mode_name in "${modes[@]}"; do
                echo "- $mode_name"
        done
}

# Function to print a specific mode
print_mode_cli() {
        local mode_name=$1
        local -n mode_ref=$mode_name # Use a name reference to the associative array
        if declare -p mode_ref &> /dev/null; then
                print_mode "$mode_name"
        else
                echo "Mode '$mode_name' does not exist."
        fi
}

spawn_command_in_minutes() {
    local minutes=$1
    local command=$2
    local end_time=$(( $(date +%s) + minutes * 60 ))

    log "Executing $command in $minutes minutes."

    # Start a background process using screen to execute the command after the delay
    screen -dmS "hackbrain___delayed_command" bash -c " \
    while [ \$(date +%s) -lt $end_time ]; do \
        sleep 10; \
    done; \
    $command"
}

spawn_switch_to_default_mode_in_minutes() {
    local current_mode=$1
    local minutes=$2

    # Check if we are already in the default mode, do nothing if true
    if [ "$current_mode" = "$default_mode" ]; then
        log "spawn_switch_to_default_mode_in_minutes we are in default mode so we are doing nothing here"
        return
    fi

    spawn_command_in_minutes "$minutes" "$script_path switch_to_default_mode"
}

switch_to_default_mode_cli() {
        log "switch_to_default_mode_cli switching to $default_mode"
        execute_mode $default_mode
}

# Function to switch to a specific mode
switch_mode() {
    local mode_name=${1:-$default_mode}
    local -n mode_ref=$mode_name
    local duration=${2:-${mode_ref[default_duration]}}

    if declare -p mode_ref &> /dev/null; then
        if [[ $duration -eq -1 ]] || ([[ $duration -gt 0 ]] && [[ $duration -le ${mode_ref[max_duration]} ]]); then
            if execute_function_string "${mode_ref[challenges]}"; then
                execute_mode $mode_name

                if [[ $duration -eq -1 ]]; then
                    echo "Switched to $mode_name mode indefinitely..."
                else
                    echo "Switched to $mode_name mode for $duration minutes..."
                    spawn_switch_to_default_mode_in_minutes $mode_name $duration
                fi
            else
                echo "Challenges execution failed. Mode switch aborted."
            fi
        else
            echo "Invalid duration. Please specify a duration of -1 or between 1 and ${mode_ref[max_duration]} minutes."
        fi
    else
        echo "Mode '$mode_name' does not exist."
    fi
}

switch_mode_cli() {
        local mode_name=$1
        local duration=$2
        switch_mode "$mode_name" "$duration"
}

# Function to edit the script
edit_script_cli() {
        local editors=("subl" "vim" "vi" "emacs")
        for editor in "${editors[@]}"; do
                if command -v "$editor" "$script_dir/hack.sh" &> /dev/null; then
                        "$editor" "$0"
                        return
                fi
        done
        echo "No suitable editor found. Please install one of the following: ${editors[*]}"
}

test_cli() {
        echo "127.0.0.1 localhost" > /etc/hosts
        set_mode_hosts "clear"
        cat /etc/hosts
}

test_system() {
  if [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
      echo "Bash version 4 or higher is required."
      exit 1
  fi
}

download_and_sanitise_hosts_cli() {
  if [ $# -ne 2 ]; then
    echo "Usage: $0 url output_file"
    return 1
  fi

  local url="$1"
  local output_file="$2"
  local tmp_file=$(mktemp)

  # Download the content to a temporary file
  if ! curl -o "$tmp_file" -s "$url"; then
    echo "Failed to download the file from $url"
    return 1
  fi

  # Sanitize the hosts and save to the output file
  awk '/^0\.0\.0\.0/ {print $2}' "$tmp_file" | tr '\n' ' ' > "$output_file"
  echo >> "$output_file" # Add a newline at the end of the file

  # Clean up the temporary file
  rm "$tmp_file"
}
# Main CLI logic
main() {
    test_system

    local command=$1

    case "$command" in
        switch)
            if [[ -z "$2" ]]; then
                echo "Usage: $0 switch [mode_name] [duration]"
                echo "  mode_name - The name of the mode to switch to."
                echo "  duration - Optional duration in minutes for the mode to be active."
                return
            fi
            switch_mode_cli "$2" "$3"
            ;;
        list)
            list_modes_cli
            ;;
        print)
            if [[ -z "$2" ]]; then
                echo "Usage: $0 print [mode_name]"
                echo "  mode_name - The name of the mode to print."
                return
            fi
            print_mode_cli "$2"
            ;;
        edit)
            edit_script_cli
            ;;
        *)
            echo "Invalid command: $command"
            echo "Usage: $0 {switch|list|print|edit} [options]"
            echo "Commands:"
            echo "  switch [mode_name] [duration] - Switch to a specific mode with an optional duration."
            echo "  list - List all available modes."
            echo "  print [mode_name] - Print the configuration of a specific mode."
            echo "  hack - hack the script using a suitable text editor."
            ;;
    esac
}
