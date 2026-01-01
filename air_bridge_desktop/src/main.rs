#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use axum::{
    extract::{Path, State, Query},
    response::{Html, IntoResponse, Response},
    routing::get,
    Router,
    body::Body,
};
use local_ip_address::local_ip;
use rand::Rng;
use serde::{Deserialize, Serialize, Serializer};
use std::{
    io::{Cursor, Write, Read},
    net::{SocketAddr, Ipv6Addr, IpAddr}, // 引入 IpAddr
    sync::{Arc, Mutex},
    path::PathBuf,
    fs::File,
    collections::HashMap,
    process::Command,
};
use tauri::State as TauriState;
use tower_http::cors::CorsLayer;
use qrcode::QrCode;
use image::Luma;
use base64::{Engine as _, engine::general_purpose};
use walkdir::WalkDir;
use tokio::net::TcpListener;
use socket2::{Socket, Domain, Type, Protocol};
use if_addrs::get_if_addrs; // 新增

// --- 核心数据结构 ---

#[derive(Clone)]
enum SharedItem {
    File { id: String, name: String, path: String, size: u64 },
    Folder { id: String, name: String, path: String, size: u64, children: Vec<SharedItem> },
}

impl SharedItem {
    fn id(&self) -> &str {
        match self {
            SharedItem::File { id, .. } => id,
            SharedItem::Folder { id, .. } => id,
        }
    }
}

impl Serialize for SharedItem {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        use serde::ser::SerializeStruct;
        match self {
            SharedItem::File { id, name, size, .. } => {
                let mut state = serializer.serialize_struct("SharedItem", 4)?;
                state.serialize_field("type", "file")?;
                state.serialize_field("id", id)?;
                state.serialize_field("name", name)?;
                state.serialize_field("size", size)?;
                state.end()
            }
            SharedItem::Folder { id, name, size, children, .. } => {
                let mut state = serializer.serialize_struct("SharedItem", 5)?;
                state.serialize_field("type", "folder")?;
                state.serialize_field("id", id)?;
                state.serialize_field("name", name)?;
                state.serialize_field("size", size)?;
                state.serialize_field("children", children)?;
                state.end()
            }
        }
    }
}

struct AppState {
    items: Mutex<Vec<SharedItem>>,
    token: Mutex<String>,
    is_serving: Mutex<bool>,
    use_short_token: Mutex<bool>,
    use_ipv6: Mutex<bool>,
    show_hidden: Mutex<bool>,
    port: u16,
}

// --- 辅助函数 ---

fn generate_token(short: bool) -> String {
    if short {
        rand::thread_rng().gen_range(1000..9999).to_string()
    } else {
        let chars: Vec<char> = "abcdefghijklmnopqrstuvwxyz0123456789".chars().collect();
        (0..6).map(|_| chars[rand::thread_rng().gen_range(0..chars.len())]).collect()
    }
}

fn find_item(items: &[SharedItem], target_id: &str) -> Option<SharedItem> {
    for item in items {
        if item.id() == target_id {
            return Some(item.clone());
        }
        if let SharedItem::Folder { children, .. } = item {
            if let Some(found) = find_item(children, target_id) {
                return Some(found);
            }
        }
    }
    None
}

fn remove_item_recursive(items: &mut Vec<SharedItem>, target_id: &str) -> bool {
    if let Some(pos) = items.iter().position(|x| x.id() == target_id) {
        items.remove(pos);
        return true;
    }
    for item in items.iter_mut() {
        if let SharedItem::Folder { children, size, .. } = item {
            if remove_item_recursive(children, target_id) {
                *size = children.iter().map(|c| match c {
                    SharedItem::File { size, .. } => *size,
                    SharedItem::Folder { size, .. } => *size,
                }).sum();
                return true;
            }
        }
    }
    false
}

fn get_mime_type(name: &str) -> &'static str {
    let ext = std::path::Path::new(name).extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
    match ext.as_str() {
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "bmp" => "image/bmp",
        "pdf" => "application/pdf",
        "txt" => "text/plain",
        "html" => "text/html",
        "mp4" => "video/mp4",
        _ => "application/octet-stream",
    }
}

