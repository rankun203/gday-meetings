use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::body::Body;
use axum::extract::{DefaultBodyLimit, Path, Query, Request, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use clap::Parser;
use serde::Deserialize;
use serde_json::json;
use tokio::fs;
use tokio::io::AsyncWriteExt;
use tokio::sync::RwLock;
use tower_http::cors::CorsLayer;
use tracing::{error, info, warn};
use uuid::Uuid;

#[derive(Parser)]
#[command(name = "file-drop")]
#[command(about = "Temporary file parking server — upload once, retry downloads until expiry")]
struct Cli {
    /// API key required for uploads
    #[arg(long)]
    api_key: String,

    /// Port to listen on
    #[arg(short, long, default_value = "8199")]
    port: u16,

    /// Host to bind to
    #[arg(long, default_value = "0.0.0.0")]
    host: String,

    /// Storage directory for parked files
    #[arg(long, default_value = "./storage")]
    storage_dir: PathBuf,

    /// Maximum file size in bytes (default: 100MB)
    #[arg(long, default_value = "104857600")]
    max_size: u64,

    /// Allowed file extensions (comma-separated)
    #[arg(long, default_value = "mp3,opus")]
    ext: String,

    /// File expiry time in seconds (default: 86400 = 24h)
    #[arg(long, default_value = "86400")]
    expiry_secs: u64,
}

#[derive(Clone)]
struct AppConfig {
    api_key: String,
    storage_dir: PathBuf,
    max_size: u64,
    allowed_ext: Vec<String>,
    expiry: Duration,
}

struct FileEntry {
    original_name: String,
    path: PathBuf,
    size: u64,
    created: Instant,
}

type FileStore = Arc<RwLock<HashMap<String, FileEntry>>>;

#[derive(Clone)]
struct AppState {
    config: AppConfig,
    files: FileStore,
}

fn storage_info(config: &AppConfig, files: &HashMap<String, FileEntry>) -> serde_json::Value {
    let total_size: u64 = files.values().map(|f| f.size).sum();
    let file_count = files.len();
    let dir = config.storage_dir.display().to_string();

    // Try to get filesystem free space
    let free_space = fs_free_space(&config.storage_dir);

    json!({
        "storage_dir": dir,
        "file_count": file_count,
        "total_size_bytes": total_size,
        "total_size_human": format_size(total_size),
        "free_space_bytes": free_space,
        "free_space_human": free_space.map(format_size),
        "max_file_size_bytes": config.max_size,
        "max_file_size_human": format_size(config.max_size),
        "allowed_extensions": config.allowed_ext,
        "expiry_secs": config.expiry.as_secs(),
    })
}

fn print_storage_info(config: &AppConfig, files: &HashMap<String, FileEntry>) {
    let info = storage_info(config, files);
    info!(
        "Storage: {} files, {}, free: {}, dir: {}",
        info["file_count"],
        info["total_size_human"].as_str().unwrap_or("?"),
        info["free_space_human"].as_str().unwrap_or("unknown"),
        info["storage_dir"].as_str().unwrap_or("?"),
    );
}

fn format_size(bytes: u64) -> String {
    if bytes < 1024 {
        format!("{} B", bytes)
    } else if bytes < 1024 * 1024 {
        format!("{:.1} KB", bytes as f64 / 1024.0)
    } else if bytes < 1024 * 1024 * 1024 {
        format!("{:.1} MB", bytes as f64 / (1024.0 * 1024.0))
    } else {
        format!("{:.1} GB", bytes as f64 / (1024.0 * 1024.0 * 1024.0))
    }
}

fn fs_free_space(path: &std::path::Path) -> Option<u64> {
    #[cfg(unix)]
    {
        use std::ffi::CString;
        let c_path = CString::new(path.to_str()?).ok()?;
        unsafe {
            let mut stat: libc::statvfs = std::mem::zeroed();
            if libc::statvfs(c_path.as_ptr(), &mut stat) == 0 {
                Some(stat.f_bavail as u64 * stat.f_frsize as u64)
            } else {
                None
            }
        }
    }
    #[cfg(not(unix))]
    {
        None
    }
}

fn validate_api_key(headers: &HeaderMap, query: &HashMap<String, String>, expected: &str) -> Result<(), (StatusCode, String)> {
    // Check Authorization header first, then ?api_key query param
    let key = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .or_else(|| query.get("api_key").map(|s| s.as_str()));

    match key {
        Some(k) if k == expected => Ok(()),
        Some(_) => {
            warn!("Upload rejected: invalid API key");
            Err((StatusCode::UNAUTHORIZED, "Invalid API key".to_string()))
        }
        None => {
            warn!("Upload rejected: missing API key");
            Err((StatusCode::UNAUTHORIZED, "API key required (Authorization: Bearer <key> or ?api_key=<key>)".to_string()))
        }
    }
}

fn validate_filename(filename: &str, allowed_ext: &[String]) -> Result<String, (StatusCode, String)> {
    let filename = filename.trim();
    if filename.is_empty() || filename.contains('/') || filename.contains('\\') || filename.starts_with('.') {
        warn!("Upload rejected: invalid filename '{}'", filename);
        return Err((StatusCode::BAD_REQUEST, "Invalid filename".to_string()));
    }

    let ext = filename
        .rsplit('.')
        .next()
        .unwrap_or("")
        .to_lowercase();

    if !allowed_ext.iter().any(|a| a == &ext) {
        warn!(
            "Upload rejected: extension '{}' not allowed (allowed: {:?})",
            ext, allowed_ext
        );
        return Err((
            StatusCode::BAD_REQUEST,
            format!("File extension '{}' not allowed. Allowed: {:?}", ext, allowed_ext),
        ));
    }

    Ok(ext)
}

// --- Handlers ---

async fn handle_info(State(state): State<AppState>) -> Json<serde_json::Value> {
    let files = state.files.read().await;
    Json(storage_info(&state.config, &files))
}

#[derive(Deserialize)]
struct UploadQuery {
    #[serde(default)]
    api_key: Option<String>,
    filename: Option<String>,
}

async fn handle_upload(
    State(state): State<AppState>,
    Query(query): Query<UploadQuery>,
    headers: HeaderMap,
    request: Request,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<serde_json::Value>)> {
    // Validate API key
    let query_map: HashMap<String, String> = query.api_key
        .map(|k| [("api_key".to_string(), k)].into_iter().collect())
        .unwrap_or_default();
    validate_api_key(&headers, &query_map, &state.config.api_key)
        .map_err(|(s, e)| (s, Json(json!({"error": e}))))?;

    // Get filename from query param or Content-Disposition header
    let filename = query.filename
        .or_else(|| {
            headers.get("content-disposition")
                .and_then(|v| v.to_str().ok())
                .and_then(|v| {
                    v.split("filename=").nth(1)
                        .map(|f| f.trim_matches('"').to_string())
                })
        })
        .ok_or_else(|| {
            warn!("Upload rejected: no filename provided");
            (StatusCode::BAD_REQUEST, Json(json!({"error": "filename required (?filename=name.opus or Content-Disposition header)"})))
        })?;

    let ext = validate_filename(&filename, &state.config.allowed_ext)
        .map_err(|(s, e)| (s, Json(json!({"error": e}))))?;

    // Check Content-Length early if available
    if let Some(cl) = headers.get("content-length").and_then(|v| v.to_str().ok()).and_then(|v| v.parse::<u64>().ok()) {
        if cl > state.config.max_size {
            warn!(
                "Upload rejected: Content-Length {} exceeds max {} (file: {})",
                format_size(cl), format_size(state.config.max_size), filename
            );
            return Err((
                StatusCode::BAD_REQUEST,
                Json(json!({"error": format!("File too large ({} > {})", format_size(cl), format_size(state.config.max_size))})),
            ));
        }
    }

    // Generate unique ID and file path
    let id = Uuid::new_v4().to_string();
    let stored_name = format!("{}.{}", id, ext);
    let file_path = state.config.storage_dir.join(&stored_name);

    // Stream body to disk, enforcing max size
    let body = request.into_body();
    let stream = body.into_data_stream();
    use tokio_stream::StreamExt;

    let mut file = fs::File::create(&file_path).await.map_err(|e| {
        error!("Failed to create file {}: {}", file_path.display(), e);
        (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": "Failed to create file"})))
    })?;

    let mut total_bytes: u64 = 0;
    let mut stream = std::pin::pin!(stream);

    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| {
            error!("Stream error during upload: {}", e);
            (StatusCode::BAD_REQUEST, Json(json!({"error": format!("Upload stream error: {e}")})))
        })?;

        total_bytes += chunk.len() as u64;
        if total_bytes > state.config.max_size {
            // Clean up partial file
            drop(file);
            let _ = fs::remove_file(&file_path).await;
            warn!(
                "Upload rejected mid-stream: {} exceeds max {} (file: {})",
                format_size(total_bytes), format_size(state.config.max_size), filename
            );
            return Err((
                StatusCode::BAD_REQUEST,
                Json(json!({"error": format!("File too large (exceeded {} limit)", format_size(state.config.max_size))})),
            ));
        }

        file.write_all(&chunk).await.map_err(|e| {
            error!("Write error: {}", e);
            (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": "Failed to write file"})))
        })?;
    }

    file.flush().await.map_err(|e| {
        error!("Flush error: {}", e);
        (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": "Failed to flush file"})))
    })?;
    drop(file);

    if total_bytes == 0 {
        let _ = fs::remove_file(&file_path).await;
        warn!("Upload rejected: empty file ({})", filename);
        return Err((StatusCode::BAD_REQUEST, Json(json!({"error": "Empty file"}))));
    }

    // Register in store
    let download_url = format!("/d/{}.{}", id, ext);
    {
        let mut files = state.files.write().await;
        files.insert(id.clone(), FileEntry {
            original_name: filename.clone(),
            path: file_path,
            size: total_bytes,
            created: Instant::now(),
        });
        info!(
            "Parked: {} ({}) (expires in {}s)",
            filename,
            format_size(total_bytes),
            state.config.expiry.as_secs()
        );
        print_storage_info(&state.config, &files);
    }

    Ok(Json(json!({
        "id": id,
        "url": download_url,
        "filename": filename,
        "size": total_bytes,
        "size_human": format_size(total_bytes),
        "expires_in_secs": state.config.expiry.as_secs(),
    })))
}

async fn handle_download(
    State(state): State<AppState>,
    Path(id_with_ext): Path<String>,
) -> Result<impl IntoResponse, (StatusCode, Json<serde_json::Value>)> {
    // Strip extension if present (e.g., "uuid.opus" -> "uuid")
    let id = id_with_ext.split('.').next().unwrap_or(&id_with_ext).to_string();
    let (path, original_name) = {
        let files = state.files.read().await;
        let entry = files.get(&id).filter(|entry| entry.created.elapsed() < state.config.expiry)
            .ok_or_else(|| (StatusCode::NOT_FOUND, Json(json!({"error": "File not found or expired"}))))?;

        (entry.path.clone(), entry.original_name.clone())
    };

    // Read file and serve
    let bytes = fs::read(&path).await.map_err(|e| {
        error!("Failed to read file {}: {}", path.display(), e);
        (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": "Failed to read file"})))
    })?;

    let size = bytes.len();

    // Creating a response does not mean the remote peer received every byte.
    // Retain the source for retries until the normal expiry task removes it.
    info!("Downloaded: {} ({})", original_name, format_size(size as u64));

    // Determine content type
    let content_type = if original_name.ends_with(".opus") {
        "audio/opus"
    } else if original_name.ends_with(".mp3") {
        "audio/mpeg"
    } else {
        "application/octet-stream"
    };

    Ok((
        [
            ("content-type", content_type.to_string()),
            ("content-disposition", format!("attachment; filename=\"{}\"", original_name)),
            ("content-length", size.to_string()),
        ],
        Body::from(bytes),
    ))
}

async fn handle_health(State(state): State<AppState>) -> (StatusCode, Json<serde_json::Value>) {
    let min_free: u64 = 1024 * 1024 * 1024; // 1 GB
    let free = fs_free_space(&state.config.storage_dir);
    let available = free.map_or(true, |f| f > min_free);
    let status = if available { StatusCode::OK } else { StatusCode::SERVICE_UNAVAILABLE };
    (status, Json(json!({
        "status": if available { "available" } else { "unavailable" },
    })))
}

/// Background task: expire files older than config.expiry
async fn expiry_task(state: AppState) {
    let mut interval = tokio::time::interval(Duration::from_secs(10));
    loop {
        interval.tick().await;
        let mut files = state.files.write().await;
        let now = Instant::now();
        let expired: Vec<String> = files
            .iter()
            .filter(|(_, entry)| now.duration_since(entry.created) > state.config.expiry)
            .map(|(id, _)| id.clone())
            .collect();

        for id in &expired {
            if let Some(entry) = files.remove(id) {
                let _ = fs::remove_file(&entry.path).await;
                warn!(
                    "Expired: {} ({}) after {}s",
                    entry.original_name,
                    format_size(entry.size),
                    state.config.expiry.as_secs()
                );
            }
        }
        if !expired.is_empty() {
            print_storage_info(&state.config, &files);
        }
    }
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "file_drop=info".into()),
        )
        .init();

    let cli = Cli::parse();

    let allowed_ext: Vec<String> = cli.ext.split(',').map(|s| s.trim().to_lowercase()).collect();

    let config = AppConfig {
        api_key: cli.api_key.clone(),
        storage_dir: cli.storage_dir.clone(),
        max_size: cli.max_size,
        allowed_ext: allowed_ext.clone(),
        expiry: Duration::from_secs(cli.expiry_secs),
    };

    // Create storage directory
    std::fs::create_dir_all(&config.storage_dir).expect("failed to create storage directory");

    let state = AppState {
        config: config.clone(),
        files: Arc::new(RwLock::new(HashMap::new())),
    };

    // Print initial storage info
    {
        let files = state.files.read().await;
        print_storage_info(&config, &files);
    }

    // Start expiry background task
    let expiry_state = state.clone();
    tokio::spawn(expiry_task(expiry_state));

    let app = Router::new()
        .route("/health", get(handle_health))
        .route("/info", get(handle_info))
        .route("/upload", post(handle_upload))
        .route("/d/{id}", get(handle_download))
        .layer(DefaultBodyLimit::max(cli.max_size as usize + 1024)) // slight overhead for headers
        .layer(CorsLayer::permissive())
        .with_state(state);

    let addr = format!("{}:{}", cli.host, cli.port);
    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    info!("file-drop listening on http://{}", addr);
    info!("API key required for uploads");
    info!("Max file size: {}", format_size(cli.max_size));
    info!("Allowed extensions: {:?}", allowed_ext);
    info!("Expiry: {}s", cli.expiry_secs);

    axum::serve(listener, app).await.unwrap();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn credential_probe_validates_key_without_creating_files() {
        let directory = std::env::temp_dir().join(format!("file-drop-probe-{}", Uuid::new_v4()));
        fs::create_dir_all(&directory).await.unwrap();
        let state = AppState {
            config: AppConfig {
                api_key: "test".into(), storage_dir: directory.clone(), max_size: 100,
                allowed_ext: vec!["opus".into()], expiry: Duration::from_secs(60),
            },
            files: Arc::new(RwLock::new(HashMap::new())),
        };
        for (key, expected) in [("wrong", StatusCode::UNAUTHORIZED), ("test", StatusCode::BAD_REQUEST)] {
            let mut headers = HeaderMap::new();
            headers.insert("authorization", format!("Bearer {key}").parse().unwrap());
            let request = Request::builder().method("POST").uri("/upload").body(Body::empty()).unwrap();
            let result = handle_upload(
                State(state.clone()), Query(UploadQuery { api_key: None, filename: None }),
                headers, request,
            ).await;
            let (status, Json(body)) = result.unwrap_err();
            assert_eq!(status, expected);
            if key == "test" {
                assert_eq!(body["error"], "filename required (?filename=name.opus or Content-Disposition header)");
            }
            assert!(state.files.read().await.is_empty());
            assert!(fs::read_dir(&directory).await.unwrap().next_entry().await.unwrap().is_none());
        }
        fs::remove_dir_all(directory).await.unwrap();
    }

    #[tokio::test]
    async fn downloads_can_retry_until_expiry() {
        let directory = std::env::temp_dir().join(format!("file-drop-test-{}", Uuid::new_v4()));
        fs::create_dir_all(&directory).await.unwrap();
        let path = directory.join("audio.opus");
        fs::write(&path, b"audio bytes").await.unwrap();
        let state = AppState {
            config: AppConfig {
                api_key: "test".into(), storage_dir: directory.clone(), max_size: 100,
                allowed_ext: vec!["opus".into()], expiry: Duration::from_secs(60),
            },
            files: Arc::new(RwLock::new(HashMap::from([("test".into(), FileEntry {
                original_name: "audio.opus".into(), path: path.clone(), size: 11,
                created: Instant::now(),
            })]))),
        };
        for _ in 0..2 {
            let response = handle_download(State(state.clone()), Path("test.opus".into()))
                .await.unwrap().into_response();
            assert_eq!(response.status(), StatusCode::OK);
            let body = axum::body::to_bytes(response.into_body(), 100).await.unwrap();
            assert_eq!(body.as_ref(), b"audio bytes");
        }
        assert!(path.exists());
        state.files.write().await.get_mut("test").unwrap().created =
            Instant::now() - Duration::from_secs(61);
        let result = handle_download(State(state), Path("test.opus".into())).await;
        assert!(matches!(result, Err((StatusCode::NOT_FOUND, _))));
        fs::remove_dir_all(directory).await.unwrap();
    }
}
