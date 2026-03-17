---
name: browser-auto
description: "Use when operating a browser: opening web pages, clicking UI elements, filling forms, checking design specs, testing frontend, debugging APIs. Coordinates two browser engines - Claude in Chrome (visual) and chrome-devtools-mcp (data/CDP)."
---

# 浏览器双引擎协同

## ⚠️ 铁律（必须遵守）

1. **永远不要启动新的 Chrome 浏览器**。所有操作必须在用户日常使用的 Chrome 上进行。
2. **两个引擎必须连同一个 Chrome**。如果不在同一个浏览器，"保姆"机制失效、扩展不存在、登录态丢失。
3. **禁用** `mcp__browsermcp__*` 和 `mcp__puppeteer__*`，它们会启动独立 Chrome 实例。

### 为什么？

chrome-devtools-mcp 默认行为是启动一个独立的 Chrome 实例（`--user-data-dir=~/.cache/chrome-devtools-mcp/chrome-profile`）。这个独立 Chrome：
- ❌ 没有 Claude in Chrome 扩展
- ❌ 没有用户的登录态（Shopify、蓝湖等）
- ❌ 没有用户的书签和设置
- ❌ 和 Claude in Chrome 不在同一个浏览器，无法协同

### 正确的连接方式

chrome-devtools-mcp 必须通过 `--connect-url` 连接用户日常 Chrome 的调试端口：

**MCP 配置（.mcp.json）：**
```json
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": [
        "chrome-devtools-mcp@latest",
        "--connect-url=http://localhost:9222"
      ]
    }
  }
}
```

**用户的 Chrome 需要开启调试端口（一次性配置）：**

macOS - 修改 Chrome 启动方式：
```bash
# 创建启动脚本
cat > ~/chrome-debug.sh << 'EOF'
#!/bin/bash
open -a "Google Chrome" --args --remote-debugging-port=9222
EOF
chmod +x ~/chrome-debug.sh
```

或者直接改 Chrome 的启动参数（推荐，永久生效）：
```bash
# macOS: 修改 Chrome 的 Info.plist 或用 alias
alias chrome='open -a "Google Chrome" --args --remote-debugging-port=9222'
```

### 新项目自动配置（首次使用时必须执行）

当 AI 在一个项目中首次使用浏览器功能时，**先检查再操作，不要问用户**：

**Step 1: 检查 .mcp.json**
```bash
# 如果项目下没有 .mcp.json 或没有 chrome-devtools 配置，直接创建/补充
cat .mcp.json 2>/dev/null | grep -q "connect-url" || echo "需要配置"
```

如果没有配置，**直接写入**（不要问用户）：
```json
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": [
        "chrome-devtools-mcp@latest",
        "--connect-url=http://localhost:9222"
      ]
    }
  }
}
```

如果已有 .mcp.json 但缺少 chrome-devtools，追加到 mcpServers 里。

**Step 2: 检查 Chrome 调试端口**
```bash
curl -s http://localhost:9222/json/version && echo "✅ OK" || echo "❌ 需要重启 Chrome"
```

端口不通 → 告诉用户：请关闭 Chrome，用以下方式重启：
```bash
open -a "Google Chrome" --args --remote-debugging-port=9222
```

**Step 3: 告知用户**需要重启当前 Claude Code 会话以加载新的 MCP 配置。

---

## 角色分工

| 角色 | 引擎 | 用途 |
|------|------|------|
| **眼睛 + 手** | Claude in Chrome (`mcp__claude-in-chrome__*`) | 视觉理解、精准点击、看 UI 效果 |
| **大脑 + 数据** | chrome-devtools-mcp (`mcp__chrome-devtools__*`) | DOM 树、网络请求、控制台、执行 JS、性能 |
| **保姆** | chrome-devtools-mcp | Claude in Chrome 断开时自动重启扩展 |

两个引擎连接**同一个 Chrome 浏览器**（用户日常使用的那个），操作**同一个页面**。

## 启动流程

### Step 1: 检测环境

```
1. curl http://localhost:9222/json/version → Chrome 调试端口是否可用
2. mcp__claude-in-chrome__tabs_context_mcp → 视觉引擎状态
3. mcp__chrome-devtools__list_pages → 数据引擎状态
```

| Chrome 调试端口 | 视觉引擎 | 数据引擎 | 策略 |
|----------------|----------|----------|------|
| 不可用 | - | - | 停止，提示用户用 `--remote-debugging-port=9222` 重启 Chrome |
| 可用 | 可用 | 可用 | 双引擎协同（最佳） |
| 可用 | 不可用 | 可用 | 先自动修复视觉引擎，修复后双引擎协同 |
| 可用 | 可用 | 不可用 | 仅视觉引擎，检查 .mcp.json 中 chrome-devtools 配置 |

### Step 2: 自动修复 Claude in Chrome

当 Claude in Chrome 连接失败时，用 chrome-devtools-mcp 自动重启扩展：

