#-------------------------------------------------------------------------
#
# Makefile for extended_rum_recovery_tests
#
# TAP tests for RUM WAL redo via streaming replication.
# Based on PostgreSQL's src/test/recovery test framework.
#
#-------------------------------------------------------------------------

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Locate pg_regress from the installed PGXS directory
PG_REGRESS_BIN := $(pgxsdir)/src/test/regress/pg_regress

ifeq ($(enable_tap_tests),yes)

define run_prove
rm -rf $(CURDIR)/tmp_check
rm -rf $(CURDIR)/log
$(MKDIR_P) $(CURDIR)/tmp_check
$(MKDIR_P) $(CURDIR)/log
cd $(CURDIR) && \
{ TESTDIR=$(CURDIR) PG_REGRESS=$(PG_REGRESS_BIN) $(PROVE) $(PG_PROVE_FLAGS) $(PROVE_FLAGS) -f $(if $(PROVE_TESTS),$(PROVE_TESTS),t/*.pl) 2>&1; echo $$? > log/.exitcode; } | tee log/summary_$(1).out; test $$(cat log/.exitcode) -eq 0
endef

else
run_prove = $(error TAP tests not enabled when postgres was compiled, consider passing --enable-tap-tests flag when configuring postgres build)
endif

.PHONY: check-recovery clean-recovery all

check-recovery:
	@echo "======= RUNNING RUM WAL REDO RECOVERY TESTS ======="
	$(call run_prove,extended_rum_recovery)
	@echo "=======   END RUM WAL REDO RECOVERY TESTS   ======="

clean-recovery:
	rm -rf tmp_check
	rm -rf log
all: check-recovery
