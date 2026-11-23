#![doc = include_str!("../README.md")]
#![cfg_attr(docsrs, feature(doc_cfg))]
#![deny(
    nonstandard_style,
    rust_2018_idioms,
    rustdoc::broken_intra_doc_links,
    rustdoc::private_intra_doc_links
)]
#![forbid(non_ascii_idents, unsafe_code)]
#![warn(
    deprecated_in_future,
    missing_copy_implementations,
    missing_debug_implementations,
    missing_docs,
    unreachable_pub,
    unused_import_braces,
    unused_labels,
    unused_lifetimes,
    unused_qualifications,
    unused_results
)]

mod config;
mod generic_client;
mod statement_cache;

use std::{
    fmt,
    future::Future,
    ops::{Deref, DerefMut},
    pin::Pin,
    sync::Arc,
};

use deadpool::managed;
#[cfg(not(target_arch = "wasm32"))]
use tokio::spawn;
use tokio::task::JoinHandle;
use tokio_postgres::{
    Client as PgClient, Config as PgConfig, Error, IsolationLevel, Statement,
    Transaction as PgTransaction, TransactionBuilder as PgTransactionBuilder, types::Type,
};

#[cfg(not(target_arch = "wasm32"))]
use tokio_postgres::{
    Socket,
    tls::{MakeTlsConnect, TlsConnect},
};

pub use tokio_postgres;

pub use crate::statement_cache::{StatementCache, StatementCaches};

pub use self::config::{
    ChannelBinding, Config, ConfigError, LoadBalanceHosts, ManagerConfig, RecyclingMethod, SslMode,
    TargetSessionAttrs,
};

pub use self::generic_client::GenericClient;

pub use deadpool::managed::reexports::*;
deadpool::managed_reexports!(
    "tokio_postgres",
    Manager,
    managed::Object<Manager>,
    Error,
    ConfigError
);

type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// Type alias for [`Object`]
pub type Client = Object;

type RecycleResult = managed::RecycleResult<Error>;
type RecycleError = managed::RecycleError<Error>;

/// [`Manager`] for creating and recycling PostgreSQL connections.
///
/// [`Manager`]: managed::Manager
pub struct Manager {
    config: ManagerConfig,
    pg_config: PgConfig,
    connect: Box<dyn Connect>,
    /// [`StatementCaches`] of [`Client`]s handed out by the [`Pool`].
    pub statement_caches: StatementCaches,
}

impl Manager {
    #[cfg(not(target_arch = "wasm32"))]
    /// Creates a new [`Manager`] using the given [`tokio_postgres::Config`] and
    /// `tls` connector.
    pub fn new<T>(pg_config: tokio_postgres::Config, tls: T) -> Self
    where
        T: MakeTlsConnect<Socket> + Clone + Sync + Send + 'static,
        T::Stream: Sync + Send,
        T::TlsConnect: Sync + Send,
        <T::TlsConnect as TlsConnect<Socket>>::Future: Send,
    {
        Self::from_config(pg_config, tls, ManagerConfig::default())
    }

    #[cfg(not(target_arch = "wasm32"))]
    /// Create a new [`Manager`] using the given [`tokio_postgres::Config`], and
    /// `tls` connector and [`ManagerConfig`].
    pub fn from_config<T>(pg_config: tokio_postgres::Config, tls: T, config: ManagerConfig) -> Self
    where
        T: MakeTlsConnect<Socket> + Clone + Sync + Send + 'static,
        T::Stream: Sync + Send,
        T::TlsConnect: Sync + Send,
        <T::TlsConnect as TlsConnect<Socket>>::Future: Send,
    {
        Self::from_connect(pg_config, ConfigConnectImpl { tls }, config)
    }

    /// Create a new [`Manager`] using the given [`tokio_postgres::Config`], and
    /// `connect` impl and [`ManagerConfig`].
    pub fn from_connect(
        pg_config: tokio_postgres::Config,
        connect: impl Connect + 'static,
        config: ManagerConfig,
    ) -> Self {
        Self {
            config,
            pg_config,
            connect: Box::new(connect),
            statement_caches: StatementCaches::default(),
        }
    }
}

