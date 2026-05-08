// 启动时检查 hub 工作所必需的依赖。
// 缺啥直接告诉前端，由 UI 给出明确的安装命令引导，避免静默失败。

use serde::Serialize;
use std::path::Path;
use std::process::Command;

#[derive(Debug, Clone, Serialize)]
pub struct DepStatus {
    pub key: String,
    pub label: String,
    pub installed: bool,
    pub path: Option<String>,
    pub install_cmd: String,
    pub doc_url: Option<String>,
    pub required: bool,
}

pub fn check_all() -> Vec<DepStatus> {
    vec![
        check_command(
            "tmux",
            "tmux",
            "终端复用器（项目窗口管理必需）",
            true,
            "brew install tmux",
            None,
        ),
        check_app(
            "iterm2",
            "iTerm",
            "iTerm2",
            "终端模拟器（tmux -CC 控制模式必需）",
            true,
            "brew install --cask iterm2",
            Some("https://iterm2.com/"),
        ),
        check_command(
            "claude",
            "claude",
            "Claude Code CLI",
            true,
            "npm install -g @anthropic-ai/claude-code",
            Some("https://claude.com/claude-code"),
        ),
        check_command(
            "git",
            "git",
            "项目扫描必需（Apple Silicon 自带，通常不缺）",
            false,
            "xcode-select --install",
            None,
        ),
        check_command(
            "terminal-notifier",
            "terminal-notifier",
            "桌面通知（缺失时降级用 osascript）",
            false,
            "brew install terminal-notifier",
            None,
        ),
    ]
}

fn check_command(
    key: &str,
    cmd: &str,
    label: &str,
    required: bool,
    install_cmd: &str,
    doc_url: Option<&str>,
) -> DepStatus {
    let path = which(cmd);
    let _ = label;
    DepStatus {
        key: key.to_string(),
        label: label.to_string(),
        installed: path.is_some(),
        path,
        install_cmd: install_cmd.to_string(),
        doc_url: doc_url.map(String::from),
        required,
    }
}

fn check_app(
    key: &str,
    app_basename: &str,
    label: &str,
    _desc: &str,
    required: bool,
    install_cmd: &str,
    doc_url: Option<&str>,
) -> DepStatus {
    // 优先在 /Applications，再看 ~/Applications
    let candidates = [
        format!("/Applications/{}.app", app_basename),
        format!(
            "{}/Applications/{}.app",
            std::env::var("HOME").unwrap_or_default(),
            app_basename
        ),
    ];
    let path = candidates.into_iter().find(|p| Path::new(p).exists());
    DepStatus {
        key: key.to_string(),
        label: label.to_string(),
        installed: path.is_some(),
        path,
        install_cmd: install_cmd.to_string(),
        doc_url: doc_url.map(String::from),
        required,
    }
}

fn which(cmd: &str) -> Option<String> {
    let out = Command::new("/usr/bin/which").arg(cmd).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if s.is_empty() { None } else { Some(s) }
}
