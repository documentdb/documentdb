# .copr/Makefile — called by Copr SCM integration to produce an SRPM.
# Usage: make -f .copr/Makefile srpm outdir=<results-dir>

SPEC     := packaging/rpm/spec/documentdb-copr.spec
VERSION  := $(shell grep -m1 '^Version:' $(SPEC) | awk '{print $$2}')
PG_VER   := $(shell grep '%global pg_version' $(SPEC) | awk '{print $$3}')
PKG_NAME := postgresql$(PG_VER)-documentdb

LIBBSON_VERSION     := 1.28.0
INTELMATHLIB_TAG    := applied/2.0u3-1
INTELMATHLIB_TARVER := 2.0u3-1

TOPDIR   := $(shell pwd)/rpmbuild
SRCDIR   := $(TOPDIR)/SOURCES

.PHONY: srpm
srpm:
	mkdir -p $(outdir) $(SRCDIR) $(TOPDIR)/SPECS $(TOPDIR)/SRPMS

	# ---- Install cargo/rust (not available until mock installs BuildRequires) ----
	dnf install -y cargo rust

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
