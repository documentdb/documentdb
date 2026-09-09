#-------------------------------------------------------------------------
#
# Makefile for background worker TAP tests
#
#-------------------------------------------------------------------------

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

PG_REGRESS_BIN := $(pgxsdir)/src/test/regress/pg_regress

ifeq ($(enable_tap_tests),yes)

define run_prove
rm -rf $(CURDIR)/tmp_check
rm -rf $(CURDIR)/log
$(MKDIR_P) $(CURDIR)/tmp_check
$(MKDIR_P) $(CURDIR)/log
cd $(CURDIR) && \
{ TESTDIR=$(CURDIR) \
  PG_REGRESS=$(PG_REGRESS_BIN) \
  $(PROVE) $(PG_PROVE_FLAGS) $(PROVE_FLAGS) -f \
  $(if $(PROVE_TESTS),$(PROVE_TESTS),t/*.pl) 2>&1; \
  echo $$? > log/.exitcode; } | tee log/summary.out; \
test $$(cat log/.exitcode) -eq 0
endef

else
run_prove = $(error TAP tests not enabled when postgres was compiled, consider passing --enable-tap-tests flag when configuring postgres build)
endif

.PHONY: all check-background-worker clean-background-worker

all: check-background-worker

check-background-worker:
	@echo "======= RUNNING BACKGROUND WORKER TESTS ======="
	$(run_prove)
	@echo "=======   END BACKGROUND WORKER TESTS   ======="

clean-background-worker:
	rm -rf tmp_check
	rm -rf log
