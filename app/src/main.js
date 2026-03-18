// Claude Hub 状态面板

const { listen } = window.__TAURI__.event;
const { invoke } = window.__TAURI__.core;

const state = {
  projects: [],
  events: [],
  menuTarget: null, // 当前弹出菜单的项目
  searchQuery: '',
};

async function init() {
  // 监听 Rust 后端事件
  await listen('hub-event', (event) => {
    handleEvent(event.payload);
  });

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
    renderProjects();
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

function renderProjects() {
  const list = document.getElementById('projectList');

  if (state.projects.length === 0) {
    list.innerHTML = '<div class="empty">没有项目，运行 scripts/scan-projects.sh</div>';
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
          <span class="project-name">${p.name}</span>
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
  });
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

// 暴露给 HTML onclick
window.menuAction = menuAction;

init();
