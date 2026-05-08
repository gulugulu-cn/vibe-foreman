// Claude Hub 状态面板

const { listen } = window.__TAURI__.event;
const { invoke } = window.__TAURI__.core;

const state = {
  projects: [],
  events: [],
  menuTarget: null, // 当前弹出菜单的项目
  searchQuery: '',
  currentTab: 'projects',
  usageRange: 'all',
  usageData: null,
};

async function init() {
  // 监听 Rust 后端事件
  await listen('hub-event', (event) => {
    handleEvent(event.payload);
  });

  // 启动时跑一次依赖检查
  refreshDeps();

  // 加载项目列表
  await refreshProjects();

  // 加载历史事件
  try {
    const history = await invoke('get_events');
    history.forEach(handleEvent);
  } catch (e) {}

  // 每 5 秒刷新项目状态
  setInterval(refreshProjects, 5000);

  // 搜索框
  const searchInput = document.getElementById('searchInput');
  searchInput.addEventListener('input', (e) => {
    state.searchQuery = e.target.value.toLowerCase();
    renderProjects();
  });

  // 点击空白处关闭菜单
  document.addEventListener('click', (e) => {
    if (!e.target.closest('.context-menu') && !e.target.closest('.project-item')) {
      closeMenu();
    }
  });
}

async function refreshProjects() {
  try {
    state.projects = await invoke('get_projects');
    if (state.currentTab === 'projects') {
      renderProjects();
    }
    updateGlobalStatus();
  } catch (e) {}
}

function handleEvent(data) {
  // 更新对应项目的最新状态
  const proj = state.projects.find(p => p.name === data.project);
  if (proj) {
    proj.lastEvent = data;
  }

  state.events.unshift(data);
  if (state.events.length > 20) state.events.pop();

  renderProjects();
  renderEvents();
  updateGlobalStatus();
}

// Tab 切换
function switchTab(tab) {
  state.currentTab = tab;
  document.querySelectorAll('.tab').forEach(t => {
    t.classList.toggle('active', t.dataset.tab === tab);
  });
  document.getElementById('projectsView').style.display = tab === 'projects' ? '' : 'none';
  document.getElementById('usageView').style.display = tab === 'usage' ? '' : 'none';

  if (tab === 'usage' && !state.usageData) {
    loadUsage(state.usageRange);
  }
}

// 加载用量数据
async function loadUsage(range) {
  state.usageRange = range;

  // 更新按钮状态
  document.querySelectorAll('.range-btn').forEach(btn => {
    btn.classList.toggle('active', btn.dataset.range === range);
  });

  document.getElementById('usageList').innerHTML = '<div class="empty">统计中...</div>';

  try {
    state.usageData = await invoke('get_usage_stats', { range });
    renderUsage();
  } catch (e) {
    document.getElementById('usageList').innerHTML = '<div class="empty">加载失败</div>';
  }
}

function renderUsage() {
  const data = state.usageData;
  if (!data) return;

  // 汇总
  const summary = document.getElementById('usageSummary');
  summary.innerHTML = `
    <div class="summary-item">
      <span class="summary-value">${data.total_sessions}</span>
      <span class="summary-label">会话</span>
    </div>
    <div class="summary-item">
      <span class="summary-value">${formatNum(data.total_messages)}</span>
      <span class="summary-label">消息</span>
    </div>
    <div class="summary-item">
      <span class="summary-value">${formatTokens(data.total_input_tokens)}</span>
      <span class="summary-label">输入</span>
    </div>
    <div class="summary-item">
      <span class="summary-value">${formatTokens(data.total_output_tokens)}</span>
      <span class="summary-label">输出</span>
    </div>
  `;

  // 排行榜
  const list = document.getElementById('usageList');
  if (data.projects.length === 0) {
    list.innerHTML = '<div class="empty">无数据</div>';
    return;
  }

  const maxTokens = data.projects[0].output_tokens || 1;

  list.innerHTML = data.projects.map(p => {
    const pct = Math.max(2, (p.output_tokens / maxTokens) * 100);
    const lastTime = p.last_active ? formatDate(p.last_active) : '';

    const modelTags = (p.models || []).map(m => {
      return `<span class="model-tag" title="${m.model}">${m.display_name} <em>${formatTokens(m.output_tokens)}</em></span>`;
    }).join('');

    return `
      <div class="usage-item">
        <div class="usage-row">
          <span class="usage-name">${p.name}</span>
          <span class="usage-tokens">${formatTokens(p.output_tokens)}</span>
        </div>
        <div class="usage-bar-bg">
          <div class="usage-bar" style="width:${pct}%"></div>
        </div>
        <div class="usage-meta">
          <span>${p.session_count} 会话 · ${formatNum(p.message_count)} 消息</span>
          <span>${lastTime}</span>
        </div>
        ${modelTags ? `<div class="usage-models">${modelTags}</div>` : ''}
      </div>
    `;
  }).join('');
}

