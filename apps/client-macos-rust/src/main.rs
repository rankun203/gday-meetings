use std::ffi::OsString;
use std::path::{Path, PathBuf};

use clap::{Parser, Subcommand};
use tracing::info;
use tokio_util::sync::CancellationToken;

#[cfg(target_os = "macos")]
mod desktop;

#[derive(Clone, Debug)]
enum DesktopStatus {
    Ready { url: Option<String>, recordings: usize },
    Stopping,
}
type StatusCallback = std::sync::Arc<dyn Fn(DesktopStatus) + Send + Sync>;


use gday_meetings_client::chat::manager::ConversationManager;
use gday_meetings_client::filesdb::FilesDb;
use gday_meetings_client::llm::secrets::LlmSecrets;
use gday_meetings_client::people::PeopleManager;
use gday_meetings_client::server;
#[cfg(target_os = "macos")]
use gday_meetings_client::session::AutoStopTrigger;
use gday_meetings_client::session::SessionManager;
use gday_meetings_client::settings::AppSettings;
use gday_meetings_client::tags::TagsManager;

fn install_signal_handlers() {
    unsafe {
        for sig in [libc::SIGSEGV, libc::SIGBUS, libc::SIGABRT] {
            libc::signal(
                sig,
                crash_handler as *const () as libc::sighandler_t,
            );
        }
    }
}

extern "C" fn crash_handler(sig: libc::c_int) {
    let name = match sig {
        libc::SIGSEGV => "SIGSEGV (segmentation fault)",
        libc::SIGBUS => "SIGBUS (bus error)",
        libc::SIGABRT => "SIGABRT (abort)",
        _ => "unknown signal",
    };
    eprintln!("\n=== FATAL: {} (signal {}) ===", name, sig);
    eprintln!("Set RUST_BACKTRACE=1 for a backtrace.");
    eprintln!("{:?}", std::backtrace::Backtrace::force_capture());
    unsafe {
        libc::signal(sig, libc::SIG_DFL);
        libc::raise(sig);
    }
}

fn default_data_dir() -> PathBuf {
    let home = dirs::home_dir().expect("could not determine home directory");
    gday_meetings_client::data_dir::default_data_dir(&home)
        .unwrap_or_else(|error| panic!("{error}"))
}

#[derive(Parser)]
#[command(name = "gday-meetings-client", version)]
#[command(about = "System-level audio recorder and meeting notes processor")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Start the HTTP API server
    Serve {
        /// Port to listen on (0 lets the OS choose an available port)
        #[arg(short, long, default_value = "0")]
        port: u16,

        /// Host to bind to
        #[arg(long, default_value = "127.0.0.1")]
        host: String,

        /// Data directory for recordings and app data
        #[arg(short = 'd', long)]
        data_dir: Option<PathBuf>,

        /// Enable built-in web UI
        #[arg(long)]
        web_ui: bool,

        /// Open the web UI in the default browser (macOS)
        #[arg(long = "open", requires = "web_ui")]
        open_browser: bool,
    },
}

fn is_app_bundle(executable: &Path) -> bool {
    let macos = executable.parent();
    let contents = macos.and_then(Path::parent);
    let bundle = contents.and_then(Path::parent);
    cfg!(target_os = "macos")
        && macos.and_then(Path::file_name).is_some_and(|name| name == "MacOS")
        && contents.and_then(Path::file_name).is_some_and(|name| name == "Contents")
        && bundle.and_then(Path::extension).is_some_and(|extension| extension == "app")
}

fn parse_cli(mut args: Vec<OsString>, executable: &Path) -> Result<Cli, clap::Error> {
    // Finder supplies no subcommand. Keep ordinary CLI invocation unchanged.
    if is_app_bundle(executable) && args.len() == 1 {
        args.extend(["serve", "--web-ui", "--open"].map(OsString::from));
    }
    Cli::try_parse_from(args)
}

