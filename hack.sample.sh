#!/usr/bin/env bash

declare -g script_path=$(realpath "$0")
declare -g script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
declare -g log_file="${script_dir}/.prime.debug.log"

################## DEFINE YOUR MODES HERE ##################
# Modes are predefined sets of configurations that determine the behavior of the script when activated.
# Each mode is an associative array with the following keys:
# - default_duration: The default time in minutes the mode will be active.
# - max_duration: The maximum time in minutes the mode can be active.
# - hosts: A list of domain names to be blocked in the hosts file.
# - closed_apps: A list of applications to be closed when the mode is activated.
# - suppressed_apps: A list of applications to be continuously suppressed (closed if opened) while the mode is active.
# - challenges: A list of challenges to be completed before the mode is activated.
#
# The default_mode is the mode that the system will revert to after a specified duration or when manually triggered.

declare -g  modes=("clear" "work" "zen", "news")
declare -g default_mode="zen"

declare -gA clear=(
        [default_duration]=10
        [max_duration]=15
        [hosts]=""
        [closed_apps]=""
        [suppressed_apps]=""
        [challenges]=""
        [closed_apps]="chrome.app"
        [challenges]="mantra2 pushups addition4 plank"
)

declare -gA news=(
        [default_duration]=10
        [max_duration]=20
        [closed_apps]="${clear[closed_apps]}"
        [hosts]="$(cat "$script_dir/hosts/porn") app.tandem.net tinder.com etl.tindersparks.com"
        [suppressed_apps]=""
        [challenges]="mantra1 addition2 pushups"
        # [challenges]="addition1"
)

declare -gA work=(
        [default_duration]=-1
        [max_duration]=60
        [closed_apps]="${clear[closed_apps]}"
        [hosts]="${news[hosts]} $(cat "$script_dir/hosts/social") www.understandingwar.org app.tandem.net nachdenkseiten.de golem.de heise.de news.ycombinator.com"
        [suppressed_apps]="telegram whatsapp viber"
        [challenges]="addition3 pushups"
)

declare -gA zen=(
        [default_duration]=-1
        [max_duration]=-1
        [closed_apps]="${clear[closed_apps]}"
        [suppressed_apps]="${news[suppressed_apps]} slack discord mattermost"
        [hosts]="${work[hosts]} mail.google.com"
        [challenges]=""
)

################## DEFINE YOUR MANTRAS HERE ##################
# Define your mantras here. Mantras are motivational phrases that can be used as part of challenges. When a mantra challenge is activated,
# the user must complete the mantra by typing it out.

mantras=(
        "Work as hard as Elon Musk"
        "What would a succesful entrepreneur do?"
        "What would Elon Musk do?"
        "What would a succesful weight lifter do?"
        "Increase friction of bad habits"
        "Make good habits easier"
        "I have a clear plan of the day"
        "I love Anna wholeheartedly"
)

################## DEFINE YOUR CHALLENGES HERE ##################
# Challenges can include math problems, physical exercises, or reciting mantras. Customize challenges to fit your goals and preferences.


# The mantra function presents the user with a challenge to complete a mantra by typing it out.
# It selects 4 random words from the mantra and asks the user to type the full mantra.
mantra() {
        complete_mantra 2 "${mantras[@]}"
}

# The mantra2 function is similar to the mantra function but repeats the challenge twice.
mantra2() {
        complete_mantra 2 "${mantras[@]}"
        complete_mantra 2 "${mantras[@]}"
}

# The mantra3 function is similar to the mantra function but repeats the challenge three times.
mantra3() {
        complete_mantra 2 "${mantras[@]}"
        complete_mantra 2 "${mantras[@]}"
        complete_mantra 2 "${mantras[@]}"
}

# The addition1 function presents the user with a math challenge to solve an addition problem with 1-digit numbers.
addition1() {
        generate_math_challenge 1 3 "+"
}

# The addition2 function presents the user with a math challenge to solve an addition problem with 2-digit numbers.
addition2() {
        generate_math_challenge 2 3 "+"
}

# The addition3 function presents the user with a math challenge to solve an addition problem with 3-digit numbers.
addition3() {
        generate_math_challenge 3 3 "+"
}

# The addition4 function presents the user with a math challenge to solve an addition problem with 4-digit numbers.
addition4() {
        generate_math_challenge 4 3 "+"
}

# The pushups function presents the user with a physical challenge to do 10 push-ups within a 30-second timer.
pushups() {
        do_stuff "Do 10 push ups" 30
}

# The plank function presents the user with a physical challenge to do 1 minute of planking with a 75-second timer.
plank() {
        do_stuff "Do 1 minute of planking" 75
}

################## END DEFINE YOUR CHALLENGES ##################

source "$script_dir/src/main.sh"
main "$@"

