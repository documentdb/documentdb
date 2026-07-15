/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway/src/cli.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{env, path::PathBuf};

use documentdb_gateway_core::configuration::env_keys;

use crate::{bootstrap, check};

/// Parsed top-level command for the gateway binary.
///
/// Per `packaging-design.md` §4.3 the gateway exposes:
///   `documentdb-gateway run [--config <path>]`
///   `documentdb-gateway check [--config <path>]` (alias: `--check`)
///   `documentdb-gateway --version`
pub enum Cli {
    Run { config: Option<PathBuf> },
    Check { config: Option<PathBuf> },
    Version,
    Help,
}

// `Debug` is derived purely so unit tests can use `Result::unwrap_err`
// (which requires the `Ok` variant to be Debug). The runtime doesn't
// log this type.
impl std::fmt::Debug for Cli {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Run { config } => f.debug_struct("Run").field("config", config).finish(),
            Self::Check { config } => f.debug_struct("Check").field("config", config).finish(),
            Self::Version => f.write_str("Version"),
            Self::Help => f.write_str("Help"),
        }
    }
}

/// Inspect argv and dispatch any recognized terminal subcommand. Exits the
/// process for `--help`, `--version`, and `check`. Returns `Some(path)` for
/// either `run --config <path>` OR the legacy positional invocation
/// `documentdb-gateway <path>` — in BOTH cases the path is guaranteed to
/// exist (we exit 78 here if it doesn't, mirroring the explicit-must-exist
/// semantics from `bootstrap::load_configuration` so a missing file fails
/// loud instead of silently degrading to env-only mode). Returns `None`
/// when no positional path / `--config` was supplied; in that case
/// `main.rs`'s `bootstrap::load_configuration` handles the 3-tier
/// (packaged → dev → env-only) resolution.
pub fn dispatch_or_passthrough() -> Option<PathBuf> {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.is_empty() {
        return None;
    }

    // Parse every non-empty argv through the full parser so the legacy
    // positional form (`documentdb-gateway <path>`) goes through the same
    // strict validation as `run --config <path>` — including
    // unexpected-trailing-arg rejection and the must-exist check below.
    // This closes the historical bypass where `documentdb-gateway
    // <typo>` would silently start the daemon with env-only defaults.
    let cli = match parse_cli_from_args(args) {
        Ok(c) => c,
        Err(msg) => {
            eprintln!("documentdb-gateway: error: {msg}");
            eprintln!("Run 'documentdb-gateway --help' for usage.");
            std::process::exit(2);
        }
    };

    match cli {
        Cli::Help => {
            print_help();
            std::process::exit(0);
        }
        Cli::Version => {
            println!("documentdb-gateway {}", env!("CARGO_PKG_VERSION"));
            std::process::exit(0);
        }
        Cli::Check { config } => {
            bootstrap::init_tracing();
            let setup_configuration = bootstrap::load_configuration(config);
            let code = check::run_check(&setup_configuration);
            std::process::exit(code);
        }
        Cli::Run { config } => {
            // Reject explicit user-supplied paths that don't exist (operator
            // typo, mis-merged drop-in, missing legacy positional arg, etc.)
            // so they fail loud rather than silently falling back to
            // env-only mode. Applies to both `run --config <path>` and the
            // legacy `documentdb-gateway <path>` form.
            if let Some(p) = &config {
                if !p.exists() {
                    eprintln!(
                        "documentdb-gateway: config file does not exist: {}",
                        p.display()
                    );
                    std::process::exit(78);
                }
            }
            // Fall back to the packaged /etc/documentdb/gateway/SetupConfiguration.json
            // when no path was given. The dev-path fallback and final
            // env-only mode live in bootstrap::load_configuration.
            config.or_else(|| {
                let packaged = PathBuf::from("/etc/documentdb/gateway/SetupConfiguration.json");
                packaged.exists().then_some(packaged)
            })
        }
    }
}