function renderProjects() {
  const list = document.getElementById('projectList');

  if (state.projects.length === 0) {
    list.innerHTML = `
      <div class="empty-cta">
        <div class="empty-title">还没添加项目</div>
        <div class="empty-hint">点击下方按钮自动扫描 <code>~/Documents/code</code> 下的 git 仓库</div>
        <div class="empty-actions">
          <button class="btn-primary" onclick="scanProjects()">扫描项目</button>
          <button class="btn-ghost" onclick="revealDataDir()">打开配置目录</button>
        </div>
      </div>
    `;
    return;
  }

  // 搜索过滤（匹配名称、描述、路径）
  const filtered = state.projects.filter(p => {
    if (!state.searchQuery) return true;
    const q = state.searchQuery;
    return (p.name || '').toLowerCase().includes(q)
      || (p.description || '').toLowerCase().includes(q)
      || (p.path || '').toLowerCase().includes(q);
  });

  if (filtered.length === 0 && state.searchQuery) {
    list.innerHTML = '<div class="empty">无匹配项目</div>';
    return;
  }

  // 运行中的排前面
  const sorted = [...filtered].sort((a, b) => {
    if (a.running !== b.running) return b.running ? 1 : -1;
    return 0;
  });

  list.innerHTML = sorted.map(p => {
    const statusClass = p.running ? 'running' : 'idle';
    const lastEvent = p.lastEvent;
    let statusText = p.running ? '运行中' : '';
    let timeText = '';

    if (lastEvent) {
      statusText = lastEvent.type === 'stop' ? '完成' : '等待授权';
      timeText = formatTime(lastEvent.timestamp);
    }

    return `
      <div class="project-item ${statusClass}" data-name="${p.name}" data-path="${p.path}" data-running="${p.running}">
        <div class="project-dot ${statusClass}"></div>
        <div class="project-info">
          <div class="project-name-row">
            <span class="project-name">${p.name}</span>
            ${renderGitBadge(p.git)}
          </div>
          <span class="project-desc">${p.description || ''}</span>
        </div>
        <div class="project-right">
          <span class="project-status">${statusText}</span>
          <span class="project-time">${timeText}</span>
        </div>
      </div>
    `;
  }).join('');

  // 绑定点击
  list.querySelectorAll('.project-item').forEach(el => {
    el.addEventListener('click', (e) => {
      const name = el.dataset.name;
      const path = el.dataset.path;
      const running = el.dataset.running === 'true';

      if (running) {
        invoke('focus_project', { project: name });
      } else {
        showMenu(e, name, path);
      }
    });

    // 右键：无论运行与否都弹操作菜单（打开 Finder/VS Code/再开窗口 等）
    el.addEventListener('contextmenu', (e) => {
      e.preventDefault();
      showMenu(e, el.dataset.name, el.dataset.path);
    });
  });
}

