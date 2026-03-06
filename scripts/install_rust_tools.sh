#!/bin/bash

set -euo pipefail

# Installs tools listed in the [tools] section of a rust-toolchain.toml file.
# Usage: install_rust_tools.sh [path/to/rust-toolchain.toml]
# Defaults to looking for rust-toolchain.toml in the current directory.

FILE="${1:-rust-toolchain.toml}"

if [ ! -f "$FILE" ]; then
  echo "::error::File $FILE not found."
  exit 1
fi

if ! grep -q '^\[tools\]' "$FILE"; then
  echo "::warning::[tools] section not found in $FILE."
  exit 1
fi

# Extract tools section from rust-toolchain.toml
sed -n '/\[tools\]/,/^$/p' "$FILE" | grep -v '\[tools\]' | while read -r line; do
  # Skip empty lines
  [ -z "$line" ] && continue

  # Extract tool name and clean it
  TOOL_NAME=${line%%=*}
  TOOL_NAME=${TOOL_NAME//[[:space:]]/}
  TOOL_NAME="${TOOL_NAME//$'\n'/}"

  # Extract tool version and clean it
  TOOL_VERSION=${line#*=}
  TOOL_VERSION=${TOOL_VERSION//[[:space:]]/}
  TOOL_VERSION=${TOOL_VERSION//\"/}
  TOOL_VERSION="${TOOL_VERSION//$'\n'/}"

  echo ""
  echo "##################################################################"
  echo "Installing $TOOL_NAME@$TOOL_VERSION"
  echo "##################################################################"
  echo ""

  # Check if the tool is already installed at the correct version
  if command -v "$TOOL_NAME" &> /dev/null && "$TOOL_NAME" --version 2>/dev/null | grep -q "$TOOL_VERSION"; then
    echo "$TOOL_NAME@$TOOL_VERSION is already installed, skipping"
  else
    echo "$TOOL_NAME not found or wrong version, installing from source..."
    cargo install --locked --force "$TOOL_NAME" --version "$TOOL_VERSION"
  fi
done
