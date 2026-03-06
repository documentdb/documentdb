# Makefile for pg_documentdb_gw

DOCDB_GW_DIR := $(dir $(realpath $(firstword $(MAKEFILE_LIST))))
OSS_SRC_DIR = $(DOCDB_GW_DIR)/../

.PHONY: notice all

all: notice

# Regenerate NOTICE file when Cargo.toml or Cargo.lock changes
NOTICE: Cargo.toml Cargo.lock
	$(OSS_SRC_DIR)/scripts/generate_notice.sh -d $(DOCDB_GW_DIR) -o $(DOCDB_GW_DIR)/NOTICE

notice: NOTICE
