(function () {
  'use strict';

  function renderAdmin(rootEl) {
    rootEl.innerHTML = `
      <div class="admin-shell">
        <aside class="admin-sidebar">
          <div class="brand">PicaKeep Admin</div>
          <div class="sub">服务端只暴露当前设备本地可访问的漫画资源与状态。客户端模式连接后，本质上也是在访问这些本地资源。</div>
          <div class="admin-nav">
            <button class="active" data-tab="overview">概览</button>
            <button data-tab="resources">本地资源</button>
            <button data-tab="trash">回收站</button>
            <button data-tab="favorites">收藏夹</button>
            <button data-tab="image-favorites">图片收藏</button>
            <button data-tab="config">服务配置</button>
            <button data-tab="logs">运行日志</button>
            <button data-tab="endpoints">接口</button>
          </div>
        </aside>
        <main class="admin-content">
          <div class="admin-topbar">
            <div>
              <div class="brand" style="font-size: 28px; margin-bottom: 4px;">网页端后台</div>
              <div class="admin-status muted">正在加载服务状态...</div>
            </div>
            <div class="toolbar">
              <button class="action admin-refresh" type="button">刷新全部</button>
              <button class="ghost admin-scan" type="button">重新扫描资源</button>
            </div>
          </div>
          <div class="admin-error card admin-error-card" hidden></div>
          <section data-panel="overview" class="tab-panel"></section>
          <section data-panel="resources" class="tab-panel" hidden></section>
          <section data-panel="trash" class="tab-panel" hidden></section>
          <section data-panel="favorites" class="tab-panel" hidden></section>
          <section data-panel="image-favorites" class="tab-panel" hidden></section>
          <section data-panel="config" class="tab-panel" hidden></section>
          <section data-panel="logs" class="tab-panel" hidden></section>
          <section data-panel="endpoints" class="tab-panel" hidden></section>
        </main>
      </div>
    `;

    const state = {
      activeTab: 'overview',
      summary: null,
      resources: null,
      config: null,
      logs: null,
      error: '',
      selectedResources: new Set(),
      selectedTrash: new Set(),
      trash: { loaded: false, loading: false, error: '', items: [] },
      favorites: {
        loaded: false,
        loading: false,
        itemLoading: false,
        error: '',
        itemError: '',
        folders: [],
        selectedFolder: '',
        itemsByFolder: new Map(),
      },
      imageFavorites: { loaded: false, loading: false, error: '', items: [] },
      logsFilter: { type: 'all', keyword: '' },
    };
    const api = window.PicaKeepConsole.api;

    rootEl.querySelectorAll('.admin-nav button').forEach((button) => {
      button.addEventListener('click', () => switchTab(button.dataset.tab));
    });
    rootEl.querySelector('.admin-refresh').addEventListener('click', refreshAll);
    rootEl.querySelector('.admin-scan').addEventListener('click', (event) => withButtonBusy(event.currentTarget, scanResources));

    refreshAll();

    function panel(name) { return rootEl.querySelector(`[data-panel="${name}"]`); }

    function setError(message) {
      state.error = message || '';
      const banner = rootEl.querySelector('.admin-error');
      if (!state.error) {
        banner.hidden = true;
        banner.textContent = '';
        return;
      }
      banner.hidden = false;
      banner.textContent = state.error;
    }

    function switchTab(tab) {
      state.activeTab = tab;
      rootEl.querySelectorAll('.admin-nav button').forEach((button) => {
        button.classList.toggle('active', button.dataset.tab === tab);
      });
      rootEl.querySelectorAll('.tab-panel').forEach((item) => {
        item.hidden = item.dataset.panel !== tab;
      });
      if (tab === 'trash' && !state.trash.loaded && !state.trash.loading) loadTrash();
      if (tab === 'favorites' && !state.favorites.loaded && !state.favorites.loading) loadFavorites();
      if (tab === 'image-favorites' && !state.imageFavorites.loaded && !state.imageFavorites.loading) loadImageFavorites();
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
      state.summary = await api.get('/api/admin/summary');
      rootEl.querySelector('.admin-status').textContent = `${state.summary.statusText} · 启动于 ${state.summary.startedAt || '--'} · 漫画 ${state.summary.comicCount}`;
    }

    async function loadResources() { state.resources = await api.get('/api/admin/resources'); }
    async function loadConfig() { state.config = await api.get('/api/admin/config'); }
    async function loadLogs() { state.logs = await api.get('/api/admin/logs'); }

    async function loadTrash() {
      state.trash.loading = true;
      state.trash.error = '';
      renderTrash();
      try {
        const data = await api.get('/api/library/trash');
        state.trash.items = data.items || [];
        state.trash.loaded = true;
        pruneSelection(state.selectedTrash, state.trash.items.map((item) => item.id));
      } catch (error) {
        state.trash.error = error instanceof Error ? error.message : String(error || '回收站加载失败');
      } finally {
        state.trash.loading = false;
        renderTrash();
        renderOverview();
      }
    }

    async function loadFavorites() {
      state.favorites.loading = true;
      state.favorites.error = '';
      renderFavorites();
      try {
        const data = await api.get('/api/library/favorites');
        state.favorites.folders = data.folders || [];
        state.favorites.loaded = true;
        if (!state.favorites.folders.some((folder) => folder.name === state.favorites.selectedFolder)) {
          state.favorites.selectedFolder = (state.favorites.folders[0] && state.favorites.folders[0].name) || '';
        }
        renderFavorites();
        if (state.favorites.selectedFolder && !state.favorites.itemsByFolder.has(state.favorites.selectedFolder)) {
          await loadFavoriteItems(state.favorites.selectedFolder);
        }
      } catch (error) {
        state.favorites.error = error instanceof Error ? error.message : String(error || '收藏夹加载失败');
      } finally {
        state.favorites.loading = false;
        renderFavorites();
        renderOverview();
      }
    }

    async function loadFavoriteItems(folder) {
      if (!folder) return;
      state.favorites.itemLoading = true;
      state.favorites.itemError = '';
      renderFavorites();
      try {
        const data = await api.get(`/api/library/favorites/${encodeURIComponent(folder)}`);
        state.favorites.itemsByFolder.set(folder, data.items || []);
      } catch (error) {
        state.favorites.itemError = error instanceof Error ? error.message : String(error || '收藏夹内容加载失败');
      } finally {
        state.favorites.itemLoading = false;
        renderFavorites();
      }
    }

    async function loadImageFavorites() {
      state.imageFavorites.loading = true;
      state.imageFavorites.error = '';
      renderImageFavorites();
      try {
        const data = await api.get('/api/library/image-favorites');
        state.imageFavorites.items = data.items || [];
        state.imageFavorites.loaded = true;
      } catch (error) {
        state.imageFavorites.error = error instanceof Error ? error.message : String(error || '图片收藏加载失败');
      } finally {
        state.imageFavorites.loading = false;
        renderImageFavorites();
        renderOverview();
      }
    }

    async function scanResources() {
      try {
        await api.post('/api/admin/scan');
        await refreshResourcesAndSummary();
      } catch (error) {
        setError(error instanceof Error ? error.message : String(error || '扫描失败'));
      }
    }

    async function refreshResourcesAndSummary() {
      await Promise.all([loadSummary(), loadResources()]);
      state.selectedResources.clear();
      renderOverview();
      renderResources();
      renderEndpoints();
    }

    async function refreshSummaryOnly() {
      await loadSummary();
      renderOverview();
      renderEndpoints();
    }

    async function withButtonBusy(button, task) {
      if (!button || button.disabled) return;
      button.disabled = true;
      try {
        await task();
      } finally {
        button.disabled = false;
      }
    }

    function bindConfigForm() {
      const form = rootEl.querySelector('.admin-config-form');
      if (!form) return;
      form.addEventListener('submit', async (event) => {
        event.preventDefault();
        setError('');
        const host = rootEl.querySelector('#cfg-host').value.trim() || '0.0.0.0';
        const port = Number(rootEl.querySelector('#cfg-port').value.trim() || 9527);
        if (!Number.isInteger(port) || port < 1 || port > 65535) {
          setError('监听 Port 必须是 1~65535 的整数。');
          return;
        }
        const payload = {
          host,
          port,
          currentDownloadRoot: rootEl.querySelector('#cfg-current-root').value.trim(),
          originalDownloadRoot: rootEl.querySelector('#cfg-original-root').value.trim(),
          customLibraryRoots: rootEl.querySelector('#cfg-custom-roots').value
            .split('\n')
            .map((item) => item.trim())
            .filter(Boolean),
          logRequests: rootEl.querySelector('#cfg-log-requests').checked,
          consolePassword: rootEl.querySelector('#cfg-console-password').value,
        };
        const submit = form.querySelector('button[type="submit"]');
        submit.disabled = true;
        try {
          await api.put('/api/admin/config', payload);
          const passwordChanged = payload.consolePassword !== (state.config.consolePassword || '');
          if (passwordChanged) {
            alert('配置已保存。后台密码已变更，请重新登录。涉及 host/port 的修改需要重启服务才能完全生效。');
            window.PicaKeepConsole.auth.logout();
            return;
          }
          await refreshAll();
          alert('配置已保存。涉及 host/port 的修改需要重启服务后生效。');
        } catch (error) {
          setError(error instanceof Error ? error.message : String(error || '保存失败'));
          alert('配置保存失败，请查看页面顶部错误提示。');
        } finally {
          submit.disabled = false;
        }
      });
    }

    function renderOverview() {
      if (!state.summary || !state.resources) return;
      const summary = state.summary;
      const resources = state.resources;
      const trashCount = state.trash.loaded ? number(state.trash.items.length) : '--';
      const folderCount = state.favorites.loaded ? number(state.favorites.folders.length) : '--';
      const imageFavoriteCount = state.imageFavorites.loaded ? number(state.imageFavorites.items.length) : '--';
      panel('overview').innerHTML = `
        <div class="admin-overview">
          ${summary.consolePasswordEmpty ? '<div class="card admin-warning-card">未设置后台密码：局域网内任何人都可能登录访问，请到“服务配置”设置密码。</div>' : ''}
          <section class="card admin-overview-section admin-overview-primary">
            <div class="admin-section-head"><h3>运行概览</h3><span class="muted">服务端实时状态</span></div>
            <div class="grid stats admin-stat-grid">
              <div class="stat admin-stat"><div class="muted">运行状态</div><div class="v">${escapeHtml(summary.statusText)}</div></div>
              <div class="stat admin-stat"><div class="muted">漫画项目数</div><div class="v">${number(summary.comicCount)}</div></div>
              <div class="stat admin-stat"><div class="muted">已配置资源根</div><div class="v">${number(summary.libraryRootCount)}</div></div>
              <div class="stat admin-stat"><div class="muted">累计请求数</div><div class="v">${number(summary.totalRequests)}</div></div>
            </div>
          </section>
          <section class="card admin-overview-section">
            <div class="admin-section-head"><h3>服务说明</h3></div>
            <div class="muted">${escapeHtml(summary.message)}</div>
          </section>
          <section class="card admin-overview-section">
            <div class="admin-section-head"><h3>当前资源概览</h3><span class="muted">扫描与资源根</span></div>
            <div class="grid stats admin-stat-grid">
              <div class="stat admin-stat admin-stat-compact"><div class="muted">扫描时间</div><div class="v">${escapeHtml(resources.generatedAt)}</div></div>
              <div class="stat admin-stat admin-stat-compact"><div class="muted">总图片体积</div><div class="v">${formatBytes(summary.resourceBytes ?? resources.totalBytes)}</div></div>
              <div class="stat admin-stat admin-stat-compact"><div class="muted">可用 / 缺失资源根</div><div class="v">${number(summary.availableLibraryRootCount)} / ${number(summary.missingLibraryRootCount)}</div></div>
              <div class="stat admin-stat"><div class="muted">活动连接</div><div class="v">${number(summary.activeConnections)}</div></div>
            </div>
          </section>
          <section class="card admin-overview-section">
            <div class="admin-section-head"><h3>管理快捷统计</h3><span class="muted">加载后更新</span></div>
            <div class="grid stats admin-stat-grid">
              <div class="stat admin-stat"><div class="muted">回收站项数</div><div class="v">${trashCount}</div></div>
              <div class="stat admin-stat"><div class="muted">收藏夹数</div><div class="v">${folderCount}</div></div>
              <div class="stat admin-stat"><div class="muted">图片收藏</div><div class="v">${imageFavoriteCount}</div></div>
              <div class="stat admin-stat admin-stat-compact"><div class="muted">未加载显示</div><div class="v">--</div></div>
            </div>
          </section>
          <section class="card admin-overview-section">
            <div class="admin-section-head"><h3>快速访问</h3><span class="muted">常用服务信息</span></div>
            <div class="grid stats admin-stat-grid">
              <div class="stat admin-stat admin-stat-compact"><div class="muted">状态接口</div><div class="v">${escapeHtml(summary.statusUrl || '/status')}</div></div>
              <div class="stat admin-stat admin-stat-compact"><div class="muted">后台地址</div><div class="v">${escapeHtml(summary.adminUrl || '/')}</div></div>
              <div class="stat admin-stat admin-stat-compact"><div class="muted">启动时间</div><div class="v">${escapeHtml(summary.startedAt || '--')}</div></div>
              <div class="stat admin-stat admin-stat-compact"><div class="muted">日志记录</div><div class="v">${summary.logRequests ? '开启' : '关闭'}</div></div>
            </div>
          </section>
        </div>
      `;
    }

    function renderResources() {
      const resources = state.resources;
      if (!resources) return;
      const items = resources.items || [];
      pruneSelection(state.selectedResources, items.map((item) => item.id));
      const rootsTable = (resources.roots || []).map((root) => `
        <tr>
          <td>${escapeHtml(root.title)}</td>
          <td>${root.exists ? '<span class="ok">存在</span>' : '<span class="bad">不存在</span>'}</td>
          <td>${number(root.itemCount)}</td>
          <td>${formatBytes(root.totalBytes)}</td>
          <td>${escapeHtml(root.path)}</td>
        </tr>
      `).join('');
      const itemsTable = items.map((item) => `
        <tr>
          <td><input class="admin-row-check admin-resource-check" type="checkbox" data-id="${escapeAttr(item.id)}" ${state.selectedResources.has(item.id) ? 'checked' : ''}></td>
          <td>${escapeHtml(item.title)}<div class="muted">${escapeHtml(item.subtitle || item.sourceDisplayName || '')}</div></td>
          <td>${number(item.imageCount)}</td>
          <td>${formatBytes(item.totalBytes)}</td>
          <td>${escapeHtml(item.path)}</td>
          <td>
            <div class="toolbar admin-row-actions">
              <button class="ghost" type="button" data-resource-trash="${escapeAttr(item.id)}">移入回收站</button>
              <button class="ghost danger" type="button" data-resource-delete="${escapeAttr(item.id)}">直接删除</button>
            </div>
          </td>
        </tr>
      `).join('');
      const allChecked = items.length > 0 && state.selectedResources.size === items.length;
      panel('resources').innerHTML = `
        <div class="card">
          <h3>资源总览</h3>
          <div class="grid stats">
            <div class="stat"><div class="muted">资源根数量</div><div class="v">${number((resources.roots || []).length)}</div></div>
            <div class="stat"><div class="muted">发现项目数</div><div class="v">${number(items.length)}</div></div>
            <div class="stat"><div class="muted">总图片体积</div><div class="v" style="font-size:18px">${formatBytes(resources.totalBytes)}</div></div>
            <div class="stat"><div class="muted">最近扫描</div><div class="v" style="font-size:18px">${escapeHtml(resources.generatedAt)}</div></div>
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
          <div class="admin-card-head">
            <h3>发现到的本地项目</h3>
            <div class="toolbar admin-batch-bar">
              <span class="muted">已选 ${state.selectedResources.size} 项</span>
              <button class="ghost" type="button" data-resource-batch-trash ${state.selectedResources.size ? '' : 'disabled'}>批量移入回收站</button>
              <button class="ghost danger" type="button" data-resource-batch-delete ${state.selectedResources.size ? '' : 'disabled'}>批量直接删除</button>
            </div>
          </div>
          <table>
            <thead><tr><th><input class="admin-resource-check-all" type="checkbox" ${allChecked ? 'checked' : ''}></th><th>标题</th><th>图片数</th><th>体积</th><th>路径</th><th>操作</th></tr></thead>
            <tbody>${itemsTable || '<tr><td colspan="6" class="muted">当前没有发现可服务的本地漫画资源</td></tr>'}</tbody>
          </table>
        </div>
      `;
      bindResources();
    }

    function bindResources() {
      const wrap = panel('resources');
      wrap.querySelector('.admin-resource-check-all')?.addEventListener('change', (event) => {
        state.selectedResources.clear();
        if (event.currentTarget.checked) {
          (state.resources.items || []).forEach((item) => state.selectedResources.add(item.id));
        }
        renderResources();
      });
      wrap.querySelectorAll('.admin-resource-check').forEach((input) => {
        input.addEventListener('change', (event) => {
          const id = event.currentTarget.dataset.id;
          if (event.currentTarget.checked) state.selectedResources.add(id);
          else state.selectedResources.delete(id);
          renderResources();
        });
      });
      wrap.querySelectorAll('[data-resource-trash]').forEach((button) => {
        button.addEventListener('click', (event) => withButtonBusy(event.currentTarget, () => trashResources([event.currentTarget.dataset.resourceTrash])));
      });
      wrap.querySelectorAll('[data-resource-delete]').forEach((button) => {
        button.addEventListener('click', (event) => withButtonBusy(event.currentTarget, () => deleteResources([event.currentTarget.dataset.resourceDelete])));
      });
      wrap.querySelector('[data-resource-batch-trash]')?.addEventListener('click', (event) => withButtonBusy(event.currentTarget, () => trashResources(Array.from(state.selectedResources))));
      wrap.querySelector('[data-resource-batch-delete]')?.addEventListener('click', (event) => withButtonBusy(event.currentTarget, () => deleteResources(Array.from(state.selectedResources))));
    }

    async function trashResources(ids) {
      const itemIds = ids.filter(Boolean);
      if (!itemIds.length) return;
      if (!confirm(`确定将 ${itemIds.length} 个本地项目移入回收站？`)) return;
      try {
        const result = await api.post('/api/library/items/batch-trash', { itemIds });
        notifyBatchResult(result, '移入回收站');
        if (state.trash.loaded) await loadTrash();
        await refreshResourcesAndSummary();
      } catch (error) {
        setError(error instanceof Error ? error.message : String(error || '移入回收站失败'));
      }
    }

    async function deleteResources(ids) {
      const itemIds = ids.filter(Boolean);
      if (!itemIds.length) return;
      if (!confirm(`确定直接删除 ${itemIds.length} 个本地项目？此操作不可恢复。`)) return;
      try {
        const result = await api.post('/api/library/items/batch-delete', { itemIds });
        notifyBatchResult(result, '直接删除');
        await refreshResourcesAndSummary();
      } catch (error) {
        setError(error instanceof Error ? error.message : String(error || '直接删除失败'));
      }
    }

    function renderTrash() {
      const box = panel('trash');
      if (state.trash.loading) {
        box.innerHTML = '<div class="card muted">正在加载回收站...</div>';
        return;
      }
      if (state.trash.error) {
        box.innerHTML = retryCard(state.trash.error, 'data-trash-refresh');
        box.querySelector('[data-trash-refresh]').addEventListener('click', (event) => withButtonBusy(event.currentTarget, loadTrash));
        return;
      }
      if (!state.trash.loaded) {
        box.innerHTML = '<div class="card muted">切换到回收站后加载数据。</div>';
        return;
      }
      const items = state.trash.items || [];
      pruneSelection(state.selectedTrash, items.map((item) => item.id));
      const allChecked = items.length > 0 && state.selectedTrash.size === items.length;
      const rows = items.map((item) => `
        <tr>
          <td><input class="admin-row-check admin-trash-check" type="checkbox" data-id="${escapeAttr(item.id)}" ${state.selectedTrash.has(item.id) ? 'checked' : ''}></td>
          <td>${thumbHtml(item.coverUrl, item.title, 'admin-trash-thumb')}</td>
          <td>
            <strong>${escapeHtml(item.title || item.id)}</strong>
            <div class="muted">${escapeHtml(item.subtitle || item.sourceDisplayName || '')}</div>
          </td>
          <td><span class="badge">${escapeHtml(item.source || '--')}</span></td>
          <td>${number(item.imageCount)}</td>
          <td>${formatBytes(item.totalBytes ?? item.sizeBytes)}</td>
          <td>${escapeHtml(item.deletedAt || '--')}</td>
          <td>
            <div class="toolbar admin-row-actions">
              <button class="ghost" type="button" data-trash-restore="${escapeAttr(item.id)}">恢复</button>
              <button class="ghost danger" type="button" data-trash-purge="${escapeAttr(item.id)}">彻底删除</button>
            </div>
          </td>
        </tr>
      `).join('');
      box.innerHTML = `
        <div class="card">
          <div class="admin-card-head">
            <h3>回收站</h3>
            <div class="toolbar admin-batch-bar">
              <button class="ghost" type="button" data-trash-refresh>刷新</button>
              <span class="muted">共 ${items.length} 项，已选 ${state.selectedTrash.size} 项</span>
              <button class="ghost" type="button" data-trash-batch-restore ${state.selectedTrash.size ? '' : 'disabled'}>批量恢复</button>
              <button class="ghost danger" type="button" data-trash-batch-purge ${state.selectedTrash.size ? '' : 'disabled'}>批量彻底删除</button>
            </div>
          </div>
          <table>
            <thead><tr><th><input class="admin-trash-check-all" type="checkbox" ${allChecked ? 'checked' : ''}></th><th>封面</th><th>标题</th><th>来源</th><th>图数</th><th>体积</th><th>删除时间</th><th>操作</th></tr></thead>
            <tbody>${rows || '<tr><td colspan="8" class="muted">回收站为空</td></tr>'}</tbody>
          </table>
        </div>
      `;
      bindTrash();
    }

    function bindTrash() {
      const wrap = panel('trash');
      wrap.querySelector('[data-trash-refresh]')?.addEventListener('click', (event) => withButtonBusy(event.currentTarget, loadTrash));
      wrap.querySelector('.admin-trash-check-all')?.addEventListener('change', (event) => {
        state.selectedTrash.clear();
        if (event.currentTarget.checked) state.trash.items.forEach((item) => state.selectedTrash.add(item.id));
        renderTrash();
      });
      wrap.querySelectorAll('.admin-trash-check').forEach((input) => {
        input.addEventListener('change', (event) => {
          const id = event.currentTarget.dataset.id;
          if (event.currentTarget.checked) state.selectedTrash.add(id);
          else state.selectedTrash.delete(id);
          renderTrash();
        });
      });
      wrap.querySelectorAll('[data-trash-restore]').forEach((button) => {
        button.addEventListener('click', (event) => withButtonBusy(event.currentTarget, () => restoreTrash([event.currentTarget.dataset.trashRestore], false)));
      });
      wrap.querySelectorAll('[data-trash-purge]').forEach((button) => {
        button.addEventListener('click', (event) => withButtonBusy(event.currentTarget, () => purgeTrash([event.currentTarget.dataset.trashPurge], false)));
      });
      wrap.querySelector('[data-trash-batch-restore]')?.addEventListener('click', (event) => withButtonBusy(event.currentTarget, () => restoreTrash(Array.from(state.selectedTrash), true)));
      wrap.querySelector('[data-trash-batch-purge]')?.addEventListener('click', (event) => withButtonBusy(event.currentTarget, () => purgeTrash(Array.from(state.selectedTrash), true)));
    }

    async function restoreTrash(ids, batch) {
      const trashIds = ids.filter(Boolean);
      if (!trashIds.length) return;
      if (!confirm(`确定恢复 ${trashIds.length} 个回收站项目？`)) return;
      try {
        const result = batch || trashIds.length > 1
          ? await api.post('/api/library/trash/batch-restore', { trashIds })
          : await api.post(`/api/library/trash/${encodeURIComponent(trashIds[0])}/restore`);
        notifyBatchResult(result, '恢复');
        await loadTrash();
        await refreshSummaryOnly();
      } catch (error) {
        setError(error instanceof Error ? error.message : String(error || '恢复失败'));
      }
    }

    async function purgeTrash(ids, batch) {
      const trashIds = ids.filter(Boolean);
      if (!trashIds.length) return;
      if (!confirm(`确定彻底删除 ${trashIds.length} 个回收站项目？此操作不可恢复。`)) return;
      try {
        const result = batch || trashIds.length > 1
          ? await api.post('/api/library/trash/batch-purge', { trashIds })
          : await api.del(`/api/library/trash/${encodeURIComponent(trashIds[0])}`);
        notifyBatchResult(result, '彻底删除');
        await loadTrash();
        await refreshSummaryOnly();
      } catch (error) {
        setError(error instanceof Error ? error.message : String(error || '彻底删除失败'));
      }
    }

    function renderFavorites() {
      const box = panel('favorites');
      if (state.favorites.loading && !state.favorites.loaded) {
        box.innerHTML = '<div class="card muted">正在加载收藏夹...</div>';
        return;
      }
      if (state.favorites.error) {
        box.innerHTML = retryCard(state.favorites.error, 'data-fav-refresh');
        box.querySelector('[data-fav-refresh]').addEventListener('click', (event) => withButtonBusy(event.currentTarget, loadFavorites));
        return;
      }
      if (!state.favorites.loaded) {
        box.innerHTML = '<div class="card muted">切换到收藏夹后加载数据。</div>';
        return;
      }
      const selected = state.favorites.selectedFolder;
      const folders = state.favorites.folders || [];
      const items = state.favorites.itemsByFolder.get(selected) || [];
      const folderList = folders.map((folder) => `
        <div class="admin-fav-folder ${folder.name === selected ? 'active' : ''}" data-fav-folder="${escapeAttr(folder.name)}">
          <button class="ghost admin-fav-folder-name" type="button" data-fav-select="${escapeAttr(folder.name)}">
            <strong>${escapeHtml(folder.name)}</strong>
            <span class="muted">${number(folder.count)} 项</span>
          </button>
          <div class="toolbar admin-row-actions">
            <button class="ghost" type="button" data-fav-rename="${escapeAttr(folder.name)}">重命名</button>
            <button class="ghost danger" type="button" data-fav-delete="${escapeAttr(folder.name)}">删除</button>
          </div>
        </div>
      `).join('');
      const itemList = items.map((item) => `
        <div class="admin-fav-item">
          ${thumbHtml(item.coverUrl, item.name, 'admin-fav-thumb')}
          <div class="admin-fav-info">
            <strong>${escapeHtml(item.name || item.target)}</strong>
            <div class="muted">${escapeHtml(item.author || item.type || '')}</div>
            <div class="admin-tags">${(item.tags || []).slice(0, 6).map((tag) => `<span class="badge">${escapeHtml(tag)}</span>`).join('')}</div>
          </div>
          <button class="ghost danger" type="button" data-fav-item-delete="${escapeAttr(item.target)}" data-type="${escapeAttr(item.type)}">删除</button>
        </div>
      `).join('');
      box.innerHTML = `
        <div class="card">
          <div class="admin-card-head">
            <h3>收藏夹</h3>
            <div class="toolbar">
              <button class="action" type="button" data-fav-create>新建收藏夹</button>
              <button class="ghost" type="button" data-fav-refresh>刷新</button>
            </div>
          </div>
          <div class="admin-fav-layout">
            <div class="admin-fav-folders">
              ${folderList || '<div class="muted">暂无收藏夹</div>'}
            </div>
            <div class="admin-fav-content">
              ${selected ? `<div class="admin-card-head"><h3>${escapeHtml(selected)}</h3><button class="ghost" type="button" data-fav-items-refresh>刷新内容</button></div>` : '<div class="muted">请选择或新建收藏夹。</div>'}
              ${state.favorites.itemLoading ? '<div class="muted">正在加载收藏内容...</div>' : ''}
              ${state.favorites.itemError ? `<div class="card admin-inline-error">${escapeHtml(state.favorites.itemError)} <button class="ghost" type="button" data-fav-items-refresh>重试</button></div>` : ''}
              ${selected && !state.favorites.itemLoading && !state.favorites.itemError ? `<div class="admin-fav-items">${itemList || '<div class="muted">当前收藏夹为空</div>'}</div>` : ''}
            </div>
          </div>
        </div>
      `;
      bindFavorites();
    }

    function bindFavorites() {
      const wrap = panel('favorites');
      wrap.querySelector('[data-fav-refresh]')?.addEventListener('click', (event) => withButtonBusy(event.currentTarget, loadFavorites));
      wrap.querySelectorAll('[data-fav-items-refresh]').forEach((button) => {
        button.addEventListener('click', (event) => withButtonBusy(event.currentTarget, () => loadFavoriteItems(state.favorites.selectedFolder)));
      });
      wrap.querySelector('[data-fav-create]')?.addEventListener('click', (event) => withButtonBusy(event.currentTarget, createFavoriteFolder));
      wrap.querySelectorAll('[data-fav-select]').forEach((button) => {
        button.addEventListener('click', async (event) => {
          const folder = event.currentTarget.dataset.favSelect;
          state.favorites.selectedFolder = folder;
          renderFavorites();
          if (!state.favorites.itemsByFolder.has(folder)) await loadFavoriteItems(folder);
        });
      });
      wrap.querySelectorAll('[data-fav-rename]').forEach((button) => {
        button.addEventListener('click', (event) => withButtonBusy(event.currentTarget, () => renameFavoriteFolder(event.currentTarget.dataset.favRename)));
      });
      wrap.querySelectorAll('[data-fav-delete]').forEach((button) => {
        button.addEventListener('click', (event) => withButtonBusy(event.currentTarget, () => deleteFavoriteFolder(event.currentTarget.dataset.favDelete)));
      });
      wrap.querySelectorAll('[data-fav-item-delete]').forEach((button) => {
        button.addEventListener('click', (event) => withButtonBusy(event.currentTarget, () => deleteFavoriteItem(
          state.favorites.selectedFolder,
          event.currentTarget.dataset.favItemDelete,
          event.currentTarget.dataset.type,
        )));
      });
    }

    async function createFavoriteFolder() {
      const name = prompt('请输入新收藏夹名称：', '');
      if (!name || !name.trim()) return;
      if (!confirm(`确定新建收藏夹“${name.trim()}”？`)) return;
      try {
        await api.post('/api/library/favorites', { name: name.trim() });
        state.favorites.selectedFolder = name.trim();
        await loadFavorites();
      } catch (error) {
        setError(error instanceof Error ? error.message : String(error || '新建收藏夹失败'));
      }
    }

    async function renameFavoriteFolder(folder) {
      const newName = prompt('请输入新的收藏夹名称：', folder);
      if (!newName || !newName.trim() || newName.trim() === folder) return;
      if (!confirm(`确定将收藏夹“${folder}”重命名为“${newName.trim()}”？`)) return;
      try {
        await api.put(`/api/library/favorites/${encodeURIComponent(folder)}`, { newName: newName.trim() });
        const oldItems = state.favorites.itemsByFolder.get(folder);
        state.favorites.itemsByFolder.delete(folder);
        if (oldItems) state.favorites.itemsByFolder.set(newName.trim(), oldItems);
        state.favorites.selectedFolder = newName.trim();
        await loadFavorites();
      } catch (error) {
        setError(error instanceof Error ? error.message : String(error || '重命名收藏夹失败'));
      }
    }

    async function deleteFavoriteFolder(folder) {
      if (!folder) return;
      if (!confirm(`确定删除收藏夹“${folder}”？夹内收藏关系会被清空。`)) return;
      try {
        await api.del(`/api/library/favorites/${encodeURIComponent(folder)}`);
        state.favorites.itemsByFolder.delete(folder);
        if (state.favorites.selectedFolder === folder) state.favorites.selectedFolder = '';
        await loadFavorites();
      } catch (error) {
        setError(error instanceof Error ? error.message : String(error || '删除收藏夹失败'));
      }
    }

    async function deleteFavoriteItem(folder, target, type) {
      if (!folder || !target) return;
      if (!confirm('确定从当前收藏夹删除这条收藏？')) return;
      try {
        const query = type == null || String(type).trim() === '' ? '' : `?type=${encodeURIComponent(type)}`;
        await api.del(`/api/library/favorites/${encodeURIComponent(folder)}/${encodeURIComponent(target)}${query}`);
        state.favorites.itemsByFolder.delete(folder);
        await loadFavorites();
        await loadFavoriteItems(folder);
      } catch (error) {
        setError(error instanceof Error ? error.message : String(error || '删除收藏失败'));
      }
    }

    function renderImageFavorites() {
      const box = panel('image-favorites');
      if (state.imageFavorites.loading) {
        box.innerHTML = '<div class="card muted">正在加载图片收藏...</div>';
        return;
      }
      if (state.imageFavorites.error) {
        box.innerHTML = retryCard(state.imageFavorites.error, 'data-imgfav-refresh');
        box.querySelector('[data-imgfav-refresh]').addEventListener('click', (event) => withButtonBusy(event.currentTarget, loadImageFavorites));
        return;
      }
      if (!state.imageFavorites.loaded) {
        box.innerHTML = '<div class="card muted">切换到图片收藏后加载数据。</div>';
        return;
      }
      const items = state.imageFavorites.items || [];
      const cards = items.map((item) => `
        <div class="card admin-imgfav-card">
          ${thumbHtml(item.imageUrl, item.title, 'admin-imgfav-thumb')}
          <strong>${escapeHtml(item.title || item.id)}</strong>
          <div class="muted">EP ${escapeHtml(item.ep ?? '--')} · Page ${escapeHtml(item.page ?? '--')}</div>
          ${item.otherInfo ? `<div class="muted">${escapeHtml(item.otherInfo)}</div>` : ''}
          <button class="ghost danger" type="button" data-imgfav-delete="${escapeAttr(item.id)}" data-ep="${escapeAttr(item.ep)}" data-page="${escapeAttr(item.page)}">删除</button>
        </div>
      `).join('');
      box.innerHTML = `
        <div class="card">
          <div class="admin-card-head">
            <h3>图片收藏</h3>
            <div class="toolbar"><button class="ghost" type="button" data-imgfav-refresh>刷新</button></div>
          </div>
          ${cards ? `<div class="admin-imgfav-grid">${cards}</div>` : '<div class="muted">暂无图片收藏</div>'}
        </div>
      `;
      bindImageFavorites();
    }

    function bindImageFavorites() {
      const wrap = panel('image-favorites');
      wrap.querySelector('[data-imgfav-refresh]')?.addEventListener('click', (event) => withButtonBusy(event.currentTarget, loadImageFavorites));
      wrap.querySelectorAll('[data-imgfav-delete]').forEach((button) => {
        button.addEventListener('click', (event) => withButtonBusy(event.currentTarget, () => deleteImageFavorite(
          event.currentTarget.dataset.imgfavDelete,
          event.currentTarget.dataset.ep,
          event.currentTarget.dataset.page,
        )));
      });
    }

    async function deleteImageFavorite(id, ep, page) {
      if (!id) return;
      if (!confirm('确定删除这条图片收藏？')) return;
      try {
        await api.del(`/api/library/image-favorites/${encodeURIComponent(id)}/${encodeURIComponent(ep)}/${encodeURIComponent(page)}`);
        await loadImageFavorites();
      } catch (error) {
        setError(error instanceof Error ? error.message : String(error || '删除图片收藏失败'));
      }
    }

    function renderConfig() {
      if (!state.config || !state.summary) return;
      const config = state.config;
      const summary = state.summary;
      panel('config').innerHTML = `
        <form class="card admin-config-form">
          <h3>服务配置</h3>
          <div class="form-grid">
            <label>监听 Host
              <input id="cfg-host" value="${escapeAttr(config.host)}" placeholder="0.0.0.0">
            </label>
            <label>监听 Port
              <input id="cfg-port" type="number" min="1" max="65535" value="${number(config.port)}">
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
            <label>后台密码（留空表示不设防）
              <input id="cfg-console-password" type="password" value="${escapeAttr(config.consolePassword || '')}" autocomplete="new-password">
            </label>
            <div class="muted" style="margin-top:8px">当前为空密码时，登录接口会直接签发 token，并在页面显示风险提示。</div>
          </div>
          <div style="margin-top:14px">
            <label><input id="cfg-log-requests" type="checkbox" ${config.logRequests ? 'checked' : ''} style="width:auto; margin-right:8px;"> 记录请求日志</label>
          </div>
          <div style="margin-top:16px" class="toolbar">
            <button class="action" type="submit">保存配置</button>
            <span class="muted">提示：host/port 改动保存后需要重启服务才能完全生效；Host 留空会按 0.0.0.0 保存。</span>
          </div>
        </form>
        <div class="card">
          <h3>当前生效信息</h3>
          <table>
            <tbody>
              <tr><th>后台地址</th><td>${escapeHtml(summary.adminUrl || '/')}</td></tr>
              <tr><th>状态接口</th><td>${escapeHtml(summary.statusUrl || '/status')}</td></tr>
              <tr><th>配置文件</th><td>${escapeHtml(summary.configPath || '--')}</td></tr>
              <tr><th>日志记录</th><td>${summary.logRequests ? '开启' : '关闭'}</td></tr>
            </tbody>
          </table>
        </div>
      `;
      bindConfigForm();
    }

    function renderLogs() {
      const logs = (state.logs && state.logs.logs) || [];
      const types = Array.from(new Set(logs.map((log) => log.type).filter(Boolean)));
      const keyword = state.logsFilter.keyword.toLowerCase();
      const filtered = logs.filter((log) => {
        const typeOk = state.logsFilter.type === 'all' || log.type === state.logsFilter.type;
        const text = `${log.time} ${log.type} ${log.message}`.toLowerCase();
        return typeOk && (!keyword || text.includes(keyword));
      });
      const text = filtered.map((log) => `[${log.time}] [${log.type}] ${log.message}`).join('\n');
      panel('logs').innerHTML = `
        <div class="card">
          <div class="admin-card-head">
            <h3>最近日志</h3>
            <div class="toolbar admin-log-tools">
              <button class="ghost" type="button" data-logs-refresh>刷新日志</button>
              <select data-log-type>
                <option value="all">全部级别</option>
                ${types.map((type) => `<option value="${escapeAttr(type)}" ${state.logsFilter.type === type ? 'selected' : ''}>${escapeHtml(type)}</option>`).join('')}
              </select>
              <input data-log-keyword value="${escapeAttr(state.logsFilter.keyword)}" placeholder="关键词过滤">
            </div>
          </div>
          <pre class="admin-log-pre">${escapeHtml(text || '当前暂无日志输出')}</pre>
        </div>
      `;
      bindLogs();
      const pre = panel('logs').querySelector('.admin-log-pre');
      pre.scrollTop = pre.scrollHeight;
    }

    function bindLogs() {
      const wrap = panel('logs');
      wrap.querySelector('[data-logs-refresh]')?.addEventListener('click', (event) => withButtonBusy(event.currentTarget, async () => {
        await loadLogs();
        renderLogs();
      }));
      wrap.querySelector('[data-log-type]')?.addEventListener('change', (event) => {
        state.logsFilter.type = event.currentTarget.value;
        renderLogs();
      });
      wrap.querySelector('[data-log-keyword]')?.addEventListener('input', (event) => {
        state.logsFilter.keyword = event.currentTarget.value;
        renderLogs();
      });
    }

    function renderEndpoints() {
      if (!state.summary) return;
      const summary = state.summary;
      const endpoints = [
        'GET /status',
        'GET /',
        'POST /api/console/login',
        'GET /api/remote/proxy',
        'GET /api/events',
        'GET /api/admin/status',
        'GET /api/admin/summary',
        'GET /api/admin/resources',
        'GET /api/admin/config',
        'PUT /api/admin/config',
        'GET /api/admin/logs',
        'POST /api/admin/scan',
        'GET /api/library/items',
        'POST /api/library/items/batch-trash',
        'POST /api/library/items/batch-delete',
        'POST /api/library/items/refresh',
        'GET /api/library/trash',
        'POST /api/library/trash/{id}/restore',
        'DELETE /api/library/trash/{id}',
        'POST /api/library/trash/batch-restore',
        'POST /api/library/trash/batch-purge',
        'GET /api/library/favorites',
        'POST /api/library/favorites',
        'GET /api/library/favorites/{folder}',
        'PUT /api/library/favorites/{folder}',
        'DELETE /api/library/favorites/{folder}',
        'DELETE /api/library/favorites/{folder}/{target}',
        'GET /api/library/image-favorites',
        'DELETE /api/library/image-favorites/{id}/{ep}/{page}',
      ];
      panel('endpoints').innerHTML = `
        <div class="card">
          <h3>当前接口</h3>
          <div class="admin-endpoint-list">${endpoints.map((endpoint) => `<div class="badge">${escapeHtml(endpoint)}</div>`).join('')}</div>
        </div>
        <div class="card">
          <h3>主要地址</h3>
          <table>
            <tbody>
              <tr><th>后台</th><td>${escapeHtml(summary.adminUrl || '/')}</td></tr>
              <tr><th>状态</th><td>${escapeHtml(summary.statusUrl || '/status')}</td></tr>
              <tr><th>概览</th><td>/api/admin/summary</td></tr>
              <tr><th>资源</th><td>/api/admin/resources</td></tr>
            </tbody>
          </table>
        </div>
      `;
    }
  }

  function notifyBatchResult(result, action) {
    if (!result || !Array.isArray(result.failed) || result.failed.length === 0) return;
    const failed = result.failed.map((item) => item.id || item.title || item.error || JSON.stringify(item)).join('\n');
    alert(`${action}完成，但有 ${result.failed.length} 项失败：\n${failed}`);
  }

  function pruneSelection(selection, allowedIds) {
    const allowed = new Set(allowedIds.filter(Boolean));
    Array.from(selection).forEach((id) => {
      if (!allowed.has(id)) selection.delete(id);
    });
  }

  function retryCard(message, actionAttr) {
    return `<div class="card admin-inline-error"><div>${escapeHtml(message)}</div><button class="ghost" type="button" ${actionAttr}>重试</button></div>`;
  }

  function thumbHtml(path, title, className) {
    if (!path) return `<div class="${className} admin-thumb-placeholder">无图</div>`;
    const src = window.PicaKeepConsole.api.imageUrl(path);
    return `<img class="${className}" src="${escapeAttr(src)}" alt="${escapeAttr(title || 'cover')}" onerror="this.style.display='none';this.nextElementSibling.hidden=false"><div class="${className} admin-thumb-placeholder" hidden>无图</div>`;
  }

  function formatBytes(bytes) {
    if (!bytes) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    let value = Number(bytes) || 0;
    let index = 0;
    while (value >= 1024 && index < units.length - 1) {
      value /= 1024;
      index++;
    }
    return `${value.toFixed(value >= 10 || index === 0 ? 0 : 1)} ${units[index]}`;
  }

  function escapeHtml(value) {
    return String(value ?? '')
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
  }

  function escapeAttr(value) { return escapeHtml(value).replaceAll("'", '&#39;'); }
  function number(value) { return Number(value || 0); }

  window.renderAdmin = renderAdmin;
})();
