#!/bin/bash

# fail if trying to reference a variable that is not set.
set -u
# exit immediately if a command exits with a non-zero status
set -e

curl https://sh.rustup.rs -sSf | bash -s -- -y --no-modify-path --default-toolchain none
. "$CARGO_HOME/env" && rustup show
