#!/bin/bash

# Script to set up and use a specific Terraform version
# Created on: May 18, 2025

TERRAFORM_VERSION="1.5.7"
TERRAFORM_PATH="$HOME/.terraform_versions/terraform"

if [ ! -f "$TERRAFORM_PATH" ]; then
    echo "Error: Terraform binary not found at $TERRAFORM_PATH"
    exit 1
fi

# Create a symbolic link to the Terraform binary
if [ -f "$HOME/bin/terraform" ]; then
    echo "Removing existing Terraform symlink..."
    rm "$HOME/bin/terraform"
fi

# Create bin directory if it doesn't exist
mkdir -p "$HOME/bin"

# Create the new symlink
ln -s "$TERRAFORM_PATH" "$HOME/bin/terraform"

# Add to PATH if not already there
if [[ ":$PATH:" != *":$HOME/bin:"* ]]; then
    echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc"
    export PATH="$HOME/bin:$PATH"
    echo "Added $HOME/bin to PATH"
fi

# Verify the installation
echo "Terraform has been set up with version $TERRAFORM_VERSION:"
"$HOME/bin/terraform" version

echo "You may need to restart your shell or run 'source ~/.bashrc' for PATH changes to take effect."
echo "You can now use Terraform v$TERRAFORM_VERSION with your Terraform Enterprise backend."