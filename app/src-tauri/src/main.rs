// Claude Hub - 通知托盘 + 状态面板
// 监听 /tmp/hub-signals/events/ 目录，接收 Claude Code hooks 的事件

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod watcher;

use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use tauri::{
    AppHandle, Manager,
    menu::{MenuBuilder, MenuItemBuilder},
    tray::TrayIconBuilder,
};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HubEvent {
    #[serde(rename = "type")]
    pub event_type: String,
    pub project: String,
    pub message: String,
    pub timestamp: String,
}

// 全局状态
pub struct AppState {
    pub events: Mutex<Vec<HubEvent>>,
}

// 前端调用：获取历史事件
#[tauri::command]
fn get_events(state: tauri::State<AppState>) -> Vec<HubEvent> {
    state.events.lock().unwrap().clone()
}

// 前端调用：跳转到项目窗口
#[tauri::command]
fn focus_project(project: String) {
    #[cfg(target_os = "macos")]
    {
        let script = format!(
            r#"
            tell application "iTerm2" to activate
            do shell script "tmux select-window -t hub:{}"
            "#,
            project
        );
        std::process::Command::new("osascript")
            .arg("-e")
            .arg(&script)
            .spawn()
            .ok();
    }

    #[cfg(target_os = "windows")]
    {
        // Windows: 激活 Windows Terminal
        std::process::Command::new("cmd")
            .args(["/c", "start", "wt", "-w", "0", "focus-tab", "-t", "0"])
            .spawn()
            .ok();
    }
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_notification::init())
        .manage(AppState {
            events: Mutex::new(Vec::new()),
        })
        .invoke_handler(tauri::generate_handler![get_events, focus_project])
        .setup(|app| {
            let handle = app.handle().clone();

            // 创建托盘菜单
            let show_item = MenuItemBuilder::with_id("show", "显示面板").build(app)?;
            let quit_item = MenuItemBuilder::with_id("quit", "退出").build(app)?;
            let menu = MenuBuilder::new(app)
                .item(&show_item)
                .separator()
                .item(&quit_item)
                .build()?;

            // 创建托盘图标
            TrayIconBuilder::new()
                .menu(&menu)
                .tooltip("Claude Hub")
                .on_menu_event(move |app, event| {
                    match event.id().as_ref() {
                        "show" => {
                            if let Some(window) = app.get_webview_window("main") {
                                window.show().ok();
                                window.set_focus().ok();
                            }
                        }
                        "quit" => {
                            app.exit(0);
                        }
                        _ => {}
                    }
                })
                .on_tray_icon_event(|tray, event| {
                    if let tauri::tray::TrayIconEvent::Click { .. } = event {
                        let app = tray.app_handle();
                        if let Some(window) = app.get_webview_window("main") {
                            window.show().ok();
                            window.set_focus().ok();
                        }
                    }
                })
                .build(app)?;

            // 启动文件监听
            watcher::start_watching(handle);

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