impl fmt::Debug for Manager {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Manager")
            .field("config", &self.config)
            .field("pg_config", &self.pg_config)
            //.field("connect", &self.connect)
            .field("statement_caches", &self.statement_caches)
            .finish()
    }
}

impl managed::Manager for Manager {
    type Type = ClientWrapper;
    type Error = Error;

    async fn create(&self) -> Result<ClientWrapper, Error> {
        let (client, conn_task) = self.connect.connect(&self.pg_config).await?;
        let client_wrapper = ClientWrapper::new(client, conn_task);
        self.statement_caches
            .attach(&client_wrapper.statement_cache);
        Ok(client_wrapper)
    }

    async fn recycle(&self, client: &mut ClientWrapper, _: &Metrics) -> RecycleResult {
        if client.is_closed() {
            tracing::warn!(target: "deadpool.postgres", "Connection could not be recycled: Connection closed");
            return Err(RecycleError::message("Connection closed"));
        }
        match self.config.recycling_method.query() {
            Some(sql) => match client.simple_query(sql).await {
                Ok(_) => Ok(()),
                Err(e) => {
                    tracing::warn!(target: "deadpool.postgres", "Connection could not be recycled: {}", e);
                    Err(e.into())
                }
            },
            None => Ok(()),
        }
    }

    fn detach(&self, object: &mut ClientWrapper) {
        self.statement_caches.detach(&object.statement_cache);
    }
}

/// Describes a mechanism for establishing a connection to a PostgreSQL
/// server via `tokio_postgres`.
pub trait Connect: Sync + Send {
    /// Establishes a new `tokio_postgres` connection, returning
    /// the associated `Client` and a `JoinHandle` to a tokio task
    /// for processing the connection.
    fn connect(
        &self,
        pg_config: &PgConfig,
    ) -> BoxFuture<'_, Result<(PgClient, JoinHandle<()>), Error>>;
}

#[cfg(not(target_arch = "wasm32"))]
/// Provides an implementation of [`Connect`] that establishes the connection
/// using the `tokio_postgres` configuration itself.
#[derive(Debug)]
pub struct ConfigConnectImpl<T>
where
    T: MakeTlsConnect<Socket> + Clone + Sync + Send + 'static,
    T::Stream: Sync + Send,
    T::TlsConnect: Sync + Send,
    <T::TlsConnect as TlsConnect<Socket>>::Future: Send,
{
    /// The TLS connector to use for the connection.
    pub tls: T,
}

#[cfg(not(target_arch = "wasm32"))]
impl<T> Connect for ConfigConnectImpl<T>
where
    T: MakeTlsConnect<Socket> + Clone + Sync + Send + 'static,
    T::Stream: Sync + Send,
    T::TlsConnect: Sync + Send,
    <T::TlsConnect as TlsConnect<Socket>>::Future: Send,
{
    fn connect(
        &self,
        pg_config: &PgConfig,
    ) -> BoxFuture<'_, Result<(PgClient, JoinHandle<()>), Error>> {
        let tls = self.tls.clone();
        let pg_config = pg_config.clone();
        Box::pin(async move {
            let fut = pg_config.connect(tls);
            let (client, connection) = fut.await?;
            let conn_task = spawn(async move {
                if let Err(e) = connection.await {
                    tracing::warn!(target: "deadpool.postgres", "Connection error: {}", e);
                }
            });
            Ok((client, conn_task))
        })
    }
}

/// Wrapper around [`tokio_postgres::Client`] with a [`StatementCache`].
#[derive(Debug)]
pub struct ClientWrapper {
    /// Original [`PgClient`].
    client: PgClient,

    /// A handle to the connection task that should be aborted when the client
    /// wrapper is dropped.
    conn_task: JoinHandle<()>,

