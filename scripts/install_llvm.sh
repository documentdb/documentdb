#!/bin/bash

# fail if trying to reference a variable that is not set.
set -u
# exit immediately if a command exits with a non-zero status
set -e

LLVM_VERSION=20

# apt.llvm.org lags new Ubuntu releases; when the running codename has no
# upstream repo yet, install the same LLVM major from the distro archive.
CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
if wget -q --spider "https://apt.llvm.org/$CODENAME/dists/llvm-toolchain-$CODENAME-$LLVM_VERSION/Release"; then
    wget https://apt.llvm.org/llvm.sh
    chmod +x ./llvm.sh
    sudo ./llvm.sh $LLVM_VERSION all
else
    sudo apt-get update
    sudo apt-get install -y clang-$LLVM_VERSION clang-tools-$LLVM_VERSION \
        llvm-$LLVM_VERSION lld-$LLVM_VERSION libclang-$LLVM_VERSION-dev
fi
sudo ln -s /usr/lib/llvm-$LLVM_VERSION/bin/clang-cl /usr/bin/clang-cl
sudo ln -s /usr/lib/llvm-$LLVM_VERSION/bin/llvm-lib /usr/bin/llvm-lib
sudo ln -s /usr/lib/llvm-$LLVM_VERSION/bin/lld-link /usr/bin/lld-link
sudo ln -s /usr/lib/llvm-$LLVM_VERSION/bin/llvm-ml /usr/bin/llvm-ml
sudo ln -s /usr/lib/llvm-$LLVM_VERSION/bin/ld.lld /usr/bin/ld.lld
sudo ln -s /usr/lib/llvm-$LLVM_VERSION/bin/clang /usr/bin/clang