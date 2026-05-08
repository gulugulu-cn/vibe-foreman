// 读取 projects.yaml + 检查 tmux 窗口状态

use crate::init;
use serde::Serialize;
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
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
    let yaml_path = init::yaml_path();
    let home = std::env::var("HOME").unwrap_or_default();

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
    use crate::term;

    // finder / vscode：不需要 tmux
    if mode == "finder" {
        Command::new("open").arg(path).status().ok();
        return;
    }
    if mode == "vscode" {
        Command::new("code").arg(path).status().ok();
        return;
    }

    let scripts_dir = init::scripts_dir();
    let menu_script = scripts_dir
        .join("project-menu.sh")
        .to_string_lossy()
        .to_string();

    // 拼接要在 tmux window 内执行的命令（None = 不跑命令，只开 shell）
    let inner_cmd: Option<String> = match mode {
        "claude" => Some(format!("cd '{}' && claude", path)),
        "claude-skip" => Some(format!(
            "cd '{}' && claude --dangerously-skip-permissions",
            path
        )),
        "terminal" => None,
        "menu" => Some(format!("bash '{}' '{}' '{}'", menu_script, name, path)),
        _ => return,
    };

    let hub_exists = Command::new("tmux")
        .args(["has-session", "-t", "hub"])
        .status()
        .map(|s| s.success())
        .unwrap_or(false);

    if !hub_exists {
        // 关键：第一次创建 hub session 必须由终端跑，
        // 这样 tmux server 父进程是终端，claude 子进程能复用终端的 Keychain ACL。
        term::create_hub_session(name, path, inner_cmd.as_deref());
        return;
    }

    // session 已存在 → client 操作（.app 直接跑），不影响 server 进程链
    let mut args: Vec<&str> = vec!["new-window", "-t", "hub", "-n", name, "-c", path];
    let cmd_owned;
    if let Some(c) = inner_cmd {
        cmd_owned = c;
        args.push(&cmd_owned);
    }
    Command::new("tmux").args(&args).status().ok();

    // 终端是否已连到 hub？没连就让终端 attach
    let has_client = Command::new("tmux")
        .args(["list-clients", "-t", "hub"])
        .output()
        .map(|o| !String::from_utf8_lossy(&o.stdout).trim().is_empty())
        .unwrap_or(false);
    if !has_client {
        term::attach_existing_hub();
    }
}

/// 扫描指定目录下的 git 仓库，把没出现在 yaml 里的项目追加进去
/// base 为 None 时默认 ~/Documents/code
pub fn scan_and_save(base: Option<String>) -> Result<usize, String> {
    let home = std::env::var("HOME").unwrap_or_default();
    let base_dir = base
        .map(|s| {
            if s.starts_with("~/") {
                format!("{}/{}", home, &s[2..])
            } else {
                s
            }
        })
        .unwrap_or_else(|| format!("{}/Documents/code", home));

    let mut found: Vec<(String, String)> = Vec::new();
    walk_for_git(&PathBuf::from(&base_dir), 0, &mut found);

    let yaml_path = init::yaml_path();
    let existing = fs::read_to_string(&yaml_path).unwrap_or_default();

    // 收集已有项目的 path，避免重复添加
    let mut existing_paths: HashSet<String> = HashSet::new();
    for line in existing.lines() {
        let t = line.trim_start();
        if let Some(rest) = t.strip_prefix("path:") {
            existing_paths.insert(rest.trim().to_string());
        }
    }

    let mut added = 0;
    let mut additions = String::new();
    for (name, path) in &found {
        if existing_paths.contains(path) {
            continue;
        }
        additions.push_str(&format!(
            "\n  - name: {}\n    aliases: []\n    path: {}\n    description: \"\"\n    tags: []\n",
            name, path
        ));
        added += 1;
    }

    if added > 0 {
        let mut content = if existing.trim().is_empty() {
            "# Claude Hub 项目清单\n\nprojects:\n".to_string()
        } else if !existing.contains("projects:") {
            format!("{}\nprojects:\n", existing.trim_end())
        } else {
            existing
        };
        content.push_str(&additions);
        fs::write(&yaml_path, content).map_err(|e| e.to_string())?;
    }

    Ok(added)
}

fn walk_for_git(dir: &Path, depth: u8, out: &mut Vec<(String, String)>) {
    if depth > 3 || !dir.is_dir() {
        return;
    }
    if dir.join(".git").exists() {
        if let Some(name) = dir.file_name().and_then(|n| n.to_str()) {
            out.push((name.to_string(), dir.to_string_lossy().to_string()));
        }
        return;
    }
    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        let p = entry.path();
        if !p.is_dir() {
            continue;
        }
        let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
        if name.starts_with('.')
            || matches!(name, "node_modules" | "target" | "dist" | "build" | "vendor")
        {
            continue;
        }
        walk_for_git(&p, depth + 1, out);
    }
}