    /// [`StatementCache`] of this client.
    pub statement_cache: Arc<StatementCache>,
}

impl ClientWrapper {
    /// Create a new [`ClientWrapper`] instance using the given
    /// [`tokio_postgres::Client`] and handle to the connection task.
    #[must_use]
    pub fn new(client: PgClient, conn_task: JoinHandle<()>) -> Self {
        Self {
            client,
            conn_task,
            statement_cache: Arc::new(StatementCache::new()),
        }
    }

    /// Like [`tokio_postgres::Client::prepare()`], but uses an existing
    /// [`Statement`] from the [`StatementCache`] if possible.
    pub async fn prepare_cached(&self, query: &str) -> Result<Statement, Error> {
        self.statement_cache.prepare(&self.client, query).await
    }

    /// Like [`tokio_postgres::Client::prepare_typed()`], but uses an
    /// existing [`Statement`] from the [`StatementCache`] if possible.
    pub async fn prepare_typed_cached(
        &self,
        query: &str,
        types: &[Type],
    ) -> Result<Statement, Error> {
        self.statement_cache
            .prepare_typed(&self.client, query, types)
            .await
    }

    /// Like [`tokio_postgres::Client::transaction()`], but returns a wrapped
    /// [`Transaction`] with a [`StatementCache`].
    #[allow(unused_lifetimes)] // false positive
    pub async fn transaction(&mut self) -> Result<Transaction<'_>, Error> {
        Ok(Transaction {
            txn: PgClient::transaction(&mut self.client).await?,
            statement_cache: self.statement_cache.clone(),
        })
    }

    /// Like [`tokio_postgres::Client::build_transaction()`], but creates a
    /// wrapped [`Transaction`] with a [`StatementCache`].
    pub fn build_transaction(&mut self) -> TransactionBuilder<'_> {
        TransactionBuilder {
            builder: self.client.build_transaction(),
            statement_cache: self.statement_cache.clone(),
        }
    }
}

impl Deref for ClientWrapper {
    type Target = PgClient;

    fn deref(&self) -> &PgClient {
        &self.client
    }
}

impl DerefMut for ClientWrapper {
    fn deref_mut(&mut self) -> &mut PgClient {
        &mut self.client
    }
}

impl Drop for ClientWrapper {
    fn drop(&mut self) {
        self.conn_task.abort()
    }
}

/// Wrapper around [`tokio_postgres::Transaction`] with a [`StatementCache`]
/// from the [`Client`] object it was created by.
pub struct Transaction<'a> {
    /// Original [`PgTransaction`].
    txn: PgTransaction<'a>,

    /// [`StatementCache`] of this [`Transaction`].
    pub statement_cache: Arc<StatementCache>,
}

impl Transaction<'_> {
    /// Like [`tokio_postgres::Transaction::prepare()`], but uses an existing
    /// [`Statement`] from the [`StatementCache`] if possible.
    pub async fn prepare_cached(&self, query: &str) -> Result<Statement, Error> {
        self.statement_cache.prepare(self.client(), query).await
    }

    /// Like [`tokio_postgres::Transaction::prepare_typed()`], but uses an
    /// existing [`Statement`] from the [`StatementCache`] if possible.
    pub async fn prepare_typed_cached(
        &self,
        query: &str,
        types: &[Type],
    ) -> Result<Statement, Error> {
        self.statement_cache
            .prepare_typed(self.client(), query, types)
            .await
    }

    /// Like [`tokio_postgres::Transaction::commit()`].
    pub async fn commit(self) -> Result<(), Error> {
        self.txn.commit().await
    }

    /// Like [`tokio_postgres::Transaction::rollback()`].
    pub async fn rollback(self) -> Result<(), Error> {
        self.txn.rollback().await
    }

    /// Like [`tokio_postgres::Transaction::transaction()`], but returns a
    /// wrapped [`Transaction`] with a [`StatementCache`].
    #[allow(unused_lifetimes)] // false positive
    pub async fn transaction(&mut self) -> Result<Transaction<'_>, Error> {
        Ok(Transaction {
            txn: PgTransaction::transaction(&mut self.txn).await?,
            statement_cache: self.statement_cache.clone(),
        })
    }

    /// Like [`tokio_postgres::Transaction::savepoint()`], but returns a wrapped
    /// [`Transaction`] with a [`StatementCache`].
    #[allow(unused_lifetimes)] // false positive
    pub async fn savepoint<I>(&mut self, name: I) -> Result<Transaction<'_>, Error>
    where
        I: Into<String>,
    {
        Ok(Transaction {
            txn: PgTransaction::savepoint(&mut self.txn, name).await?,
            statement_cache: self.statement_cache.clone(),
        })
    }
}

