// This code must compile even without the async_trait crate
// See: https://github.com/deadpool-rs/deadpool/issues/323

use deadpool_postgres::{GenericClient, tokio_postgres::Row};
use futures_util::{Stream, StreamExt};
use std::future::Future;
use tokio_postgres::types::ToSql;

// this function borrowed from tokio_postgres source code
fn slice_iter<'a>(
    s: &'a [&'a (dyn ToSql + Sync)],
) -> impl ExactSizeIterator<Item = &'a dyn ToSql> + 'a {
    s.iter().map(|s| *s as _)
}

pub trait PgQuery {
    fn query_raw(
        db: &impl GenericClient,
        params: &[&(dyn ToSql + Sync)],
    ) -> impl Future<Output = impl Stream<Item = Row>> + Send {
        async {
            let rows = db.query_raw("SELECT 1", slice_iter(params)).await.unwrap();
            rows.map(|row| row.unwrap())
        }
    }
}
