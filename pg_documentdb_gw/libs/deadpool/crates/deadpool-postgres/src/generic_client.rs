//! This is a 1:1 copy of the `tokio_postgres::GenericClient`
//! trait as of `tokio-postgres 0.7.7` with two changes:
//! - The `client()` method is not available.
//! - The `prepare_cached()` and `prepare_typed_cached()` are
//!   added.
use tokio_postgres::RowStream;
use tokio_postgres::types::{BorrowToSql, ToSql, Type};
use tokio_postgres::{Error, Row, Statement, ToStatement};

use async_trait::async_trait;

use crate::{Client, ClientWrapper, Transaction};

mod private {
    pub trait Sealed {}
}

/// A trait allowing abstraction over connections and transactions.
///
/// This trait is "sealed", and cannot be implemented outside of this crate.
#[async_trait]
pub trait GenericClient: Sync + private::Sealed {
    /// Like `Client::execute`.
    async fn execute<T>(&self, query: &T, params: &[&(dyn ToSql + Sync)]) -> Result<u64, Error>
    where
        T: ?Sized + ToStatement + Sync + Send;

    /// Like `Client::execute_raw`.
    async fn execute_raw<P, I, T>(&self, statement: &T, params: I) -> Result<u64, Error>
    where
        T: ?Sized + ToStatement + Sync + Send,
        P: BorrowToSql,
        I: IntoIterator<Item = P> + Sync + Send,
        I::IntoIter: ExactSizeIterator;

    /// Like `Client::query`.
    async fn query<T>(&self, query: &T, params: &[&(dyn ToSql + Sync)]) -> Result<Vec<Row>, Error>
    where
        T: ?Sized + ToStatement + Sync + Send;

    /// Like `Client::query_one`.
    async fn query_one<T>(
        &self,
        statement: &T,
        params: &[&(dyn ToSql + Sync)],
    ) -> Result<Row, Error>
    where
        T: ?Sized + ToStatement + Sync + Send;

    /// Like `Client::query_opt`.
    async fn query_opt<T>(
        &self,
        statement: &T,
        params: &[&(dyn ToSql + Sync)],
    ) -> Result<Option<Row>, Error>
    where
        T: ?Sized + ToStatement + Sync + Send;

    /// Like `Client::query_raw`.
    async fn query_raw<T, P, I>(&self, statement: &T, params: I) -> Result<RowStream, Error>
    where
        T: ?Sized + ToStatement + Sync + Send,
        P: BorrowToSql,
        I: IntoIterator<Item = P> + Sync + Send,
        I::IntoIter: ExactSizeIterator;

    /// Like `Client::prepare`.
    async fn prepare(&self, query: &str) -> Result<Statement, Error>;

    /// Like `Client::prepare_typed`.
    async fn prepare_typed(
        &self,
        query: &str,
        parameter_types: &[Type],
    ) -> Result<Statement, Error>;

    /// Like [`Client::prepare_cached`].
    async fn prepare_cached(&self, query: &str) -> Result<Statement, Error>;

    /// Like [`Client::prepare_typed_cached`]
    async fn prepare_typed_cached(&self, query: &str, types: &[Type]) -> Result<Statement, Error>;

    /// Like `Client::transaction`.
    async fn transaction(&mut self) -> Result<Transaction<'_>, Error>;

    /// Like `Client::batch_execute`.
    async fn batch_execute(&self, query: &str) -> Result<(), Error>;
}

impl private::Sealed for Client {}

#[async_trait]
impl GenericClient for Client {
    async fn execute<T>(&self, query: &T, params: &[&(dyn ToSql + Sync)]) -> Result<u64, Error>
    where
        T: ?Sized + ToStatement + Sync + Send,
    {
        tokio_postgres::Client::execute(self, query, params).await
    }

    async fn execute_raw<P, I, T>(&self, statement: &T, params: I) -> Result<u64, Error>
    where
        T: ?Sized + ToStatement + Sync + Send,
        P: BorrowToSql,
        I: IntoIterator<Item = P> + Sync + Send,
        I::IntoIter: ExactSizeIterator,
    {
        tokio_postgres::Client::execute_raw(self, statement, params).await
    }

    async fn query<T>(&self, query: &T, params: &[&(dyn ToSql + Sync)]) -> Result<Vec<Row>, Error>
    where
        T: ?Sized + ToStatement + Sync + Send,
    {
        tokio_postgres::Client::query(self, query, params).await
    }

    async fn query_one<T>(
        &self,
        statement: &T,
        params: &[&(dyn ToSql + Sync)],
    ) -> Result<Row, Error>
    where
        T: ?Sized + ToStatement + Sync + Send,
    {
        tokio_postgres::Client::query_one(self, statement, params).await
    }

