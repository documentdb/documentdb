---
rfc: 0008
title: "Versioning and Support"
status: Draft
owner: "@gxgerman"
issue: "https://github.com/documentdb/documentdb/issues/TBD"
discussion: "https://github.com/documentdb/documentdb/discussions/TBD"
version-target: 1.0
implementations:
  - "https://github.com/documentdb/documentdb/pull/TBD"
---

# RFC-0008: [Versioning and Support]

## Problem

As we enter different distribution channels (e.g. package repositories) we need
to improve our strategy to align closer with package repositories. In particular
we need to come up with strategies for long term support, compatibility, release
cadence, and security servicing.

## Approach

Currently we are running `0.1xx-y` with `0` being the major version, `1xx` being
the minor version, and `-y` being the patch version. We will work to ensure that
DocumentDB is ready for production, then release version 1.0. This RFC will describe
the contract we have with users.

The versioning and release strategy should follow these principles:

* Provide a predictable release schedule so users can plan upgrades.
* Publish a new major version every year.
* Define clear support windows for production deployments.
* Preserve backward compatibility within a supported major version.
* Make it easy to identify which versions of bundled or dependent components are
  used in each release.
* Prefer simple roll-forward updates during active development, with backports
  reserved for long term support releases.

The proposed release pattern is:

* DocumentDB will publish one new major version every calendar year.
* Breaking changes in DocumentDB require a new major version. Breaking changes
  are also allowed in the development branch on minor versions.
* When a new major version is released, it will be supported with
  bugfixes and security patches for 2 years before being deprecated.

## Detailed Design

### Technical Details

#### Branching and tagging strategy

The unreleased next major version will be developed on the `main` branch. Development
on the current and previous releases will be done on a `release/v#` branch.
Those releases get LTS patch fixes. A third `release/v#` branch will be created
for the purposes of generating release candidates before the n-2 version is deprecated.

We will use tags to mark the minor and patch versions in git, with `vMajor.Minor.Patch`
tags being assigned to appropriate commits on each branch. We will use the `-rc`
tag suffix for creating release candidates before releasing a new version.

For example, if we are about to release v3, we would start with these branches and
tags:

* `release/v1` with tag `v1.0-8`
* `release/v2` with tag `v2.0-4`
* `main` with tag `v2.8-0`, contains development for `v3`

Next we would put up a release candidate for `v3` in a new branch based off of main:

* `release/v1` with tag `v1.0-8`
* `release/v2` with tag `v2.0-4`
* `release/v3` with tag `v3.0-rc0`
* `main` tagged `v2.8-0`, identical to `release/v3`

Then, when we do the full release `release/v1` would be abandoned, and `release/v3`
would be tagged with a regular version. Version 4 would then be able to be
developed on the `main` branch. The `release/v2` branch would continue to be supported
for another year.

* `release/v2` with tag `v2.0-4`
* `release/v3` with tag `v3.0-0`
* `main` with tag `v3.1-0`, contains development for `v4`

#### Semantic Versioning

The major version is incremented once per year when starting the next
development line. That new major may include breaking changes from the previous
major version. Examples include:

* Deprecated API removals
* Dependency updates which break old versions
* Removal of support for old PostgreSQL version

Minor changes will only be added to the current development line, not backported
to LTS release lines. Minor changes include:

* New features
* Refactors
* Downstream Syncs
* Backward-compatible dependency or bundled component updates

Patch changes may be released for the latest current minor release and for any
supported LTS release line. Patch changes can include:

* Security fixes
* Bug fixes
* Minimal dependency updates required to resolve a security or critical stability
  issue

### Support Policy

Each minor release on the current development line is supported until the next
minor release is published. Bug fixes and security fixes during active development
generally roll forward into the latest release instead of being backported to
older minor releases.

Support for a release means:

* Issues can be tracked and triaged against that release line.
* Bug fixes are backported.
* Security fixes are prioritized. Critical vulnerabilities may trigger an
  expedited patch release.
* Security advisories are published for critical vulnerabilities when applicable.
* Package builds will be tested for correctness.

Each version will have a support matrix modeled as below

| Support level                          | PostgreSQL versions
|----------------------------------------|--------------------
| Build packages for consumption         | 18
| Respond to all bugs and issues         | 15, 16, 17, 18
| Ensure extension is compatible in code | 15, 16, 17, 18

Packages are currently being built for the following distributions:
deb11, deb12, ubuntu22.04, ubuntu24.04, rhel8, rhel9. New versions will be added
as they are released. Removal of a supported version will be possible on minor updates
on `main`, but won't affect LTS releases.

### Compatibility and Dependency Policy

Each release should document the compatible versions of important bundled or
dependent components, including PostgreSQL. Each major release line will remain
compatible with the PostgreSQL versions promised at the inception of that major
version for the duration of its support window.

When a new major version removes PostgreSQL support for a particular version,
DocumentDB itself will remove any references to that version of PostgreSQL.

### API Changes

N/A

### Database Schema Changes

N/A

### Configuration Changes

N/A

### Testing Strategy

N/A

### Migration Path

We will support direct in-place upgrades between major versions. We will also
develop install scripts for each major version to be installed without having
to go through a stacked upgrade.

Upgrade from the rc versions will not be supported, and the extension version for
Release Candidates will always be X.0-0. This will be the same as the first
full release version, so an upgrade wouldn't be feasible.

### Documentation Updates

When fully agreed upon, these rules will be added to the official documentation.

The documentation should include the current support status, compatible component
versions, and release process guidance for producing minor, patch, security, and
LTS releases.

---

## Implementation Tracking

*This section SHALL be populated during the Implementation phase.*

**Purpose:** Track the implementation progress of this RFC.

**Complete this section when:** Your RFC has been accepted and implementation work begins.

**Guidance:**
- Link to the PRs that implement this RFC. Update as implementation progresses.
- Provide success metrics.

### Implementation PRs

- [ ] PR #XXX: [Brief description of what this PR implements]
- [ ] PR #XXX: [Brief description of what this PR implements]
- [ ] PR #XXX: [Brief description of what this PR implements]

### Status Updates

*Add dated status updates as implementation progresses*

**YYYY-MM-DD:** Initial implementation started in PR #XXX

**YYYY-MM-DD:** [Update on progress, blockers, or changes]

### Open Questions

*Track unresolved questions that arise during implementation*

- [ ] Question: [Description]
  - Discussion: [Link to discussion or resolution]

### Implementation Notes

*Capture important decisions or learnings during implementation*

- **Decision [YYYY-MM-DD]:** [What was decided]
  - **Context:** [Why this decision was made]
  - **Alternatives:** [What else was considered]
