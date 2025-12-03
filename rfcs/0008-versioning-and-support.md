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

Currently our versioning strategy is optimized for the needs of a cloud service.
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
* Define clear support windows for production deployments.
* Preserve backward compatibility within a supported major version.
* Make it easy to identify which versions of bundled or dependent components are
  used in each release.
* Prefer simple roll-forward updates during active development, with backports
  reserved for long term support releases.

The proposed release pattern is:

* Breaking changes in DocumentDB require a new major version. When a new major
  version is released, the previous major version becomes  long term support
  release line. It will no longer receive minor updates, only patch releases for
  backported bug fixes and security fixes.
* When a long term support release is deemed too much effort to continue to
  maintain, it will be marked deprecated and that will start a one year clock
  after which it will no longer be supported.

## Detailed Design

### Technical Details

#### Branching strategy

The current major version will be developed on the `main` branch. Before a
breaking change is introduced, the current major version will split off into a
new release branch into which LTS patch fixes can be added.

#### Semantic Versioning

The major version is incremented when starting a new development line that may
include breaking changes from the previous major version. Examples include:

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

After a major release becomes an LTS release line, it is supported until it is
marked deprecated, after which there will be one more year of support. During
that support window, patch releases may include backported bug fixes and security
fixes. Users who require a stable production baseline should use the current LTS
release line and apply LTS patch releases as they become available.

Support for a release means:

* Issues can be tracked and triaged against that release line.
* Bug fixes are included in a later release or, for LTS releases, may be
  backported to an LTS patch release.
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

For now, we will not support direct in-place upgrades between major versions. We
will create upgrade scripts to preserve data, but to reduce complexity the scripts
will mandate that the database shuts down completely.

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
