#!/bin/bash
set -e

# Change to the test directory
cd /test-install

# Keep the internal directory out of the testing
sed -i '/internal/d' Makefile

# Run the test
adduser --disabled-password --gecos "" documentdb
chown -R documentdb:documentdb .
# Pass PG bin dir on PATH so TAP tests can locate initdb under `su`.
su documentdb -c "PATH=\"$(pg_config --bindir):\$PATH\" make check"