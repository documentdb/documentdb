OSS_SRC_DIR = ../../

MODULE_big = pg_documentdb_extended_rum_core_builtin_rmgr
RUM_BUILT_IN_RMGR_MODE=yes
RUM_BUILD_ONLY_CORE_RMGR=yes
# Keep OBJDIR as this directory (rather than a "../../"-prefixed path pointing
# back to it). A relative path containing ".." is echoed verbatim into the
# object/bitcode file names, and PGXS then installs the LLVM bitcode to
# $(bitcodedir)/$(MODULE_big)/<that path>, so the ".." escapes lib/bitcode and
# lands the .bc files outside it. That breaks packaging that only cleans or
# packages lib/bitcode (e.g. the RPM spec), which then fails with "Installed
# (but unpackaged) file(s) found". "." keeps the bitcode under lib/bitcode.
OBJDIR=.
CORESRCDIR=$(OSS_SRC_DIR)pg_documentdb_extended_rum/core/src
COREINCDIR=$(OSS_SRC_DIR)pg_documentdb_extended_rum/core/include

EXTRA_CLEAN += $(OBJDIR)/src

include $(OSS_SRC_DIR)/pg_documentdb_extended_rum/core/Makefile