    async fn query_opt<T>(
        &self,
        statement: &T,
        params: &[&(dyn ToSql + Sync)],
    ) -> Result<Option<Row>, Error>
    where
        T: ?Sized + ToStatement + Sync + Send,
    {
        tokio_postgres::Client::query_opt(self, statement, params).await
    }

    async fn query_raw<T, P, I>(&self, statement: &T, params: I) -> Result<RowStream, Error>
    where
        T: ?Sized + ToStatement + Sync + Send,
        P: BorrowToSql,
        I: IntoIterator<Item = P> + Sync + Send,
        I::IntoIter: ExactSizeIterator,
    {
        tokio_postgres::Client::query_raw(self, statement, params).await
    }

    async fn prepare(&self, query: &str) -> Result<Statement, Error> {
        tokio_postgres::Client::prepare(self, query).await
    }

    async fn prepare_typed(
        &self,
        query: &str,
        parameter_types: &[Type],
    ) -> Result<Statement, Error> {
        tokio_postgres::Client::prepare_typed(self, query, parameter_types).await
    }

    async fn prepare_cached(&self, query: &str) -> Result<Statement, Error> {
        ClientWrapper::prepare_cached(self, query).await
    }

    async fn prepare_typed_cached(&self, query: &str, types: &[Type]) -> Result<Statement, Error> {
        ClientWrapper::prepare_typed_cached(self, query, types).await
    }

    async fn transaction(&mut self) -> Result<Transaction<'_>, Error> {
        ClientWrapper::transaction(self).await
    }

    async fn batch_execute(&self, query: &str) -> Result<(), Error> {
        tokio_postgres::Client::batch_execute(self, query).await
    }
}

impl private::Sealed for Transaction<'_> {}

#[async_trait]
#[allow(clippy::needless_lifetimes)]
impl GenericClient for Transaction<'_> {
    async fn execute<T>(&self, query: &T, params: &[&(dyn ToSql + Sync)]) -> Result<u64, Error>
    where
        T: ?Sized + ToStatement + Sync + Send,
    {
        tokio_postgres::Transaction::execute(self, query, params).await
    }

    async fn execute_raw<P, I, T>(&self, statement: &T, params: I) -> Result<u64, Error>
    where
        T: ?Sized + ToStatement + Sync + Send,
        P: BorrowToSql,
        I: IntoIterator<Item = P> + Sync + Send,
        I::IntoIter: ExactSizeIterator,
    {
        tokio_postgres::Transaction::execute_raw(self, statement, params).await
    }

    async fn query<T>(&self, query: &T, params: &[&(dyn ToSql + Sync)]) -> Result<Vec<Row>, Error>
    where
        T: ?Sized + ToStatement + Sync + Send,
    {
        tokio_postgres::Transaction::query(self, query, params).await
    }

    async fn query_one<T>(
        &self,
        statement: &T,
        params: &[&(dyn ToSql + Sync)],
    ) -> Result<Row, Error>
    where
        T: ?Sized + ToStatement + Sync + Send,
    {
        tokio_postgres::Transaction::query_one(self, statement, params).await
    }

    async fn query_opt<T>(
        &self,
        statement: &T,
        params: &[&(dyn ToSql + Sync)],
    ) -> Result<Option<Row>, Error>
    where
        T: ?Sized + ToStatement + Sync + Send,
    {
        tokio_postgres::Transaction::query_opt(self, statement, params).await
    }

    async fn query_raw<T, P, I>(&self, statement: &T, params: I) -> Result<RowStream, Error>
    where
        T: ?Sized + ToStatement + Sync + Send,
        P: BorrowToSql,
        I: IntoIterator<Item = P> + Sync + Send,
        I::IntoIter: ExactSizeIterator,
    {
        tokio_postgres::Transaction::query_raw(self, statement, params).await
    }

    async fn prepare(&self, query: &str) -> Result<Statement, Error> {
        tokio_postgres::Transaction::prepare(self, query).await
    }

    async fn prepare_typed(
        &self,
        query: &str,
        parameter_types: &[Type],
    ) -> Result<Statement, Error> {
        tokio_postgres::Transaction::prepare_typed(self, query, parameter_types).await
    }

    async fn prepare_cached(&self, query: &str) -> Result<Statement, Error> {
        Transaction::prepare_cached(self, query).await
    }

    async fn prepare_typed_cached(&self, query: &str, types: &[Type]) -> Result<Statement, Error> {
        Transaction::prepare_typed_cached(self, query, types).await
    }

    #[allow(clippy::needless_lifetimes)]
    async fn transaction<'a>(&'a mut self) -> Result<Transaction<'a>, Error> {
        Transaction::transaction(self).await
    }

    async fn batch_execute(&self, query: &str) -> Result<(), Error> {
        tokio_postgres::Transaction::batch_execute(self, query).await
    }
}
