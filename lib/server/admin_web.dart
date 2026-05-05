String buildAdminConsoleHtml() {
  return r'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>PicaKeep Admin</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #0f1115;
      --panel: #171a21;
      --panel-2: #1f2430;
      --line: #2d3445;
      --text: #eef2ff;
      --muted: #9ba6c2;
      --accent: #7c9cff;
      --success: #4dd4ac;
      --danger: #ff7d8b;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: "Segoe UI", "PingFang SC", sans-serif;
      background: linear-gradient(180deg, #0b0d12 0%, var(--bg) 100%);
      color: var(--text);
    }
    .shell {
      display: grid;
      grid-template-columns: 280px 1fr;
      min-height: 100vh;
    }
    .sidebar {
      border-right: 1px solid var(--line);
      background: rgba(15,17,21,0.92);
      padding: 24px 20px;
      position: sticky;
      top: 0;
      height: 100vh;
    }
    .brand { font-size: 24px; font-weight: 700; margin-bottom: 8px; }
    .sub { color: var(--muted); font-size: 13px; line-height: 1.6; }
    .nav { margin-top: 24px; display: grid; gap: 10px; }
    .nav button {
      background: var(--panel);
      color: var(--text);
      border: 1px solid var(--line);
      border-radius: 14px;
      padding: 14px 16px;
      text-align: left;
      cursor: pointer;
    }
    .nav button.active { border-color: var(--accent); background: #20283b; }
    .content { padding: 24px; }
    .topbar {
      display: flex;
      flex-wrap: wrap;
      gap: 12px;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 20px;
    }
    .card {
      background: rgba(23,26,33,0.92);
      border: 1px solid var(--line);
      border-radius: 18px;
      padding: 18px;
      margin-bottom: 16px;
      box-shadow: 0 8px 32px rgba(0,0,0,0.18);
    }
    .card h3 { margin: 0 0 12px; }
    .muted { color: var(--muted); }
    .grid { display: grid; gap: 16px; }
    .grid.stats { grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); }
    .stat { background: var(--panel-2); border-radius: 14px; padding: 16px; }
    .stat .v { font-size: 28px; font-weight: 700; margin-top: 8px; }
    .toolbar { display: flex; gap: 10px; flex-wrap: wrap; }
    button.action {
      background: var(--accent);
      color: white;
      border: 0;
      border-radius: 12px;
      padding: 10px 16px;
      cursor: pointer;
      font-weight: 600;
    }
    button.ghost {
      background: transparent;
      color: var(--text);
      border: 1px solid var(--line);
      border-radius: 12px;
      padding: 10px 16px;
      cursor: pointer;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 14px;
    }
    th, td {
      border-bottom: 1px solid var(--line);
      padding: 12px 10px;
      text-align: left;
      vertical-align: top;
    }
    input, textarea {
      width: 100%;
      background: #0f131c;
      color: var(--text);
      border: 1px solid var(--line);
      border-radius: 12px;
      padding: 12px;
      margin-top: 6px;
    }
    textarea { min-height: 120px; resize: vertical; }
    .form-grid { display: grid; gap: 14px; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); }
    .badge {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 6px 10px;
      border-radius: 999px;
      background: #20283b;
      color: var(--text);
      border: 1px solid var(--line);
      font-size: 12px;
    }
    .login-mask {
      position: fixed;
      inset: 0;
      background: rgba(5,7,11,0.78);
      display: flex;
      align-items: center;
      justify-content: center;
      z-index: 20;
      backdrop-filter: blur(8px);
    }
    .login-card {
      width: min(520px, calc(100vw - 32px));
      background: rgba(23,26,33,0.96);
      border: 1px solid var(--line);
      border-radius: 24px;
      padding: 24px;
    }
    .slider-row { margin-top: 18px; }
    .slider-row input { width: 100%; }
    .ok { color: var(--success); }
    .bad { color: var(--danger); }
    pre {
      margin: 0;
      white-space: pre-wrap;
      word-break: break-word;
      background: #0e1219;
      border: 1px solid var(--line);
      border-radius: 12px;
      padding: 14px;
    }
    @media (max-width: 960px) {
      .shell { grid-template-columns: 1fr; }
      .sidebar { position: static; height: auto; border-right: 0; border-bottom: 1px solid var(--line); }
    }
  </style>