function renderGitBadge(git) {
  if (!git || !git.is_git) {
    return '<span class="git-pill no-git" title="非 git 仓库">无 git</span>';
  }
  const isClean = git.changes === 0;
  const statusClass = isClean ? 'clean' : 'dirty';
  const statusIcon = isClean ? '✓' : '●';
  const statusText = isClean ? '干净' : `${git.changes}`;
  const statusTitle = isClean ? '工作区干净' : `${git.changes} 个未提交变更`;

  let extra = '';
  if (git.ahead > 0)  extra += `<span class="git-pill ahead"  title="${git.ahead} 个未推送 commit">↑${git.ahead}</span>`;
  if (git.behind > 0) extra += `<span class="git-pill behind" title="${git.behind} 个落后远端 commit">↓${git.behind}</span>`;
  if (!git.has_upstream && git.branch) {
    extra += `<span class="git-pill no-upstream" title="无 upstream">无远端</span>`;
  }

  return `
    <span class="git-pill branch" title="当前分支">${git.branch || '?'}</span>
    <span class="git-pill ${statusClass}" title="${statusTitle}">${statusIcon} ${statusText}</span>
    ${extra}
  `;
}

function showMenu(event, name, path) {
  closeMenu();
  state.menuTarget = { name, path };

  const menu = document.getElementById('contextMenu');
  menu.style.display = 'block';

  // 定位到点击位置
  const rect = event.currentTarget.getBoundingClientRect();
  menu.style.top = rect.bottom + 4 + 'px';
  menu.style.left = rect.left + 'px';

  event.stopPropagation();
}

function closeMenu() {
  document.getElementById('contextMenu').style.display = 'none';
  state.menuTarget = null;
}

function menuAction(mode) {
  if (!state.menuTarget) return;
  const { name, path } = state.menuTarget;
  invoke('open_project', { name, path, mode });
  closeMenu();

  // 延迟刷新
  setTimeout(refreshProjects, 2000);
}

function renderEvents() {
  const list = document.getElementById('eventList');

  if (state.events.length === 0) {
    list.innerHTML = '<div class="empty">等待通知...</div>';
    return;
  }

  list.innerHTML = state.events.slice(0, 10).map(e => `
    <div class="event-item">
      <span class="event-time">${formatTime(e.timestamp)}</span>
      <span class="event-icon ${e.type}">${e.type === 'stop' ? '●' : '⚠'}</span>
      <span class="event-message">${e.project} ${e.message}</span>
    </div>
  `).join('');
}

function formatTime(ts) {
  try {
    const d = new Date(ts);
    return d.toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' });
  } catch {
    return ts || '';
  }
}

function formatDate(ts) {
  try {
    const d = new Date(ts);
    return d.toLocaleDateString('zh-CN', { month: 'short', day: 'numeric' });
  } catch {
    return '';
  }
}

function formatNum(n) {
  if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
  if (n >= 1000) return (n / 1000).toFixed(1) + 'K';
  return String(n);
}

function formatTokens(n) {
  if (n >= 1000000000) return (n / 1000000000).toFixed(1) + 'B';
  if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
  if (n >= 1000) return (n / 1000).toFixed(1) + 'K';
  return String(n);
}

function updateGlobalStatus() {
  const badge = document.getElementById('globalStatus');
  const hasRunning = state.projects.some(p => p.running);
  const hasPermission = state.events.some(e => e.type === 'permission' &&
    (Date.now() - new Date(e.timestamp).getTime()) < 60000);

  if (hasPermission) {
    badge.textContent = '需要操作';
    badge.className = 'status-badge attention';
  } else if (hasRunning) {
    badge.textContent = `${state.projects.filter(p => p.running).length} 个运行中`;
    badge.className = 'status-badge busy';
  } else {
    badge.textContent = '就绪';
    badge.className = 'status-badge';
  }
}

async function refreshDeps() {
  try {
    const [list, terminal, legacy] = await Promise.all([
      invoke('check_dependencies'),
      invoke('get_terminal_info'),
      invoke('hub_server_legacy'),
    ]);
    state.deps = list;
    state.terminal = terminal;
    state.legacyServer = legacy;
    renderDeps();
  } catch (e) {}
}

