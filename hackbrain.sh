#!/usr/bin/env bash

declare -g script_path=$(realpath "$0")
declare -g script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
declare -g log_file="${script_dir}/.prime.debug.log"

################## DEFINE YOUR MODES HERE ##################

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
        [hosts]="app.tandem.net tinder.com etl.tindersparks.com"
        [suppressed_apps]=""
        [challenges]="mantra2 pushups"
        # [challenges]="addition1"
)

declare -gA work=(
        [default_duration]=-1
        [max_duration]=60
        [closed_apps]="${clear[closed_apps]}"
        [hosts]="${news[hosts]} twitter.com www.youtube.com api.gotinder.com www.understandingwar.org www.anti-spiegel.ru app.tandem.net nachdenkseiten.de golem.de heise.de youtube.de youtube.com news.ycombinator.com"
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

mantra() {
        complete_mantra 4 "${mantras[@]}"
}

mantra2() {
        complete_mantra 4 "${mantras[@]}"
        complete_mantra 4 "${mantras[@]}"
}

mantra3() {
        complete_mantra 4 "${mantras[@]}"
        complete_mantra 4 "${mantras[@]}"
        complete_mantra 4 "${mantras[@]}"
}

addition1() {
        generate_math_challenge 1 3 "+"
}

addition2() {
        generate_math_challenge 2 3 "+"
}

addition3() {
        generate_math_challenge 3 3 "+"
}

addition4() {
        generate_math_challenge 4 3 "+"
}

pushups() {
        do_stuff "Do 10 push ups" 30
}

plank() {
        do_stuff "Do 1 minute of planking" 75
}

################## END DEFINE YOUR CHALLENGES ##################

source "$script_dir/src/main.sh"
main "$@"