/// Parsing core extracted so unit tests can drive it with a synthetic argv
/// (real `env::args` is process-global and awkward to mock).
fn parse_cli_from_args(mut args: Vec<String>) -> Result<Cli, String> {
    if args.is_empty() {
        return Ok(Cli::Run { config: None });
    }

    // Back-compat: if the first arg looks like a JSON config path (not a
    // recognized flag), treat the invocation as `run --config <path>` so
    // pre-Phase-3 systemd units (`ExecStart=… /etc/.../SetupConfiguration.json`)
    // continue to work without modification.
    let first = &args[0];
    if !first.starts_with('-') && first != "run" && first != "check" {
        let config = PathBuf::from(args.remove(0));
        if !args.is_empty() {
            return Err(format!("Unexpected trailing arguments: {args:?}"));
        }
        return Ok(Cli::Run {
            config: Some(config),
        });
    }

    match args.remove(0).as_str() {
        "run" => {
            let config = parse_config_flag("run", &mut args)?;
            if !args.is_empty() {
                return Err(format!("Unknown 'run' argument(s): {args:?}"));
            }
            Ok(Cli::Run { config })
        }
        "--check" | "check" => {
            let config = parse_config_flag("check", &mut args)?;
            if !args.is_empty() {
                return Err(format!("Unknown 'check' argument(s): {args:?}"));
            }
            Ok(Cli::Check { config })
        }
        "--version" | "-V" => Ok(Cli::Version),
        "-h" | "--help" => Ok(Cli::Help),
        other => Err(format!("Unknown command or flag: {other}")),
    }
}

/// Pulls `--config <path>` out of `args` if present, returning the path.
/// Shared between `run` and `check` so both accept the same flag with
/// identical semantics. Errors on duplicate `--config` flags rather
/// than silently using the last one — an invocation like
/// `documentdb-gateway run --config /a.json --config /b.json` almost
/// always indicates an operator mistake (mis-merged systemd drop-in,
/// double-edited env file, etc.).
fn parse_config_flag(subcommand: &str, args: &mut Vec<String>) -> Result<Option<PathBuf>, String> {
    let mut config = None;
    let mut i = 0;
    while i < args.len() {
        if args[i] == "--config" {
            if config.is_some() {
                return Err(format!(
                    "'{subcommand}' was given --config more than once; specify exactly one config path"
                ));
            }
            args.remove(i);
            if i >= args.len() {
                return Err(format!("'{subcommand} --config' requires a path argument"));
            }
            config = Some(PathBuf::from(args.remove(i)));
        } else {
            i += 1;
        }
    }
    Ok(config)
}

fn print_help() {
    println!(
        "Usage: documentdb-gateway <command> [options]

Commands:
  run [--config <path>]     Start the gateway daemon (default).
  check [--config <path>]   Probe the configured PostgreSQL backend and verify
                            the DocumentDB extension is loaded. Exits 0/1.
  --version                 Print version information.
  -h, --help                Show this help message.

Configuration is taken from the environment first; a JSON config file is
optional. See /etc/documentdb/gateway/gateway.env (sample at
/usr/share/doc/documentdb-gateway/examples/gateway.env.sample) for the
documented environment variables:

  {pg_url_file}   File containing the PostgreSQL connection URL
  {listen_addr}     host:port or :port for the gateway listener
  {tls_cert_file}   Path to the TLS certificate file
  {tls_key_file}    Path to the TLS private key file
  {tls_auto}        true to auto-generate a self-signed cert
  {tls_state_dir}   Where to persist the auto-generated cert
  {log_level}       Tracing filter (e.g. info, debug)",
        pg_url_file = env_keys::PG_URL_FILE,
        listen_addr = env_keys::LISTEN_ADDR,
        tls_cert_file = env_keys::TLS_CERT_FILE,
        tls_key_file = env_keys::TLS_KEY_FILE,
        tls_auto = env_keys::TLS_AUTO_GENERATE,
        tls_state_dir = env_keys::TLS_STATE_DIR,
        log_level = env_keys::LOG_LEVEL,
    );
}

#[cfg(test)]
mod tests {
    use super::{parse_cli_from_args, Cli};
    use std::path::PathBuf;

    fn args(parts: &[&str]) -> Vec<String> {
        parts.iter().map(|s| (*s).to_owned()).collect()
    }

    #[test]
    fn empty_args_defaults_to_run_without_config() {
        let cli = parse_cli_from_args(args(&[])).unwrap();
        assert!(matches!(cli, Cli::Run { config: None }));
    }

    #[test]
    fn legacy_single_path_arg_treated_as_run_with_config() {
        // Pre-Phase-3 systemd units used `ExecStart=… /etc/.../SetupConfiguration.json`
        // — that contract must keep working.
        let cli = parse_cli_from_args(args(&["/etc/documentdb/gateway/SetupConfiguration.json"]))
            .unwrap();
        let Cli::Run { config } = cli else {
            panic!("expected Cli::Run for legacy single-path arg");
        };
        assert_eq!(
            config,
            Some(PathBuf::from(
                "/etc/documentdb/gateway/SetupConfiguration.json"
            ))
        );
    }

