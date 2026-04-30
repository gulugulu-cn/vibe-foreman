// Claude Hub - 通知托盘 + 状态面板

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod projects;
mod usage;
mod watcher;

use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use tauri::{
    Manager,
    menu::{Menu, MenuItem},
    tray::{MouseButton, TrayIconBuilder, TrayIconEvent},
};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HubEvent {
    #[serde(rename = "type")]
    pub event_type: String,
    pub project: String,
    pub message: String,
    pub timestamp: String,
}

pub struct AppState {
    pub events: Mutex<Vec<HubEvent>>,
}

#[tauri::command]
fn get_events(state: tauri::State<AppState>) -> Vec<HubEvent> {
    state.events.lock().unwrap().clone()
}

#[tauri::command]
fn get_projects() -> Vec<projects::Project> {
    projects::load_projects()
}

#[tauri::command]
fn get_usage_stats(range: String) -> usage::UsageStats {
    usage::compute_usage(&range)
}

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
}

#[tauri::command]
fn open_project(name: String, path: String, mode: String) {
    projects::open_in_tmux(&name, &path, &mode);
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_notification::init())
        .manage(AppState {
            events: Mutex::new(Vec::new()),
        })
        .invoke_handler(tauri::generate_handler![
            get_events,
            get_projects,
            get_usage_stats,
            focus_project,
            open_project
        ])
        .setup(|app| {
            // 窗口关闭 → 隐藏
            let handle = app.handle().clone();
            if let Some(window) = app.get_webview_window("main") {
                window.on_window_event(move |event| {
                    if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                        api.prevent_close();
                        if let Some(win) = handle.get_webview_window("main") {
                            win.hide().ok();
                        }
                    }
                });
            }

            // 右键菜单只放"退出"，左键点击负责 toggle 窗口
            let quit_item = MenuItem::with_id(app, "quit", "退出 Claude Hub", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&quit_item])?;

            // 托盘图标（必须显式设置 icon，TrayIconBuilder 不继承 config）
            let _tray = TrayIconBuilder::new()
                .icon(tauri::image::Image::from_bytes(include_bytes!("../icons/32x32.png"))?)
                .menu(&menu)
                .show_menu_on_left_click(false)
                .tooltip("Claude Hub")
                .on_menu_event(|app, event| {
                    if event.id.as_ref() == "quit" {
                        app.exit(0);
                    }
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        ..
                    } = event
                    {
                        if let Some(window) = tray.app_handle().get_webview_window("main") {
                            window.show().ok();
                            window.set_focus().ok();
                        }
                    }
                })
                .build(app)?;

            // 文件监听
            watcher::start_watching(app.handle().clone());

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
