# Delegate all rules to sub directories.

Makefile:;

.DEFAULT_GOAL := .DEFAULT

.PHONY: %

notice:
	$(MAKE) -C pg_documentdb_gw notice

check-no-distributed:
	$(MAKE) -C pg_documentdb_core check
	$(MAKE) -C pg_documentdb check

install-no-distributed: install-documentdb

install-documentdb:
	$(MAKE) -C pg_documentdb_core install
	$(MAKE) -C pg_documentdb install
	$(MAKE) -C pg_documentdb_extended_rum install

.DEFAULT:
	$(MAKE) -C pg_documentdb_core
	$(MAKE) -C pg_documentdb
	$(MAKE) -C pg_documentdb_extended_rum
	$(MAKE) -C internal/pg_documentdb_distributed

%:
	$(MAKE) -C pg_documentdb_core $@
	$(MAKE) -C pg_documentdb $@
	$(MAKE) -C pg_documentdb_extended_rum $@
	$(MAKE) -C internal/pg_documentdb_distributed $@