// Claude Hub 状态面板
// 通过 Tauri IPC 从 Rust 后端接收事件

const { listen } = window.__TAURI__.event;
const { invoke } = window.__TAURI__.core;

// 状态存储
const state = {
  projects: {},  // { name: { status, message, time } }
  events: [],    // [{ type, project, message, timestamp }]
};

// 初始化
async function init() {
  // 监听来自 Rust 的事件
  await listen('hub-event', (event) => {
    handleEvent(event.payload);
  });

  // 加载历史事件
  try {
    const history = await invoke('get_events');
    history.forEach(handleEvent);
  } catch (e) {
    console.log('No history:', e);
  }
}

function handleEvent(data) {
  // 更新项目状态
  state.projects[data.project] = {
    status: data.type === 'stop' ? 'done' : 'permission',
    message: data.message,
    time: formatTime(data.timestamp),
  };

  // 添加到事件列表
  state.events.unshift(data);
  if (state.events.length > 20) state.events.pop();

  render();
}

function formatTime(ts) {
  try {
    const d = new Date(ts);
    return d.toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' });
  } catch {
    return ts;
  }
}

function render() {
  renderProjects();
  renderEvents();
  updateGlobalStatus();
}

function renderProjects() {
  const list = document.getElementById('projectList');
  const entries = Object.entries(state.projects);

  if (entries.length === 0) {
    list.innerHTML = '<div class="empty">没有活跃项目</div>';
    return;
  }

  list.innerHTML = entries.map(([name, info]) => `
    <div class="project-item" data-project="${name}">
      <div class="project-dot ${info.status}"></div>
      <span class="project-name">${name}</span>
      <span class="project-status">${statusText(info.status)}</span>
      <span class="project-time">${info.time}</span>
    </div>
  `).join('');

  // 点击跳转
  list.querySelectorAll('.project-item').forEach(el => {
    el.addEventListener('click', () => {
      const project = el.dataset.project;
      invoke('focus_project', { project });
    });
  });
}

function renderEvents() {
  const list = document.getElementById('eventList');

  if (state.events.length === 0) {
    list.innerHTML = '<div class="empty">等待通知...</div>';
    return;
  }

  list.innerHTML = state.events.map(e => `
    <div class="event-item">
      <span class="event-time">${formatTime(e.timestamp)}</span>
      <span class="event-icon ${e.type}">${e.type === 'stop' ? '●' : '⚠'}</span>
      <span class="event-message">${e.project} ${e.message}</span>
    </div>
  `).join('');
}

function statusText(status) {
  switch (status) {
    case 'done': return '完成';
    case 'busy': return '工作中...';
    case 'permission': return '等待授权';
    default: return '空闲';
  }
}

function updateGlobalStatus() {
  const badge = document.getElementById('globalStatus');
  const statuses = Object.values(state.projects).map(p => p.status);

  if (statuses.includes('permission')) {
    badge.textContent = '需要操作';
    badge.className = 'status-badge attention';
  } else if (statuses.includes('busy')) {
    badge.textContent = '工作中';
    badge.className = 'status-badge busy';
  } else {
    badge.textContent = '就绪';
    badge.className = 'status-badge';
  }
}

init();
