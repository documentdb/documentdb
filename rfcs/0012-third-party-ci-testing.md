---
rfc: 0012
title: "Third-Party CI Testing"
status: Draft
owner: "@xgerman"
issue: ""
discussion: ""
version-target: ""
implementations: []
---

# RFC-0012: Third-Party CI Testing

## Problem

The public DocumentDB repository runs basic regression tests via GitHub Actions
(SQL tests, gateway tests, CodeQL). However, 3rd parties integrating with the
project might be concerned about PRs breaking their integrations or want to run
more extensive non-public tests to inform review decisions.

Today there is no automated feedback loop: a contributor opens a PR, the public
CI passes, but 3rd party integrations might fail. There is no standard mechanism
for external CI systems to participate in the PR validation process.

**Upstream-first strategy:** The project is moving toward an upstream-first
development model where external contributors submit PRs directly to the public
GitHub repository. When these PRs pass the public CI but break
internal/proprietary extensions or downstream integrations, there is currently
no automated way to detect this before merge.

**Licensed or proprietary test suites:** Some 3rd party organizations may run
test suites that cannot be shared publicly due to licensing or IP constraints.
These organizations need a mechanism to run their tests against PRs and report
a PASS/FAIL signal without exposing test details.

**Who is impacted:** Contributors, maintainers, and any organization that builds
products or services on top of DocumentDB.

**Consequences of not solving:** Breaking changes can slip into releases
undetected by downstream integrators. Maintainers lack signal from integration
test suites that exercise code paths not covered by the public CI.

**Current workarounds:** 3rd parties must manually monitor the repository and run
tests out-of-band, with no automated feedback to PR authors.

**Success criteria:**
- One or more external CI systems can register to test PRs.
- PASS/FAIL results are posted as GitHub commit status checks on the PR.
- Each registered system declares whether its result is **informational**
  (non-gating) or **required** (blocking). Default: informational.
- Adding a new 3rd party CI requires only configuration changes, not code changes.
- The mechanism is secure against unauthorized triggers and forged results.
- Triggering 3rd party CI requires explicit maintainer approval (no automatic
  triggers on untrusted PRs).

**Non-goals:**
- Providing 3rd parties with access to internal infrastructure or secrets.
- Replacing the existing public GitHub Actions CI.
- Exposing test names, output, or detailed results from proprietary test suites.

---

## Approach