    #[test]
    fn run_subcommand_without_config() {
        let cli = parse_cli_from_args(args(&["run"])).unwrap();
        assert!(matches!(cli, Cli::Run { config: None }));
    }

    #[test]
    fn run_subcommand_with_config() {
        let cli = parse_cli_from_args(args(&["run", "--config", "/tmp/x.json"])).unwrap();
        let Cli::Run { config } = cli else {
            panic!("expected Cli::Run");
        };
        assert_eq!(config, Some(PathBuf::from("/tmp/x.json")));
    }

    #[test]
    fn check_subcommand_without_config() {
        let cli = parse_cli_from_args(args(&["check"])).unwrap();
        assert!(matches!(cli, Cli::Check { config: None }));
    }

    #[test]
    fn check_subcommand_with_config() {
        // Resolved a reviewer-flagged inconsistency: `check` accepts the
        // same `--config` flag as `run`.
        let cli = parse_cli_from_args(args(&["check", "--config", "/tmp/x.json"])).unwrap();
        let Cli::Check { config } = cli else {
            panic!("expected Cli::Check");
        };
        assert_eq!(config, Some(PathBuf::from("/tmp/x.json")));
    }

    #[test]
    fn legacy_dash_dash_check_flag_form_with_config() {
        // The `--check` flag form is the original (kept for back-compat
        // with documentation that referenced it).
        let cli = parse_cli_from_args(args(&["--check", "--config", "/tmp/y.json"])).unwrap();
        let Cli::Check { config } = cli else {
            panic!("expected Cli::Check");
        };
        assert_eq!(config, Some(PathBuf::from("/tmp/y.json")));
    }

    #[test]
    fn config_flag_without_path_errors() {
        let err = parse_cli_from_args(args(&["run", "--config"])).unwrap_err();
        assert!(
            err.contains("--config"),
            "error must reference --config; got: {err}"
        );
    }

    #[test]
    fn duplicate_config_flag_errors() {
        // PR-Assistant reliability finding (Iter5): silently using
        // the last --config when given twice masks operator mistakes
        // like a mis-merged systemd drop-in or a double-edited env
        // file. Reject the ambiguity explicitly.
        let err = parse_cli_from_args(args(&[
            "run",
            "--config",
            "/etc/a.json",
            "--config",
            "/etc/b.json",
        ]))
        .unwrap_err();
        assert!(
            err.contains("--config more than once"),
            "error must explain the duplicate; got: {err}"
        );

        // Same on `check`.
        let err = parse_cli_from_args(args(&[
            "check", "--config", "/a.json", "--config", "/b.json",
        ]))
        .unwrap_err();
        assert!(err.contains("--config more than once"), "got: {err}");
    }

    #[test]
    fn dash_dash_version_returns_version() {
        let cli = parse_cli_from_args(args(&["--version"])).unwrap();
        assert!(matches!(cli, Cli::Version));
        let cli = parse_cli_from_args(args(&["-V"])).unwrap();
        assert!(matches!(cli, Cli::Version));
    }

    #[test]
    fn dash_dash_help_returns_help() {
        let cli = parse_cli_from_args(args(&["--help"])).unwrap();
        assert!(matches!(cli, Cli::Help));
        let cli = parse_cli_from_args(args(&["-h"])).unwrap();
        assert!(matches!(cli, Cli::Help));
    }

    #[test]
    fn unknown_flag_errors_with_message() {
        let err = parse_cli_from_args(args(&["--unknown-flag"])).unwrap_err();
        assert!(
            err.contains("Unknown command or flag"),
            "error must indicate unknown command; got: {err}"
        );
    }

    #[test]
    fn run_with_unknown_argument_errors() {
        let err = parse_cli_from_args(args(&["run", "--bogus"])).unwrap_err();
        assert!(
            err.contains("Unknown 'run' argument"),
            "error must indicate unknown run argument; got: {err}"
        );
    }

    #[test]
    fn legacy_path_with_trailing_args_errors() {
        let err = parse_cli_from_args(args(&["/etc/foo.json", "extra"])).unwrap_err();
        assert!(err.contains("Unexpected trailing arguments"), "got: {err}");
    }
}
