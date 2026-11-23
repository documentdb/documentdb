use std::{collections::HashMap, env, time::Duration};

use futures::future;
use serde::{Deserialize, Serialize};
use tokio_postgres::{IsolationLevel, types::Type};

use deadpool_postgres::{ManagerConfig, Pool, RecyclingMethod, Runtime};

#[derive(Debug, Deserialize, Serialize)]
struct Config {
    #[serde(default)]
    pg: deadpool_postgres::Config,
}

impl Config {
    pub fn from_env() -> Self {
        let cfg = config::Config::builder()
            .add_source(config::Environment::default().separator("__"))
            .build()
            .unwrap();

        let mut cfg = cfg.try_deserialize::<Self>().unwrap();
        cfg.pg.dbname.get_or_insert("deadpool".to_string());
        cfg
    }

    pub fn from_env_with_prefix(prefix: &str) -> Self {
        let cfg = config::Config::builder()
            .add_source(config::Environment::with_prefix(prefix).separator("__"))
            .build()
            .unwrap();
        let mut cfg = cfg.try_deserialize::<Self>().unwrap();
        cfg.pg.dbname.get_or_insert("deadpool".to_string());
        cfg
    }
}

fn create_pool() -> Pool {
    let cfg = Config::from_env();
    cfg.pg
        .create_pool(Some(Runtime::Tokio1), tokio_postgres::NoTls)
        .unwrap()
}

fn create_pool_defaultdb() -> Pool {
    let mut cfg = Config::from_env();
    cfg.pg.dbname = None;
    cfg.pg
        .create_pool(Some(Runtime::Tokio1), tokio_postgres::NoTls)
        .unwrap()
}

async fn basic_tests(pool: Pool) {
    let client = pool.get().await.unwrap();
    let stmt = client.prepare_cached("SELECT 1 + 2").await.unwrap();
    let rows = client.query(&stmt, &[]).await.unwrap();
    let value: i32 = rows[0].get(0);
    assert_eq!(value, 3);
    assert_eq!(client.statement_cache.size(), 1);
}

#[tokio::test]
async fn basic() {
    basic_tests(create_pool()).await;
}

#[tokio::test]
async fn basic_defaultdb() {
    basic_tests(create_pool_defaultdb()).await;
}

#[tokio::test]
async fn prepare_typed_cached() {
    let pool = create_pool();
    let client = pool.get().await.unwrap();
    let stmt = client
        .prepare_typed_cached("SELECT 1 + $1", &[Type::INT2])
        .await
        .unwrap();
    let rows = client.query(&stmt, &[&42i16]).await.unwrap();
    let value: i32 = rows[0].get(0);
    assert_eq!(value, 43i32);
}

#[tokio::test]
async fn prepare_typed_error() {
    let pool = create_pool();
    let client = pool.get().await.unwrap();
    let stmt = client
        .prepare_typed_cached("SELECT 1 + $1", &[Type::INT2])
        .await
        .unwrap();
    assert!(client.query(&stmt, &[&42i32]).await.is_err());
}

#[tokio::test]
async fn transaction_1() {
    let pool = create_pool();
    let mut client = pool.get().await.unwrap();
    {
        let txn = client.transaction().await.unwrap();
        let stmt = txn.prepare_cached("SELECT 1 + 2").await.unwrap();
        let rows = txn.query(&stmt, &[]).await.unwrap();
        let value: i32 = rows[0].get(0);
        txn.commit().await.unwrap();
        assert_eq!(value, 3);
    }
    assert_eq!(client.statement_cache.size(), 1);
}

#[tokio::test]
async fn transaction_2() {
    let pool = create_pool();
    let mut client = pool.get().await.unwrap();
    let stmt = client.prepare_cached("SELECT 1 + 2").await.unwrap();
    {
        let txn = client.transaction().await.unwrap();
        let rows = txn.query(&stmt, &[]).await.unwrap();
        let value: i32 = rows[0].get(0);
        txn.commit().await.unwrap();
        assert_eq!(value, 3);
    }
    assert_eq!(client.statement_cache.size(), 1);
}

