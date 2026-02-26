
BASEPATH:=../../../
OSS_SRC_DIR:=$(BASEPATH)../../

REGRESS := 1

PG_CONFIG ?= pg_config

# export pg_config for child make commands (check etc)
export PG_CONFIG

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

pg_major_version := $(shell $(PG_CONFIG) --version | awk -F' ' '{ print $$2 }' | awk -F'.' '{ print $$1 }')

EXTENSIONLOAD :=  --load-extension=tsm_system_rows --load-extension=pg_cron --load-extension=vector --load-extension=postgis --load-extension citus  --load-extension=documentdb_core --load-extension=documentdb --load-extension=documentdb_distributed --load-extension documentdb_extended_rum

MAKEFILE_DIR := $(dir $(realpath $(firstword $(MAKEFILE_LIST))))
export PATH := $(MAKEFILE_DIR)bin:$(PATH)
export PG_REGRESS_DIFF_OPTS = -dU10

export PGISOLATIONTIMEOUT = 60

.PHONY: check-basic check-dist-minimal

# Helper to run a multinode test suite: start cluster -> run tests -> stop cluster
define run_multinode_test
	$(OSS_SRC_DIR)scripts/start_oss_server.sh -c -x -r -n 1 -w 5808 -p 58070 -d ./tmp/multinode/data -f $(CURDIR)/regression_opts.conf -l $(CURDIR)/log/pglog_multinode.log
	{ $(top_builddir)/src/test/regress/pg_regress --port 58070 --encoding=UTF8 --dlpath=$(BASEPATH) --use-existing --dbname=postgres $(1) $(2) 2>&1; echo $$? > log/.exitcode; } | tee log/summary.out;
	exitcode=$$(cat log/.exitcode); \
	if test $$exitcode -ne 0; then \
		$(OSS_SRC_DIR)scripts/start_oss_server.sh -s -x -r -n 1 -w 5808 -p 58070 -d ./tmp/multinode/data; \
		cat regression.diffs; \
		false; \
	else \
		$(OSS_SRC_DIR)scripts/start_oss_server.sh -s -x -r -n 1 -w 5808 -p 58070 -d ./tmp/multinode/data; \
	fi
endef

define common_test
	mkdir -p log && { $(top_builddir)/src/test/regress/pg_regress --encoding=UTF8 --dlpath=$(BASEPATH) $(EXTENSIONLOAD) --temp-instance ./tmp --temp-config ./postgresql.conf --host localhost --port 58070 $(1) $(2) 2>&1; echo $$? > log/.exitcode; } | tee log/summary.out; test $$(cat log/.exitcode) -eq 0 || (cat regression.diffs && false)
endef

define isolation_test
	mkdir -p log && { $(top_builddir)/src/test/isolation/pg_isolation_regress --encoding=UTF8 --dlpath=$(BASEPATH) $(EXTENSIONLOAD) --temp-instance ./tmp --temp-config ./isolation_postgresql.conf --host localhost --port 58071 $(1) $(2) 2>&1; echo $$? > log/.exitcode; } | tee log/summary.out; test $$(cat log/.exitcode) -eq 0 || (cat regression.diffs && false)
endef

define rbac_test
	$(top_builddir)/src/test/regress/pg_regress --encoding=UTF8 --dlpath=$(BASEPATH) $(EXTENSIONLOAD) --temp-instance ./tmp --temp-config=./postgresql.conf --temp-config=./rbac_postgresql.conf --host localhost --port 58080 $(1) $(2) || (cat regression.diffs && false)
endef

check-basic: generate_version_schedule
	$(call common_test,--schedule=./basic_schedule --schedule=./log/basic_schedule_$(pg_major_version))

check-dist-minimal:
	$(call common_test,--schedule=./minimal_schedule, $(EXTRA_TESTS))

check-test-output:
	./validate_test_output.sh $(pg_major_version)

check-rbac-minimal:
	$(call rbac_test,--schedule=./rbac_minimal_schedule, $(EXTRA_TESTS),)

check-rbac:
	$(call rbac_test,--schedule=./rbac_minimal_schedule --schedule=./rbac_tests_schedule,,)

generate_version_schedule:
	@mkdir -p log
	@cp basic_schedule_core log/basic_schedule_$(pg_major_version)
	@cp basic_multinode_schedule_core log/basic_multinode_schedule_$(pg_major_version)
	@./mutate_schedule.sh log/basic_schedule_$(pg_major_version) $(pg_major_version)
	@./mutate_schedule.sh log/basic_multinode_schedule_$(pg_major_version) $(pg_major_version)

# Ensure nested results directories exist for multinode schedules
prepare_multinode_dirs:
	@mkdir -p results/multinode
	@mkdir -p expected/multinode
	@mkdir -p ./tmp/multinode/data

INSTALL_PG_PORT ?= 5432

define install_check_common
	mkdir -p log && { $(top_builddir)/src/test/regress/pg_regress --port $(INSTALL_PG_PORT) --encoding=UTF8 --dlpath=$(BASEPATH) --use-existing --dbname=postgres $(1) $(2) 2>&1; echo $$? > log/.exitcode; } | tee log/summary.out; test $$(cat log/.exitcode) -eq 0 || (cat regression.diffs && false)
endef

installcheck: generate_version_schedule
	$(call install_check_common,--schedule=./install_schedule --schedule=./log/basic_schedule_$(pg_major_version))

installcheck-minimal:
	$(call install_check_common,--schedule=./install_schedule, $(EXTRA_TESTS))

check-multinode: prepare_multinode_dirs generate_version_schedule
	$(call run_multinode_test,--schedule=./multinode_install_schedule --schedule=./log/basic_multinode_schedule_$(pg_major_version))

check-multinode-minimal: prepare_multinode_dirs
	$(call run_multinode_test,--schedule=./multinode_install_schedule, $(EXTRA_TESTS))

all: check-basic check-rbac check-multinode check-test-output
