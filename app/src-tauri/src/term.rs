// 终端检测与派发：让 tmux server 由用户终端创建，
// claude 进程链祖先就是终端，能复用终端在 macOS Keychain 上的 ACL。
//
// 核心约定：
// - 第一次创建 hub session（new-session）必须由终端跑 → tmux server 父进程是终端
// - 后续 new-window / send-keys 是 client 操作，谁跑都行（不影响进程链）

use serde::Serialize;
use std::path::Path;
use std::process::Command;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum TerminalKind {
    ITerm,
    Warp,
    WezTerm,
    Terminal, // /System/Applications/Utilities/Terminal.app（系统自带，永远可用）
}

impl TerminalKind {
    pub fn supported(self) -> bool {
        matches!(self, TerminalKind::ITerm | TerminalKind::Terminal)
    }
}

#[derive(Serialize)]
pub struct TerminalInfo {
    pub kind: String,
    pub label: String,
    pub path: String,
    pub supported: bool,
}

/// 按优先级查找已安装的终端，跳过未支持的。
/// 优先级：iTerm > Warp > WezTerm > Terminal
pub fn detect() -> TerminalKind {
    let candidates = [
        TerminalKind::ITerm,
        TerminalKind::Warp,
        TerminalKind::WezTerm,
    ];
    for kind in candidates {
        if installed_path(kind).is_some() && kind.supported() {
            return kind;
        }
    }
    TerminalKind::Terminal // 系统自带，永远兜底
}

pub fn detect_info() -> TerminalInfo {
    let kind = detect();
    let path = installed_path(kind).unwrap_or_else(|| match kind {
        TerminalKind::Terminal => "/System/Applications/Utilities/Terminal.app".to_string(),
        _ => String::new(),
    });
    let label = match kind {
        TerminalKind::ITerm => "iTerm.app",
        TerminalKind::Warp => "Warp.app（暂不支持）",
        TerminalKind::WezTerm => "WezTerm.app（暂不支持）",
        TerminalKind::Terminal => "Terminal.app",
    };
    TerminalInfo {
        kind: kind_str(kind).to_string(),
        label: label.to_string(),
        path,
        supported: kind.supported(),
    }
}

fn kind_str(k: TerminalKind) -> &'static str {
    match k {
        TerminalKind::ITerm => "iterm",
        TerminalKind::Warp => "warp",
        TerminalKind::WezTerm => "wezterm",
        TerminalKind::Terminal => "terminal",
    }
}

fn installed_path(kind: TerminalKind) -> Option<String> {
    let bundle = match kind {
        TerminalKind::ITerm => "iTerm.app",
        TerminalKind::Warp => "Warp.app",
        TerminalKind::WezTerm => "WezTerm.app",
        TerminalKind::Terminal => return Some("/System/Applications/Utilities/Terminal.app".into()),
    };
    let home = std::env::var("HOME").unwrap_or_default();
    let candidates = [
        format!("/Applications/{}", bundle),
        format!("{}/Applications/{}", home, bundle),
    ];
    candidates.into_iter().find(|p| Path::new(p).exists())
}

/// 通过当前终端跑一条 shell 命令。命令会被 zsh/bash 解析。
pub fn run_in_terminal(cmd: &str) {
    let kind = detect();
    let escaped = cmd.replace('\\', "\\\\").replace('"', "\\\"");
    let script = match kind {
        TerminalKind::ITerm => format!(
            r#"
            tell application "iTerm2"
                activate
                if (count of windows) = 0 then
                    create window with default profile
                else
                    tell current window
                        create tab with default profile
                    end tell
                end if
                tell current session of current window
                    write text "{}"
                end tell
            end tell
            "#,
            escaped
        ),
        // Warp/WezTerm 暂未实现，fallback 到 Terminal.app
        _ => format!(
            r#"
            tell application "Terminal"
                activate
                do script "{}"
            end tell
            "#,
            escaped
        ),
    };
    let _ = Command::new("osascript").arg("-e").arg(&script).status();
}

/// 第一次创建 hub session（必须由终端跑）+ attach。
/// 这样 tmux server 的父进程是终端，claude 子进程能复用终端的 Keychain ACL。
pub fn create_hub_session(window_name: &str, work_dir: &str, inner_cmd: Option<&str>) {
    let kind = detect();
    let create = if let Some(inner) = inner_cmd {
        format!(
            "tmux new-session -d -s hub -n {} -c {} {}",
            sh_quote(window_name),
            sh_quote(work_dir),
            sh_quote(inner)
        )
    } else {
        format!(
            "tmux new-session -d -s hub -n {} -c {}",
            sh_quote(window_name),
            sh_quote(work_dir)
        )
    };
    let attach = match kind {
        TerminalKind::ITerm => "tmux -CC attach -t hub",
        _ => "tmux attach -t hub",
    };
    run_in_terminal(&format!("{} && {}", create, attach));
}

/// 让终端 attach 到已存在的 hub session
pub fn attach_existing_hub() {
    let kind = detect();
    let cmd = match kind {
        TerminalKind::ITerm => "tmux -CC attach -t hub",
        _ => "tmux attach -t hub",
    };
    run_in_terminal(cmd);
}

/// 单引号包裹做 shell 转义
fn sh_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// 检测当前 hub tmux server 是否由 Claude Hub.app 创建（旧版本遗留）。
/// 返回 true 表示需要提示用户 kill-server 重新由终端创建。
pub fn hub_server_owned_by_app() -> bool {
    // 拿 hub session 客户端列表为空 + server pid 的父进程名是 "claude-hub" 才判定
    // 简单做法：找 tmux server 进程，看它的父进程 name
    let out = match Command::new("/bin/ps")
        .args(["-A", "-o", "pid=,ppid=,command="])
        .output()
    {
        Ok(o) => o,
        Err(_) => return false,
    };
    let text = String::from_utf8_lossy(&out.stdout);
    let mut tmux_ppid: Option<&str> = None;
    for line in text.lines() {
        let trimmed = line.trim_start();
        // 找 tmux server，命令含 "tmux" 且不含 "tmux attach" 等 client 标记
        // 实际 server 进程命令名通常是 "tmux: server" 或 "tmux"
        if (trimmed.contains("tmux: server") || trimmed.contains("tmux new-session"))
            && !trimmed.contains("attach")
        {
            let mut it = trimmed.split_whitespace();
            it.next();
            if let Some(ppid) = it.next() {
                tmux_ppid = Some(ppid);
                break;
            }
        }
    }
    let ppid = match tmux_ppid {
        Some(p) => p,
        None => return false,
    };
    for line in text.lines() {
        let mut it = line.trim_start().split_whitespace();
        if let Some(pid) = it.next() {
            if pid == ppid {
                return line.to_lowercase().contains("claude-hub")
                    || line.contains("Claude Hub.app");
            }
        }
    }
    false
}
