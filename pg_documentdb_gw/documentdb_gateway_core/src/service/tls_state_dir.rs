/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/service/tls_state_dir.rs
 *
 * State-directory resolution for auto-generated TLS material. Pulled
 * into tls.rs via:
 *   #[path = "tls_state_dir.rs"] mod state_dir;
 * so it is a private submodule of `tls`. All items are pub(super) so
 * they remain crate-private but are reachable from tls.rs and from the
 * sibling tls_tests.rs test module.
 *-------------------------------------------------------------------------
 */

use std::{env, fs, path::Path};

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

use crate::error::{DocumentDBError, Result};

/// Default directory for auto-generated TLS material when the operator
/// has not pinned a location via `DOCUMENTDB_TLS_STATE_DIR`.
///
/// This is an **absolute** path so the cert/key location does not depend
/// on whatever current working directory the gateway happens to inherit
/// (which under the packaged systemd units is
/// `/var/lib/documentdb-gateway` for Workflow B and
/// `/var/lib/documentdb-local/N/gateway` for the per-major standalone
/// units — both unique, both writable by the gateway OS user, but
/// neither obvious to an operator looking for "where is my cert?").
///
/// Hard-coding `./pkey.pem` / `./cert.pem` instead — as the gateway
/// previously did — meant:
///   * an operator running `documentdb-gateway` from `/tmp` would
///     scatter files there;
///   * `journalctl` showed no record of where the cert lived;
///   * back-up tooling had to read the systemd unit to find the path.
///
/// Switching to an absolute default + env override closes those gaps.
pub(super) const DEFAULT_TLS_STATE_DIR: &str = "/var/lib/documentdb-gateway/tls";

/// Environment variable name an operator can set to relocate the
/// auto-generated TLS material. Mirrored in
/// `documentdb_gateway_core::configuration::env_keys::TLS_STATE_DIR`
/// for documentation consistency.
pub(super) const ENV_TLS_STATE_DIR: &str = "DOCUMENTDB_TLS_STATE_DIR";

/// File names inside the resolved TLS state directory. Names are kept
/// stable across versions so admin tooling (backup scripts, cert
/// rotation, audits) can rely on them.
const TLS_CERT_FILENAME: &str = "cert.pem";
const TLS_KEY_FILENAME: &str = "pkey.pem";

/// Resolves the directory in which auto-generated TLS material lives,
/// creating it as a side effect.
///
/// Resolution order:
///   1. `DOCUMENTDB_TLS_STATE_DIR` env var (any non-empty value). Honored
///      verbatim — if the operator pointed us somewhere uncreatable,
///      surface their error rather than silently picking another path.
///   2. The canonical absolute default `/var/lib/documentdb-gateway/tls`.
///      Works under the packaged systemd unit because the DEB/RPM
///      `postinst` pre-creates `/var/lib/documentdb-gateway` mode `0750`
///      owned by `documentdb-gateway:documentdb-gateway`.
///   3. Per-user state directory (`$XDG_STATE_HOME` or
///      `$HOME/.local/state`). Covers the Docker image, `cargo run` from
///      the source tree, and OSS test runs that don't pin a state dir.
///   4. Last-resort per-process tempdir. Worst case the TLS material is
///      ephemeral, but the gateway can still start; for long-lived
///      installs the operator sets `DOCUMENTDB_TLS_STATE_DIR` explicitly.
///
/// Fallbacks past step 2 emit `tracing::warn!` so operators see the
/// fallback in `journalctl` and know to set the env var if they want a
/// pinned location.
pub(super) fn resolve_tls_state_dir() -> Result<String> {
    if let Some(explicit) = env::var(ENV_TLS_STATE_DIR)
        .ok()
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty())
    {
        ensure_tls_state_dir(&explicit)?;
        return Ok(explicit);
    }

    if try_ensure_dir(DEFAULT_TLS_STATE_DIR).is_ok() {
        return Ok(DEFAULT_TLS_STATE_DIR.to_owned());
    }

    // Try the per-user state directory. Skip if user_local_state_dir
    // already had to fall back to a shared/fixed tempdir name —
    // collisions with concurrent instances would defeat the purpose.
    let user_dir = user_local_state_dir();
    let shared_tempdir_name = std::env::temp_dir()
        .join("documentdb-gateway-tls")
        .to_string_lossy()
        .into_owned();
    if user_dir != shared_tempdir_name && try_ensure_dir(&user_dir).is_ok() {
        tracing::warn!(
            "Default TLS state dir {DEFAULT_TLS_STATE_DIR} is not writable; \
             using {user_dir} instead. Set {ENV_TLS_STATE_DIR} to override."
        );
        return Ok(user_dir);
    }

    // Last resort: per-process tempdir with a PID discriminator so
    // concurrent gateway instances don't clobber each other's certs.
    let temp_dir = std::env::temp_dir()
        .join(format!("documentdb-gateway-tls-{}", std::process::id()))
        .to_string_lossy()
        .into_owned();
    ensure_tls_state_dir(&temp_dir)?;
    tracing::warn!(
        "Default TLS state dir {DEFAULT_TLS_STATE_DIR} and user state dir are not writable; \
         using {temp_dir} instead. TLS material will not persist across reboots. \
         Set {ENV_TLS_STATE_DIR} to a persistent writable location for production deployments."
    );
    Ok(temp_dir)
}

