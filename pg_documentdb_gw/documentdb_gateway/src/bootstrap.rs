/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway/src/bootstrap.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{env, path::PathBuf};

use documentdb_gateway_core::configuration::{env_keys, DocumentDBSetupConfiguration};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

pub fn init_tracing() {
    // EnvFilter honors DOCUMENTDB_LOG_LEVEL when set; falls back to
    // RUST_LOG, then to "info" as the package's documented default.
    // Validate up front so a misconfigured value surfaces on stderr
    // rather than silently degrading to the fallback.
    let filter = match env::var(env_keys::LOG_LEVEL) {
        Ok(raw) => {
            let trimmed = raw.trim();
            if trimmed.is_empty() {
                eprintln!(
                    "documentdb-gateway: {key} is set but empty/whitespace; \
                     ignoring and falling back to RUST_LOG / info. \
                     Set {key} to a tracing filter (e.g. 'info', 'debug', or 'documentdb_gateway=debug').",
                    key = env_keys::LOG_LEVEL
                );
                EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"))
            } else {
                match EnvFilter::try_new(trimmed) {
                    Ok(f) => f,
                    Err(e) => {
                        eprintln!(
                            "documentdb-gateway: {key}='{trimmed}' is not a valid tracing filter \
                             ({e}); ignoring and falling back to RUST_LOG / info.",
                            key = env_keys::LOG_LEVEL
                        );
                        EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"))
                    }
                }
            }
        }
        Err(env::VarError::NotPresent) => {
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"))
        }
        Err(env::VarError::NotUnicode(_)) => {
            eprintln!(
                "documentdb-gateway: {key} contains non-UTF-8 bytes; \
                 ignoring and falling back to RUST_LOG / info.",
                key = env_keys::LOG_LEVEL
            );
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"))
        }
    };
    let _ = tracing_subscriber::registry()
        .with(filter)
        .with(tracing_subscriber::fmt::layer())
        .try_init();
}

pub fn load_configuration(config: Option<PathBuf>) -> DocumentDBSetupConfiguration {
    // Resolve the optional JSON config. Precedence (highest first):
    //   1. explicit --config (must exist if given)
    //   2. packaged /etc/documentdb/gateway/SetupConfiguration.json
    //      (written by documentdb-setup / shipped by the DEB/RPM gateway
    //      package; this is what the packaged systemd units expect to
    //      pick up at `ExecStart=/usr/bin/documentdb-gateway run`)
    //   3. historical Cargo-relative dev path (for `cargo run` from the
    //      source tree)
    //   4. env-only (no JSON config at all)
    const PACKAGED_CONFIG_PATH: &str = "/etc/documentdb/gateway/SetupConfiguration.json";
    let dev_path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../SetupConfiguration.json");
    let packaged_path = PathBuf::from(PACKAGED_CONFIG_PATH);
    let explicit = config.is_some();
    let resolved = config
        .or_else(|| packaged_path.exists().then_some(packaged_path))
        .or_else(|| dev_path.exists().then_some(dev_path));

    if explicit {
        if let Some(p) = resolved.as_deref() {
            if !p.exists() {
                eprintln!(
                    "documentdb-gateway: --config file does not exist: {}",
                    p.display()
                );
                std::process::exit(78);
            }
        }
    }

    match DocumentDBSetupConfiguration::from_env_with_optional_json(resolved.as_deref()) {
        Ok(cfg) => cfg,
        Err(e) => {
            eprintln!("documentdb-gateway: failed to load configuration: {e}");
            std::process::exit(78); // EX_CONFIG
        }
    }
}