Allow any number of external CI systems to register as **third-party testing
systems**, borrowing from the established [OpenDev Third-Party CI](https://docs.opendev.org/opendev/system-config/latest/third_party.html)
pattern. The mechanism has two parts:

1. **Outbound trigger** (GitHub → 3rd party): A GitHub Action triggers on PR events
   and fans out HMAC-signed HTTP POSTs to each registered 3rd party CI webhook.
2. **Result delivery** (3rd party → GitHub): When tests complete, each 3rd party CI
   reports results back via one of two mechanisms:
   - **Option 1 (Recommended):** Directly call the GitHub commit status API with a
     fine-grained PAT (`statuses:write` scope). Simplest path — no callback
     workflow needed.
   - **Option 2:** POST a `repository_dispatch` event with an HMAC-signed payload,
     processed by a callback workflow that verifies the signature, sets a commit
     status, and posts a PR comment.

**Why this approach:**
- **Scalable**: Multiple CI systems register independently, each with isolated secrets.
- **Event-driven**: No polling — callbacks eliminate timeout and latency issues.
- **Secure**: Bidirectional HMAC signatures prevent unauthorized triggers and forged results.
- **Low friction**: Adding a new 3rd party CI is a configuration-only change.

**Alternative considered — Polling Pattern:**
The initial design used polling where a GitHub Action would query the 3rd party
CI Build API every 2 minutes. This creates unnecessary API load, has timeout
concerns for long-running tests (1-2 hours), adds latency, and requires complex
polling loop management. The callback pattern is superior in all dimensions.

**Design principles** (from [OpenDev Third-Party CI](https://docs.opendev.org/opendev/system-config/latest/third_party.html)):

| Principle | How We Apply It |
|---|---|
| **Configurable gating** | Each system declares informational (non-gating) or required (blocking). Default: informational. |
| **One comment per patch set** | Each `synchronize` event produces at most one result comment per system. |
| **Recheck support** | Maintainers can comment `/recheck` to re-trigger all 3rd party tests. |
| **Public logs** | Comments include a link to accessible build logs when possible. |
| **Contact information** | Bot comments identify the system and link to a contact page. |
| **Stable operation** | New systems start in informational mode for ≥2 weeks before going production. |
| **Maintainer approval** | 3rd party CI is only triggered after explicit maintainer approval — never automatically on untrusted PRs. |

---

## Detailed Design

### Architecture

```
GitHub PR event
      │
      ▼
GitHub Action (on documentdb/documentdb)
      │
      ├──► HTTP POST → 3rd Party CI "A"  ──► runs tests ──► callback ──┐
      ├──► HTTP POST → 3rd Party CI "B"  ──► runs tests ──► callback ──┤
      └──► HTTP POST → 3rd Party CI "N"  ──► runs tests ──► callback ──┤
                                                                        │
      ┌─────────────────────────────────────────────────────────────────┘
      ▼
GitHub Action (repository_dispatch event)
      │
      ▼
PR comment posted per system (one comment each)
```

### Outbound Trigger Workflow

A workflow at `.github/workflows/trigger-3rd-party-ci.yml`:

```yaml
name: Trigger 3rd Party CI
on:
  pull_request:
    types: [opened, reopened, synchronize, ready_for_review]
    paths-ignore:
      - 'docs/**'
      - '*.md'
  issue_comment:
    types: [created]  # for /recheck support
```

> **Security:** This workflow does NOT immediately fire webhooks. On
> `pull_request` events from external contributors, it waits for a maintainer
> to approve the run (see Maintainer Approval Gate below). The `/recheck`
> comment path is inherently maintainer-gated since only users with write
> access should use it.

#### Maintainer Approval Gate

Third-party CI pipelines MUST NOT be triggered automatically on PR events
from external contributors. Malicious PRs can exploit CI compute for
cryptocurrency mining, inject code via Makefile or branch names that
exfiltrates internal data, or abuse pipeline resources.

In some cases only maintainers from a *specific* company can approve
CI runs on their company's infrastructure - this might be needed to fulfill
legal or other security policies.

**Trigger flow:**

1. Public GitHub Actions CI runs first on the PR (existing behavior).
2. A maintainer (someone with write access to the repo and in some cases is 
   from a specific company whose external CI will be used) reviews the PR for
   obvious malicious content.
3. The maintainer **explicitly approves** triggering 3rd party CI — either via:
   - A `/run-3rd-party-ci` comment on the PR, or
   - A manual workflow dispatch targeting that PR.
4. Only after approval does the webhook fire to registered 3rd party CI systems.
5. **Safeguard:** Public OSS CI must have already passed before 3rd party CI
   can be triggered. This ensures basic code quality checks happen first.

This mirrors the established GitHub Actions approval flow for first-time
contributors and was the proven pattern in other large OSS projects with
internal CI (e.g., .NET/DevDiv).

**Access control recommendations for the trigger workflow:**

- **Org membership check:** The trigger workflow should verify that the
  approving user is a member of the repository's owning organization. This
  prevents scenarios where a contributor with write access (e.g., a trusted
  external collaborator) triggers expensive internal pipelines.
- **Per-system company restriction:** A 3rd party organization may require
  that only maintainers who are also members of that organization can approve
  CI runs on their infrastructure. For example, Microsoft may require that
  only Microsoft employees can trigger the Microsoft 3rd party CI — even if
  other maintainers have write access to the repo. This is enforced by
  configuring an `approver_org` or `approver_team` per system in the trigger
  matrix. The workflow checks GitHub org/team membership before firing the
  webhook for that system. Systems without this restriction fall back to the
  default org membership check.
- **Auto-approval:** 3rd party systems may configure auto-approval for PRs
  authored by org members with write access, skipping the explicit comment
  trigger. This is per-system configurable. Auto-approval still requires that
  public OSS CI has passed — it only skips the manual `/run-3rd-party-ci`
  comment, not the public CI gate.

#### SHA Pinning

The webhook payload MUST include the **commit SHA at the time the trigger
was approved**, not the current `HEAD` of the PR branch. This prevents a
race condition where:

1. A contributor pushes benign code.
2. A maintainer reviews and approves the 3rd party CI trigger.
3. The contributor force-pushes malicious code before the pipeline starts.
4. The pipeline unknowingly runs the malicious code.

By pinning the SHA, the pipeline always runs exactly the code that was
reviewed and approved.

```yaml
# In the trigger workflow — capture SHA at approval time
- name: Get pinned SHA
  id: sha
  run: |
    SHA=$(gh api repos/${{ github.repository }}/pulls/${{ env.PR_NUMBER }} \
      --jq '.head.sha')
    echo "commit_sha=$SHA" >> $GITHUB_OUTPUT
```

3rd party CI pipelines MUST check out code by commit SHA, never by branch
name. This also prevents branch name injection attacks.

#### Job: `trigger-3rd-party-pipelines`

For each registered 3rd party CI system:

1. Build a JSON payload containing `pr_number`, `commit_sha`, `source_branch`,
   `repo`, and `trigger_timestamp` (Unix epoch seconds at trigger time).
2. Compute HMAC-SHA256 over the payload using that system's shared secret.
3. POST to the system's registered webhook endpoint with the signature header.
4. Verify HTTP 200 response.

Each system is defined as an entry in a configuration matrix, so adding a new
3rd party CI only requires adding a new entry and its corresponding secrets.

**Example** (matrix strategy):
```yaml
strategy:
  matrix:
    include:
      - system: microsoft
        WEBHOOK_URL: https://dev.azure.com/<ORG>/_apis/public/distributedtask/webhooks/<NAME>?api-version=6.0-preview
        WEBHOOK_SECRET_NAME: MS_WEBHOOK_SECRET
        SIGNATURE_HEADER: X-GitHub-ADO-Signature
        APPROVER_ORG: microsoft  # only Microsoft org members can trigger
      - system: partner-corp
        WEBHOOK_URL: https://ci.partner-corp.example/webhooks/documentdb
        WEBHOOK_SECRET_NAME: PARTNER_WEBHOOK_SECRET
        SIGNATURE_HEADER: X-Webhook-Signature
        # APPROVER_ORG omitted — any repo org member can trigger
```

### Result Delivery

3rd party CI systems can report results back to GitHub using either of two
mechanisms. Both are supported; systems choose based on their security
requirements and simplicity preferences.

#### Option 1: GitHub Commit Status API (Recommended)

The simplest approach: the 3rd party CI pipeline directly calls the GitHub
commit status API using a fine-grained PAT with `statuses:write` scope.

```
POST /repos/documentdb/documentdb/statuses/<commit_sha>
Authorization: Bearer <GITHUB_STATUS_TOKEN>
Content-Type: application/json

{
  "state": "success",
  "target_url": "https://link-to-build-logs",
  "description": "3rd Party CI: PASSED",
  "context": "3rd-party-ci/<system_name>"
}
```

**Advantages:**
- No shared HMAC secrets needed on the callback path.
- Results appear directly in the PR's Checks tab as a named status check.
- The PAT only needs `statuses:write` scope (more restrictive than
  `contents:write` required for `repository_dispatch`).
- No intermediate GitHub Action workflow needed to process the callback.

**Disadvantages:**
- The 3rd party CI must have outbound HTTPS access to `api.github.com`.
- No server-side signature verification (the PAT itself is the auth).

#### Option 2: Bidirectional Webhook (`repository_dispatch` + HMAC)

For 3rd parties that prefer server-side signature verification or whose
pipelines cannot directly reach `api.github.com`, the `repository_dispatch`
callback pattern provides an alternative.

#### Inbound Callback Workflow (Option 2 only)

A separate workflow at `.github/workflows/receive-3rd-party-result.yml`:

```yaml
name: Receive 3rd Party Test Result
on:
  repository_dispatch:
    types: [third_party_test_result]
```

When the 3rd party CI completes its tests, it POSTs a `repository_dispatch`
event to the GitHub API:

```
POST /repos/documentdb/documentdb/dispatches
Authorization: Bearer <GITHUB_CALLBACK_TOKEN>
Content-Type: application/json

{
  "event_type": "third_party_test_result",
  "client_payload": {
    "pr_number": "123",
    "commit_sha": "abc1234",
    "result": "succeeded",
    "build_url": "https://link-to-build-logs",
    "system_name": "MS",
    "contact_url": "https://link-to-maintainers",
    "trigger_timestamp": 1700000000,
    "hmac_signature": "<HMAC-SHA256 — see Canonical JSON below>"
  }
}
```

> **Canonical JSON:** Both the sender and the callback workflow MUST use
> **canonical JSON** when computing the HMAC: keys sorted alphabetically,
> compact format (no extra whitespace). In `jq` this is `jq -cS`. Senders
> MUST apply the same canonicalization before signing. Without this, key
> ordering differences between serializers will break signature verification.

The callback workflow **verifies the HMAC signature** using the per-system
callback secret looked up by `system_name`:

```yaml
jobs:
  post-result:
    runs-on: ubuntu-latest
    steps:
      - name: Verify callback signature
        env:
          # Per-system secrets — add a new line for each registered system
          MS_CALLBACK_SECRET: ${{ secrets.MS_CALLBACK_SECRET }}
          PARTNER_CALLBACK_SECRET: ${{ secrets.PARTNER_CALLBACK_SECRET }}
        run: |
          SYSTEM_NAME='${{ github.event.client_payload.system_name }}'

          # Validate system_name to prevent variable injection via ${!...}
          if ! [[ "$SYSTEM_NAME" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
            echo "::error::Invalid system_name format: must match ^[A-Z][A-Z0-9_]*$"
            exit 1
          fi

          SECRET_VAR="${SYSTEM_NAME}_CALLBACK_SECRET"
          CALLBACK_SECRET="${!SECRET_VAR}"
          if [ -z "$CALLBACK_SECRET" ]; then
            echo "::error::Unknown 3rd party system: $SYSTEM_NAME"
            exit 1
          fi

          # Enforce 3-hour TTL — reject stale callbacks
          TRIGGER_TS='${{ github.event.client_payload.trigger_timestamp }}'
          if [ -n "$TRIGGER_TS" ]; then
            NOW=$(date +%s)
            AGE=$(( NOW - TRIGGER_TS ))
            if [ "$AGE" -gt 10800 ]; then
              echo "::error::Callback expired (age=${AGE}s, max=10800s)"
              exit 1
            fi
          fi

          # Canonical JSON (sorted keys, compact) for deterministic HMAC
          PAYLOAD='${{ toJSON(github.event.client_payload) }}'
          RECEIVED_SIG='${{ github.event.client_payload.hmac_signature }}'
          CHECK_PAYLOAD=$(echo "$PAYLOAD" | jq -cS 'del(.hmac_signature)')
          EXPECTED_SIG=$(echo -n "$CHECK_PAYLOAD" | openssl dgst -sha256 -hmac "$CALLBACK_SECRET" | awk '{print $2}')
          if [ "$RECEIVED_SIG" != "$EXPECTED_SIG" ]; then
            echo "::error::Invalid callback signature — rejecting"
            exit 1
          fi

      - name: Set commit status
        uses: actions/github-script@v7
        with:
          script: |
            const p = context.payload.client_payload;
            const state = p.result === 'succeeded' ? 'success' : 'failure';
            await github.rest.repos.createCommitStatus({
              owner: context.repo.owner,
              repo: context.repo.repo,
              sha: p.commit_sha,
              state: state,
              target_url: p.build_url,
              description: `3rd Party CI: ${state === 'success' ? 'PASSED' : 'FAILED'}`,
              context: `3rd-party-ci/${p.system_name}`
            });

      - name: Post PR comment
        uses: actions/github-script@v7
        with:
          script: |
            const p = context.payload.client_payload;
            const emoji = p.result === 'succeeded' ? '✅' : '❌';
            const status = p.result === 'succeeded' ? 'PASSED' : 'FAILED';
            const body = `## ${emoji} 3rd Party CI: ${status}\n\n` +
              `| Detail | Value |\n|---|---|\n` +
              `| **System** | ${p.system_name} ([contact](${p.contact_url})) |\n` +
              `| **Result** | ${p.result} |\n` +
              `| **Build** | [View logs](${p.build_url}) |\n` +
              `| **Commit** | \`${p.commit_sha}\` |\n`;
            await github.rest.issues.createComment({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: Number(p.pr_number),
              body: body
            });
```

### Recheck Support

When a maintainer comments `/recheck` on a PR, the `issue_comment` trigger fires.
The workflow filters for comments matching `/recheck` on open PRs, then
re-triggers all registered 3rd party webhooks as applicable. The workflow **re-pins the commit
SHA** at the time of the `/recheck` comment (using the same mechanism as the
initial trigger), ensuring that re-triggered pipelines run the current HEAD
of the PR, not the SHA from the original approval.

### Failure Handling Workflow

When a 3rd party CI reports **FAIL**:

1. The PR receives a GitHub commit status check (or PR comment) with a generic
   FAIL status and a link to the system contact. **No internal logs or test
   details are exposed.**
2. The 3rd party organization investigates internally to determine root cause.
3. **Two possible outcomes:**
   - **Contributor fix required:** The 3rd party communicates (via PR comment
     or private message) what the contributor needs to change, without
     exposing proprietary test details. They may suggest: *"Please run
     [public test suite X] to validate compatibility."*
   - **Internal fix required:** The 3rd party determines the change is
     desirable for the project but requires corresponding internal work.
     The PR can proceed; the internal team tracks their own follow-up.
4. For proprietary or licensed test suites, **no test names, output,
   or detailed results** are shared in PR comments — only PASS/FAIL.

### Contributor Capabilities

**What contributors can run locally:**
- The public CI test suites (SQL tests, gateway tests) — always available.
- Any open-source test framework against their own DocumentDB instance.

**What contributors cannot access:**
- Internal/proprietary test suites run by 3rd party CI systems.
- Internal/proprietary test infrastructure or detailed results.

Contributors may be *suggested* to run specific open-source tests when a
failure is detected, but they will not be given access to proprietary
test code or infrastructure.

### Pipeline Security Requirements

Any pipeline that builds or tests untrusted external PR code MUST implement
the following security controls. This applies to all registered 3rd party CI
systems, not just internal ones.

**Threat model:**

| Threat | Vector | Mitigation |
|---|---|---|
| Resource abuse | Crypto mining via CI compute | Maintainer approval gate; resource limits on agent pool |
| Code injection | Malicious Makefile targets or build scripts | De-privileged execution; ephemeral containers; code review before approval |
| Branch name injection | Branch names crafted to execute code on checkout | Sanitize branch names; use commit SHA for checkout, not branch name |
| Exfiltration | PR code attempts to read/upload internal repo contents | Network isolation; no internal repo access |
| Lateral movement | Exploiting CI to access internal services | Network isolation; dedicated pool with no corpnet access |

> **Recommendation:** Organizations setting up their 3rd party CI pipeline
> should consult with teams that have already solved this problem
> rather than building security controls
> from scratch.

### Merge Conflict Handling

When an external PR triggers a 3rd party CI pipeline that builds against
internal code, the pipeline may fail due to merge conflicts between the
upstream PR and internal-only changes.

**Policy:**

1. The pipeline reports FAIL back to GitHub.
2. The 3rd party organization performs an **immediate forward sync** from their
   internal repo to upstream to resolve the conflict.
3. The contributor is asked to rebase their PR after the sync completes.
4. Merge conflicts should be resolved same-day rather than making contributors
   wait for a scheduled sync cycle.

### API Changes

No DocumentDB API changes. This RFC only adds GitHub Actions workflows and
a `THIRD_PARTY_CI.md` registry file.

### Database Schema Changes

N/A.

### Configuration Changes

| Item | Type | Description |
|---|---|---|
| `<SYSTEM>_WEBHOOK_SECRET` | GitHub repo secret | Per-system HMAC-SHA256 key for signing outbound payloads |
| `<SYSTEM>_CALLBACK_SECRET` | GitHub repo secret | Per-system HMAC-SHA256 key for verifying inbound callbacks (Option 2 only) |
| `GITHUB_STATUS_TOKEN` or `GITHUB_CALLBACK_TOKEN` | 3rd party CI secret | Fine-grained PAT — `statuses:write` for Option 1 (commit status API) or `contents:write` for Option 2 (`repository_dispatch`) |
| Trigger matrix entry | Workflow YAML | Webhook URL, secret name, and signature header per system |
| `THIRD_PARTY_CI.md` | Repo root | Public registry of all participating 3rd party CI systems |

Each 3rd party CI system gets its own isolated set of secrets:
- An outbound HMAC secret (e.g., `MS_WEBHOOK_SECRET`, `PARTNER_WEBHOOK_SECRET`)
- For Option 1 (commit status API): a fine-grained PAT with `statuses:write`
- For Option 2 (`repository_dispatch`): an inbound callback HMAC secret + a
  fine-grained PAT with `contents:write`

This per-system isolation ensures that compromising one 3rd party's credentials
does not affect any other system, and allows independent secret rotation.

#### Registering a New 3rd Party CI

1. **3rd party** opens an issue titled "Register 3rd Party CI: \<System Name\>".
2. **3rd party** provides: webhook endpoint URL, preferred signature header name,
   contact information, description of what their CI tests, and preferred result
   delivery mechanism (commit status API or `repository_dispatch`).
3. **DocumentDB maintainers** generate per-system HMAC secrets and add them to
   GitHub repo secrets and the 3rd party's CI configuration.
4. **DocumentDB maintainers** add the system to the trigger matrix in the workflow
   and to `THIRD_PARTY_CI.md`.
5. **3rd party** configures their pipeline to report results back on completion —
   either via the commit status API (Option 1) or `repository_dispatch` with
   HMAC-signed payload (Option 2).
6. **3rd party** is given the appropriate fine-grained PAT for their chosen
   result delivery mechanism.

### Testing Strategy

**Manual validation:**
1. Create a test PR, verify the trigger workflow fires for all registered systems.
2. Simulate a callback with a valid HMAC signature, verify PR comment is posted.
3. Simulate a callback with an invalid signature, verify rejection.
4. Test `/recheck` comment re-triggers all systems.

**Negative tests:**
1. POST callback without `hmac_signature` field → rejected.
2. POST callback with wrong `system_name` → rejected (unknown system).
3. POST callback with System A's secret but System B's `system_name` → rejected.
4. POST callback with `system_name` containing special characters → rejected.
5. POST callback with `trigger_timestamp` older than 3 hours → rejected.

**Automated validation:**
1. A unit test for the HMAC verification logic using known test vectors
   (fixed payload + secret → expected signature), run as part of CI.
2. A workflow syntax validation step (`actionlint`) in the public CI to
   catch YAML errors in the trigger and callback workflows.

### Security Considerations

- **Outbound HMAC-SHA256** (GitHub → 3rd party): Every trigger POST is signed. The
  3rd party verifies and rejects tampered or unsigned requests.
- **Inbound HMAC-SHA256** (3rd party → GitHub): For systems using the
  `repository_dispatch` callback (Option 2), each callback is signed with that
  system's per-system `<SYSTEM>_CALLBACK_SECRET`. The workflow looks up the correct
  secret by `system_name` and verifies before posting. One system cannot impersonate
  another.
- **Fine-grained PAT**: Each system's PAT is restricted to a single repository with
  the minimum required scope (`statuses:write` for Option 1, `contents:write` for
  Option 2). No access to other repos or admin actions.
- **`contents:write` risk (Option 2):** The `repository_dispatch` API requires
  `contents:write` scope, which also grants the ability to push commits to the
  repository. A compromised 3rd party PAT could be used to write to the repo, not
  just dispatch events. **Mitigation:** Option 1 (commit status API) is recommended
  precisely because it requires only `statuses:write`. Organizations that must use
  Option 2 should consider using a GitHub App with narrowly scoped permissions
  instead of a PAT, and should monitor the PAT's usage via GitHub audit logs.
- **SHA pinning**: The trigger workflow captures the commit SHA at approval time.
  Pipelines check out code by SHA, never by branch name. This prevents race
  conditions and branch name injection attacks.
- **Maintainer approval gate**: 3rd party CI is never triggered automatically on
  untrusted PRs. A maintainer with write access must explicitly approve each run.
  Public OSS CI must pass first.
- **Org membership**: The trigger workflow verifies the approving user is a member
  of the repository's owning organization, preventing unauthorized use of
  expensive CI resources.
- **Pipeline isolation**: All 3rd party CI pipelines that execute untrusted PR code
  should run in de-privileged, network-isolated, ephemeral environments (see Pipeline
  Security Requirements above).
- **No code access**: The trigger webhook only starts a pipeline. Pipelines check
  out code from the public GitHub PR, not from internal/proprietary repositories.
- **Secret rotation**: All secrets and PATs should be rotated at least quarterly.

### Migration Path

N/A — this is a new feature with no existing behavior to migrate from.

### Documentation Updates

- Add `THIRD_PARTY_CI.md` to repo root as the public registry.
- Update `CONTRIBUTING.md` to mention 3rd party CI results on PRs.

---

## Implementation Tracking

### Implementation PRs

- [ ] PR: Add `THIRD_PARTY_CI.md` registry file
- [ ] PR: Add `.github/workflows/trigger-3rd-party-ci.yml` trigger workflow
- [ ] PR: Add `.github/workflows/receive-3rd-party-result.yml` callback workflow
- [ ] PR: Update `CONTRIBUTING.md` with 3rd party CI information

### Status Updates

**2026-02-17:** RFC drafted.

### Open Questions

- [x] Question: Should there be a maximum time limit between trigger and callback? (e.g., ignore callbacks older than 3 hours)
  - **Resolved:** Yes — implement a 3-hour TTL. Callbacks arriving after 3 hours
    from the trigger event are silently dropped. This prevents stale results
    from posting on PRs that may have already been updated.
- [x] Question: Should the callback workflow also set a GitHub commit status in addition to a PR comment?
  - **Resolved:** Yes — use a GitHub commit status check (visible on the PR's
    Checks tab) as the primary reporting mechanism. This shows directly on the
    PR as "3rd Party CI (System): ✅ passed" or "❌ failed." External
    contributors cannot see internal pipeline logs but can see the pass/fail
    status inline. PR comments remain as supplementary detail.
- [x] Question: Should 3rd party results be gating or non-gating?
  - **Resolved:** Configurable per registered system. Each system declares
    whether its result is **informational** (non-gating) or **required**
    (blocking merge). Default: informational. Systems that are the primary
    integration test suite for the project should start as required/blocking
    and can be relaxed to informational as public OSS test coverage improves.

### Implementation Notes

*No implementation decisions yet — RFC is in Draft status.*