```
1. mcp__chrome-devtools__navigate_page → chrome://extensions/
2. mcp__chrome-devtools__evaluate_script:

() => {
  const mgr = document.querySelector('extensions-manager');
  const list = mgr.shadowRoot.querySelector('extensions-item-list');
  const items = list.shadowRoot.querySelectorAll('extensions-item');
  for (const item of items) {
    if (item.id === 'fcoeoabgfenejglbffodgkkbkcdhcgfn') {
      const toggle = item.shadowRoot.querySelector('#enableToggle');
      toggle.click(); // 关闭
      return 'disabled';
    }
  }
}

3. 等待 1 秒
4. 再次执行上面的脚本（toggle.click() 重新开启）
5. 等待 3 秒
6. 重试 mcp__claude-in-chrome__tabs_context_mcp
```

## 场景路由

### 设计稿查看（蓝湖/Figma）
**主：Claude in Chrome**
- `computer` screenshot → 看设计稿全貌
- `computer` left_click → 点击图层元素
- `computer` scroll → 滚动查看
- 右侧面板自动显示尺寸/字体/颜色

### 前端开发验收
**双引擎协同**
1. `[devtools] navigate_page` → 打开页面
2. `[devtools] take_snapshot` → 获取 DOM 结构
3. `[chrome] computer screenshot` → 视觉检查 UI 效果
4. `[devtools] list_console_messages` → 检查有无报错
5. `[devtools] list_network_requests` → 检查 API 调用
6. 综合视觉 + 数据给出验收报告

### 表单测试
**主：chrome-devtools-mcp，辅：Claude in Chrome**
1. `[devtools] take_snapshot` → 获取表单元素 uid
2. `[devtools] fill_form` → 批量填写（比视觉点击快）
3. `[devtools] click` → 点击提交按钮
4. `[devtools] get_network_request` → 检查 API 请求/响应
5. `[chrome] computer screenshot` → 截图看结果展示

### API 调试
**仅 chrome-devtools-mcp**
- `list_network_requests` → 查看所有请求
- `get_network_request` → 获取请求/响应详情（含 body）
- `list_console_messages` → 查看控制台输出

### 性能分析
**仅 chrome-devtools-mcp**
- `lighthouse_audit` → Lighthouse 审计
- `performance_start_trace` / `performance_stop_trace` → 性能追踪
- `take_memory_snapshot` → 内存分析

### 复杂 UI 交互（拖拽、hover、右键菜单）
**主：Claude in Chrome**
- `computer` hover → 触发 hover 效果
- `computer` right_click → 右键菜单
- `computer` left_click_drag → 拖拽操作
- `computer` double_click → 双击进入编辑

## 工具对照表

| 操作 | Claude in Chrome | chrome-devtools-mcp |
|------|-----------------|---------------------|
| 导航 | `navigate` | `navigate_page` |
| 截图 | `computer` screenshot | `take_screenshot` |
| 读页面 | `read_page` | `take_snapshot`（更省 token） |
| 点击 | `computer` left_click (坐标) | `click` (uid，更精准) |
| 填表 | `form_input` | `fill` / `fill_form`（支持批量） |
| 执行 JS | `javascript_tool` | `evaluate_script` |
| 网络请求 | `read_network_requests` | `list_network_requests` + `get_network_request` |
| 控制台 | `read_console_messages` | `list_console_messages` |
| 滚动 | `computer` scroll | `evaluate_script` + `scrollBy()` |
| hover | `computer` hover | `hover` (uid) |

## 选择引擎的原则

**用 Claude in Chrome 当：**
- 需要"看"页面效果（截图、视觉对比）
- 点击位置不确定（没有明确的 CSS selector / uid）
- 操作设计工具（蓝湖、Figma 等图层交互）
- 需要拖拽、hover 等复杂鼠标操作

**用 chrome-devtools-mcp 当：**
- 需要快速读取页面结构（snapshot 比截图省 token）
- 批量表单填写（fill_form 一次填多个字段）
- 需要查看网络请求/响应内容
- 需要检查控制台错误
- 需要执行复杂 JS 逻辑
- 做性能分析/Lighthouse 审计

**两个一起用当：**
- 前端开发验收（视觉 + 数据双重验证）
- 复杂测试场景（devtools 填数据 → chrome 验证 UI）
- 调试页面问题（chrome 看现象 → devtools 查原因）

## 注意事项

- 两个引擎连接同一个 Chrome 浏览器，操作的是同一个页面
- 在一个引擎导航后，另一个引擎看到的也是新页面
- `take_snapshot` 返回文本格式的 DOM 树（带 uid），比截图省 token，优先使用
- 滚动内部容器时，chrome-devtools 需要用 JS：`document.querySelector('.容器').scrollBy(0, 500)`
- Claude in Chrome 的权限确认弹窗需要用户手动点击，AI 无法自动处理