#[tokio::test]
async fn transaction_pipeline() {
    let pool = create_pool();
    let mut client = pool.get().await.unwrap();
    let stmt = client.prepare_cached("SELECT 1 + $1").await.unwrap();
    let txn = client.transaction().await.unwrap();
    let mut futures = vec![];
    for i in 0..100i32 {
        let stmt = stmt.clone();
        let txn = &txn;
        futures.push(async move {
            let rows = txn.query(&stmt, &[&i]).await.unwrap();
            let value: i32 = rows[0].get(0);
            value
        });
    }
    let results = future::join_all(futures).await;
    for (i, &result) in results.iter().enumerate() {
        assert_eq!(result, (i as i32) + 1);
    }
}

#[tokio::test]
async fn transaction_builder() {
    let pool = create_pool();
    let mut client = pool.get().await.unwrap();
    let txn = client
        .build_transaction()
        .isolation_level(IsolationLevel::ReadUncommitted)
        .read_only(true)
        .deferrable(true)
        .start()
        .await
        .unwrap();
    let rows = txn.query("SELECT 1 + 2", &[]).await.unwrap();
    let value: i32 = rows[0].get(0);
    assert_eq!(value, 3);
    txn.commit().await.unwrap();
}

#[tokio::test]
async fn generic_client() {
    let pool = create_pool();
    let client = pool.get().await.unwrap();
    _use_generic_client(&**client);
}

#[tokio::test]
async fn recycling_methods() {
    let recycling_methods = vec![
        RecyclingMethod::Fast,
        RecyclingMethod::Verified,
        RecyclingMethod::Clean,
        RecyclingMethod::Custom("DISCARD ALL;".to_string()),
    ];
    let mut cfg = Config::from_env();
    for recycling_method in recycling_methods {
        cfg.pg.manager = Some(ManagerConfig { recycling_method });
        let pool = cfg
            .pg
            .create_pool(Some(Runtime::Tokio1), tokio_postgres::NoTls)
            .unwrap();
        for _ in 0usize..20usize {
            let client = pool.get().await.unwrap();
            let rows = client.query("SELECT 1 + 2", &[]).await.unwrap();
            let value: i32 = rows[0].get(0);
            assert_eq!(value, 3);
        }
    }
}

fn _use_generic_client(_client: &impl tokio_postgres::GenericClient) {
    // nop
}

#[tokio::test]
async fn statement_cache_clear() {
    let pool = create_pool();
    let client = pool.get().await.unwrap();
    assert!(client.statement_cache.size() == 0);
    client.prepare_cached("SELECT 1;").await.unwrap();
    assert!(client.statement_cache.size() == 1);
    client.statement_cache.clear();
    assert!(client.statement_cache.size() == 0);
}

#[tokio::test]
async fn statement_caches_clear() {
    let pool = create_pool();
    // prepare 1st client
    let client0 = pool.get().await.unwrap();
    assert!(client0.statement_cache.size() == 0);
    client0.prepare_cached("SELECT 1;").await.unwrap();
    assert!(client0.statement_cache.size() == 1);
    // prepare 2nd client
    let client1 = pool.get().await.unwrap();
    assert!(client1.statement_cache.size() == 0);
    client1.prepare_cached("SELECT 1;").await.unwrap();
    assert!(client1.statement_cache.size() == 1);
    // clear statement cache using manager
    pool.manager().statement_caches.clear();
    assert!(client0.statement_cache.size() == 0);
    assert!(client1.statement_cache.size() == 0);
}

struct Env {
    backup: HashMap<String, Option<String>>,
}

