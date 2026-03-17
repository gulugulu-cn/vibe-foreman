// 监听 /tmp/hub-signals/events/ 目录
// 新 JSON 文件出现 → 读取 → 发通知 → 推送到前端

use crate::{AppState, HubEvent};
use notify::{Config, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use std::fs;
use std::path::Path;
use std::sync::mpsc;
use std::thread;
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_notification::NotificationExt;

const EVENTS_DIR: &str = "/tmp/hub-signals/events";

pub fn start_watching(app: AppHandle) {
    // 确保目录存在
    fs::create_dir_all(EVENTS_DIR).ok();

    thread::spawn(move || {
        let (tx, rx) = mpsc::channel();

        let mut watcher = RecommendedWatcher::new(tx, Config::default())
            .expect("Failed to create watcher");

        watcher
            .watch(Path::new(EVENTS_DIR), RecursiveMode::NonRecursive)
            .expect("Failed to watch events directory");

        // 处理文件事件
        for result in rx {
            match result {
                Ok(event) => {
                    if matches!(event.kind, EventKind::Create(_)) {
                        for path in event.paths {
                            if path.extension().map_or(false, |e| e == "json") {
                                handle_event_file(&app, &path);
                            }
                        }
                    }
                }
                Err(e) => eprintln!("Watch error: {}", e),
            }
        }
    });
}

fn handle_event_file(app: &AppHandle, path: &Path) {
    // 读取 JSON
    let content = match fs::read_to_string(path) {
        Ok(c) => c,
        Err(_) => return,
    };

    let event: HubEvent = match serde_json::from_str(&content) {
        Ok(e) => e,
        Err(_) => return,
    };

    // 发系统通知
    send_notification(app, &event);

    // 推送到前端面板
    app.emit("hub-event", &event).ok();

    // 保存到状态
    if let Some(state) = app.try_state::<AppState>() {
        let mut events = state.events.lock().unwrap();
        events.insert(0, event);
        if events.len() > 50 {
            events.truncate(50);
        }
    }

    // 删除已处理的文件
    fs::remove_file(path).ok();
}

fn send_notification(app: &AppHandle, event: &HubEvent) {
    let (title, icon) = match event.event_type.as_str() {
        "stop" => (format!("✅ {}", event.project), "done"),
        "permission" => (format!("⚠️ {} 需要授权", event.project), "attention"),
        _ => (event.project.clone(), "info"),
    };

    app.notification()
        .builder()
        .title(&title)
        .body(&event.message)
        .show()
        .ok();

    // macOS: 播放语音
    #[cfg(target_os = "macos")]
    {
        let hub_dir = std::env::var("HOME")
            .map(|h| std::path::PathBuf::from(h).join("Documents/code/claude-hub/sounds"))
            .unwrap_or_default();

        let pattern = if event.event_type == "stop" { "done" } else { "auth" };
        if let Ok(entries) = fs::read_dir(&hub_dir) {
            let files: Vec<_> = entries
                .filter_map(|e| e.ok())
                .filter(|e| {
                    e.file_name()
                        .to_string_lossy()
                        .starts_with(pattern)
                })
                .collect();

            if !files.is_empty() {
                let idx = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_nanos() as usize % files.len())
                    .unwrap_or(0);

                std::process::Command::new("afplay")
                    .arg(files[idx].path())
                    .spawn()
                    .ok();
            }
        }
    }
}
