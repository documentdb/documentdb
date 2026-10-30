# DocumentDB COPR Packaging

This directory is self-contained COPR packaging. No changes to existing
upstream files, runtime scripts, or Debian packaging are required. Run the
commands below from the repository root unless stated otherwise.

## Package Scope

[postgres18-documentdb.spec](postgres18-documentdb.spec) packages the official
`v1.0-0` source archive as RPM version `1.0`, release `0%{?dist}`, not the
development checkout. The release's SQL extension versions remain unchanged.
It emits two packages:

- `documentdb` on native PostgreSQL 18 Fedora targets, or
  `postgresql18-documentdb` on PGDG targets: PostgreSQL extensions only.
- `documentdb-gateway`: the lean wire-protocol daemon, configuration, service
  user, systemd unit, tmpfiles rules, and log rotation.

The official archive supplies the runtime wrapper, configuration helpers,
sysusers, systemd and tmpfiles inputs. Only the RPM-specific logrotate input
is supplied by this directory. The appliance and operator-tools packages are
deferred. Installation does not initialize or configure PostgreSQL clusters,
run setup wizards, or create extensions. The smoke test explicitly provisions
its own disposable cluster, independently of package installation.

## Source Integrity

[sources.sha256](sources.sha256) pins the release, libbson, pg_cron and PCRE2
archives. [Makefile](Makefile) verifies those hashes, checks the Intel source
commit, and vendors Cargo dependencies using the release's lockfile, including
Git source replacements. The SRPM carries a complete source checksum manifest,
verified again in `%prep`. When updating the release or bundled dependencies,
update their checksums too; do not generate the vendor bundle from a different
checkout.

Source generation needs network access. Binary RPM builds use the vendored
Cargo sources and do not generate `crate(...)` BuildRequires: EPEL 9 does not
provide the needed crate RPMs. This is an intentional deviation from Fedora's
usual `%cargo_generate_buildrequires` workflow.

## COPR Source Configuration

### SCM Make SRPM

Use COPR's SCM source method with **Make SRPM**, your repository URL, and the
branch containing these files. Leave the SCM subdirectory empty. COPR invokes
the standard `.copr/Makefile` entry point, which includes this directory's
Makefile. The spec, checksums, packaging inputs, tests, and documentation stay
under `packaging/copr/`; no changes to existing upstream files are required.

The equivalent local command is:

```bash
make -f .copr/Makefile srpm outdir=/tmp/documentdb-copr-srpm
```

SRPM upload and Custom sources are optional alternatives below. Changing
project configuration or submitting a build is a separate operator action,
not part of local tests.

### Upload an SRPM

Build locally with Docker:

```bash
./packaging/copr/test_copr_srpm.sh --output-dir /tmp/documentdb-copr-srpm
srpm=$(find /tmp/documentdb-copr-srpm -name '*.src.rpm' -print -quit)
```

Upload that file through COPR's "New Build" SRPM form, or submit it with the
authenticated CLI (this command creates a remote build):

```bash
copr-cli build xgerman/DocumentDB "$srpm"
```

### Optional Custom Source Method

The standard SCM Make SRPM method already supports automatic source generation.
To use **Custom** instead, configure:

- Script chroot: `fedora-43-x86_64`.
- Script build dependencies: `rpm-build curl make git cargo rust`
  plus `cargo-rpm-macros systemd-rpm-macros tar gzip cpio` as one space-separated
  list.
- Script result directory: `results`.
- Script: the following Bash script.

The clone URL/ref below targets the packaging branch. It will work remotely
only after this layout has been committed and published there. Adjust the
URL/ref for the eventual upstream location; pin a reviewed commit when
reproducible recipe selection is required.

```bash
#!/bin/bash
set -euo pipefail

git clone --depth 1 --branch users/alaye/coprSpec \
    https://github.com/alaye-ms/documentdb.git recipe
cd recipe
make -f packaging/copr/Makefile srpm INSTALL_BUILD_TOOLS=0 \
    outdir="$PWD/srpm-output"
srpm=$(find "$PWD/srpm-output" -name '*.src.rpm' -print -quit)
test -n "$srpm"
mkdir -p "$COPR_RESULTDIR"
rpm2cpio "$srpm" | cpio -idmu --no-absolute-filenames -D "$COPR_RESULTDIR"
```

COPR's [Custom source method](https://docs.pagure.org/copr.copr/custom_source_method.html)
runs as an unprivileged user. Its build dependencies must be declared in the
configuration, not installed by the script. `INSTALL_BUILD_TOOLS=0` skips the
Makefile's default `dnf install` step. Custom sources must return a spec and
source files in `COPR_RESULTDIR`, not just an SRPM, hence the extraction step.
COPR then builds the shared SRPM from those files. Ordinary SCM webhooks are
not automatically preserved by switching to Custom; configure a custom webhook
separately if required.

## Target Repositories

| Target | PostgreSQL Layout | Additional Repositories |
| --- | --- | --- |
| `fedora-43-x86_64` | Native PostgreSQL 18 | None |
| `fedora-42-x86_64` | PGDG PostgreSQL 18 | PGDG Fedora repository |
| `epel-9-x86_64` | PGDG PostgreSQL 18 | EPEL, CRB, PGDG EL repository |
| `fedora-45-x86_64` | Native PostgreSQL 18 | None |
| `fedora-rawhide-x86_64` | Native PostgreSQL 18 | None |

For Fedora 42 and EL9, configure the applicable PGDG external repository in
the COPR project. EPEL and CRB are enabled by COPR's EPEL 9 chroot; local test
helpers enable them explicitly. The repository packages used by the helpers
are:

