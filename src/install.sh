#!/usr/bin/env bash

declare -g script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
declare -g parent_dir="$( cd "$script_dir/.." &> /dev/null && pwd )"
declare -g script_path=$(realpath "$0")

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
        "sed"
    )

    # Check for Bash version 4 or higher
    if [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
        echo "Error: Bash version 4 or higher is required." >&2
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

    # If Bash is outdated, provide the installation or update command
    if [ "${BASH_VERSINFO:-0}" -lt 4 ] && [ -n "$bash_install_command" ]; then
        echo "To install or update Bash, run: $bash_install_command" >&2
    fi

    if [ "$missing_tools" -ne 0 ]; then
        echo "One or more required tools are missing or outdated." >&2
        return 1
    fi

    echo "All required tools are installed and Bash is up to date."
    return 0
}

# Example usage:
if ! check_and_provide_install_commands; then
    exit 1
fi

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
      echo "alias $script_name='$script_path'" >> "$shell_config"
      echo "Alias for $script_name added to $shell_config"
    else
      echo "Alias for $script_name already exists in $shell_config"
    fi
  else
    echo "Shell configuration file not found."
    return 1
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
  local shell_config=$(detect_shell_config)
  if [ $? -eq 0 ]; then
    add_alias_to_config "$script_path" "$shell_config"
    source_shell_config "$shell_config"
  fi
}

install() {
  cp "$parent_dir/hack.sample.sh" "$parent_dir/hack.sh"
  chmod +x "$parent_dir/hack.sh"
  add_alias "$parent_dir/hack.sh"
  echo "Run hack edit to start hacking your brain!"
}

install