/// Joins the resolved TLS state directory with the conventional
/// (cert.pem, pkey.pem) file names. Returns `(cert_path, key_path)`.
pub(super) fn resolve_tls_paths() -> Result<(String, String)> {
    Ok(tls_paths_for_dir(&resolve_tls_state_dir()?))
}

/// Pure joiner extracted so unit tests can exercise it without
/// touching process-global env state.
pub(super) fn tls_paths_for_dir(dir: &str) -> (String, String) {
    let cert = format!("{dir}/{TLS_CERT_FILENAME}");
    let key = format!("{dir}/{TLS_KEY_FILENAME}");
    (cert, key)
}

/// Computes the per-user state directory we fall back to when the
/// canonical absolute default is not writable. Follows the XDG Base
/// Directory Specification: `$XDG_STATE_HOME` if set, else
/// `$HOME/.local/state`, else the process tempdir.
pub(super) fn user_local_state_dir() -> String {
    if let Some(xdg) = env::var("XDG_STATE_HOME")
        .ok()
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty())
    {
        return format!("{xdg}/documentdb-gateway/tls");
    }
    if let Some(home) = env::var("HOME")
        .ok()
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty())
    {
        return format!("{home}/.local/state/documentdb-gateway/tls");
    }
    std::env::temp_dir()
        .join("documentdb-gateway-tls")
        .to_string_lossy()
        .into_owned()
}

/// Best-effort variant of `ensure_tls_state_dir` that returns the
/// underlying `io::Error` instead of wrapping it. Used by
/// `resolve_tls_state_dir` to try multiple candidate directories.
///
/// Only tightens permissions on a directory we just created — if the
/// operator pre-created it with looser perms (e.g. group-readable for
/// a sidecar reverse proxy), we respect their choice.
pub(super) fn try_ensure_dir(dir: &str) -> std::io::Result<()> {
    let already_existed = Path::new(dir).exists();
    fs::create_dir_all(dir)?;
    #[cfg(unix)]
    if !already_existed {
        let _ = fs::set_permissions(dir, fs::Permissions::from_mode(0o700));
    }
    Ok(())
}

/// Ensures the TLS state directory exists with restrictive permissions
/// on first creation.
///
/// Best-effort on permission tightening: when the gateway is running
/// as a non-root user (the expected case under systemd), we may not be
/// able to `chmod` an admin-created directory — that's fine, the admin
/// owns the policy. We only fail the call if `create_dir_all` itself
/// fails, since without the directory we cannot persist a key.
///
/// Mirrors `try_ensure_dir` in only chmodding newly-created
/// directories so the operator's permissions choice on a pre-existing
/// directory is preserved.
fn ensure_tls_state_dir(dir: &str) -> Result<()> {
    let already_existed = Path::new(dir).exists();
    fs::create_dir_all(dir).map_err(|e| {
        DocumentDBError::internal_error(format!("Cannot create TLS state directory {dir}: {e}"))
    })?;
    #[cfg(unix)]
    if !already_existed {
        let _ = fs::set_permissions(dir, fs::Permissions::from_mode(0o700));
    }
    Ok(())
}
