# .copr/Makefile — called by Copr SCM integration to produce an SRPM.
# Usage: make -f .copr/Makefile srpm outdir=<results-dir>
#
# The SRPM must include ALL vendored sources (pcre2 for EL9, pg_cron for Fedora)
# even though each is only used conditionally — rpmbuild needs them present.

SPEC     := packaging/rpm/spec/documentdb-copr.spec
VERSION  := $(shell grep -m1 '^Version:' $(SPEC) | awk '{print $$2}')

# Detect package name: on Fedora it's "documentdb", on EL9 "postgresql18-documentdb"
# NOTE: SRPM builder always runs on Fedora, so we use a fixed tarball name
# "documentdb-VERSION" regardless of target. The spec uses Source0: documentdb-%{version}.tar.gz
# and %setup -n documentdb-%{version} to match.
PKG_NAME := documentdb

LIBBSON_VERSION     := 1.28.0
INTELMATHLIB_TAG    := applied/2.0u3-1
INTELMATHLIB_TARVER := 2.0u3-1
PCRE2_VERSION       := 10.44
PG_CRON_VERSION     := 1.6.7

TOPDIR   := $(shell pwd)/rpmbuild
SRCDIR   := $(TOPDIR)/SOURCES

.PHONY: srpm
srpm:
	mkdir -p $(outdir) $(SRCDIR) $(TOPDIR)/SPECS $(TOPDIR)/SRPMS

	# ---- Install cargo/rust/git (not available until mock installs BuildRequires) ----
	dnf install -y cargo rust git

	# ---- Source1: mongo-c-driver ----
	curl -L -o $(SRCDIR)/mongo-c-driver-$(LIBBSON_VERSION).tar.gz \
	    https://github.com/mongodb/mongo-c-driver/releases/download/$(LIBBSON_VERSION)/mongo-c-driver-$(LIBBSON_VERSION).tar.gz

	# ---- Source2: Intel Decimal Math Library ----
	git clone --depth 1 -b $(INTELMATHLIB_TAG) \
	    https://git.launchpad.net/ubuntu/+source/intelrdfpmath \
	    intelrdfpmath-$(INTELMATHLIB_TARVER)
	tar czf $(SRCDIR)/intelrdfpmath-$(INTELMATHLIB_TARVER).tar.gz \
	    intelrdfpmath-$(INTELMATHLIB_TARVER)
	rm -rf intelrdfpmath-$(INTELMATHLIB_TARVER)

	# ---- Source3: Cargo vendor tarball for the gateway ----
	cd pg_documentdb_gw && cargo vendor && \
	    tar czf $(SRCDIR)/documentdb-gateway-vendor.tar.gz vendor/ && \
	    rm -rf vendor

	# ---- Source4: vendored pcre2 (used on EL9, included for all SRPMs) ----
	curl -L -o $(SRCDIR)/pcre2-$(PCRE2_VERSION).tar.gz \
	    https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$(PCRE2_VERSION)/pcre2-$(PCRE2_VERSION).tar.gz

	# ---- Source5: vendored pg_cron (used on Fedora, included for all SRPMs) ----
	curl -L -o $(SRCDIR)/pg_cron-$(PG_CRON_VERSION).tar.gz \
	    https://github.com/citusdata/pg_cron/archive/refs/tags/v$(PG_CRON_VERSION).tar.gz

	# ---- Source0: main source tarball ----
	tar czf $(SRCDIR)/$(PKG_NAME)-$(VERSION).tar.gz \
	    --transform 's,^\.,$(PKG_NAME)-$(VERSION),' \
	    --exclude=.git \
	    --exclude=rpmbuild \
	    --exclude=intelrdfpmath-$(INTELMATHLIB_TARVER) \
	    .

	# ---- Build the SRPM ----
	rpmbuild \
	    --define "_topdir $(TOPDIR)" \
	    --define "_sourcedir $(SRCDIR)" \
	    -bs $(SPEC)

	# ---- Copy SRPM to Copr output directory ----
	cp $(TOPDIR)/SRPMS/*.src.rpm $(outdir)/