fn main() {
    // Private capture child: skip desktop/server startup and keep stdout solely
    // for framed audio. Same executable preserves the app's signing identity.
    #[cfg(target_os = "macos")]
    if std::env::args().nth(1).as_deref() == Some("--gday-mic-helper") {
        let rate = std::env::args().nth(2).and_then(|v| v.parse().ok()).unwrap_or(48000);
        gday_meetings_client::audio::mic::run_helper(rate);
    }
    install_signal_handlers();

    let cli = parse_cli(
        std::env::args_os().collect(),
        &std::env::current_exe().unwrap_or_default(),
    )
    .unwrap_or_else(|error| error.exit());

    gday_meetings_client::logging::init();

    let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build()
        .expect("could not start async runtime");
    #[cfg(target_os = "macos")]
    if is_app_bundle(&std::env::current_exe().unwrap_or_default()) {
        desktop::run(cli, &runtime);
        return;
    }
    runtime.block_on(serve(cli, CancellationToken::new(), None));
}

async fn serve(cli: Cli, shutdown: CancellationToken, notify: Option<StatusCallback>) {
    match cli.command {
        Commands::Serve { port, host, data_dir, web_ui, open_browser } => {
            info!("Gday Meetings daemon starting on port {}...", port);
            // Reserve the listener before loading data or resuming background jobs.
            let addr = format!("{}:{}", host, port);
            let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
            let addr = listener.local_addr().expect("bound listener has a local address");
            let data_dir = data_dir.unwrap_or_else(default_data_dir);
            let recordings_dir = data_dir.join("recordings");
            std::fs::create_dir_all(&recordings_dir)
                .expect("failed to create recordings directory");

            let data_dir = std::fs::canonicalize(&data_dir).unwrap_or(data_dir);
            let recordings_dir = std::fs::canonicalize(&recordings_dir).unwrap_or(recordings_dir);

            let manager = SessionManager::new(recordings_dir.clone());
            manager.load_from_disk().await;
            manager.start_file_size_ticker();

            #[cfg(target_os = "macos")]
            match gday_meetings_client::system_events::start() {
                Ok((mut system_events, support)) => {
                    info!(
                        "macOS auto-stop events enabled (screen lock: {}, system sleep: {})",
                        support.screen_lock, support.system_sleep
                    );
                    let event_manager = manager.clone();
                    tokio::spawn(async move {
                        while let Some(event) = system_events.recv().await {
                            match event {
                                gday_meetings_client::system_events::SystemEvent::ScreenLocked => {
                                    info!("macOS screen-lock event received");
                                    let stopped = event_manager
                                        .auto_stop_recordings(AutoStopTrigger::ScreenLock)
                                        .await;
                                    if stopped > 0 {
                                        info!("Screen locked — auto-stopped {} recording(s)", stopped);
                                    }
                                }
                                gday_meetings_client::system_events::SystemEvent::SystemWillSleep(request) => {
                                    info!("macOS system-sleep event received");
                                    let stopped = tokio::time::timeout(
                                        std::time::Duration::from_secs(25),
                                        event_manager.auto_stop_recordings(AutoStopTrigger::SystemSleep),
                                    )
                                    .await;
                                    match stopped {
                                        Ok(count) if count > 0 => info!(
                                            "System sleeping — auto-stopped {} recording(s)",
                                            count
                                        ),
                                        Err(_) => tracing::warn!(
                                            "System sleep: stopping recordings timed out after 25s"
                                        ),
                                        _ => {}
                                    }
                                    request.allow();
                                }
                            }
                        }
                    });
                }
                Err(e) => tracing::warn!("Could not monitor macOS lock/sleep events: {}", e),
            }

            let people_manager = PeopleManager::new(&data_dir);
            people_manager.load_from_disk().await;

            let tags_manager = TagsManager::new(&data_dir);

            let files_db = FilesDb::new(recordings_dir.clone());

            let settings = AppSettings::load_or_create(&data_dir);
            let shared_settings = std::sync::Arc::new(tokio::sync::RwLock::new(settings));

            let llm_secrets = LlmSecrets::load_or_create(&data_dir);
            let shared_secrets = std::sync::Arc::new(tokio::sync::RwLock::new(llm_secrets));

            let conversation_manager = ConversationManager::new(&data_dir);

            // Generate CLAUDE.md and markdown index files
            {
                let self_intro = shared_settings.read().await.chat_self_intro.clone();
                gday_meetings_client::markdown::write_claude_md(&data_dir, self_intro.as_deref());
            }
            {
                use gday_meetings_client::markdown;
                let mut sessions = manager.session_entries().await;
                let mut people = people_manager.person_entries().await;
                let people_dir = people_manager.people_dir().to_path_buf();
                let rec_dir = recordings_dir.clone();
                let (rec_index_bytes, people_index_bytes) =
                    tokio::task::spawn_blocking(move || {
                        let r = if rec_dir.join("index.md").exists() {
                            std::fs::metadata(rec_dir.join("index.md")).map(|m| m.len() as usize).unwrap_or(0)
                        } else { markdown::write_recordings_catalog(&rec_dir, &mut sessions, false) };
                        let p = markdown::write_people_index(&people_dir, &mut people);
                        (r, p)
                    }).await.unwrap();
                info!(
                    "Updated markdown indexes: recordings/index.md ({}), people/index.md ({})",
                    markdown::human_size(rec_index_bytes),
                    markdown::human_size(people_index_bytes),
                );
            }

            let gday_auth = server::gday_auth::GdayAuth::load(&data_dir);

            // Resume any pending extraction jobs from before restart
            server::routes::resume_pending_extractions(
                manager.clone(), people_manager.clone(),
                files_db.clone(), shared_settings.clone(),
                shared_secrets.clone(), tags_manager.clone(), gday_auth.clone(),
            ).await;

            let claude_runner = gday_meetings_client::llm::claude_code::ClaudeCodeRunner::new(&data_dir);

            let shutdown_manager = manager.clone();
            let status_manager = manager.clone();
            let app = server::create_router(
                manager, people_manager, shared_settings, files_db, tags_manager,
                conversation_manager, shared_secrets, claude_runner, web_ui, gday_auth.clone(),
            );

            info!("Server listening on http://{}", addr);
            info!("Data directory: \"{}\"", data_dir.display());
            info!("Recordings directory: \"{}\"", recordings_dir.display());
            if web_ui {
                info!("Web UI available at http://{}", addr);
            }
            let mut browser_addr = addr;
            if browser_addr.ip().is_unspecified() {
                browser_addr.set_ip(if browser_addr.is_ipv4() {
                    std::net::Ipv4Addr::LOCALHOST.into()
                } else {
                    std::net::Ipv6Addr::LOCALHOST.into()
                });
            }
            let browser_url = format!("http://{browser_addr}");
            if let Some(notify) = notify.clone() {
                let status_shutdown = shutdown.clone();
                let url = web_ui.then(|| browser_url.clone());
                tokio::spawn(async move {
                    let mut previous = None;
                    loop {
                        let recordings = status_manager.recording_session_ids().await.len();
                        if previous != Some(recordings) {
                            notify(DesktopStatus::Ready { url: url.clone(), recordings });
                            previous = Some(recordings);
                        }
                        tokio::select! {
                            _ = status_shutdown.cancelled() => break,
                            _ = tokio::time::sleep(std::time::Duration::from_secs(1)) => {},
                        }
                    }
                });
            }
            if open_browser {
                #[cfg(target_os = "macos")]
                {
                    let url = browser_url;
                    tokio::spawn(async move {
                        match tokio::process::Command::new("/usr/bin/open").arg(&url).status().await {
                            Ok(status) if status.success() => {}
                            result => tracing::warn!("Could not open browser at {}: {:?}", url, result),
                        }
                    });
                }
                #[cfg(not(target_os = "macos"))]
                tracing::warn!("Automatic browser opening is currently supported on macOS only");
            }

            // Graceful shutdown: stop all recording sessions on SIGINT/SIGTERM
            // so audio writers can finalize (write trailing OGG pages, flush
            // BufWriters) before the process exits.
            let shutdown_signal = async move {
                tokio::select! {
                    _ = shutdown.cancelled() => {},
                    _ = wait_for_shutdown_signal() => {},
                }
                shutdown.cancel();
                if let Some(notify) = notify { notify(DesktopStatus::Stopping); }
                info!("Shutdown requested — stopping active recordings (press again to force quit)");

                // A second signal force-exits even if a Core Audio call or an
                // in-flight request is wedged.
                tokio::spawn(async {
                    wait_for_shutdown_signal().await;
                    eprintln!("Second shutdown signal — exiting immediately");
                    std::process::exit(130);
                });

                if tokio::time::timeout(
                    std::time::Duration::from_secs(30),
                    shutdown_manager.shutdown(),
                )
                .await
                .is_err()
                {
                    tracing::warn!("Shutdown: stopping recordings timed out after 30s");
                }

                // After this future resolves, axum waits for in-flight
                // connections to drain — a hung request must not keep the
                // process alive forever.
                tokio::spawn(async {
                    tokio::time::sleep(std::time::Duration::from_secs(10)).await;
                    tracing::warn!("Graceful shutdown drain timed out after 10s — forcing exit");
                    std::process::exit(0);
                });
            };

            axum::serve(listener, app)
                .with_graceful_shutdown(shutdown_signal)
                .await
                .unwrap();

            info!("Server stopped");
        }
    }
}