```text
https://download.postgresql.org/pub/repos/yum/reporpms/F-42-x86_64/pgdg-fedora-repo-latest.noarch.rpm
https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
```

These targets depend on the external repositories remaining available. Local
PGDG dependency tests use `--nogpgcheck` where the disposable container lacks
PGDG's signing keys; that is not a recommendation to disable verification on
production hosts.

The spec bounds native PostgreSQL server and development packages to
`>= 18, < 19`, so a distribution PostgreSQL major upgrade fails dependency
resolution rather than silently building a PostgreSQL 19 extension. The
vendored mongo-c-driver build enables only libbson; its unused libmongoc code
is incompatible with newer Fedora OpenSSL headers.

EL9 requires Rust/Cargo 1.92 or newer from AppStream. The locked nacelle 0.3.1
crates declare Rust 1.95 but compile with 1.92; the spec backports only their
manifests on EL9 and updates the vendored file checksums, leaving Cargo's
version and integrity checks enabled. Recheck compatibility when updating the
release or vendor bundle. EL9 rebuild helpers update stale Rocky release
metadata before installing PGDG, avoiding obsolete minor-release URLs.

## Local Build Checks

Build one fresh Fedora SRPM, then pass that same SRPM to each target:

```bash
./packaging/copr/test_copr_srpm.sh --output-dir /tmp/documentdb-copr-srpm
srpm=$(find /tmp/documentdb-copr-srpm -name '*.src.rpm' -print -quit)

for chroot in fedora-43-x86_64 fedora-42-x86_64 epel-9-x86_64 \
              fedora-45-x86_64 fedora-rawhide-x86_64; do
    ./packaging/copr/test_copr_dynamic_br.sh --chroot "$chroot" --srpm "$srpm"
done

# Only when source/build changes require recompilation:
./packaging/copr/test_copr_rebuild.sh --chroot epel-9-x86_64 --srpm "$srpm" --keep
```

The SRPM helper defaults to Fedora 43, accepts the targets above, and writes
to this directory unless `--output-dir` is supplied. Relative output paths
are resolved from the repository root. The dependency helper defaults to
the newest SRPM in this directory and builds one if absent; explicitly pass
`--srpm` to avoid accidentally testing an older artifact. The rebuild helper
builds a fresh shared Fedora SRPM when `--srpm` is omitted.

Mock regenerates the incoming shared SRPM with `rpmbuild -bs` in each target
chroot and installs the regenerated static BuildRequires until the package
set stabilizes. Fedora's source header contains `postgresql-server-devel`
and `pcre2-static`; the EL9-regenerated header contains `postgresql18-devel`
and no `pcre2-static`. Directly running `dnf builddep` on the original Fedora
SRPM in EL9 skips that regeneration and does not model COPR/mock correctly.

The dependency helper tests this shared-SRPM workflow, the real `%prep`, and
the dynamic-requirements stage without compiling binaries. The full rebuild
also checks offline compilation, `%install`, and `%files`, including buildroot
leaks and unpackaged files. With `--keep`, binary RPMs remain under
`/root/rpmbuild/RPMS/` in `docdb-rebuild-<chroot>` and can be retrieved with
`docker cp`. Build helpers keep the checkout read-only and build artifacts
inside disposable containers, apart from explicitly exported results.

The Makefile installs source-builder tooling and macros by default for local
root-container use. `rpm-build`, `curl`, `make`, and Cargo alone do not supply
`cargo-rpm-macros` or `systemd-rpm-macros` on a clean Fedora installation.
Preinstall the documented dependencies and use `INSTALL_BUILD_TOOLS=0` for an
unprivileged source build. No local helper submits remote builds.

## Published Package Smoke Test

```bash
./packaging/copr/test_copr_install.sh --chroot fedora-43-x86_64 --systemd
./packaging/copr/test_copr_install.sh --chroot fedora-42-x86_64 --systemd
./packaging/copr/test_copr_install.sh --chroot epel-9-x86_64 --systemd
```

The default repository is `xgerman/DocumentDB`; override it with `--copr`.
The install helper also supports Fedora 45, but not Rawhide. `--systemd`
requires privileged Docker containers and private cgroup namespaces. Without
it, the packaged gateway entry point runs manually as its service user; that
is not a systemd boot test. No host PostgreSQL or gateway service is modified.

Each run starts a fresh container, installs the published extension and
gateway with weak dependencies disabled, checks package provenance and RPM
integrity, provisions PostgreSQL 18, and checks authenticated TLS CRUD,
indexing and aggregation using PyMongo. No checkout runtime files are overlaid.
It rejects appliance/tools dependencies and tests the packaged wrapper,
configuration and service user. `--systemd` additionally exercises the actual
packaged PostgreSQL and gateway units. Logs, installed versions, package URLs,
unit configuration, and CRUD results are exported to a fresh temporary
directory, or to `--output-dir DIR`. `--keep-container` retains the container.
A passing run prints `SMOKE_OK` and `Copr install + gateway smoke test PASSED.`

**Published-build caveat:** these checks install what COPR currently serves,
not an RPM rebuilt from this working tree. Fedora 43 has selected the older
`1.0-1.fc43` packages during validation; a lower `1.0-0` release does not
supersede `1.0-1` automatically. Use `--package-version 1.0-0.fc43` to test that
exact version-release of both the extension and gateway packages instead of
the repository default. Inspect the exported versions and provenance
before claiming a new build was tested. Use the SRPM and rebuild helpers to
validate the local recipe, and publish/select the desired build separately.