function renderDeps() {
  const panel = document.getElementById('depsPanel');
  if (!panel || !state.deps) return;
  const missing = state.deps.filter(d => !d.installed);
  const term = state.terminal || {};
  const legacy = !!state.legacyServer;
  const termWarn = term && term.supported === false;

  // 全部 OK 且无遗留 server → 隐藏面板
  if (missing.length === 0 && !termWarn && !legacy) {
    panel.style.display = 'none';
    return;
  }

  const requiredMissing = missing.filter(d => d.required);
  const optionalMissing = missing.filter(d => !d.required);

  let title;
  if (legacy) title = '⚠️ 检测到旧版 tmux server';
  else if (requiredMissing.length > 0) title = '⚠️ 缺少必需依赖';
  else if (termWarn) title = '⚠️ 终端不受支持';
  else title = '可选依赖未装';

  let body = '';

  // 旧版 server 提示
  if (legacy) {
    body += `
      <div class="dep-row required">
        <div class="dep-info">
          <span class="dep-label">现有 hub server 由 .app 创建（无法读 Keychain 登录态）</span>
        </div>
        <code class="dep-cmd" title="点击复制" onclick="copyText(this, 'tmux kill-server')">tmux kill-server</code>
      </div>
    `;
  }

  // 终端不支持提示
  if (termWarn) {
    body += `
      <div class="dep-row required">
        <div class="dep-info">
          <span class="dep-label">检测到终端 ${term.label || ''}，第一版仅支持 iTerm / Terminal.app</span>
        </div>
        <code class="dep-cmd" title="点击复制" onclick="copyText(this, 'brew install --cask iterm2')">brew install --cask iterm2</code>
      </div>
    `;
  }

  // 缺失依赖
  for (const d of [...requiredMissing, ...optionalMissing]) {
    body += `
      <div class="dep-row ${d.required ? 'required' : 'optional'}">
        <div class="dep-info">
          <span class="dep-label">${d.label}</span>
          <span class="dep-tag">${d.required ? '必需' : '可选'}</span>
        </div>
        <code class="dep-cmd" title="点击复制" onclick="copyText(this, '${escapeAttr(d.install_cmd)}')">${d.install_cmd}</code>
      </div>
    `;
  }

  panel.style.display = '';
  panel.innerHTML = `
    <div class="deps-header">
      <span class="deps-title">${title}</span>
      <button class="deps-recheck" onclick="refreshDeps()" title="重新检查">⟳</button>
    </div>
    ${body}
    <div class="deps-footer">终端：<b>${term.label || '?'}</b></div>
  `;
}

function escapeAttr(s) {
  return String(s).replace(/'/g, "\\'");
}

async function copyText(el, text) {
  try {
    await navigator.clipboard.writeText(text);
    const orig = el.textContent;
    el.textContent = '已复制 ✓';
    el.classList.add('copied');
    setTimeout(() => {
      el.textContent = orig;
      el.classList.remove('copied');
    }, 1200);
  } catch (e) {}
}

async function scanProjects() {
  try {
    const added = await invoke('scan_projects', { base: null });
    await refreshProjects();
    const msg = added > 0 ? `扫描完成，新增 ${added} 个项目` : '已是最新，未发现新项目';
    flashStatus(msg);
  } catch (e) {
    flashStatus('扫描失败：' + e, true);
  }
}

async function revealDataDir() {
  try { await invoke('reveal_data_dir'); } catch (e) {}
}

// 临时在 globalStatus 闪一条提示
function flashStatus(text, error = false) {
  const badge = document.getElementById('globalStatus');
  const prevText = badge.textContent;
  const prevClass = badge.className;
  badge.textContent = text;
  badge.className = 'status-badge ' + (error ? 'attention' : 'busy');
  setTimeout(() => updateGlobalStatus(), 2400);
}

// 暴露给 HTML onclick
window.menuAction = menuAction;
window.switchTab = switchTab;
window.loadUsage = loadUsage;
window.scanProjects = scanProjects;
window.revealDataDir = revealDataDir;
window.refreshDeps = refreshDeps;
window.copyText = copyText;

init();