impl fmt::Debug for Transaction<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Transaction")
            //.field("txn", &self.txn)
            .field("statement_cache", &self.statement_cache)
            .finish()
    }
}

impl<'a> Deref for Transaction<'a> {
    type Target = PgTransaction<'a>;

    fn deref(&self) -> &PgTransaction<'a> {
        &self.txn
    }
}

impl<'a> DerefMut for Transaction<'a> {
    fn deref_mut(&mut self) -> &mut PgTransaction<'a> {
        &mut self.txn
    }
}

/// Wrapper around [`tokio_postgres::TransactionBuilder`] with a
/// [`StatementCache`] from the [`Client`] object it was created by.
#[must_use = "builder does nothing itself, use `.start()` to use it"]
pub struct TransactionBuilder<'a> {
    /// Original [`PgTransactionBuilder`].
    builder: PgTransactionBuilder<'a>,

    /// [`StatementCache`] of this [`TransactionBuilder`].
    statement_cache: Arc<StatementCache>,
}

impl<'a> TransactionBuilder<'a> {
    /// Sets the isolation level of the transaction.
    ///
    /// Like [`tokio_postgres::TransactionBuilder::isolation_level()`].
    pub fn isolation_level(self, isolation_level: IsolationLevel) -> Self {
        Self {
            builder: self.builder.isolation_level(isolation_level),
            statement_cache: self.statement_cache,
        }
    }

    /// Sets the access mode of the transaction.
    ///
    /// Like [`tokio_postgres::TransactionBuilder::read_only()`].
    pub fn read_only(self, read_only: bool) -> Self {
        Self {
            builder: self.builder.read_only(read_only),
            statement_cache: self.statement_cache,
        }
    }

    /// Sets the deferrability of the transaction.
    ///
    /// If the transaction is also serializable and read only, creation
    /// of the transaction may block, but when it completes the transaction
    /// is able to run with less overhead and a guarantee that it will not
    /// be aborted due to serialization failure.
    ///
    /// Like [`tokio_postgres::TransactionBuilder::deferrable()`].
    pub fn deferrable(self, deferrable: bool) -> Self {
        Self {
            builder: self.builder.deferrable(deferrable),
            statement_cache: self.statement_cache,
        }
    }

    /// Begins the [`Transaction`].
    ///
    /// The transaction will roll back by default - use the commit method
    /// to commit it.
    ///
    /// Like [`tokio_postgres::TransactionBuilder::start()`].
    pub async fn start(self) -> Result<Transaction<'a>, Error> {
        Ok(Transaction {
            txn: self.builder.start().await?,
            statement_cache: self.statement_cache,
        })
    }
}

impl fmt::Debug for TransactionBuilder<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("TransactionBuilder")
            //.field("builder", &self.builder)
            .field("statement_cache", &self.statement_cache)
            .finish()
    }
}

impl<'a> Deref for TransactionBuilder<'a> {
    type Target = PgTransactionBuilder<'a>;

    fn deref(&self) -> &Self::Target {
        &self.builder
    }
}

impl DerefMut for TransactionBuilder<'_> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.builder
    }
}