// 智能获取公网 IPv6 地址
fn get_global_ipv6_address() -> Option<String> {
    let ifaces = get_if_addrs().ok()?;
    for iface in ifaces {
        if let IpAddr::V6(ip) = iface.addr.ip() {
            // 排除回环 (::1)
            if ip.is_loopback() { continue; }
            // 排除链路本地 (fe80::)
            // segments() 返回 [u16; 8]，检查前缀
            let segments = ip.segments();
            if (segments[0] & 0xffc0) == 0xfe80 { continue; }
            
            return Some(ip.to_string());
        }
    }
    None
}

async fn bind_port_range(start: u16, end: u16) -> (TcpListener, u16) {
    for port in start..=end {
        if let Ok(socket) = Socket::new(Domain::IPV6, Type::STREAM, Some(Protocol::TCP)) {
            if socket.set_only_v6(false).is_ok() {
                let addr = SocketAddr::from((Ipv6Addr::UNSPECIFIED, port));
                if socket.bind(&addr.into()).is_ok() {
                    if socket.listen(128).is_ok() {
                        let std_listener: std::net::TcpListener = socket.into();
                        std_listener.set_nonblocking(true).unwrap();
                        let tokio_listener = TcpListener::from_std(std_listener).unwrap();
                        return (tokio_listener, port);
                    }
                }
            }
        }
    }
    let addr = SocketAddr::from(([0, 0, 0, 0], 0));
    let listener = TcpListener::bind(addr).await.expect("No ports available");
    let port = listener.local_addr().unwrap().port();
    (listener, port)
}

// --- Axum Handlers ---

async fn start_server(app_state: Arc<AppState>, listener: TcpListener) {
    let app = Router::new()
        .route("/:token", get(handle_index))
        .route("/:token/api/files", get(handle_file_list))
        .route("/:token/download/:id", get(handle_download))
        .route("/:token/zip/:id", get(handle_zip))
        .layer(CorsLayer::permissive())
        .with_state(app_state.clone());

    println!("Server listening...");
    axum::serve(listener, app).await.unwrap();
}

fn check_access(state: &Arc<AppState>, token: &str) -> bool {
    let serving = *state.is_serving.lock().unwrap();
    let current_token = state.token.lock().unwrap();
    serving && token == *current_token
}

