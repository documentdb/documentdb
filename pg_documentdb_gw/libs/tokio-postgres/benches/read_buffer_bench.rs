//! Microbenchmarks for the `Framed` read-buffer reclaim added to
//! `PostgresCodec::decode`.
//!
//! The codec module is private, so — like `documentdb_gateway_core`'s
//! `hot_path_bench` — these benches replicate the exact buffer lifecycle the
//! decoder drives (`reserve` to take in a batch, `split_to` to hand the framed
//! bytes downstream, then an optional reclaim of the drained buffer) rather than
//! calling the private code directly. The goal is to confirm the reclaim branch
//! does not regress steady-state throughput while keeping the buffer bounded.

use std::hint::black_box;

use bytes::{BufMut, BytesMut};
use criterion::{criterion_group, criterion_main, BatchSize, Criterion};

/// Reclaim bound, mirroring the gateway's per-connection `buffer_size` (256 KiB).
const BOUND: usize = 256 * 1024;
/// A large result batch that grows the read buffer well past the bound.
const LARGE_BATCH: usize = 8 * 1024 * 1024;
/// A typical small result batch.
const SMALL_BATCH: usize = 256;

/// Simulate one decoded batch: bytes arrive into the read buffer and the framed
/// region is split off to `BackendMessages`. When `reclaim` is set, an
/// oversized, fully drained buffer is shrunk back to `BOUND` — exactly the
/// branch added to `PostgresCodec::decode`.
#[inline]
fn process_batch(buf: &mut BytesMut, body: usize, reclaim: bool) {
    buf.reserve(body);
    buf.put_bytes(0, body);
    let framed = buf.split_to(buf.len());
    if reclaim && buf.is_empty() && buf.capacity() > BOUND {
        *buf = BytesMut::with_capacity(BOUND);
    }
    // `framed` models the handoff to `BackendMessages`; dropping it frees the
    // batch once the consumer is done with it.
    drop(black_box(framed));
}

/// Cost of reclaiming a single oversized, fully drained buffer vs. the old
/// behavior of only clearing it (which retains the large capacity forever).
fn bench_reclaim_decision(c: &mut Criterion) {
    let mut group = c.benchmark_group("framed_read_buffer_reclaim");

    // Old behavior: clear keeps the high-water capacity (memory retained).
    group.bench_function("clear_retains_capacity", |b| {
        b.iter_batched(
            || {
                let mut buf = BytesMut::with_capacity(LARGE_BATCH);
                buf.put_bytes(0, LARGE_BATCH);
                let _ = buf.split_to(buf.len());
                buf
            },
            |mut buf| {
                buf.clear();
                black_box(buf.capacity())
            },
            BatchSize::SmallInput,
        )
    });

    // New behavior: reclaim the drained buffer down to the bound.
    group.bench_function("reclaim_to_bound", |b| {
        b.iter_batched(
            || {
                let mut buf = BytesMut::with_capacity(LARGE_BATCH);
                buf.put_bytes(0, LARGE_BATCH);
                let _ = buf.split_to(buf.len());
                buf
            },
            |mut buf| {
                if buf.is_empty() && buf.capacity() > BOUND {
                    buf = BytesMut::with_capacity(BOUND);
                }
                black_box(buf.capacity())
            },
            BatchSize::SmallInput,
        )
    });

    group.finish();
}

/// Steady-state throughput: one large batch followed by many small batches,
/// with and without reclaim. Confirms the reclaim does not regress the common
/// small-batch path while keeping peak capacity bounded.
fn bench_mixed_workload(c: &mut Criterion) {
    let mut group = c.benchmark_group("framed_read_buffer_workload");

    let run = |reclaim: bool| -> usize {
        let mut buf = BytesMut::with_capacity(BOUND);
        process_batch(&mut buf, LARGE_BATCH, reclaim);
        for _ in 0..64 {
            process_batch(&mut buf, SMALL_BATCH, reclaim);
        }
        buf.capacity()
    };

    group.bench_function("retain", |b| b.iter(|| black_box(run(false))));
    group.bench_function("reclaim", |b| b.iter(|| black_box(run(true))));

    group.finish();
}

criterion_group!(benches, bench_reclaim_decision, bench_mixed_workload);
criterion_main!(benches);
