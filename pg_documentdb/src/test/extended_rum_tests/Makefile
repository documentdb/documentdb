
BASEPATH:=../../../

REGRESS := 1

PG_CONFIG ?= pg_config

# export pg_config for child make commands (check etc)
export PG_CONFIG

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

pg_major_version := $(shell $(PG_CONFIG) --version | awk -F' ' '{ print $$2 }' | awk -F'.' '{ print $$1 }' | awk -F'r' '{ print $$1 }')

EXTENSIONLOAD :=  --load-extension=tsm_system_rows --load-extension=pg_cron --load-extension=pageinspect --load-extension=vector --load-extension=postgis --load-extension=documentdb_core --load-extension=documentdb --load-extension=documentdb_extended_rum

MAKEFILE_DIR := $(dir $(realpath $(firstword $(MAKEFILE_LIST))))
export PATH := $(MAKEFILE_DIR)/../regress/bin:$(PATH)
export PG_REGRESS_DIFF_OPTS = -dU10

# When RUM_USE_BUILTIN_RMGR=yes, run the suite against the regular (side-by-side)
# extended_rum build but with the built-in rmgr core module selected at runtime
# via an additional temp-config layered on top of postgresql.conf. The full suite
# runs in this mode with no schedule exclusions (mutate_schedule.sh applies any
# version- or mode-specific mutations if present; see generate_version_schedule).
BUILTIN_RMGR_TEMP_CONFIG_OPTION = --temp-config ./postgresql_builtin_rmgr.conf
BUILTIN_RMGR_TEMP_CONFIG :=
ifeq ($(RUM_USE_BUILTIN_RMGR),yes)
    BUILTIN_RMGR_TEMP_CONFIG := $(BUILTIN_RMGR_TEMP_CONFIG_OPTION)
endif

.PHONY: check-basic check-minimal check-builtin-rmgr-minimal check-rum-builtin-rmgr

define common_test
	mkdir -p log && { $(top_builddir)/src/test/regress/pg_regress --encoding=UTF8 --dlpath=$(BASEPATH) $(EXTENSIONLOAD) --temp-instance ./tmp --temp-config ./postgresql.conf $(4) --host localhost --port 58060 $(1) $(2) 2>&1; echo $$? > log/.exitcode; } | tee log/summary_$(3).out; test $$(cat log/.exitcode) -eq 0 || (cat regression.diffs && false)
endef

check-basic: generate_version_schedule
	$(call common_test,--schedule=./log/basic_schedule_$(pg_major_version),,extended_rum_tests,$(BUILTIN_RMGR_TEMP_CONFIG))
check-minimal:
	$(call common_test,--schedule=./minimal_schedule, $(EXTRA_TESTS),extended_rum_tests_minimal,$(BUILTIN_RMGR_TEMP_CONFIG))

# Same minimal / full runs, but with the built-in rmgr core module forced on via
# the temp-config regardless of the RUM_USE_BUILTIN_RMGR environment variable.
check-builtin-rmgr-minimal:
	$(call common_test,--schedule=./minimal_schedule, $(EXTRA_TESTS),extended_rum_tests_minimal,$(BUILTIN_RMGR_TEMP_CONFIG_OPTION))

check-rum-builtin-rmgr: generate_version_schedule
	$(call common_test,--schedule=./log/basic_schedule_$(pg_major_version),,extended_rum_tests_builtin_rmgr,$(BUILTIN_RMGR_TEMP_CONFIG_OPTION))

check-test-output:
	$(MAKEFILE_DIR)/../regress/validate_test_output.sh $(pg_major_version) $(MAKEFILE_DIR)

generate_version_schedule:
	@mkdir -p log
	@cp basic_schedule log/basic_schedule_$(pg_major_version)
	@RUM_USE_BUILTIN_RMGR=$(RUM_USE_BUILTIN_RMGR) $(MAKEFILE_DIR)/../regress/mutate_schedule.sh log/basic_schedule_$(pg_major_version) $(pg_major_version)


all: check-basic check-test-output
