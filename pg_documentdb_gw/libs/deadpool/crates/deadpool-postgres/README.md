# Deadpool for PostgreSQL [![Latest Version](https://img.shields.io/crates/v/deadpool-postgres.svg)](https://crates.io/crates/deadpool-postgres) [![Build Status](https://img.shields.io/github/actions/workflow/status/deadpool-rs/deadpool/deadpool-postgres.yml?branch=main)](https://github.com/deadpool-rs/deadpool/actions/workflows/deadpool-postgres.yml?query=branch%3Amain) ![Unsafe forbidden](https://img.shields.io/badge/unsafe-forbidden-success.svg "Unsafe forbidden") [![Rust 1.85+](https://img.shields.io/badge/rustc-1.85+-lightgray.svg "Rust 1.85+")](https://blog.rust-lang.org/2025/02/20/Rust-1.85.0/)

Deadpool is a dead simple async pool for connections and objects
of any type.

This crate implements a [`deadpool`](https://crates.io/crates/deadpool)
manager for [`tokio-postgres`](https://crates.io/crates/tokio-postgres)
and also provides a `statement` cache by wrapping `tokio_postgres::Client`
and `tokio_postgres::Transaction`.

## Features

| Feature          | Description                                                              | Extra dependencies               | Default |
| ---------------- | ------------------------------------------------------------------------ | -------------------------------- | ------- |
| `rt_tokio_1`     | Enable support for [tokio](https://crates.io/crates/tokio) crate         | `deadpool/rt_tokio_1`            | yes     |
| `rt_async-std_1` | Enable support for [async-std](https://crates.io/crates/async-std) crate | `deadpool/rt_async-std_1`        | no      |
| `serde`          | Enable support for [serde](https://crates.io/crates/serde) crate         | `deadpool/serde`, `serde/derive` | no      |

**Important:** `async-std` support is currently limited to the
`async-std` specific timeout function. You still need to enable
the `tokio1` feature of `async-std` in order to use this crate
with `async-std`.

## Example

The following example assumes a PostgreSQL reachable via an unix domain
socket and peer auth enabled for the local user in
[pg\_hba.conf](https://www.postgresql.org/docs/current/auth-pg-hba-conf.html).
If you're running Windows you probably want to specify the `host`, `user`
and `password` in the connection config or use an alternative
[authentication method](https://www.postgresql.org/docs/current/auth-methods.html).

```rust,no_run
use deadpool_postgres::{Config, ManagerConfig, RecyclingMethod, Runtime};
use tokio_postgres::NoTls;

#[tokio::main]
async fn main() {
    let mut cfg = Config::new();
    cfg.dbname = Some("deadpool".to_string());
    cfg.manager = Some(ManagerConfig {
        recycling_method: RecyclingMethod::Fast,
    });
    let pool = cfg.create_pool(Some(Runtime::Tokio1), NoTls).unwrap();
    for i in 1..10i32 {
        let client = pool.get().await.unwrap();
        let stmt = client.prepare_cached("SELECT 1 + $1").await.unwrap();
        let rows = client.query(&stmt, &[&i]).await.unwrap();
        let value: i32 = rows[0].get(0);
        assert_eq!(value, i + 1);
    }
}
```

## Example with `config` and `dotenvy` crate

```env
# .env
PG__DBNAME=deadpool
```

```rust
use deadpool_postgres::Runtime;
use dotenvy::dotenv;
use tokio_postgres::NoTls;

#[derive(Debug, serde::Deserialize)]
struct Config {
    pg: deadpool_postgres::Config,
}

impl Config {
    pub fn from_env() -> Result<Self, config::ConfigError> {
        config::Config::builder()
            .add_source(config::Environment::default().separator("__"))
            .build()?
            .try_deserialize()
    }
}

#[tokio::main]
async fn main() {
    dotenv().ok();
    let cfg = Config::from_env().unwrap();
    let pool = cfg.pg.create_pool(Some(Runtime::Tokio1), NoTls).unwrap();
    for i in 1..10i32 {
        let client = pool.get().await.unwrap();
        let stmt = client.prepare_cached("SELECT 1 + $1").await.unwrap();
        let rows = client.query(&stmt, &[&i]).await.unwrap();
        let value: i32 = rows[0].get(0);
        assert_eq!(value, i + 1);
    }
}
```

**Note:** The code above uses the crate name `config_crate` because of the
`config` feature and both features and dependencies share the same namespace.
In your own code you will probably want to use `::config::ConfigError` and
`::config::Config` instead.

## Example using an existing `tokio_postgres::Config` object

```rust,no_run
use deadpool_postgres::{Manager, ManagerConfig, Pool, RecyclingMethod};
use std::env;
use tokio_postgres::NoTls;

#[tokio::main]
async fn main() {
    let mut pg_config = tokio_postgres::Config::new();
    pg_config.host_path("/run/postgresql");
    pg_config.host_path("/tmp");
    pg_config.user(env::var("USER").unwrap().as_str());
    pg_config.dbname("deadpool");
    let mgr_config = ManagerConfig {
        recycling_method: RecyclingMethod::Fast,
    };
    let mgr = Manager::from_config(pg_config, NoTls, mgr_config);
    let pool = Pool::builder(mgr).max_size(16).build().unwrap();
    for i in 1..10i32 {
        let client = pool.get().await.unwrap();
        let stmt = client.prepare_cached("SELECT 1 + $1").await.unwrap();
        let rows = client.query(&stmt, &[&i]).await.unwrap();
        let value: i32 = rows[0].get(0);
        assert_eq!(value, i + 1);
    }
}
```

## FAQ

- **The database is unreachable. Why does the pool creation not fail?**

  Deadpool has [identical startup and runtime behaviour](https://crates.io/crates/deadpool/#reasons-for-yet-another-connection-pool)
  and therefore the pool creation will never fail.

  If you want your application to crash on startup if no database
  connection can be established just call `pool.get().await` right after
  creating the pool.

- **Why are connections retrieved from the pool sometimes unuseable?**

  In `deadpool-postgres 0.5.5` a new recycling method was implemented which
  is the default since `0.8`. With that recycling method the manager no
  longer performs a test query prior returning the connection but relies
  solely on `tokio_postgres::Client::is_closed` instead. Under some rare
  circumstances (e.g. unreliable networks) this can lead to `tokio_postgres`
  not noticing a disconnect and reporting the connection as useable.

  The old and slightly slower recycling method can be enabled by setting
  `ManagerConfig::recycling_method` to `RecyclingMethod::Verified` or when
  using the `config` crate by setting `PG__MANAGER__RECYCLING_METHOD=Verified`.

- **How can I enable features of the `tokio-postgres` crate?**

  Make sure that you depend on the same version of `tokio-postgres` as
  `deadpool-postgres` does and enable the needed features in your own
  `Crate.toml` file:

  ```toml
  [dependencies]
  deadpool-postgres = { version = "0.9" }
  tokio-postgres = { version = "0.7", features = ["with-uuid-0_8"] }
  ```

  **Important:** The version numbers of `deadpool-postgres` and
  `tokio-postgres` do not necessarily match. If they do it is just a
  coincidence that both crates have the same MAJOR and MINOR version
  number.

  | deadpool-postgres | tokio-postgres |
  | ----------------- | -------------- |
  | 0.7 – 0.12        | 0.7            |
  | 0.6               | 0.6            |
  | 0.4 – 0.5         | 0.5            |
  | 0.2 – 0.3         | 0.5.0-alpha    |

- **How can I clear the statement cache?**

  You can call `pool.manager().statement_cache.clear()` to clear all
  statement caches or `pool.manager().statement_cache.remove()` to remove
  a single statement from all caches.

  **Important:** The `ClientWrapper` also provides a `statement_cache`
  field which has `clear()` and `remove()` methods which only affect
  a single client.

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE) or <http://www.apache.org/licenses/LICENSE-2.0>)
- MIT license ([LICENSE-MIT](LICENSE-MIT) or <http://opensource.org/licenses/MIT>)

at your option.
