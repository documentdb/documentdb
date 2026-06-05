
MODULE_big ?= pg_documentdb_extended_rum_core
EXTVERSION = 1.0
PGFILEDESC = "DocumentDB Extended RUM index access method core implementation"

OSS_SRC_DIR = ../../

CORESRCDIR ?=src
COREINCDIR ?=include

SOURCES = $(wildcard $(CORESRCDIR)/*.c) $(wildcard $(CORESRCDIR)/roaring_bitmaps/*.c)

ifneq ($(RUM_BUILD_ONLY_CORE_RMGR),yes)
SOURCES += $(wildcard $(CORESRCDIR)/infra/*.c)
endif

OBJS = $(patsubst %.c,%.o,$(SOURCES)) $(WIN32RES)

ifneq ($(OBJDIR),)
OBJS := $(subst $(CORESRCDIR)/,$(OBJDIR)/src/,$(OBJS)) $(WIN32RES)
endif

# INCLUDES = rum.h rumsort.h
RELATIVE_INCLUDES = $(addprefix src/, $(INCLUDES))

LDFLAGS_SL += $(filter -lm, $(LIBS))

PG_CPPFLAGS = -I$(COREINCDIR)
ifeq ($(CC),gcc)
    PG_CFLAGS = -std=gnu99 -Wall -Wextra -Werror -Wno-declaration-after-statement -Wno-unused-parameter -Wno-implicit-fallthrough -Wno-missing-variable-declarations -fno-lto $(LIBBSON) $(INTEL_DECIMAL_MATH_LIB) $(PCRE2_LIB) -I$(COREINCDIR)
else
    PG_CFLAGS = -std=gnu99 -Wall -Wextra -Werror -Wno-declaration-after-statement -Wno-unused-parameter -Wno-implicit-fallthrough -Wno-missing-variable-declarations $(LIBBSON) $(INTEL_DECIMAL_MATH_LIB) $(PCRE2_LIB) -I$(COREINCDIR)
endif

ifeq ($(RUM_BUILT_IN_RMGR_MODE), yes)
    PG_CPPFLAGS += -DRUM_BUILT_IN_RMGR_MODE
    PG_CFLAGS += -DRUM_BUILT_IN_RMGR_MODE
endif

ifeq ($(RUM_BUILD_ONLY_CORE_RMGR), yes)
    PG_CPPFLAGS += -DRUM_BUILD_ONLY_CORE_RMGR
    PG_CFLAGS += -DRUM_BUILD_ONLY_CORE_RMGR
endif

# Update to notify roaring to use the C atomics implementation (as opposed to c++): See roaring.h CROARING_ATOMIC_IMPL_C
PG_CFLAGS += -DCROARING_ATOMIC_IMPL=3
PG_CPPFLAGS += -DCROARING_ATOMIC_IMPL=3

PG_CFLAGS += -Wno-sign-compare -Wno-type-limits
PG_LDFLAGS += -Wl,-rpath=$(shell $(PG_CONFIG) --pkglibdir) -fno-lto

include $(OSS_SRC_DIR)/Makefile.global

# Default to hidden visibility
override LDFLAGS_SL += -fvisibility=hidden -DHAVE_VISIBILITY_ATTRIBUTE=1
override CFLAGS += -fvisibility=hidden  -DHAVE_VISIBILITY_ATTRIBUTE=1
override CXXFLAGS += -fvisibility=hidden  -DHAVE_VISIBILITY_ATTRIBUTE=1

ifneq ($(OBJDIR),)

create_objdir:
	mkdir -p $(OBJDIR)/src $(OBJDIR)/src/roaring_bitmaps

$(OBJS): $(OBJDIR)/src/%.o: $(CORESRCDIR)/%.c | create_objdir
	$(CC) $(CFLAGS) $(CPPFLAGS) -c -o $@ $<

# Mirror the .o rule for LLVM bitcode so JIT-enabled builds (deb/rpm packaging)
# can locate the source. PGXS's default %.bc:%.c rule only matches when the .c
# and .bc are in the same directory, which is not the case for OBJDIR builds.
$(patsubst %.o,%.bc,$(OBJS)): $(OBJDIR)/src/%.bc: $(CORESRCDIR)/%.c | create_objdir
	$(COMPILE.c.bc) -o $@ $<
endif