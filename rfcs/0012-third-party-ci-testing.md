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

**Who is impacted:** Contributors, maintainers, and any organization that builds
products or services on top of DocumentDB.

**Consequences of not solving:** Breaking changes can slip into releases
undetected by downstream integrators. Maintainers lack signal from integration
test suites that exercise code paths not covered by the public CI.

**Current workarounds:** 3rd parties must manually monitor the repository and run
tests out-of-band, with no automated feedback to PR authors.

**Success criteria:**
- One or more external CI systems can register to test PRs automatically.
- PASS/FAIL results are posted as non-gating PR comments.
- Adding a new 3rd party CI requires only configuration changes, not code changes.
- The mechanism is secure against unauthorized triggers and forged results.

**Non-goals:**
- Making 3rd party results a required (gating) status check.
- Providing 3rd parties with access to internal infrastructure or secrets.
- Replacing the existing public GitHub Actions CI.

---

## Approach

Allow any number of external CI systems to register as **third-party testing
systems**, borrowing from the established [OpenDev Third-Party CI](https://docs.opendev.org/opendev/system-config/latest/third_party.html)
pattern. The mechanism uses **bidirectional webhooks**:

1. **Outbound** (GitHub → 3rd party): A GitHub Action triggers on PR events and
   fans out HMAC-signed HTTP POSTs to each registered 3rd party CI webhook.
2. **Inbound** (3rd party → GitHub): When tests complete, each 3rd party CI posts
   results back via GitHub's `repository_dispatch` API with an HMAC-signed payload.
3. A callback workflow verifies the signature and posts a PR comment.

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
| **Non-gating** | Results are PR comments, not required status checks. Maintainers decide. |
| **One comment per patch set** | Each `synchronize` event produces at most one result comment per system. |
| **Recheck support** | Maintainers can comment `/recheck` to re-trigger all 3rd party tests. |
| **Public logs** | Comments include a link to accessible build logs when possible. |
| **Contact information** | Bot comments identify the system and link to a contact page. |
| **Stable operation** | New systems start in informational mode for ≥2 weeks before going production. |

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

#### Job: `trigger-3rd-party-pipelines`

For each registered 3rd party CI system:

1. Build a JSON payload containing `pr_number`, `commit_sha`, `source_branch`, `repo`.
2. Compute HMAC-SHA1 over the payload using that system's shared secret.
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
      - system: partner-corp
        WEBHOOK_URL: https://ci.partner-corp.example/webhooks/documentdb
        WEBHOOK_SECRET_NAME: PARTNER_WEBHOOK_SECRET
        SIGNATURE_HEADER: X-Webhook-Signature
```

### Inbound Callback Workflow

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
    "hmac_signature": "<HMAC-SHA256 of client_payload minus this field>"
  }
}
```

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
          SECRET_VAR="${SYSTEM_NAME}_CALLBACK_SECRET"
          CALLBACK_SECRET="${!SECRET_VAR}"
          if [ -z "$CALLBACK_SECRET" ]; then
            echo "::error::Unknown 3rd party system: $SYSTEM_NAME"
            exit 1
          fi
          PAYLOAD='${{ toJSON(github.event.client_payload) }}'
          RECEIVED_SIG='${{ github.event.client_payload.hmac_signature }}'
          CHECK_PAYLOAD=$(echo "$PAYLOAD" | jq 'del(.hmac_signature)')
          EXPECTED_SIG=$(echo -n "$CHECK_PAYLOAD" | openssl dgst -sha256 -hmac "$CALLBACK_SECRET" | awk '{print $2}')
          if [ "$RECEIVED_SIG" != "$EXPECTED_SIG" ]; then
            echo "::error::Invalid callback signature — rejecting"
            exit 1
          fi

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
re-triggers all registered 3rd party webhooks.

### API Changes

No DocumentDB API changes. This RFC only adds GitHub Actions workflows and
a `THIRD_PARTY_CI.md` registry file.

### Database Schema Changes

N/A.

### Configuration Changes

| Item | Type | Description |
|---|---|---|
| `<SYSTEM>_WEBHOOK_SECRET` | GitHub repo secret | Per-system HMAC-SHA1 key for signing outbound payloads |
| `<SYSTEM>_CALLBACK_SECRET` | GitHub repo secret | Per-system HMAC-SHA256 key for verifying inbound callbacks |
| `GITHUB_CALLBACK_TOKEN` | 3rd party CI secret | Fine-grained PAT (`contents:write` on this repo only) for `repository_dispatch` |
| Trigger matrix entry | Workflow YAML | Webhook URL, secret name, and signature header per system |
| `THIRD_PARTY_CI.md` | Repo root | Public registry of all participating 3rd party CI systems |

Each 3rd party CI system gets its own isolated set of secrets:
- An outbound HMAC secret (e.g., `MS_WEBHOOK_SECRET`, `PARTNER_WEBHOOK_SECRET`)
- An inbound callback HMAC secret (e.g., `MS_CALLBACK_SECRET`, `PARTNER_CALLBACK_SECRET`)
- Its own `GITHUB_CALLBACK_TOKEN` (fine-grained PAT)

This per-system isolation ensures that compromising one 3rd party's credentials
does not affect any other system, and allows independent secret rotation.

#### Registering a New 3rd Party CI

1. **3rd party** opens an issue titled "Register 3rd Party CI: \<System Name\>".
2. **3rd party** provides: webhook endpoint URL, preferred signature header name,
   contact information, and description of what their CI tests.
3. **DocumentDB maintainers** generate per-system HMAC secrets and add them to
   GitHub repo secrets and the 3rd party's CI configuration.
4. **DocumentDB maintainers** add the system to the trigger matrix in the workflow
   and to `THIRD_PARTY_CI.md`.
5. **3rd party** configures their pipeline to call back via `repository_dispatch`
   on completion, signing the payload with their `<SYSTEM>_CALLBACK_SECRET`.
6. **3rd party** is given a `GITHUB_CALLBACK_TOKEN` (fine-grained PAT) to post
   the `repository_dispatch` event.

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

### Security Considerations

- **Outbound HMAC-SHA1** (GitHub → 3rd party): Every trigger POST is signed. The
  3rd party verifies and rejects tampered or unsigned requests.
- **Inbound HMAC-SHA256** (3rd party → GitHub): Each callback is signed with that
  system's per-system `<SYSTEM>_CALLBACK_SECRET`. The workflow looks up the correct
  secret by `system_name` and verifies before posting. One system cannot impersonate
  another.
- **Fine-grained PAT**: Each `GITHUB_CALLBACK_TOKEN` is restricted to a single
  repository with `contents:write` scope. No access to other repos or admin actions.
- **No code access**: The trigger webhook only starts a pipeline. Pipelines check
  out code from their own fork/upstream, not from untrusted sources.
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

- [ ] Question: Should there be a maximum time limit between trigger and callback? (e.g., ignore callbacks older than 3 hours)
  - Discussion: TBD
- [ ] Question: Should the callback workflow also set a GitHub commit status in addition to a PR comment?
  - Discussion: TBD

### Implementation Notes

*No implementation decisions yet — RFC is in Draft status.*
