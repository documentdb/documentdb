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
#![allow(clippy::uninlined_format_args)]

use std::{any::Any, fmt, future::Future, time::Duration};

/// Enumeration for picking a runtime implementation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[non_exhaustive]
pub enum Runtime {
    #[cfg(feature = "tokio_1")]
    #[cfg_attr(docsrs, doc(cfg(feature = "tokio_1")))]
    /// [`tokio` 1.0](tokio_1) runtime.
    Tokio1,

    #[cfg(feature = "async-std_1")]
    #[cfg_attr(docsrs, doc(cfg(feature = "async-std_1")))]
    #[deprecated(
        note = "Support for `async-std` is deprecated and will be removed in a future version. Consider using `tokio_1` or `smol_2` instead."
    )]
    /// [`async-std` 1.0](async_std_1) runtime.
    AsyncStd1,

    #[cfg(feature = "smol_2")]
    #[cfg_attr(docsrs, doc(cfg(feature = "smol_2")))]
    /// `smol` 2.0 runtime.
    Smol2,
}

/// Requires a [`Future`] to complete before the specified `duration` has
/// elapsed.
///
/// If the `future` completes before the `duration` has elapsed, then the
/// completed value is returned. Otherwise, an error is returned and
/// the `future` is canceled.
#[allow(unused_variables)]
pub async fn timeout<F>(runtime: Runtime, duration: Duration, future: F) -> Option<F::Output>
where
    F: Future,
{
    match runtime {
        #[cfg(feature = "tokio_1")]
        Runtime::Tokio1 => tokio_1::time::timeout(duration, future).await.ok(),
        #[cfg(feature = "async-std_1")]
        #[allow(deprecated)]
        Runtime::AsyncStd1 => async_std_1::future::timeout(duration, future).await.ok(),
        #[cfg(feature = "smol_2")]
        Runtime::Smol2 => {
            smol_2_futures_lite::future::or(async { Some(future.await) }, async {
                let _ = smol_2_async_io::Timer::after(duration).await;
                None
            })
            .await
        }
        #[allow(unreachable_patterns)]
        _ => unreachable!(),
    }
}

/// Runs the given closure on a thread where blocking is acceptable.
///
/// # Errors
///
/// See [`SpawnBlockingError`] for details.
#[allow(unused_variables)]
pub async fn spawn_blocking<F, R>(runtime: Runtime, f: F) -> Result<R, SpawnBlockingError>
where
    F: FnOnce() -> R + Send + 'static,
    R: Send + 'static,
{
    match runtime {
        #[cfg(feature = "tokio_1")]
        Runtime::Tokio1 => tokio_1::task::spawn_blocking(f).await.map_err(|e| {
            if e.is_cancelled() {
                SpawnBlockingError::Cancelled
            } else {
                SpawnBlockingError::Panic(e.into_panic())
            }
        }),
        #[cfg(feature = "async-std_1")]
        #[allow(deprecated)]
        Runtime::AsyncStd1 => Ok(async_std_1::task::spawn_blocking(f).await),
        #[cfg(feature = "smol_2")]
        Runtime::Smol2 => Ok(smol_2_blocking::unblock(f).await),
        #[allow(unreachable_patterns)]
        _ => unreachable!(),
    }
}

/// Runs the given closure on a thread where blocking is acceptable.
///
/// It works similar to [`spawn_blocking()`] but doesn't return a
/// [`Future`] and is meant to be used for background tasks.
///
/// # Errors
///
/// See [`SpawnBlockingError`] for details.
#[allow(unused_variables)]
pub fn spawn_blocking_background<F>(runtime: Runtime, f: F) -> Result<(), SpawnBlockingError>
where
    F: FnOnce() + Send + 'static,
{
    match runtime {
        #[cfg(feature = "tokio_1")]
        Runtime::Tokio1 => {
            drop(tokio_1::task::spawn_blocking(f));
            Ok(())
        }
        #[cfg(feature = "async-std_1")]
        #[allow(deprecated)]
        Runtime::AsyncStd1 => {
            drop(async_std_1::task::spawn_blocking(f));
            Ok(())
        }
        #[cfg(feature = "smol_2")]
        Runtime::Smol2 => {
            drop(smol_2_blocking::unblock(f));
            Ok(())
        }
        #[allow(unreachable_patterns)]
        _ => unreachable!(),
    }
}

/// Error of spawning a task on a thread where blocking is acceptable.
#[derive(Debug)]
pub enum SpawnBlockingError {
    /// Spawned task has panicked.
    Panic(Box<dyn Any + Send + 'static>),

    /// Spawned task has been cancelled.
    Cancelled,
}

impl fmt::Display for SpawnBlockingError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Panic(p) => write!(f, "SpawnBlockingError: Panic: {:?}", p),
            Self::Cancelled => write!(f, "SpawnBlockingError: Cancelled"),
        }
    }
}

impl std::error::Error for SpawnBlockingError {}

#[cfg(all(test, feature = "tokio_1"))]
mod tests_with_tokio_1 {
    use super::*;

    #[tokio_1::test(crate = "tokio_1")]
    async fn test_spawning_blocking() {
        assert!(spawn_blocking(Runtime::Tokio1, || 42).await.is_ok());
    }

    #[tokio_1::test(crate = "tokio_1")]
    async fn test_spawning_blocking_can_panic() {
        assert!(matches!(
            spawn_blocking(Runtime::Tokio1, || {
                panic!("42");
            })
            .await,
            Err(SpawnBlockingError::Panic(_))
        ));
    }
}
