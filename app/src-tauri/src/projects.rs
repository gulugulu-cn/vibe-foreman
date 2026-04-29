// 读取 projects.yaml + 检查 tmux 窗口状态

use serde::Serialize;
use std::fs;
use std::process::Command;

#[derive(Debug, Clone, Default, Serialize)]
pub struct GitInfo {
    pub is_git: bool,
    pub branch: String,
    pub changes: u32,
    pub ahead: u32,
    pub behind: u32,
    pub has_upstream: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct Project {
    pub name: String,
    pub path: String,
    pub aliases: Vec<String>,
    pub description: String,
    pub running: bool,
    pub git: GitInfo,
}

/// 从 projects.yaml 读取项目列表，并检查 tmux hub 窗口状态
pub fn load_projects() -> Vec<Project> {
    let home = std::env::var("HOME").unwrap_or_default();
    let yaml_path = format!("{}/Documents/code/claude-hub/projects.yaml", home);

    let content = match fs::read_to_string(&yaml_path) {
        Ok(c) => c,
        Err(_) => return vec![],
    };

    let running_windows = get_tmux_windows();
    let mut projects = parse_yaml(&content);

    for p in &mut projects {
        p.running = running_windows.contains(&p.name);
        // 展开 ~ 为绝对路径
        if p.path.starts_with("~/") {
            p.path = format!("{}/{}", home, &p.path[2..]);
        }
        p.git = collect_git_info(&p.path);
    }

    projects
}

/// 单次 git 命令获取分支、未提交数、ahead/behind
fn collect_git_info(path: &str) -> GitInfo {
    let output = match Command::new("git")
        .args(["-C", path, "status", "--porcelain=v2", "--branch"])
        .output()
    {
        Ok(o) if o.status.success() => o,
        _ => return GitInfo::default(),
    };

    let mut info = GitInfo {
        is_git: true,
        ..Default::default()
    };

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut changes: u32 = 0;

    for line in stdout.lines() {
        if let Some(rest) = line.strip_prefix("# branch.head ") {
            info.branch = rest.trim().to_string();
        } else if line.starts_with("# branch.upstream ") {
            info.has_upstream = true;
        } else if let Some(rest) = line.strip_prefix("# branch.ab ") {
            // 格式：+<ahead> -<behind>
            let mut parts = rest.split_whitespace();
            if let Some(a) = parts.next() {
                info.ahead = a.trim_start_matches('+').parse().unwrap_or(0);
            }
            if let Some(b) = parts.next() {
                info.behind = b.trim_start_matches('-').parse().unwrap_or(0);
            }
        } else if !line.starts_with('#') && !line.is_empty() {
            changes += 1;
        }
    }

    info.changes = changes;
    info
}

/// 获取 tmux hub session 的窗口名列表
fn get_tmux_windows() -> Vec<String> {
    let output = Command::new("tmux")
        .args(["list-windows", "-t", "hub", "-F", "#{window_name}"])
        .output();

    match output {
        Ok(o) if o.status.success() => {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .map(|s| s.to_string())
                .collect()
        }
        _ => vec![],
    }
}

/// 简单解析 projects.yaml（不依赖 yaml crate）
fn parse_yaml(content: &str) -> Vec<Project> {
    let mut projects = Vec::new();
    let mut current: Option<Project> = None;

    for line in content.lines() {
        let trimmed = line.trim();

        // 新项目开始
        if trimmed.starts_with("- name:") {
            if let Some(p) = current.take() {
                projects.push(p);
            }
            let name = trimmed.trim_start_matches("- name:").trim().to_string();
            current = Some(Project {
                name,
                path: String::new(),
                aliases: vec![],
                description: String::new(),
                running: false,
                git: GitInfo::default(),
            });
        } else if let Some(ref mut p) = current {
            if trimmed.starts_with("path:") {
                p.path = trimmed.trim_start_matches("path:").trim().to_string();
            } else if trimmed.starts_with("description:") {
                p.description = trimmed
                    .trim_start_matches("description:")
                    .trim()
                    .trim_matches('"')
                    .to_string();
            } else if trimmed.starts_with("aliases:") {
                let aliases_str = trimmed.trim_start_matches("aliases:").trim();
                if aliases_str.starts_with('[') && aliases_str.ends_with(']') {
                    p.aliases = aliases_str[1..aliases_str.len() - 1]
                        .split(',')
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty())
                        .collect();
                }
            }
        }
    }

    if let Some(p) = current {
        projects.push(p);
    }

    projects
}

/// 在 tmux hub 中打开项目
pub fn open_in_tmux(name: &str, path: &str, mode: &str) {
    let home = std::env::var("HOME").unwrap_or_default();
    let menu_script = format!("{}/Documents/code/claude-hub/scripts/project-menu.sh", home);

    // 确保 hub session 存在
    let hub_exists = Command::new("tmux")
        .args(["has-session", "-t", "hub"])
        .status()
        .map(|s| s.success())
        .unwrap_or(false);

    if !hub_exists {
        Command::new("tmux")
            .args(["new-session", "-d", "-s", "hub", "-n", "_init"])
            .status()
            .ok();
    }

    let need_cleanup = !hub_exists; // 新建 session 时需要清理 _init

    match mode {
        "claude" => {
            let cmd = format!("cd '{}' && claude", path);
            Command::new("tmux")
                .args(["new-window", "-t", "hub", "-n", name, "-c", path, &cmd])
                .status()
                .ok();
        }
        "claude-skip" => {
            let cmd = format!("cd '{}' && claude --dangerously-skip-permissions", path);
            Command::new("tmux")
                .args(["new-window", "-t", "hub", "-n", name, "-c", path, &cmd])
                .status()
                .ok();
        }
        "terminal" => {
            Command::new("tmux")
                .args(["new-window", "-t", "hub", "-n", name, "-c", path])
                .status()
                .ok();
        }
        "finder" => {
            Command::new("open").arg(path).status().ok();
            return; // 不需要 tmux
        }
        "vscode" => {
            Command::new("code").arg(path).status().ok();
            return; // 不需要 tmux
        }
        "menu" => {
            let cmd = format!("bash '{}' '{}' '{}'", menu_script, name, path);
            Command::new("tmux")
                .args(["new-window", "-t", "hub", "-n", name, "-c", path, &cmd])
                .status()
                .ok();
        }
        _ => return,
    }

    // 清理 _init 窗口（新建 session 时会产生）
    if need_cleanup {
        Command::new("tmux")
            .args(["kill-window", "-t", "hub:_init"])
            .status()
            .ok();
    }

    // 确保 iTerm2 连接到 hub
    ensure_client_attached();
}

fn ensure_client_attached() {
    let has_client = Command::new("tmux")
        .args(["list-clients", "-t", "hub"])
        .output()
        .map(|o| !String::from_utf8_lossy(&o.stdout).trim().is_empty())
        .unwrap_or(false);

    if !has_client {
        Command::new("osascript")
            .args(["-e", r#"
                tell application "iTerm2"
                    tell current window
                        create tab with default profile
                        delay 0.5
                        tell current session of current tab
                            write text "tmux -CC attach -t hub"
                        end tell
                    end tell
                end tell
            "#])
            .status()
            .ok();
    }
}
