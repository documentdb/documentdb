# Usage: make -f packaging/copr/Makefile srpm outdir=<results-dir>
#
# The SRPM must include ALL vendored sources (pcre2 for EL9, pg_cron for Fedora)
# even though each is only used conditionally - rpmbuild needs them present.

COPR_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
SPEC     := $(COPR_DIR)postgres18-documentdb.spec
VERSION  := $(shell grep -m1 '^Version:' $(SPEC) | awk '{print $$2}')

PKG_NAME := documentdb
SOURCE_VERSION := $(VERSION)-0

LIBBSON_VERSION     := 1.28.0
INTELMATHLIB_TAG    := applied/2.0u3-1
INTELMATHLIB_COMMIT := e2d24068229825f109c7f38a3be123f029174601
INTELMATHLIB_TARVER := 2.0u3-1
PCRE2_VERSION       := 10.44
PG_CRON_VERSION     := 1.6.7

TOPDIR   := $(CURDIR)/rpmbuild
SRCDIR   := $(TOPDIR)/SOURCES
SOURCE_TREE := $(TOPDIR)/$(PKG_NAME)-$(SOURCE_VERSION)
CHECKSUMS := $(COPR_DIR)sources.sha256
INSTALL_BUILD_TOOLS ?= 1

.PHONY: srpm
srpm:
	mkdir -p $(outdir) $(SRCDIR) $(TOPDIR)/SPECS $(TOPDIR)/SRPMS

ifeq ($(INSTALL_BUILD_TOOLS),1)
	# ---- Install source-builder tooling and macros before parsing the spec ----
	dnf install -y cargo rust git cargo-rpm-macros systemd-rpm-macros
endif

	curl --fail --location --retry 3 -o $(SRCDIR)/$(PKG_NAME)-$(SOURCE_VERSION).tar.gz \
	    https://github.com/documentdb/documentdb/archive/refs/tags/v$(SOURCE_VERSION).tar.gz
	cd $(SRCDIR) && sha256sum --check --ignore-missing $(CHECKSUMS)
	tar xzf $(SRCDIR)/$(PKG_NAME)-$(SOURCE_VERSION).tar.gz -C $(TOPDIR)
	cp $(COPR_DIR)documentdb-gateway.logrotate $(SRCDIR)/documentdb-gateway.logrotate
	cp $(SOURCE_TREE)/packaging/gateway/sysusers/documentdb-gateway.conf $(SRCDIR)/documentdb-gateway-sysusers.conf

	# ---- Source1: mongo-c-driver ----
	curl --fail --location --retry 3 -o $(SRCDIR)/mongo-c-driver-$(LIBBSON_VERSION).tar.gz \
	    https://github.com/mongodb/mongo-c-driver/releases/download/$(LIBBSON_VERSION)/mongo-c-driver-$(LIBBSON_VERSION).tar.gz

	# ---- Source2: Intel Decimal Math Library ----
	git clone --depth 1 -b $(INTELMATHLIB_TAG) \
	    https://git.launchpad.net/ubuntu/+source/intelrdfpmath \
	    $(TOPDIR)/intelrdfpmath-$(INTELMATHLIB_TARVER)
	test "$$(git -C $(TOPDIR)/intelrdfpmath-$(INTELMATHLIB_TARVER) rev-parse HEAD)" = "$(INTELMATHLIB_COMMIT)"
	git -C $(TOPDIR)/intelrdfpmath-$(INTELMATHLIB_TARVER) archive \
	    --prefix=intelrdfpmath-$(INTELMATHLIB_TARVER)/ HEAD | \
	    gzip -n > $(SRCDIR)/intelrdfpmath-$(INTELMATHLIB_TARVER).tar.gz
	rm -rf $(TOPDIR)/intelrdfpmath-$(INTELMATHLIB_TARVER)

	# ---- Source3: Cargo vendor tarball for the gateway ----
	cd $(SOURCE_TREE)/pg_documentdb_gw && cargo vendor --locked > vendor-config.toml && \
	    tar czf $(SRCDIR)/documentdb-gateway-vendor.tar.gz vendor/ vendor-config.toml && \
	    rm -rf vendor vendor-config.toml

	# ---- Source4: vendored pg_cron (used on Fedora, included for all SRPMs) ----
	curl --fail --location --retry 3 -o $(SRCDIR)/pg_cron-$(PG_CRON_VERSION).tar.gz \
	    https://github.com/citusdata/pg_cron/archive/refs/tags/v$(PG_CRON_VERSION).tar.gz

	# ---- Source5: vendored pcre2 (used on EL9, included for all SRPMs) ----
	curl --fail --location --retry 3 -o $(SRCDIR)/pcre2-$(PCRE2_VERSION).tar.gz \
	    https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$(PCRE2_VERSION)/pcre2-$(PCRE2_VERSION).tar.gz

	cd $(SRCDIR) && sha256sum --check $(CHECKSUMS)
	cp $(CHECKSUMS) $(SRCDIR)/documentdb-sources.sha256
	cd $(SRCDIR) && sha256sum intelrdfpmath-$(INTELMATHLIB_TARVER).tar.gz \
	    documentdb-gateway-vendor.tar.gz documentdb-gateway.logrotate \
	    documentdb-gateway-sysusers.conf >> documentdb-sources.sha256

	# ---- Build the SRPM ----
	rpmbuild \
	    --define "_topdir $(TOPDIR)" \
	    --define "_sourcedir $(SRCDIR)" \
	    -bs $(SPEC)

	# ---- Copy SRPM to Copr output directory ----
	cp $(TOPDIR)/SRPMS/*.src.rpm $(outdir)/
