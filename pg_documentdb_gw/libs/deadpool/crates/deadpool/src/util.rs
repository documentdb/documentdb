use std::{num::NonZeroUsize, sync::LazyLock};

/// Cache the logical CPU count to avoid calling
/// `std::thread::available_parallelism()` multiple times, which is
/// expensive when creating pools in quick succession.
static CPU_COUNT: LazyLock<usize> = LazyLock::new(|| {
    std::thread::available_parallelism()
        .map(NonZeroUsize::get)
        .unwrap_or(1)
});

/// Get the default maximum size of a pool, which is `cpu_core_count * 2`
/// including logical cores (Hyper-Threading).
pub(crate) fn get_default_pool_max_size() -> usize {
    *CPU_COUNT * 2
}