async fn handle_index(State(state): State<Arc<AppState>>, Path(token): Path<String>) -> Response {
    if !check_access(&state, &token) { return (axum::http::StatusCode::FORBIDDEN, "Service Stopped").into_response(); }

    let html = r#"
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AirBridge PC</title>
    <style>
        body { font-family: system-ui, -apple-system, sans-serif; padding: 20px; background: #f2f2f7; color: #333; }
        .container { max-width: 800px; margin: 0 auto; }
        .card { background: white; padding: 12px 16px; margin-bottom: 8px; border-radius: 12px; display: flex; align-items: center; box-shadow: 0 1px 3px rgba(0,0,0,0.05); }
        .card.folder { cursor: pointer; background: #fffcf5; border: 1px solid #fff3cd; }
        .icon { font-size: 24px; margin-right: 12px; }
        .info { flex: 1; overflow: hidden; }
        .name { font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .meta { font-size: 12px; color: #888; }
        .btn { text-decoration: none; color: white; background: #007bff; padding: 6px 12px; border-radius: 16px; font-size: 12px; border: none; cursor: pointer; margin-left: 5px; }
        .btn-zip { background: #ff9800; }
        .btn-preview { background: #28a745; }
        .breadcrumbs { padding: 10px 0; color: #666; margin-bottom: 10px; }
        .crumb { color: #007bff; cursor: pointer; text-decoration: underline; margin: 0 5px; }
    </style>
</head>
<body>
    <div class="container">
        <h2 style="text-align:center;color:#007bff">💻 AirBridge</h2>
        <div id="breadcrumbs" class="breadcrumbs"></div>
        <div id="list"></div>
    </div>
    <script>
        const basePath = window.location.pathname;
        let rootData = [];
        let stack = [];

        function formatSize(bytes) {
           if (typeof bytes !== 'number') return '0 B';
           if (bytes < 1024) return bytes + ' B';
           if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
           return (bytes / 1024 / 1024).toFixed(2) + ' MB';
        }

        fetch(basePath + '/api/files').then(r=>r.json()).then(data => {
            rootData = data;
            render(rootData);
            renderBread();
        });

        function render(items) {
            const list = document.getElementById('list');
            list.innerHTML = '';
            if (!items || items.length === 0) { list.innerHTML = '<p style="text-align:center;color:#999">空文件夹</p>'; return; }
            
            items.forEach(item => {
                const div = document.createElement('div');
                const isFolder = item.type === 'folder';
                div.className = isFolder ? 'card folder' : 'card';
                
                let icon = isFolder ? '📂' : '📄';
                let btns = '';
                
                if (isFolder) {
                    const zipUrl = `${basePath}/zip/${item.id}`;
                    btns = `<a class="btn btn-zip" href="${zipUrl}" download="${item.name}.zip" onclick="event.stopPropagation()">打包下载</a>`;
                    div.onclick = (e) => { if(e.target.tagName !== 'A') enter(item); };
                } else {
                    const dlUrl = `${basePath}/download/${item.id}`;
                    btns = `<a class="btn" href="${dlUrl}" download="${item.name}">下载</a>`;
                    if (/\.(jpg|png|gif|txt|pdf)$/i.test(item.name)) {
                        btns = `<a class="btn btn-preview" href="${dlUrl}?inline=true" target="_blank">预览</a>` + btns;
                    }
                }

                div.innerHTML = `
                    <div class="icon">${icon}</div>
                    <div class="info"><div class="name">${item.name}</div><div class="meta">${isFolder ? item.children.length+' 项 · ' + formatSize(item.size) : formatSize(item.size)}</div></div>
                    ${btns}
                `;
                list.appendChild(div);
            });
        }

        function renderBread() {
            const el = document.getElementById('breadcrumbs');
            let html = `<span class="crumb" onclick="goRoot()">首页</span>`;
            stack.forEach((f, i) => html += ` > <span class="crumb" onclick="goLevel(${i})">${f.name}</span>`);
            el.innerHTML = html;
        }

        function enter(item) { stack.push(item); render(item.children); renderBread(); }
        function goRoot() { stack = []; render(rootData); renderBread(); }
        function goLevel(i) { stack = stack.slice(0, i+1); render(stack[stack.length-1].children); renderBread(); }
    </script>
</body>
</html>
"#;
    Html(html).into_response()
}

async fn handle_file_list(State(state): State<Arc<AppState>>, Path(token): Path<String>) -> Response {
    if !check_access(&state, &token) { return (axum::http::StatusCode::FORBIDDEN, "").into_response(); }
    let items = state.items.lock().unwrap();
    axum::Json(items.clone()).into_response()
}

async fn handle_download(
    State(state): State<Arc<AppState>>,
    Path((token, id)): Path<(String, String)>,
    Query(params): Query<HashMap<String, String>>,
) -> Response {
    if !check_access(&state, &token) { return (axum::http::StatusCode::FORBIDDEN, "").into_response(); }

    let items = state.items.lock().unwrap();
    if let Some(SharedItem::File { path, name, .. }) = find_item(&items, &id) {
        match std::fs::read(&path) {
            Ok(content) => {
                let is_inline = params.get("inline").map(|v| v == "true").unwrap_or(false);
                let disposition = if is_inline { "inline" } else { "attachment" };
                let mime_type = get_mime_type(&name);

                Response::builder()
                    .header("Content-Type", mime_type)
                    .header("Content-Disposition", format!("{}; filename=\"{}\"", disposition, name))
                    .body(Body::from(content))
                    .unwrap()
            },
            Err(_) => (axum::http::StatusCode::INTERNAL_SERVER_ERROR, "Read Error").into_response()
        }
    } else {
        (axum::http::StatusCode::NOT_FOUND, "Not Found").into_response()
    }
}

async fn handle_zip(
    State(state): State<Arc<AppState>>,
    Path((token, id)): Path<(String, String)>,
) -> Response {
    if !check_access(&state, &token) { return (axum::http::StatusCode::FORBIDDEN, "").into_response(); }

    let items = state.items.lock().unwrap();
    if let Some(SharedItem::Folder { path, name, .. }) = find_item(&items, &id) {
        let mut buf = Cursor::new(Vec::new());
        let mut zip = zip::ZipWriter::new(buf);
        let options = zip::write::FileOptions::default().compression_method(zip::CompressionMethod::Stored);

        let walk = WalkDir::new(&path);
        for entry in walk.into_iter().filter_map(|e| e.ok()) {
            let entry_path = entry.path();
            if entry_path.is_file() {
                let relative_path = entry_path.strip_prefix(&path).unwrap_or(entry_path);
                let clean_name = relative_path.to_string_lossy().replace("\\", "/");
                let _ = zip.start_file(clean_name, options);
                if let Ok(mut f) = File::open(entry_path) {
                    let mut buffer = Vec::new();
                    if f.read_to_end(&mut buffer).is_ok() {
                        let _ = zip.write_all(&buffer);
                    }
                }
            }
        }
        
        let finished_buf = zip.finish().unwrap();
        let final_bytes = finished_buf.into_inner();

        Response::builder()
            .header("Content-Type", "application/zip")
            .header("Content-Disposition", format!("attachment; filename=\"{}.zip\"", name))
            .body(Body::from(final_bytes))
            .unwrap()
    } else {
        (axum::http::StatusCode::NOT_FOUND, "Folder Not Found").into_response()
    }
}

// --- Tauri Commands ---

fn scan_folder(dir: PathBuf, show_hidden: bool) -> Option<SharedItem> {
    let name = dir.file_name()?.to_string_lossy().to_string();
    let mut children = Vec::new();
    let mut total_size: u64 = 0;
    
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            let file_name = path.file_name().unwrap_or_default().to_string_lossy();
            if !show_hidden && file_name.starts_with('.') { continue; }
            if path.is_symlink() { continue; }

            if path.is_file() {
                let id: String = rand::thread_rng().gen_range(10000..99999).to_string();
                let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
                total_size += size;
                children.push(SharedItem::File {
                    id,
                    name: file_name.to_string(),
                    path: path.to_string_lossy().to_string(),
                    size,
                });
            } else if path.is_dir() {
                if let Some(sub) = scan_folder(path, show_hidden) {
                    if let SharedItem::Folder { size, .. } = sub {
                        total_size += size;
                    }
                    children.push(sub);
                }
            }
        }
    }
    
    children.sort_by(|a, b| {
        let a_is_folder = matches!(a, SharedItem::Folder { .. });
        let b_is_folder = matches!(b, SharedItem::Folder { .. });
        if a_is_folder && !b_is_folder { std::cmp::Ordering::Less }
        else if !a_is_folder && b_is_folder { std::cmp::Ordering::Greater }
        else { std::cmp::Ordering::Equal }
    });

    Some(SharedItem::Folder {
        id: rand::thread_rng().gen_range(10000..99999).to_string(),
        name,
        path: dir.to_string_lossy().to_string(),
        size: total_size,
        children,
    })
}

#[tauri::command]
async fn pick_files(state: TauriState<'_, Arc<AppState>>) -> Result<usize, String> {
    let files = rfd::AsyncFileDialog::new().set_title("选择文件").pick_files().await;
    let show_hidden = *state.show_hidden.lock().unwrap();
    if let Some(files) = files {
        let mut list = state.items.lock().unwrap();
        let count = files.len();
        for f in files {
            let name = f.file_name();
            if !show_hidden && name.starts_with('.') { continue; }
            let id: String = rand::thread_rng().gen_range(10000..99999).to_string();
            let size = std::fs::metadata(f.path()).map(|m| m.len()).unwrap_or(0);
            list.push(SharedItem::File {
                id,
                name,
                path: f.path().to_string_lossy().to_string(),
                size,
            });
        }
        Ok(count)
    } else { Ok(0) }
}

#[tauri::command]
async fn pick_folder(state: TauriState<'_, Arc<AppState>>) -> Result<usize, String> {
    let dir = rfd::AsyncFileDialog::new().set_title("选择文件夹").pick_folder().await;
    let show_hidden = *state.show_hidden.lock().unwrap();
    if let Some(dir) = dir {
        if let Some(folder) = scan_folder(dir.path().to_path_buf(), show_hidden) {
            let mut list = state.items.lock().unwrap();
            list.push(folder);
            return Ok(1);
        }
    }
    Ok(0)
}

#[tauri::command]
fn remove_item(state: TauriState<'_, Arc<AppState>>, id: String) {
    let mut list = state.items.lock().unwrap();
    remove_item_recursive(&mut list, &id);
}

#[tauri::command]
fn toggle_server(state: TauriState<'_, Arc<AppState>>) -> bool {
    let mut serving = state.is_serving.lock().unwrap();
    *serving = !*serving;
    *serving
}

#[tauri::command]
fn set_config(state: TauriState<'_, Arc<AppState>>, short_token: bool, ipv6: bool, show_hidden: bool) {
    let mut st = state.use_short_token.lock().unwrap();
    let mut ip6 = state.use_ipv6.lock().unwrap();
    let mut hidden = state.show_hidden.lock().unwrap();
    if *st != short_token {
        *state.token.lock().unwrap() = generate_token(short_token);
    }
    *st = short_token;
    *ip6 = ipv6;
    *hidden = show_hidden;
}

#[tauri::command]
fn fix_firewall(state: TauriState<'_, Arc<AppState>>) {
    let port = state.port;
    
    // 修正：
    // 1. 去掉了不支持的 force=yes
    // 2. 使用 PowerShell 的数组格式 (逗号分隔)，确保 netsh 能正确识别每个单词
    let ps_args = format!(
        "\"advfirewall\", \"firewall\", \"add\", \"rule\", \"name=AirBridge\", \"dir=in\", \"action=allow\", \"protocol=TCP\", \"localport={}\", \"profile=any\"",
        port
    );
    
    let _ = Command::new("powershell")
        // 注意这里直接传 ps_args 变量，不要再加 format! 和引号了
        .args(&["Start-Process", "netsh", "-ArgumentList", &ps_args, "-Verb", "RunAs"])
        .spawn();
}

#[derive(Serialize)]
struct ServerInfo {
    url: String,
    qr_base64: String,
    is_serving: bool,
    items: Vec<SharedItem>,
    short_token: bool,
    use_ipv6: bool,
    show_hidden: bool,
    ipv6_warning: Option<String>, // 新增警告字段
}

#[tauri::command]
fn get_state(state: TauriState<'_, Arc<AppState>>) -> ServerInfo {
    // IPv6 智能检测逻辑
    let use_ipv6 = *state.use_ipv6.lock().unwrap();
    let (host, warning) = if use_ipv6 {
        match get_global_ipv6_address() {
            Some(v6) => (format!("[{}]", v6), None),
            None => (local_ip().unwrap().to_string(), Some("未检测到公网 IPv6 地址，已回退到 IPv4".to_string()))
        }
    } else {
        (local_ip().unwrap().to_string(), None)
    };

    let token = state.token.lock().unwrap();
    let serving = *state.is_serving.lock().unwrap();
    let items = state.items.lock().unwrap().clone();
    let short_token = *state.use_short_token.lock().unwrap();
    let show_hidden = *state.show_hidden.lock().unwrap();
    
    let url = format!("http://{}:{}/{}", host, state.port, token);
    
    let code = QrCode::new(url.as_bytes()).unwrap();
    let image = code.render::<Luma<u8>>().build();
    let mut buffer = Cursor::new(Vec::new());
    image::DynamicImage::ImageLuma8(image)
        .write_to(&mut buffer, image::ImageOutputFormat::Png)
        .unwrap();
    let qr_base64 = general_purpose::STANDARD.encode(buffer.get_ref());

    ServerInfo {
        url: if serving { url } else { "服务已停止".to_string() },
        qr_base64,
        is_serving: serving,
        items,
        short_token,
        use_ipv6,
        show_hidden,
        ipv6_warning: warning,
    }
}

// --- Main ---

#[tokio::main]
async fn main() {
    // 自动寻找端口 (9000-9010) 并双栈绑定
    let (listener, port) = bind_port_range(9000, 9010).await;

    let app_state = Arc::new(AppState {
        items: Mutex::new(Vec::new()),
        token: Mutex::new(generate_token(true)),
        is_serving: Mutex::new(false),
        use_short_token: Mutex::new(true),
        use_ipv6: Mutex::new(false),
        show_hidden: Mutex::new(false),
        port,
    });

    let state_clone = app_state.clone();
    tokio::spawn(async move {
        start_server(state_clone, listener).await;
    });

    tauri::Builder::default()
        .manage(app_state)
        .invoke_handler(tauri::generate_handler![pick_files, pick_folder, remove_item, toggle_server, set_config, get_state, fix_firewall])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}