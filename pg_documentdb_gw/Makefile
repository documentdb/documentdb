# Makefile for pg_documentdb_gw

DOCDB_GW_DIR := $(dir $(realpath $(firstword $(MAKEFILE_LIST))))
OSS_SRC_DIR = $(DOCDB_GW_DIR)/../
DOCDB_CORE_DIR = $(OSS_SRC_DIR)/pg_documentdb_core/

.PHONY: notice all generate_external_error_mapping_file

all: notice

# Regenerate NOTICE file when Cargo.toml or Cargo.lock changes
NOTICE: Cargo.toml Cargo.lock
	$(OSS_SRC_DIR)/scripts/generate_notice.sh -d $(DOCDB_GW_DIR)/documentdb_gateway_core -o $(DOCDB_GW_DIR)/NOTICE

notice: NOTICE

generate_external_error_mapping_file: $(OSS_SRC_DIR)/scripts/generate_external_error_mapping_file.sh $(OSS_SRC_DIR)/error_mappings.csv $(DOCDB_GW_DIR)/include/core_postgres_error_mappings.csv $(DOCDB_CORE_DIR)include/utils/documentdb_codes.txt
	$(MAKE) -C $(DOCDB_CORE_DIR) generate_extension_errors
	$(OSS_SRC_DIR)/scripts/generate_external_error_mapping_file.sh $(DOCDB_CORE_DIR)include/utils/documentdb_codes.txt $(OSS_SRC_DIR)/error_mappings.csv \
		$(DOCDB_GW_DIR)/include/core_postgres_error_mappings.csv $(DOCDB_GW_DIR)/include/all_error_mappings_oss_generated.csv
