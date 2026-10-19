# Privacy Statement for `documentdb-local`

**Effective date:** 1 October 2026
**Applies to:** the `documentdb-local` container image, and no other component
of this project.

### What `documentdb-local` is

`documentdb-local` is the single-container distribution of DocumentDB,
published as `ghcr.io/documentdb/documentdb/documentdb-local` and often
retagged locally as `documentdb`. One container holds everything needed to run
DocumentDB on one machine: a PostgreSQL server with the DocumentDB extensions
installed, and the DocumentDB gateway that accepts client connections on port
`10260`. It is intended for local development, evaluation, and testing, and it
is started with a command of this form:

```bash
docker run -dt -p 10260:10260 --name documentdb-container \
    -e USERNAME=<username> -e PASSWORD=<password> documentdb
```

It is sometimes called the emulator, and the two telemetry event names below
(`emulator_launch` and `emulator_heartbeat`) use that older term.

Everything in this statement concerns that image alone. It does not describe
any other way of running DocumentDB; see [Section 1](#1-scope).

### What this statement covers

The `documentdb-local` container image sends a small amount of usage data (its
version, platform and CPU architecture) to Scarf; Scarf also sees the source IP
address. This helps the DocumentDB project understand how the software is used
and prioritize maintenance and compatibility work. This statement describes
what is collected, why, who receives it, how long it is kept, and how to turn
it off.

Usage data collection is **enabled by default** and may be disabled at any time
by the operator. See [Section 6, Your choices](#6-your-choices).

In this statement, **"operator"** means the person or organization that deploys
or administers the `documentdb-local` container. The operator is the party able
to set the controls described here; someone who merely connects to the database
generally cannot. The procedural sections address the operator as "you".
"User" is reserved for data a user stores and for names a user chooses, and is
never used for the party configuring the container.

This statement ships inside the container image at
`/home/documentdb/PRIVACY.md` so that it can be read without network access:

```bash
docker run --rm --entrypoint cat documentdb-local /home/documentdb/PRIVACY.md
```

---

## Summary

| | |
|---|---|
| What is collected | The image release version, operating system, CPU architecture, and a fixed event name. Nothing else. |
| What is never collected | Any data stored in or passed through the database, any name chosen by a user, and any credential. See [Section 3](#3-data-we-do-not-collect). |
| When it is sent | Once when the container starts, then a periodic liveness signal while it continues to run. |
| Why | To estimate how many deployments exist, on which releases and platforms, so that maintenance and compatibility work can be prioritized. |
| Who receives it | [Scarf](https://scarf.sh), a third-party analytics provider. Its handling of what it receives is governed by its own privacy policy. See [Section 4](#4-third-party-involvement). |
| Who can access it within the project | Authorized project participants who need it for project governance, maintenance, compatibility planning, or adoption analysis. See [Section 4.4](#44-access-within-the-project). |
| Retention | Determined by Scarf, not by this image. See [Section 5](#5-retention). |
| How to disable it | `--disable-usage-telemetry`, or any of the environment variables in [Section 6](#6-your-choices). |
| In automated environments | Not automatic. See [Section 6.4](#64-automated-environments). |
| Scope | The container image only. See [Section 1](#1-scope). |

---

## 1. Scope

This statement applies **only** to the `documentdb-local` container image
described under [What `documentdb-local` is](#what-documentdb-local-is).

It does **not** apply to, and no data is collected by, any of the following:

- The DocumentDB PostgreSQL extensions, whether built from source or installed
  from a package. This includes the same extensions the image itself bundles:
  it is the image's entrypoint that collects, not the database.
- The DocumentDB gateway, including the copy bundled in the image.
- Any deployment of DocumentDB assembled from the above without this image.
- Any third-party or managed service that packages DocumentDB. Such services
  are governed by their own privacy statements and are outside the control of
  this project.

The collection logic exists in a single shell script within the image's
entrypoint
([`scripts/usage_telemetry.sh`](scripts/usage_telemetry.sh)). No compiled
binary, extension, or gateway component participates in it, and it is never
invoked on the path that serves a database request.

### 1.1 Two distinct features named "telemetry"

This project contains two unrelated features that are both commonly called
"telemetry". They are configured separately, serve different audiences, and
send data to different destinations. Only the second is the subject of this
statement.

| | Operational metrics | Usage data (this statement) |
|---|---|---|
| Intended audience | The operator running the instance | The DocumentDB project |
| Destination | An endpoint the operator configures | A collection endpoint, configurable |
| Mechanism | OpenTelemetry OTLP | HTTP GET request, HTTPS by default |
| Frequency | Per request | At startup, then periodically |
| Control | `--enable-telemetry` / `ENABLE_TELEMETRY` | `--usage-telemetry` / `DOCUMENTDB_USAGE_TELEMETRY` |
| Default | Disabled | Enabled |

The two controls are independent. Setting `ENABLE_TELEMETRY=false` does **not**
disable usage data collection, and `--disable-usage-telemetry` has no effect on
operational metrics.

---

## 2. Data we collect

Two event types are transmitted, each as an HTTP GET request carrying its
attributes as URL query parameters. No request body is sent.

The default endpoint uses HTTPS, so transmissions are encrypted in transit
unless an operator changes the destination. An operator who overrides
`DOCUMENTDB_USAGE_TELEMETRY_ENDPOINT` with an `http://` address is transmitting
the fields below without encryption; that is permitted so that a collector on a
trusted local network can be used, but it is the operator's choice and the
software does not refuse it.

### 2.1 Startup event

Transmitted once per container start, after the database is confirmed to be
serving.

| Field | Example | Description |
|-------|---------|-------------|
| `event` | `emulator_launch` | Fixed event name |
| `version` | `0.109-0` | Image release version, read from `/version.txt` |
| `platform` | `linux` | Operating system name, lowercased |
| `arch` | `x86_64` | CPU architecture |
| `db_system` | `documentdb` | Fixed constant |

### 2.2 Liveness event

Transmitted repeatedly at the configured interval (one hour by default) for as
long as the container continues to run. It carries the same five fields, with
`event` set to `emulator_heartbeat`.

The two events serve distinct purposes. Startup events indicate how often the
software is launched. Liveness events indicate which deployments remain in use,
and for how long, which is what distinguishes a sustained deployment from a
single trial run.

**The fields listed above are the complete set. No other field is transmitted.**

---

## 3. Data we do not collect

The following are never read, never included in any transmission, and never
accessible to the collection logic:

- **Database contents.** No document, field name, field value, or any other
  stored data.
- **Queries.** No filter, aggregation pipeline, command, or argument.
- **Names chosen by users.** No database, collection, index, or user name.
- **Credentials.** No password, connection string, key, token, or certificate.
- **Identifiers.** No IP address, hostname, MAC address, machine identifier,
  user name, or persistent installation identifier is read by this software or
  placed in a transmission. See Section 3.1 for what the receiving service
  observes regardless.

### 3.1 Information inherent to any network request

As with any HTTP request, the receiving service observes the network source
address of the connection. This is a property of network communication itself
rather than something the transmitted data contains, and it is unavoidable for
any request that leaves the container.

What Scarf derives from that address, what it stores, and for how long are
determined by Scarf and governed by its
[privacy policy](https://about.scarf.sh/privacy-policy). This statement
describes the behavior of this software and cannot characterize Scarf's
internal handling. Operators should be aware that Scarf's services include
deriving organization-level information from network addresses, so the source
address of a deployment should not be assumed to be anonymous once received.

An operator who does not want the source address of their deployment observed
by Scarf should disable collection under [Section 6](#6-your-choices) or direct
transmissions to their own endpoint under
[Section 4.2](#42-the-provider-is-not-a-dependency).

---

## 4. Third-party involvement

### 4.1 Relationship

The DocumentDB project decides what the software transmits, when it is
transmitted, and the default destination. Transmissions are sent to
**[Scarf](https://scarf.sh)**, a third-party analytics provider, which receives
and stores them.

Scarf is a service provider used by this project. It is not a sponsor, partner,
or affiliate of this project. Naming it here is a disclosure: an operator is
entitled to know which party receives a transmission before deciding whether to
permit it.

This statement describes the behavior of this software. It does not describe,
and cannot constrain, how Scarf handles what it receives; that is governed
solely by Scarf's [privacy policy](https://about.scarf.sh/privacy-policy).
Operators who require specific guarantees about that handling should read that
policy, and if it is not acceptable use the controls in
[Section 6](#6-your-choices) or
[Section 4.2](#42-the-provider-is-not-a-dependency).

### 4.2 The provider is not a dependency

The collection mechanism is **provider-neutral**. The image contains no vendor
software development kit, no vendor library, no API key, and no proprietary
payload format. A transmission is an ordinary HTTP GET request with five URL
query parameters.

The destination is a single configurable value. Setting
`DOCUMENTDB_USAGE_TELEMETRY_ENDPOINT` directs all transmissions to any endpoint
capable of receiving an HTTP GET request, including one operated by the
operator, which keeps the data entirely within the operator's own
infrastructure. Substituting a different provider, or self-hosting collection
entirely, requires no change to the software beyond that value.

### 4.3 Disclosure of data

The DocumentDB project does not sell, rent, or trade the data described in
Section 2, and does not itself transfer it to any further party except where
required by law.

Scarf's onward disclosure of what it receives is governed by its
[privacy policy](https://about.scarf.sh/privacy-policy) rather than by this
statement. That policy permits disclosure in circumstances including its own
vendors and subprocessors, corporate affiliates, and the transfer of its
business. This statement cannot and does not restrict those terms. An operator
who does not accept them should disable collection under
[Section 6](#6-your-choices) or direct transmissions to their own endpoint
under [Section 4.2](#42-the-provider-is-not-a-dependency).

The project may publish or discuss aggregate figures derived from this data,
such as counts by release version or platform. The project does not publish
figures that name or single out an individual installation or organization.

### 4.4 Access within the project

Access to telemetry reports is limited to authorized project participants who
require it for project governance, maintenance, compatibility planning, or
adoption analysis. Under the project's [governance charter](../GOVERNANCE.md)
that means the Technical Steering Committee and the maintainers it recognizes,
together with any further participants the Technical Steering Committee
authorizes for one of those purposes.

Access is not granted for any other purpose, and the project does not
redistribute the reports outside that group beyond the aggregate figures
described in Section 4.3.

---

## 5. Retention

Data received by Scarf is retained in accordance with Scarf's policies for this
project's account. Retention is not configured, extended, or controlled by the
container image, and this statement does not set a retention period.

---

## 6. Your choices

### 6.1 Disabling collection

Any one of the following disables collection in full:

```bash
docker run ... documentdb --disable-usage-telemetry
docker run -e DOCUMENTDB_USAGE_TELEMETRY=false ... documentdb
docker run -e NO_ANALYTICS=1 ... documentdb
docker run -e DO_NOT_TRACK=1 ... documentdb
```

When you disable collection, the emitter exits immediately. No background
process runs and no request is made at any point.

### 6.2 Opt-out variables

`NO_ANALYTICS` is this project's opt-out variable. `DO_NOT_TRACK` is a
cross-project convention honored by many independent tools. Either one takes
precedence over every other setting, including an explicit instruction to
enable collection.

### 6.3 Accepted values

All controls accept ordinary spellings, case-insensitively. `false`, `0`, `no`,
`off`, and `disabled` indicate off; the corresponding values indicate on.

An unrecognized value always resolves to collection being **disabled**:

- For `DOCUMENTDB_USAGE_TELEMETRY` and `--usage-telemetry`, a value that cannot
  be interpreted produces a warning and is treated as off.
- For `NO_ANALYTICS` and `DO_NOT_TRACK`, the presence of
  the variable is itself the instruction. Only an explicit off spelling permits
  collection. Every other value is honored as an opt-out, including a value
  that cannot be interpreted and a value carrying stray whitespace, such as
  `NO_ANALYTICS=1 ` originating from an environment file.

Disabling collection can never prevent the container from starting.

### 6.4 Automated environments

The emitter treats the presence of `CI`, `GITHUB_ACTIONS`, or `TF_BUILD` in
**the container's own environment** as a signal not to collect, so that build
agents are not counted as deployments.

This is not automatic for containers. `docker run` does not forward variables
from the host, so a continuous integration system that sets `CI` on the runner
does **not** set it inside the container. If you want to rely on this behavior,
forward the variable explicitly:

```bash
docker run -e CI ... documentdb
```

Otherwise, disable collection directly, which is the clearer option in a
pipeline:

```bash
docker run -e DOCUMENTDB_USAGE_TELEMETRY=false ... documentdb
```

---

## 7. Requests concerning collected data

Requests regarding data collected under this statement, including requests for
deletion, may be directed to the project through
[the project's issue tracker](https://github.com/documentdb/documentdb/issues)
or the contact listed in [SECURITY.md](../SECURITY.md).

Please note the practical limits on such a request. The transmitted fields
(Section 2) contain no identifier, so they cannot by themselves distinguish one
deployment from another. Scarf does, however, receive the network source
address of each request (Section 3.1), and what it retains and can act on is
determined by Scarf.

Whether the events behind a particular request can be located and deleted
therefore depends on Scarf's retention and its capabilities, not on this
software. The project will pass such a request to Scarf and relay its response.
Neither the container image nor the project holds a record that maps an
installation to its events.

---

## 8. Configuration reference

| Purpose | Environment variable | Flag | Default |
|---------|----------------------|------|---------|
| Enable or disable collection | `DOCUMENTDB_USAGE_TELEMETRY` | `--usage-telemetry <true\|false>`, `--disable-usage-telemetry` | `true` |
| Collection endpoint | `DOCUMENTDB_USAGE_TELEMETRY_ENDPOINT` | not applicable | the default collection route |
| Liveness interval, in seconds | `DOCUMENTDB_USAGE_TELEMETRY_INTERVAL_S` | not applicable | `3600` (minimum `60`) |
| Opt-out variables | `NO_ANALYTICS`, `DO_NOT_TRACK` | not applicable | unset |

---

## 9. Operational guarantees

The following properties are enforced by the implementation and verified by the
project's automated tests:

- **Collection cannot degrade performance.** Each transmission is an
  independently backgrounded request with a three second timeout whose output
  is discarded. An endpoint that is slow, blocked, unreachable, or nonexistent
  has no effect on the database, the gateway, or client latency.
- **Collection cannot interrupt service.** No failure in the collection path is
  treated as fatal. An invalid interval or an uninterpretable control value
  produces a warning and a safe fallback rather than a startup failure.
- **Collection ends when the container ends.** The emitter is started by the
  entrypoint and terminated by the same shutdown handler that stops the
  database and the gateway.
- **Collection is auditable.** The entire mechanism is contained in
  [`scripts/usage_telemetry.sh`](scripts/usage_telemetry.sh). A single function
  constructs the query string, and it is the only place in the software that
  determines what leaves the container.

---

## 10. Changes to this statement

Material changes to what is collected, to the purpose of collection, or to the
parties involved will be reflected in this statement and recorded in the
project's changelog. The effective date at the top of this document indicates
when it was last revised.
