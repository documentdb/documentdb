# Third-Party CI Registry

This file lists all registered third-party CI systems that run tests against
pull requests on this repository. Each system posts non-gating results as PR
comments. See [RFC: Third-Party Testing](docs/rfcs/third-party-testing.md) for
the full design.

## Registered Systems

| System Name | Organization | Contact | Description | Status |
|---|---|---|---|---|
| <!-- example row: --> | | | | |
<!-- | MS | Microsoft | [DocumentDB Team](https://github.com/documentdb/documentdb/blob/main/MAINTAINERS.md) | Internal backend test suite (multi-node, sharded, ASAN, flex builds) | Active | -->

## How to Register

If you maintain an integration with DocumentDB and would like to run third-party
CI against our PRs, please:

1. Open an issue titled **"Register 3rd Party CI: \<Your System Name\>"**.
2. Provide:
   - **Organization name**
   - **System name** (short identifier, e.g., `ACME`)
   - **Webhook endpoint URL** your CI system exposes
   - **Preferred signature header name** (e.g., `X-Webhook-Signature`)
   - **Contact information** (link to maintainer list or email)
   - **Brief description** of what your CI tests
3. A DocumentDB maintainer will:
   - Generate shared HMAC secrets (outbound trigger + inbound callback).
   - Add your system to the trigger workflow matrix.
   - Provide you with a fine-grained `GITHUB_CALLBACK_TOKEN` for posting results.
   - Add your entry to this registry.

## Requirements for Registered Systems

Per the [RFC](docs/rfcs/third-party-testing.md) and inspired by
[OpenDev Third-Party CI](https://docs.opendev.org/opendev/system-config/latest/third_party.html):

- **Non-gating by default**: Results default to informational (non-gating). Each
  system declares whether its result is informational or required (blocking merge)
  at registration time. See the RFC for details on configurable gating.
- **One comment per push**: Each `synchronize` event produces at most one result.
- **Public logs**: Include a link to accessible build logs when possible.
- **Identify yourself**: Comments must include your system name and contact link.
- **Stable operation**: New systems start in silent/informational mode for at least
  2 weeks before being considered stable.
- **Respond to `/recheck`**: Honor maintainer-initiated re-trigger requests.
- **Rotate secrets**: Rotate your HMAC secrets and callback PAT at least quarterly.
