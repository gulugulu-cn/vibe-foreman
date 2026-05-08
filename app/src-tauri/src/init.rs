// 启动时自动初始化用户数据目录：
// ~/Library/Application Support/claude-hub/
//   ├── scripts/    ← 从 .app Resources 同步过来（每次启动覆盖，保证升级）
//   ├── sounds/     ← 同上
//   └── projects.yaml  ← 首次启动创建空模板
//
// 这样 .app 是真正独立可分发的：装上就能用，不依赖项目仓库存在。

use std::fs;
use std::path::{Path, PathBuf};
use tauri::{AppHandle, Manager};

const YAML_TEMPLATE: &str = "# Claude Hub 项目清单\n\
# 用 UI 上的「扫描」按钮自动发现项目，或手动添加。\n\
\n\
scan_dirs:\n\
  - ~/Documents/code\n\
\n\
projects: []\n";

/// 用户数据目录：~/Library/Application Support/claude-hub
pub fn app_data_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_default();
    PathBuf::from(home).join("Library/Application Support/claude-hub")
}

/// projects.yaml 路径
pub fn yaml_path() -> PathBuf {
    app_data_dir().join("projects.yaml")
}

/// 用户目录里的 scripts 路径（.app 启动时同步过来）
pub fn scripts_dir() -> PathBuf {
    app_data_dir().join("scripts")
}

/// macOS GUI app（双击 .app）从 launchd 拿到的 PATH 只有 /usr/bin:/bin:/usr/sbin:/sbin，
/// 不含 brew、也不含用户级运行时（bun/npm/cargo 等装的工具），
/// 导致 Command::new("tmux"/"claude") 静默失败。这里启动时主动扩展，
/// 优先尝试继承用户 shell 的真实 PATH（拿到 .bun/bin 等用户自定义位置），
/// 失败再 fallback 到常见标准路径列表。
pub fn ensure_path() {
    if inherit_login_shell_path() {
        return;
    }
    fallback_extend_path();
}

/// 通过跑一次 user shell 拿真实 PATH（含 ~/.bun/bin、~/.cargo/bin 等用户配置）
fn inherit_login_shell_path() -> bool {
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string());
    // -l 加载 ~/.zprofile，-i 加载 ~/.zshrc，覆盖大多数用户自定义 PATH 的写法
    let output = match std::process::Command::new(&shell)
        .args(["-l", "-i", "-c", "echo -n $PATH"])
        .output()
    {
        Ok(o) if o.status.success() => o,
        _ => return false,
    };
    let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
    // 起码得有 4 段且包含一个常见 bin 目录才算成功，否则就 fallback
    if path.split(':').count() < 4 {
        return false;
    }
    std::env::set_var("PATH", path);
    true
}

/// fallback：把 brew + 常见用户级 bin 加进 PATH（只加实际存在的目录）
fn fallback_extend_path() {
    let home = std::env::var("HOME").unwrap_or_default();
    let candidates: Vec<String> = vec![
        // 用户级运行时
        format!("{}/.bun/bin", home),
        format!("{}/.cargo/bin", home),
        format!("{}/.local/bin", home),
        format!("{}/.deno/bin", home),
        format!("{}/.volta/bin", home),
        format!("{}/.npm-global/bin", home),
        format!("{}/bin", home),
        // 系统级
        "/opt/homebrew/bin".to_string(),
        "/opt/homebrew/sbin".to_string(),
        "/usr/local/bin".to_string(),
        "/usr/local/sbin".to_string(),
    ];
    let extras: Vec<String> = candidates
        .into_iter()
        .filter(|p| std::path::Path::new(p).exists())
        .collect();

    let current = std::env::var("PATH").unwrap_or_default();
    let parts: Vec<&str> = current.split(':').collect();
    let to_add: Vec<&str> = extras
        .iter()
        .map(|s| s.as_str())
        .filter(|p| !parts.contains(p))
        .collect();
    if !to_add.is_empty() {
        let new_path = if current.is_empty() {
            to_add.join(":")
        } else {
            format!("{}:{}", to_add.join(":"), current)
        };
        std::env::set_var("PATH", new_path);
    }
}

/// 启动时调用：扩展 PATH + 创建目录 + 同步嵌入的 scripts/sounds + 确保 yaml 存在
pub fn run(app: &AppHandle) {
    ensure_path();

    let data = app_data_dir();
    if let Err(e) = fs::create_dir_all(&data) {
        eprintln!("init: 创建数据目录失败: {}", e);
        return;
    }

    // 把 .app/Contents/Resources/scripts 和 sounds 同步到用户目录
    if let Ok(resource_dir) = app.path().resource_dir() {
        sync_dir(&resource_dir.join("scripts"), &data.join("scripts"), true);
        sync_dir(&resource_dir.join("sounds"), &data.join("sounds"), false);
    }

    // 首次创建 projects.yaml（已存在则保留用户内容）
    let yaml = data.join("projects.yaml");
    if !yaml.exists() {
        let _ = fs::write(&yaml, YAML_TEMPLATE);
    }
}

/// 复制 src 下所有文件到 dst（覆盖），可选 chmod +x 让脚本可执行
fn sync_dir(src: &Path, dst: &Path, executable: bool) {
    if !src.is_dir() {
        return;
    }
    if let Err(e) = fs::create_dir_all(dst) {
        eprintln!("init: 创建 {:?} 失败: {}", dst, e);
        return;
    }
    let entries = match fs::read_dir(src) {
        Ok(e) => e,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        let from = entry.path();
        let to = dst.join(entry.file_name());
        if from.is_dir() {
            sync_dir(&from, &to, executable);
            continue;
        }
        if fs::copy(&from, &to).is_ok() && executable {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                if let Ok(meta) = fs::metadata(&to) {
                    let mut perm = meta.permissions();
                    perm.set_mode(0o755);
                    let _ = fs::set_permissions(&to, perm);
                }
            }
        }
    }
}