impl Env {
    pub fn new() -> Self {
        Self {
            backup: HashMap::new(),
        }
    }
    pub fn set(&mut self, name: &str, value: &str) {
        self.backup.insert(name.to_string(), env::var(name).ok());
        unsafe {
            env::set_var(name, value);
        }
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        for (name, value) in self.backup.iter() {
            println!("setting {} = {:?}", name, value);
            unsafe {
                match value {
                    Some(val) => env::set_var(name.as_str(), val),
                    None => env::remove_var(name.as_str()),
                }
            }
        }
    }
}

#[cfg(feature = "serde")]
#[test]
fn config_from_env() {
    // This test must not use "PG" as prefix as this can cause the other
    // tests which also use the "PG" prefix to fail.
    let mut env = Env::new();
    env.set("ENV_TEST__PG__HOST", "pg.example.com");
    env.set("ENV_TEST__PG__PORT", "5433");
    env.set("ENV_TEST__PG__USER", "john_doe");
    env.set("ENV_TEST__PG__PASSWORD", "topsecret");
    env.set("ENV_TEST__PG__DBNAME", "example");
    env.set("ENV_TEST__PG__POOL__MAX_SIZE", "42");
    env.set("ENV_TEST__PG__POOL__TIMEOUTS__WAIT__SECS", "1");
    env.set("ENV_TEST__PG__POOL__TIMEOUTS__WAIT__NANOS", "0");
    env.set("ENV_TEST__PG__POOL__TIMEOUTS__CREATE__SECS", "2");
    env.set("ENV_TEST__PG__POOL__TIMEOUTS__CREATE__NANOS", "0");
    env.set("ENV_TEST__PG__POOL__TIMEOUTS__RECYCLE__SECS", "3");
    env.set("ENV_TEST__PG__POOL__TIMEOUTS__RECYCLE__NANOS", "0");
    let cfg = Config::from_env_with_prefix("ENV_TEST");
    // `tokio_postgres::Config` does not provide any read access to its
    // internals, so we can only check if the environment was actually read
    // correctly.
    assert_eq!(cfg.pg.host, Some("pg.example.com".to_string()));
    assert_eq!(cfg.pg.port, Some(5433));
    assert_eq!(cfg.pg.user, Some("john_doe".to_string()));
    assert_eq!(cfg.pg.password, Some("topsecret".to_string()));
    assert_eq!(cfg.pg.dbname, Some("example".to_string()));
    let pool_cfg = cfg.pg.get_pool_config();
    assert_eq!(pool_cfg.max_size, 42);
    assert_eq!(pool_cfg.timeouts.wait, Some(Duration::from_secs(1)));
    assert_eq!(pool_cfg.timeouts.create, Some(Duration::from_secs(2)));
    assert_eq!(pool_cfg.timeouts.recycle, Some(Duration::from_secs(3)));
}

#[test]
fn config_url() {
    let mut cfg = deadpool_postgres::Config {
        url: Some("postgresql://zombie@localhost/deadpool".into()),
        ..Default::default()
    };
    {
        let pg_cfg = cfg.get_pg_config().unwrap();
        assert_eq!(pg_cfg.get_dbname(), Some("deadpool"));
        assert_eq!(pg_cfg.get_user(), Some("zombie"));
        assert_eq!(
            pg_cfg.get_hosts(),
            &[tokio_postgres::config::Host::Tcp("localhost".into())]
        );
    }
    // now apply some overrides
    {
        cfg.dbname = Some("livepool".into());
        cfg.host = Some("remotehost".into());
        cfg.user = Some("human".into());
        let pg_cfg = cfg.get_pg_config().unwrap();
        assert_eq!(pg_cfg.get_dbname(), Some("livepool"));
        assert_eq!(pg_cfg.get_user(), Some("human"));
        assert_eq!(
            pg_cfg.get_hosts(),
            &[
                tokio_postgres::config::Host::Tcp("localhost".into()),
                tokio_postgres::config::Host::Tcp("remotehost".into()),
            ]
        );
    }
}
