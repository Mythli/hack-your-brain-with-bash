#!/usr/bin/env bash

# Prompt the user for a directory to clone the repository into
read -p "Enter the directory to clone into (Press enter to use: ~/.): " clone_dir

# Use the home directory as the default if no input is provided
clone_dir=${clone_dir:-~}

# Create the directory if it does not exist
mkdir -p "$clone_dir"

# Change to the specified directory
cd "$clone_dir" || { echo "Failed to change directory to $clone_dir"; exit 1; }

# Clone the repository
git clone git@github.com:Mythli/hack-your-brain-with-bash.git || { echo "Failed to clone repository"; exit 1; }

# Change to the repository directory
cd hack-your-brain-with-bash || { echo "Failed to change directory to the repository"; exit 1; }

# Make sure the install script is executable
chmod +x src/install.sh

# Run the install script
./src/install.sh || { echo "Failed to run install script"; exit 1; }

echo "Installation completed successfully."
