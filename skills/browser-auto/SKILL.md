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

---

## 环境诊断（每次会话首次浏览器操作时必须执行）

AI 在执行任何浏览器操作前，**必须按顺序完成以下 4 步检查**。如果某步失败，修复后再继续。

### Step 1: 检查 chrome-devtools-mcp 是否全局可用

```bash
claude mcp get chrome-devtools 2>/dev/null
```

| 结果 | 处理 |
|------|------|
| 未配置 | 执行下方"自动配置"命令 |
| Local scope | 建议升级为 User scope（全局生效） |
| User scope + `--autoConnect` | ✅ 正确，继续 |
| 使用了默认参数（无 --autoConnect 或 --browserUrl） | ❌ 会启动独立 Chrome，需要修复 |

**自动配置命令（User scope，全局生效）：**
```bash
claude mcp add chrome-devtools --scope user -s stdio -- npx chrome-devtools-mcp@latest --autoConnect
```

> 配置完成后需要提示用户**重启 Claude Code 会话**才能生效。

### Step 2: 检查 Chrome remote debugging 是否可达

调用 `mcp__chrome-devtools__list_pages`。

| 结果 | 处理 |
|------|------|
| 成功返回页面列表 | ✅ 继续 |
| 失败/超时 | 引导用户操作（见下方） |

**引导用户开启 Chrome remote debugging（一次性操作）：**

方式一（推荐，Chrome 144+，支持 `--autoConnect`）：
1. 打开 Chrome 浏览器
2. 地址栏输入 `chrome://inspect/#remote-debugging`
3. 点击 "Enable" 开关
4. 完成！这个设置是持久的，Chrome 重启后依然生效

方式二（备选，手动指定端口）：
```bash
# macOS: 用调试端口启动 Chrome
open -a "Google Chrome" --args --remote-debugging-port=9222
```
如果用方式二，MCP 配置应改为：
```bash
claude mcp add chrome-devtools --scope user -s stdio -- npx chrome-devtools-mcp@latest --browserUrl http://localhost:9222
```

### Step 3: 检查 Claude in Chrome 是否可用

调用 `mcp__claude-in-chrome__tabs_context_mcp`。

| 结果 | 处理 |
|------|------|
| 成功返回标签页列表 | ✅ 继续 |
| 失败 | 执行自动修复（Step 3a） |

#### Step 3a: 自动修复 Claude in Chrome

用 chrome-devtools-mcp 重启扩展：

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

如果修复失败，提示用户：
- 确认已安装 Claude in Chrome 扩展
- 在 Chrome 扩展页面手动启用扩展
- 检查扩展是否需要更新

### Step 4: 验证双引擎同源

分别调用两个引擎获取标签页：
- `mcp__chrome-devtools__list_pages`
- `mcp__claude-in-chrome__tabs_context_mcp`

比对返回的标签页 URL，确认两者看到的是**同一个 Chrome 浏览器**。如果不一致，说明 chrome-devtools-mcp 连到了独立 Chrome，需要回到 Step 1 检查配置。

**诊断全部通过后，报告状态：**
```
浏览器双引擎就绪
  数据引擎 (chrome-devtools): ✅ 已连接
  视觉引擎 (Claude in Chrome): ✅ 已连接
  同源验证: ✅ 连接同一个 Chrome
```

---

## 角色分工

| 角色 | 引擎 | 用途 |
|------|------|------|
| **眼睛 + 手** | Claude in Chrome (`mcp__claude-in-chrome__*`) | 视觉理解、精准点击、看 UI 效果 |
| **大脑 + 数据** | chrome-devtools-mcp (`mcp__chrome-devtools__*`) | DOM 树、网络请求、控制台、执行 JS、性能 |
| **保姆** | chrome-devtools-mcp | Claude in Chrome 断开时自动重启扩展 |

两个引擎连接**同一个 Chrome 浏览器**（用户日常使用的那个），操作**同一个页面**。

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

## 故障排除

| 问题 | 原因 | 解决 |
|------|------|------|
| chrome-devtools 连到了独立 Chrome | 没有用 `--autoConnect` 或 `--browserUrl` | 重新配置：`claude mcp add chrome-devtools --scope user -s stdio -- npx chrome-devtools-mcp@latest --autoConnect` |
| `--autoConnect` 失败 | Chrome 没开 remote debugging | 访问 `chrome://inspect/#remote-debugging` 点 Enable |
| Chrome 版本不支持 `--autoConnect` | Chrome < 144 | 更新 Chrome，或改用 `--browserUrl http://localhost:9222` + 手动启动调试端口 |
| Claude in Chrome 反复断开 | 扩展崩溃或更新 | 执行 Step 3a 自动修复，或手动在 Chrome 扩展页重新启用 |
| 两个引擎看到不同的标签页 | 连的不是同一个 Chrome | 检查 `claude mcp get chrome-devtools`，确认用了 `--autoConnect` |
| `list_pages` 返回空 | Chrome 没有打开任何页面 | 正常现象，先用 `navigate_page` 打开一个页面 |