</head>
<body>
  <div id="loginMask" class="login-mask">
    <div class="login-card">
      <div class="brand">PicaKeep Admin</div>
      <div class="sub">当前后台先使用滑动成功即登录的占位方案。后续如需真正鉴权，再替换这里即可。</div>
      <div class="slider-row">
        <input id="loginSlider" type="range" min="0" max="100" value="0">
      </div>
      <div style="margin-top: 10px" class="muted">向右滑动完成登录</div>
    </div>
  </div>

  <div class="shell">
    <aside class="sidebar">
      <div class="brand">PicaKeep Admin</div>
      <div class="sub">服务端只暴露当前设备本地可访问的漫画资源与状态。客户端模式连接后，本质上也是在访问这些本地资源。</div>
      <div class="nav">
        <button class="active" data-tab="overview">概览</button>
        <button data-tab="resources">本地资源</button>
        <button data-tab="config">服务配置</button>
        <button data-tab="logs">运行日志</button>
        <button data-tab="endpoints">接口</button>
      </div>
    </aside>
    <main class="content">
      <div class="topbar">
        <div>
          <div class="brand" style="font-size: 28px; margin-bottom: 4px;">网页端后台</div>
          <div id="statusText" class="muted">正在加载服务状态...</div>
        </div>
        <div class="toolbar">
          <button class="action" onclick="refreshAll()">刷新全部</button>
          <button class="ghost" onclick="scanResources()">重新扫描资源</button>
        </div>
      </div>
      <div id="errorBanner" class="card" hidden style="border-color: var(--danger); color: #ffd3d8;"></div>

      <section id="tab-overview" class="tab-panel"></section>
      <section id="tab-resources" class="tab-panel" hidden></section>
      <section id="tab-config" class="tab-panel" hidden></section>
      <section id="tab-logs" class="tab-panel" hidden></section>
      <section id="tab-endpoints" class="tab-panel" hidden></section>
    </main>
  </div>

  <script>
    const state = {
      summary: null,
      resources: null,
      config: null,
      logs: null,
      error: '',
    };

    document.querySelectorAll('.nav button').forEach((button) => {
      button.addEventListener('click', () => switchTab(button.dataset.tab));
    });

    document.getElementById('loginSlider').addEventListener('change', (event) => {
      const value = Number(event.target.value || 0);
      if (value >= 95) {
        sessionStorage.setItem('picakeep-admin-unlocked', '1');
        applyLoginState();
        refreshAll();
      } else {
        event.target.value = 0;
      }
    });

    applyLoginState();

    function applyLoginState() {
      const unlocked = sessionStorage.getItem('picakeep-admin-unlocked') === '1';
      document.getElementById('loginMask').style.display = unlocked ? 'none' : 'flex';
    }

    function setError(message) {
      state.error = message || '';
      const banner = document.getElementById('errorBanner');
      if (!banner) return;
      if (!state.error) {
        banner.hidden = true;
        banner.textContent = '';
        return;
      }
      banner.hidden = false;
      banner.textContent = state.error;
    }

    function switchTab(tab) {
      document.querySelectorAll('.nav button').forEach((button) => {
        button.classList.toggle('active', button.dataset.tab === tab);
      });
      document.querySelectorAll('.tab-panel').forEach((panel) => {
        panel.hidden = panel.id !== `tab-${tab}`;
      });
    }

    async function refreshAll() {
      setError('');
      try {
        await Promise.all([loadSummary(), loadResources(), loadConfig(), loadLogs()]);
        renderOverview();
        renderResources();
        renderConfig();
        renderLogs();
        renderEndpoints();
      } catch (error) {
        setError(error instanceof Error ? error.message : String(error || '加载失败'));
      }
    }

    async function loadSummary() {
      state.summary = await fetchJson('/api/admin/summary');
      document.getElementById('statusText').textContent = `${state.summary.statusText} · 启动于 ${state.summary.startedAt} · 漫画 ${state.summary.comicCount}`;
    }

    async function loadResources() {
      state.resources = await fetchJson('/api/admin/resources');
    }

    async function loadConfig() {
      state.config = await fetchJson('/api/admin/config');
    }

    async function loadLogs() {
      state.logs = await fetchJson('/api/admin/logs');
    }

    async function scanResources() {
      await fetchJson('/api/admin/scan', { method: 'POST' });
      await refreshAll();
    }

    async function saveConfig(event) {
      event.preventDefault();
      const payload = {
        host: document.getElementById('cfg-host').value.trim(),
        port: Number(document.getElementById('cfg-port').value.trim() || 9527),
        currentDownloadRoot: document.getElementById('cfg-current-root').value.trim(),
        originalDownloadRoot: document.getElementById('cfg-original-root').value.trim(),
        customLibraryRoots: document.getElementById('cfg-custom-roots').value
          .split('\n')
          .map((item) => item.trim())
          .filter(Boolean),
        logRequests: document.getElementById('cfg-log-requests').checked,
      };
      await fetchJson('/api/admin/config', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
      await refreshAll();
      alert('配置已保存。涉及 host/port 的修改需要重启服务后生效。');
    }

    function renderOverview() {
      const summary = state.summary;
      const resources = state.resources;
      document.getElementById('tab-overview').innerHTML = `
        <div class="grid stats">
          <div class="stat"><div class="muted">运行状态</div><div class="v">${summary.statusText}</div></div>
          <div class="stat"><div class="muted">漫画项目数</div><div class="v">${summary.comicCount}</div></div>
          <div class="stat"><div class="muted">已配置资源根</div><div class="v">${summary.libraryRootCount}</div></div>
          <div class="stat"><div class="muted">累计请求数</div><div class="v">${summary.totalRequests}</div></div>
        </div>
        <div class="card">
          <h3>服务说明</h3>
          <div class="muted">${summary.message}</div>
        </div>
        <div class="card">
          <h3>当前资源概览</h3>
          <div class="grid stats">
            <div class="stat"><div class="muted">扫描时间</div><div class="v" style="font-size:18px">${resources.generatedAt}</div></div>
            <div class="stat"><div class="muted">总图片体积</div><div class="v" style="font-size:18px">${formatBytes(summary.resourceBytes ?? resources.totalBytes)}</div></div>
            <div class="stat"><div class="muted">可用 / 缺失资源根</div><div class="v" style="font-size:18px">${summary.availableLibraryRootCount ?? 0} / ${summary.missingLibraryRootCount ?? 0}</div></div>
            <div class="stat"><div class="muted">活动连接</div><div class="v">${summary.activeConnections}</div></div>
          </div>
        </div>
        <div class="card">
          <h3>快速访问</h3>
          <div class="grid stats">
            <div class="stat"><div class="muted">状态接口</div><div class="v" style="font-size:16px">${escapeHtml(summary.statusUrl || '/status')}</div></div>
            <div class="stat"><div class="muted">后台地址</div><div class="v" style="font-size:16px">${escapeHtml(summary.adminUrl || '/admin')}</div></div>
            <div class="stat"><div class="muted">启动时间</div><div class="v" style="font-size:16px">${summary.startedAt}</div></div>
            <div class="stat"><div class="muted">日志记录</div><div class="v" style="font-size:16px">${summary.logRequests ? '开启' : '关闭'}</div></div>
          </div>
        </div>
      `;
    }

    function renderResources() {
      const resources = state.resources;
      const rootsTable = resources.roots.map((root) => `
        <tr>
          <td>${root.title}</td>
          <td>${root.exists ? '<span class="ok">存在</span>' : '<span class="bad">不存在</span>'}</td>
          <td>${root.itemCount}</td>
          <td>${formatBytes(root.totalBytes)}</td>
          <td>${escapeHtml(root.path)}</td>
        </tr>
      `).join('');
      const itemsTable = resources.items.map((item) => `
        <tr>
          <td>${escapeHtml(item.title)}</td>
          <td>${item.imageCount}</td>
          <td>${formatBytes(item.totalBytes)}</td>
          <td>${escapeHtml(item.path)}</td>
        </tr>
      `).join('');
      document.getElementById('tab-resources').innerHTML = `
        <div class="card">
          <h3>资源总览</h3>
          <div class="grid stats">
            <div class="stat"><div class="muted">资源根数量</div><div class="v">${resources.roots.length}</div></div>
            <div class="stat"><div class="muted">发现项目数</div><div class="v">${resources.items.length}</div></div>
            <div class="stat"><div class="muted">总图片体积</div><div class="v" style="font-size:18px">${formatBytes(resources.totalBytes)}</div></div>
            <div class="stat"><div class="muted">最近扫描</div><div class="v" style="font-size:18px">${resources.generatedAt}</div></div>
          </div>
        </div>
        <div class="card">
          <h3>资源根</h3>
          <table>
            <thead><tr><th>名称</th><th>状态</th><th>项目数</th><th>体积</th><th>路径</th></tr></thead>
            <tbody>${rootsTable || '<tr><td colspan="5" class="muted">暂无资源根</td></tr>'}</tbody>
          </table>
        </div>
        <div class="card">
          <h3>发现到的本地项目</h3>
          <table>
            <thead><tr><th>标题</th><th>图片数</th><th>体积</th><th>路径</th></tr></thead>
            <tbody>${itemsTable || '<tr><td colspan="4" class="muted">当前没有发现可服务的本地漫画资源</td></tr>'}</tbody>
          </table>
        </div>
      `;
    }

    function renderConfig() {
      const config = state.config;
      const summary = state.summary;
      document.getElementById('tab-config').innerHTML = `
        <form class="card" onsubmit="saveConfig(event)">
          <h3>服务配置</h3>
          <div class="form-grid">
            <label>监听 Host
              <input id="cfg-host" value="${escapeAttr(config.host)}">
            </label>
            <label>监听 Port
              <input id="cfg-port" type="number" value="${config.port}">
            </label>
            <label>本应用下载目录
              <input id="cfg-current-root" value="${escapeAttr(config.currentDownloadRoot)}">
            </label>
            <label>原应用下载目录
              <input id="cfg-original-root" value="${escapeAttr(config.originalDownloadRoot)}">
            </label>
          </div>
          <div style="margin-top:14px">
            <label>自定义资源根（每行一个）
              <textarea id="cfg-custom-roots">${escapeHtml((config.customLibraryRoots || []).join('\n'))}</textarea>
            </label>
          </div>
          <div style="margin-top:14px">
            <label><input id="cfg-log-requests" type="checkbox" ${config.logRequests ? 'checked' : ''}> 记录请求日志</label>
          </div>
          <div style="margin-top:16px" class="toolbar">
            <button class="action" type="submit">保存配置</button>
            <span class="muted">提示：host/port 改动保存后需要重启服务才能完全生效。</span>
          </div>
        </form>
        <div class="card">
          <h3>当前生效信息</h3>
          <table>
            <tbody>
              <tr><th>后台地址</th><td>${escapeHtml(summary.adminUrl || '/admin')}</td></tr>
              <tr><th>状态接口</th><td>${escapeHtml(summary.statusUrl || '/status')}</td></tr>
              <tr><th>配置文件</th><td>${escapeHtml(summary.configPath || '--')}</td></tr>
              <tr><th>日志记录</th><td>${summary.logRequests ? '开启' : '关闭'}</td></tr>
            </tbody>
          </table>
        </div>
      `;
    }

    function renderLogs() {
      const logs = (state.logs.logs || []).map((log) => `[${log.time}] [${log.type}] ${log.message}`).join('\n');
      document.getElementById('tab-logs').innerHTML = `
        <div class="card">
          <h3>最近日志</h3>
          <pre>${escapeHtml(logs || '当前暂无日志输出')}</pre>
        </div>
      `;
    }

    function renderEndpoints() {
      const summary = state.summary;
      document.getElementById('tab-endpoints').innerHTML = `
        <div class="card">
          <h3>当前接口</h3>
          <div class="badge">GET /status</div>
          <div class="badge">GET /admin</div>
          <div class="badge">GET /api/admin/status</div>
          <div class="badge">GET /api/admin/summary</div>
          <div class="badge">GET /api/admin/resources</div>
          <div class="badge">GET /api/admin/config</div>
          <div class="badge">PUT /api/admin/config</div>
          <div class="badge">GET /api/admin/logs</div>
          <div class="badge">POST /api/admin/scan</div>
        </div>
        <div class="card">
          <h3>主要地址</h3>
          <table>
            <tbody>
              <tr><th>后台</th><td>${escapeHtml(summary.adminUrl || '/admin')}</td></tr>
              <tr><th>状态</th><td>${escapeHtml(summary.statusUrl || '/status')}</td></tr>
              <tr><th>概览</th><td>/api/admin/summary</td></tr>
              <tr><th>资源</th><td>/api/admin/resources</td></tr>
            </tbody>
          </table>
        </div>
      `;
    }

    async function fetchJson(url, options = {}) {
      const response = await fetch(url, options);
      if (!response.ok) {
        throw new Error(`${url} -> ${response.status}`);
      }
      return response.json();
    }

    function formatBytes(bytes) {
      if (!bytes) return '0 B';
      const units = ['B', 'KB', 'MB', 'GB', 'TB'];
      let value = bytes;
      let index = 0;
      while (value >= 1024 && index < units.length - 1) {
        value /= 1024;
        index++;
      }
      return `${value.toFixed(value >= 10 || index === 0 ? 0 : 1)} ${units[index]}`;
    }

    function escapeHtml(value) {
      return String(value || '')
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;');
    }

    function escapeAttr(value) {
      return escapeHtml(value).replaceAll("'", '&#39;');
    }
  </script>
</body>
</html>
''';
}
