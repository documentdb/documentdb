---
rfc: 0008
title: "Versioning Scheme"
status: Draft
owner: "@gxgerman"
issue: "https://github.com/documentdb/documentdb/issues/TBD"
discussion: "https://github.com/documentdb/documentdb/discussions/TBD"
version-target: 1.0
implementations:
  - "https://github.com/documentdb/documentdb/pull/TBD"
---

# RFC-0008: [Versioning Scheme]

## Problem

Currently our versioning strategy is optimized for the needs of a cloud service. As we enter
different distribution channels (e.g. package repositories) we need to improve our strategy
to align closer with packages repository. In particular we need to come up with strategies for
long term support and others.

## Approach

Currently we are running `0.106-1` with `0` being the major version, `106` being the minor
version, an `-1` the patch version. There is some loose understanding that once we reach a 
certain maturity or if there is a breaking change we will go to major version `1`.

Going forward we will codify things as follows:

* Every year in November we will release a long term support version which will be supported
  for (at least) one year with  patch versions aka bug fixes and security fixes - which get backported. Each new release will have the same major version as used during that year and the minor version will be `100`, e.g. `1.100-0`. Each subsequent patch will increment the patch version, e.g. `1.100-1`.
* During the year we will work on the new major version and have minor version releases 
  throughout the year each month. So the first release will be `2.1-0`, the next `2.2-0`,
  and so on. If needed, patch versions can be release which will increment the patch number.
  Each year we will release this work with the `100` LTS verison, e.g. `2.100-0` and then start over with `3.1-0`. 

## Detailed Design

*This section MAY BE REQUIRED before moving from Proposed to Accepted status. This section MUST be completed and approved to move to Implementing status.*

**Purpose:** Provide comprehensive technical details needed for implementation.

**Complete this section when:** Your solution approach has been validated and you're ready to commit to specific implementation details.

**Guidance:** This is where you get specific. Include enough detail that someone could implement this RFC without having to make major design decisions.

### Technical Details

*Describe the technical implementation specifics*
- Data structures
- Algorithms
- Architecture patterns
- Performance considerations

### API Changes

*Document any public API additions or modifications*
- New functions, including UDFs
- Modified signatures
- Breaking changes
- Deprecation plans

### Database Schema Changes

*If applicable, describe schema modifications*
- New tables/collections
- Schema migrations
- Index changes
- Data migration strategies

### Configuration Changes

*Document new or modified configuration options*
- New settings
- Modified defaults
- Environment variables
- Configuration validation

### Testing Strategy

*Describe how this will be tested*
- Unit test approach
- Integration test requirements
- Compatibility test requirements
- Performance test plans
- Migration test strategy

### Migration Path

*How do existing users/deployments upgrade?*
- Backwards/forwards compatibility
- Migration steps
- Rollback strategy
- Deprecation timeline

### Documentation Updates

*What documentation needs to change?*
- User-facing docs
- Developer guides
- API references
- Examples/tutorials

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