#[cfg(test)]
mod cli_tests {
    use super::*;

    #[tokio::test]
    async fn desktop_reports_bound_url_and_quits_through_graceful_shutdown() {
        let directory = std::env::temp_dir().join(format!("gday-desktop-{}", uuid::Uuid::new_v4()));
        let cli = Cli { command: Commands::Serve {
            port: 0, host: "127.0.0.1".into(), data_dir: Some(directory.clone()),
            web_ui: true, open_browser: false,
        }};
        let shutdown = CancellationToken::new();
        let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
        let task = tokio::spawn(serve(cli, shutdown.clone(), Some(std::sync::Arc::new(move |status| {
            let _ = sender.send(status);
        }))));
        let status = tokio::time::timeout(std::time::Duration::from_secs(10), receiver.recv()).await.unwrap().unwrap();
        let DesktopStatus::Ready { url: Some(url), recordings: 0 } = status else {
            panic!("expected ready state with a browser URL");
        };
        assert!(!url.ends_with(":0"));
        let response = reqwest::get(format!("{url}/api/sessions")).await.unwrap();
        assert!(response.status().is_success());
        shutdown.cancel();
        assert!(matches!(receiver.recv().await, Some(DesktopStatus::Stopping)));
        tokio::time::timeout(std::time::Duration::from_secs(10), task).await.unwrap().unwrap();
        assert!(reqwest::get(url).await.is_err());
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn finder_launch_starts_the_ui_and_browser() {
        let cli = parse_cli(
            vec!["gday-meetings-client".into()],
            Path::new("/Applications/Gday Meetings Rust.app/Contents/MacOS/gday-meetings-client"),
        ).unwrap();
        assert!(matches!(cli.command, Commands::Serve {
            port: 0, web_ui: true, open_browser: true, data_dir: None, ..
        }));
    }

    #[test]
    fn standalone_cli_still_requires_a_subcommand() {
        assert!(parse_cli(
            vec!["gday-meetings-client".into()],
            Path::new("/usr/local/bin/gday-meetings-client"),
        ).is_err());
    }

    #[test]
    fn explicit_bundle_arguments_preserve_isolated_launch_options() {
        let cli = parse_cli(
            ["gday-meetings-client", "serve", "--port", "8080", "--data-dir", "/tmp/test-meetings", "--web-ui"]
                .map(OsString::from).to_vec(),
            Path::new("/Applications/Gday Meetings Rust.app/Contents/MacOS/gday-meetings-client"),
        ).unwrap();
        assert!(matches!(cli.command, Commands::Serve {
            port: 8080, web_ui: true, open_browser: false, data_dir: Some(_), ..
        }));
    }
}

/// Resolves on the first SIGINT (Ctrl+C) or SIGTERM (e.g. `kill <pid>` or
/// systemd shutdown). On non-unix targets only SIGINT is awaited.
async fn wait_for_shutdown_signal() {
    let ctrl_c = async {
        if let Err(e) = tokio::signal::ctrl_c().await {
            tracing::error!("Failed to install Ctrl+C handler: {}", e);
        }
    };

    #[cfg(unix)]
    let terminate = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut sig) => {
                sig.recv().await;
            }
            Err(e) => {
                tracing::error!("Failed to install SIGTERM handler: {}", e);
                std::future::pending::<()>().await;
            }
        }
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }
}
