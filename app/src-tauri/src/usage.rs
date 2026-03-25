// 扫描 ~/.claude/projects/ 下的会话 JSONL，按项目统计 token 使用量

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize)]
pub struct ModelUsage {
    pub model: String,
    pub display_name: String,
    pub message_count: u32,
    pub output_tokens: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct ProjectUsage {
    pub name: String,
    pub path: String,
    pub session_count: u32,
    pub message_count: u32,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_create_tokens: u64,
    pub last_active: String,
    pub models: Vec<ModelUsage>,
}

#[derive(Debug, Clone, Serialize)]
pub struct UsageStats {
    pub projects: Vec<ProjectUsage>,
    pub total_sessions: u32,
    pub total_messages: u32,
    pub total_input_tokens: u64,
    pub total_output_tokens: u64,
}

#[derive(Deserialize)]
struct JLine {
    #[serde(rename = "type")]
    line_type: Option<String>,
    message: Option<JMessage>,
    timestamp: Option<String>,
}

#[derive(Deserialize)]
struct JMessage {
    model: Option<String>,
    usage: Option<JUsage>,
}

#[derive(Deserialize)]
struct JUsage {
    input_tokens: Option<u64>,
    output_tokens: Option<u64>,
    cache_read_input_tokens: Option<u64>,
    cache_creation_input_tokens: Option<u64>,
}

/// 从 projects.yaml 构建路径 → 项目名的映射
fn build_path_map() -> HashMap<String, String> {
    let home = std::env::var("HOME").unwrap_or_default();
    let yaml_path = format!("{}/Documents/code/claude-hub/projects.yaml", home);
    let content = match fs::read_to_string(&yaml_path) {
        Ok(c) => c,
        Err(_) => return HashMap::new(),
    };

    let mut map = HashMap::new();
    let mut current_name = String::new();

    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("- name:") {
            current_name = trimmed.trim_start_matches("- name:").trim().to_string();
        } else if trimmed.starts_with("path:") && !current_name.is_empty() {
            let mut path = trimmed.trim_start_matches("path:").trim().to_string();
            if path.starts_with("~/") {
                path = format!("{}/{}", home, &path[2..]);
            }
            // 编码路径：/Users/dev/Documents/code/xxx → -Users-dev-Documents-code-xxx
            let encoded = path.replace('/', "-");
            // 去掉开头的 -
            let encoded = encoded.trim_start_matches('-').to_string();
            map.insert(encoded, current_name.clone());
        }
    }

    map
}

/// 将目录名解码为可读路径
fn decode_dir_name(dir_name: &str) -> String {
    format!("/{}", dir_name.replace('-', "/"))
}

/// 计算截止日期
fn cutoff_date(range: &str) -> Option<String> {
    let now = chrono::Utc::now();
    let days = match range {
        "7d" => 7,
        "30d" => 30,
        _ => return None,
    };
    let cutoff = now - chrono::Duration::days(days);
    Some(cutoff.format("%Y-%m-%dT%H:%M:%S").to_string())
}

/// 将模型 ID 转为人类可读名称
fn format_model_name(model_id: &str) -> String {
    match model_id {
        s if s.starts_with("claude-opus-4-6") => "Opus 4.6".to_string(),
        s if s.starts_with("claude-opus-4-5") => "Opus 4.5".to_string(),
        s if s.starts_with("claude-sonnet-4-6") => "Sonnet 4.6".to_string(),
        s if s.starts_with("claude-sonnet-4-5") => "Sonnet 4.5".to_string(),
        s if s.starts_with("claude-haiku-4-5") => "Haiku 4.5".to_string(),
        s if s.starts_with("claude-3-5-sonnet") => "Sonnet 3.5".to_string(),
        s if s.starts_with("claude-3-5-haiku") => "Haiku 3.5".to_string(),
        s if s.starts_with("claude-3-opus") => "Opus 3".to_string(),
        _ => model_id.to_string(),
    }
}

