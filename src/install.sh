#!/usr/bin/env bash

script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
parent_dir="$( cd "$script_dir/.." &> /dev/null && pwd )"

make_host_file_writeable() {
  local hosts_file="/etc/hosts"
  if [ -w "$hosts_file" ]; then
    echo "The current user can write to the hosts file."
  else
    echo "Write permission to the hosts file is mandatory."
    read -r -p "Do you want to grant write permission to the hosts file? (y/N) " response
    if [[ "$response" =~ ^[Yy]$ ]]; then
      case "$(uname -s)" in
        Linux)
          command -v setfacl >/dev/null || {
            echo "Install the acl package first (sudo apt-get install acl)." >&2
            return 1
          }
          sudo setfacl -m "u:$(id -un):rw" "$hosts_file" || return 1
          ;;
        Darwin)
          sudo chmod +a "$(id -un) allow read,write" "$hosts_file" || return 1
          ;;
        *) echo "Unsupported operating system." >&2; return 1 ;;
      esac
      echo "Write permission granted to the hosts file."
    else
      echo "Write permission not granted. Exiting."
      return 1
    fi
  fi
}

check_and_provide_install_commands() {
    local missing_tools=0
    local tools=(
        "bc"
        "awk"
        "sleep"
        "kill"
        "pgrep"
        "grep"
        "printf"
        "screen"
        "fswatch"
        "sed"
        "realpath"
        "ps"
    )

    # Check for Bash version 4.3 or higher (namerefs)
    if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
        echo "Error: Bash version 4.3 or higher is required." >&2
        missing_tools=1
    fi

    # Detect package manager and prepare installation commands
    local pkg_manager
    local bash_install_command
    if command -v apt-get &> /dev/null; then
        pkg_manager="sudo apt-get install"
        bash_install_command="sudo apt-get install --only-upgrade bash"
    elif command -v yum &> /dev/null; then
        pkg_manager="sudo yum install"
        bash_install_command="sudo yum update bash"
    elif command -v dnf &> /dev/null; then
        pkg_manager="sudo dnf install"
        bash_install_command="sudo dnf upgrade bash"
    elif command -v pacman &> /dev/null; then
        pkg_manager="sudo pacman -S"
        bash_install_command="sudo pacman -S bash"
    elif command -v zypper &> /dev/null; then
        pkg_manager="sudo zypper install"
        bash_install_command="sudo zypper up bash"
    elif command -v brew &> /dev/null; then
        pkg_manager="brew install"
        bash_install_command="brew install bash"
    else
        echo "Error: No known package manager found. Please install the missing tools manually." >&2
        return 1
    fi

    # Check for required tools
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            echo "Error: Required tool '$tool' is not installed." >&2
            echo "To install '$tool', run: $pkg_manager $tool" >&2
            missing_tools=1
        fi
    done

    if ! command -v flock &> /dev/null && ! command -v shlock &> /dev/null; then
        echo "Error: Runtime locking requires flock (util-linux) or macOS shlock." >&2
        missing_tools=1
    fi

    # If Bash is outdated, provide the installation or update command
    if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )) && [ -n "$bash_install_command" ]; then
        echo "To install or update Bash, run: $bash_install_command" >&2
    fi

    if [ "$missing_tools" -ne 0 ]; then
        echo "One or more required tools are missing or outdated." >&2
        return 1
    fi

    echo "All required tools are installed and Bash is up to date."
    return 0
}

detect_shell_config() {
  # Determine the operating system
  case "$(uname -s)" in
    Darwin)
      os="osx"
      ;;
    Linux)
      os="linux"
      ;;
    *)
      echo "Unsupported operating system."
      return 1
      ;;
  esac

  # Determine the shell and the corresponding config file
  case "$SHELL" in
    */zsh)
      echo "${HOME}/.zshrc"
      ;;
    */bash)
      if [ "$os" = "osx" ]; then
        echo "${HOME}/.bash_profile"
      else
        echo "${HOME}/.bashrc"
      fi
      ;;
    *)
      echo "Unsupported shell."
      return 1
      ;;
  esac
}

add_alias_to_config() {
  local script_path="$1"
  local script_name=$(basename "$script_path" .sh)  # Exclude the .sh extension
  local shell_config="$2"

  # Add the alias to the shell configuration file
  if [ -f "$shell_config" ]; then
    if ! grep -q "alias $script_name=" "$shell_config"; then
      local alias_command
      printf -v alias_command '%q %q' "$BASH" "$script_path"
      printf 'alias %s=%q\n' "$script_name" "$alias_command" >> "$shell_config" || return 1
      echo "Alias for $script_name added to $shell_config"
    else
      echo "Alias for $script_name already exists in $shell_config"
    fi
  else
    touch "$shell_config" || return 1
    add_alias_to_config "$script_path" "$shell_config"
  fi
}

source_shell_config() {
  local shell_config="$1"
  if [ -f "$shell_config" ]; then
    echo "Run 'source \"$shell_config\"' to make the alias available."
  else
    echo "Shell configuration file not found."
    return 1
  fi
}

add_alias() {
  local script_path="$1"
  local shell_config
  if shell_config=$(detect_shell_config); then
    add_alias_to_config "$script_path" "$shell_config" || return 1
    source_shell_config "$shell_config"
  else
    return 1
  fi
}

install() {
  if ! check_and_provide_install_commands; then
      return 1
  fi
  if [ ! -e "$parent_dir/hack.sh" ]; then
    cp "$parent_dir/hack.sample.sh" "$parent_dir/hack.sh" || return 1
  else
    echo "Keeping your existing hack.sh configuration."
  fi
  chmod +x "$parent_dir/hack.sh" || return 1
  make_host_file_writeable || return 1
  add_alias "$parent_dir/hack.sh" || return 1
  echo "Run hack edit to start hacking your brain!"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  install
fi