pub fn compute_usage(range: &str) -> UsageStats {
    let home = std::env::var("HOME").unwrap_or_default();
    let projects_dir = PathBuf::from(&home).join(".claude").join("projects");
    let path_map = build_path_map();
    let cutoff = cutoff_date(range);

    let mut project_usages: HashMap<String, ProjectUsage> = HashMap::new();
    // 按项目 → 模型 → (message_count, output_tokens) 聚合
    let mut project_models: HashMap<String, HashMap<String, (u32, u64)>> = HashMap::new();

    let entries = match fs::read_dir(&projects_dir) {
        Ok(e) => e,
        Err(_) => {
            return UsageStats {
                projects: vec![],
                total_sessions: 0,
                total_messages: 0,
                total_input_tokens: 0,
                total_output_tokens: 0,
            }
        }
    };

    for entry in entries.flatten() {
        let entry_path = entry.path();
        if !entry_path.is_dir() {
            continue;
        }

        let dir_name = entry.file_name().to_string_lossy().to_string();

        // 匹配项目名
        let project_name = path_map
            .get(&dir_name)
            .cloned()
            .unwrap_or_else(|| {
                // 尝试从目录名提取最后一段作为项目名
                dir_name.rsplit('-').next().unwrap_or(&dir_name).to_string()
            });

        let decoded_path = decode_dir_name(&dir_name);

        // 扫描 JSONL 文件
        let jsonl_files: Vec<PathBuf> = match fs::read_dir(&entry_path) {
            Ok(entries) => entries
                .flatten()
                .filter(|e| {
                    e.path()
                        .extension()
                        .is_some_and(|ext| ext == "jsonl")
                })
                .map(|e| e.path())
                .collect(),
            Err(_) => continue,
        };

        if jsonl_files.is_empty() {
            continue;
        }

        let usage = project_usages.entry(dir_name.clone()).or_insert(ProjectUsage {
            name: project_name,
            path: decoded_path,
            session_count: 0,
            message_count: 0,
            input_tokens: 0,
            output_tokens: 0,
            cache_read_tokens: 0,
            cache_create_tokens: 0,
            last_active: String::new(),
            models: vec![],
        });

        let models = project_models.entry(dir_name.clone()).or_default();

        for jsonl_path in &jsonl_files {
            let file = match fs::File::open(jsonl_path) {
                Ok(f) => f,
                Err(_) => continue,
            };

            let mut session_has_data = false;
            let reader = BufReader::new(file);

            for line in reader.lines() {
                let line = match line {
                    Ok(l) => l,
                    Err(_) => continue,
                };

                // 快速过滤：只解析包含 "type":"assistant" 的行
                if !line.contains("\"type\":\"assistant\"") {
                    continue;
                }

                let parsed: JLine = match serde_json::from_str(&line) {
                    Ok(p) => p,
                    Err(_) => continue,
                };

                if parsed.line_type.as_deref() != Some("assistant") {
                    continue;
                }

                // 时间范围过滤
                if let Some(ref cutoff_str) = cutoff {
                    if let Some(ref ts) = parsed.timestamp {
                        if ts.as_str() < cutoff_str.as_str() {
                            continue;
                        }
                    }
                }

                if let Some(msg) = parsed.message {
                    if let Some(u) = msg.usage {
                        session_has_data = true;
                        usage.message_count += 1;
                        let out_tokens = u.output_tokens.unwrap_or(0);
                        usage.input_tokens += u.input_tokens.unwrap_or(0);
                        usage.output_tokens += out_tokens;
                        usage.cache_read_tokens += u.cache_read_input_tokens.unwrap_or(0);
                        usage.cache_create_tokens += u.cache_creation_input_tokens.unwrap_or(0);

                        // 按模型聚合
                        if let Some(ref model_id) = msg.model {
                            let entry = models.entry(model_id.clone()).or_insert((0, 0));
                            entry.0 += 1;
                            entry.1 += out_tokens;
                        }

                        // 更新最后活跃时间
                        if let Some(ref ts) = parsed.timestamp {
                            if ts.as_str() > usage.last_active.as_str() {
                                usage.last_active = ts.clone();
                            }
                        }
                    }
                }
            }

            if session_has_data {
                usage.session_count += 1;
            }
        }
    }

    // 将模型数据填入项目
    for (dir_name, model_map) in &project_models {
        if let Some(usage) = project_usages.get_mut(dir_name) {
            let mut model_list: Vec<ModelUsage> = model_map
                .iter()
                .map(|(model_id, (count, tokens))| ModelUsage {
                    model: model_id.clone(),
                    display_name: format_model_name(model_id),
                    message_count: *count,
                    output_tokens: *tokens,
                })
                .collect();
            // 按 output_tokens 降序
            model_list.sort_by(|a, b| b.output_tokens.cmp(&a.output_tokens));
            usage.models = model_list;
        }
    }

    // 收集并排序（按 output_tokens 降序）
    let mut projects: Vec<ProjectUsage> = project_usages
        .into_values()
        .filter(|p| p.message_count > 0)
        .collect();
    projects.sort_by(|a, b| b.output_tokens.cmp(&a.output_tokens));

    let total_sessions = projects.iter().map(|p| p.session_count).sum();
    let total_messages = projects.iter().map(|p| p.message_count).sum();
    let total_input_tokens = projects.iter().map(|p| p.input_tokens).sum();
    let total_output_tokens = projects.iter().map(|p| p.output_tokens).sum();

    UsageStats {
        projects,
        total_sessions,
        total_messages,
        total_input_tokens,
        total_output_tokens,
    }
}
