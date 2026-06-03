(function () {
  'use strict';

  const readerModeKey = 'pk-console-reader-mode';
  const readerPrefsKey = 'pk-console-reader-prefs-v1';
  const gridViewModeKey = 'pk-console-grid-view-mode';
  const cleanupByRoot = new WeakMap();
  const readerGestureConfig = Object.freeze({
    tapSlopMouse: 6,
    tapSlopTouch: 12,
    swipeDistance: 48,
    swipeDominance: 1.35,
  });
  const sourceOptions = [
    { value: 'local', label: '本地' },
    { value: 'merged', label: '聚合' },
    { value: 'remote', label: '远程' },
  ];

  function renderApp(rootEl) {
    const previousCleanup = cleanupByRoot.get(rootEl);
    if (previousCleanup) previousCleanup();

    const consoleApi = window.PicaKeepConsole;
    const disposers = [];
    const state = {
      view: { name: 'dashboard', params: {} },
      history: [],
      dashboard: { loading: false, error: '', items: [], historySessionKey: '', historyLoadingForToken: '' },
      grid: { loading: false, error: '', warning: '', items: [], query: '', source: consoleApi.source.get(), filter: 'all', viewMode: readGridViewMode() },
      inspector: { open: false, loading: false, error: '', item: null, params: null, requestId: 0 },
      imageFavorites: { loading: false, error: '', items: [] },
      detail: { loading: false, error: '', item: null, recommendationsLoading: false, recommendationsError: '', recommendations: [] },
      reader: { loading: false, error: '', item: null, episode: null, episodeIndex: 0, pageIndex: 0, mode: readReaderMode(), prefs: readReaderPrefs(), chromeVisible: false, settingsOpen: false, chaptersOpen: false, methodPickerOpen: false, historyTimer: null, autoTurnTimer: null, lastHistoryKey: '', favoriteSaving: false, adapter: null, pages: [], pageSizes: [], resizeRaf: 0, longPressTimer: null, tapTimer: null, gesture: null, activePointers: new Set(), zoom: defaultReaderZoomState(), drawPaged: null },
      requestId: 0,
      readerCleanup: null,
      toastTimer: null,
    };

    rootEl.innerHTML = `
      <div class="app-shell">
        <div class="app-main-toolbar card">
          <div class="app-toolbar-row">
            <div class="app-source-switch" role="group" aria-label="数据源">
              ${sourceOptions.map((option) => `<button type="button" data-source="${option.value}">${option.label}</button>`).join('')}
            </div>
            <label class="app-remote-box">
              <span class="muted">远程地址</span>
              <input class="app-remote-input" type="url" placeholder="http://192.168.1.10:9527" value="${escapeAttr(consoleApi.remoteTarget.get())}">
            </label>
            <label class="app-search-box">
              <span class="muted">搜索</span>
              <input class="app-search-input" type="search" placeholder="标题 / 副标题 / 标签">
            </label>
            <div class="app-view-switch" role="group" aria-label="视图切换" hidden>
              <button type="button" data-grid-view="poster">▦ 卡片</button>
              <button type="button" data-grid-view="detailed">☰ 详细</button>
            </div>
            <button class="ghost app-refresh" type="button">刷新</button>
            <span class="app-count muted">--</span>
          </div>
          <div class="app-warning" hidden></div>
        </div>
        <div id="app-view" class="app-view"></div>
        <div id="app-item-panel-root" class="app-item-panel-root"></div>
      </div>
    `;

    const viewEl = rootEl.querySelector('#app-view');
    const panelRoot = rootEl.querySelector('#app-item-panel-root');
    const warningEl = rootEl.querySelector('.app-warning');
    const countEl = rootEl.querySelector('.app-count');
    const viewSwitchEl = rootEl.querySelector('.app-view-switch');
    const remoteInput = rootEl.querySelector('.app-remote-input');
    const searchInput = rootEl.querySelector('.app-search-input');

    function cleanup() {
      cleanupReader();
      setReaderRouteActive(false);
      if (state.toastTimer) window.clearTimeout(state.toastTimer);
      disposers.splice(0).forEach((dispose) => {
        try { dispose(); } catch (error) { console.error(error); }
      });
      rootEl.innerHTML = '';
      cleanupByRoot.delete(rootEl);
    }

    function setReaderRouteActive(active) {
      rootEl.classList.toggle('is-reader-route', active);
      document.documentElement.classList.toggle('pk-reader-active', active);
      document.body.classList.toggle('pk-reader-active', active);
      window.dispatchEvent(new CustomEvent('pk-console-reader-route', { detail: { active } }));
    }

    function syncReaderRoute() {
      setReaderRouteActive(state.view.name === 'reader');
    }
    cleanupByRoot.set(rootEl, cleanup);

    rootEl.querySelectorAll('[data-source]').forEach((button) => {
      button.addEventListener('click', () => consoleApi.source.set(button.dataset.source));
    });
    viewSwitchEl.querySelectorAll('[data-grid-view]').forEach((button) => {
      button.addEventListener('click', () => {
        state.grid.viewMode = normalizeGridViewMode(button.dataset.gridView);
        writeGridViewMode(state.grid.viewMode);
        updateToolbar();
        if (state.view.name === 'grid') renderGridContent();
      });
    });
    rootEl.querySelector('.app-refresh').addEventListener('click', () => reloadCurrent());
    remoteInput.addEventListener('change', () => {
      consoleApi.remoteTarget.set(remoteInput.value.trim());
      if (usesRemote(consoleApi.source.get())) goGrid(true);
    });
    remoteInput.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') {
        event.preventDefault();
        remoteInput.blur();
        consoleApi.remoteTarget.set(remoteInput.value.trim());
        if (usesRemote(consoleApi.source.get())) goGrid(true);
      }
    });
    searchInput.addEventListener('input', () => {
      state.grid.query = searchInput.value.trim();
      if (state.view.name === 'grid') renderGridContent();
    });
    disposers.push(consoleApi.source.onChange(() => {
      if (state.view.name === 'dashboard') renderDashboard();
      else goGrid(true);
    }));
    let lastAuthToken = consoleApi.auth.token() || '';
    disposers.push(consoleApi.auth.onChange(() => {
      const nextToken = consoleApi.auth.token() || '';
      if (nextToken === lastAuthToken) return;
      lastAuthToken = nextToken;
      state.dashboard.items = [];
      state.dashboard.error = '';
      state.dashboard.historySessionKey = '';
      state.dashboard.historyLoadingForToken = '';
      if (state.view.name === 'dashboard' && nextToken) renderDashboard();
      else if (state.view.name === 'dashboard') renderHistoryStrip();
    }));

    disposers.push(() => closeItemPanel());
    const onGlobalKeydown = (event) => {
      if (event.key !== 'Escape') return;
      const target = event.target;
      if (target && target.closest && target.closest('input, textarea, select, [contenteditable="true"]')) return;

      if (state.view.name === 'reader' && (state.reader.settingsOpen || state.reader.chaptersOpen)) {
        event.preventDefault();
        event.stopPropagation();
        state.reader.settingsOpen = false;
        state.reader.chaptersOpen = false;
        state.reader.chromeVisible = false;
        renderReaderContent(state.view.params);
        return;
      }

      if (state.view.name === 'reader' && state.reader.chromeVisible) {
        event.preventDefault();
        event.stopPropagation();
        setReaderChromeVisible(false);
        return;
      }

      if (state.inspector.open) {
        event.preventDefault();
        event.stopPropagation();
        closeItemPanel();
        return;
      }

      if (state.view.name === 'reader') {
        event.preventDefault();
        event.stopPropagation();
        back();
        return;
      }

      if (state.view.name !== 'dashboard' || state.history.length) {
        event.preventDefault();
        event.stopPropagation();
        back();
      }
    };
    document.addEventListener('keydown', onGlobalKeydown, true);
    disposers.push(() => document.removeEventListener('keydown', onGlobalKeydown, true));

    updateToolbar();
    goDashboard(true);

    function updateToolbar() {
      syncReaderRoute();
      const toolbar = rootEl.querySelector('.app-main-toolbar');
      if (toolbar) toolbar.hidden = state.view.name === 'reader';
      const currentSource = consoleApi.source.get();
      rootEl.querySelectorAll('[data-source]').forEach((button) => {
        button.classList.toggle('active', button.dataset.source === currentSource);
      });
      remoteInput.disabled = !usesRemote(currentSource);
      remoteInput.placeholder = usesRemote(currentSource) ? 'http://192.168.1.10:9527' : '当前源不需要远程地址';
      if (state.view.name === 'dashboard') {
        searchInput.disabled = true;
      } else {
        searchInput.disabled = state.view.name !== 'grid';
      }
      viewSwitchEl.hidden = state.view.name !== 'grid';
      viewSwitchEl.querySelectorAll('[data-grid-view]').forEach((button) => {
        button.classList.toggle('active', button.dataset.gridView === state.grid.viewMode);
      });
      countEl.textContent = state.view.name === 'grid' ? gridToolbarSummary() : viewTitle(state.view);
      if (state.grid.warning) {
        warningEl.hidden = false;
        warningEl.textContent = state.grid.warning;
      } else {
        warningEl.hidden = true;
        warningEl.textContent = '';
      }
    }

    function navigate(name, params, push) {
      cleanupReader();
      closeItemPanel();
      if (push) state.history.push(state.view);
      state.view = { name, params: params || {} };
      updateToolbar();
      if (name === 'dashboard') renderDashboard();
      if (name === 'grid') renderGrid(params || {});
      if (name === 'imageFavorites') renderImageFavorites();
      if (name === 'detail') renderDetail(params || {});
      if (name === 'reader') renderReader(params || {});
    }

    function back() {
      const previous = state.history.pop();
      if (!previous) {
        goDashboard(false);
        return;
      }
      navigate(previous.name, previous.params, false);
    }

    function goDashboard(clearHistory) {
      cleanupReader();
      closeItemPanel();
      if (clearHistory) state.history = [];
      state.view = { name: 'dashboard', params: {} };
      updateToolbar();
      renderDashboard();
    }

    async function renderDashboard() {
      cleanupReader();
      state.dashboard.loading = true;
      state.dashboard.error = '';
      updateToolbar();
      viewEl.innerHTML = `
        <div class="app-dashboard">
          <section class="app-outlined-card app-history-card">
            <div class="app-card-head app-history-head" data-history-title role="button" tabindex="0">
              <span class="app-head-icon">🕘</span>
              <span>
                <strong>历史记录(${number((state.dashboard.items || []).length)})</strong>
                <span class="muted">点击封面续读上次位置</span>
              </span>
              <button class="ghost app-head-action" type="button" data-history-refresh aria-label="刷新历史记录">↻</button>
              <span class="app-chevron">›</span>
            </div>
            <div class="app-history-strip"><div class="app-history-empty"><span class="app-history-empty-icon">▱</span><strong>正在加载阅读历史...</strong><span class="muted">请稍候</span></div></div>
          </section>

          <section class="app-dashboard-columns">
            <div class="app-entry-grid">
              <button class="app-outlined-card app-entry-card app-comics-entry" type="button" data-open-comics>
                <span class="app-entry-icon">▤</span>
                <span class="app-entry-text">
                  <strong>已下载</strong>
                  <span class="muted">${entrySubtitle('comics')}</span>
                </span>
                <span class="app-chevron">›</span>
              </button>
              <button class="app-outlined-card app-entry-card app-library-entry" type="button" data-open-albums>
                <span class="app-entry-icon">▦</span>
                <span class="app-entry-text">
                  <strong>图集</strong>
                  <span class="muted">${entrySubtitle('albums')}</span>
                </span>
                <span class="app-chevron">›</span>
              </button>
              <button class="app-outlined-card app-entry-card app-resource-entry" type="button" data-open-grid>
                <span class="app-entry-icon">☁</span>
                <span class="app-entry-text">
                  <strong>资源库</strong>
                  <span class="muted">${entrySubtitle('all')}</span>
                </span>
                <span class="app-chevron">›</span>
              </button>
              <button class="app-outlined-card app-entry-card" type="button" data-open-image-favorites>
                <span class="app-entry-icon">🖼</span>
                <span class="app-entry-text">
                  <strong>图片收藏</strong>
                  <span class="muted">读取真实图片收藏缩略图</span>
                </span>
                <span class="app-chevron">›</span>
              </button>
            </div>

            <section class="app-outlined-card app-tools-card">
              <div class="app-card-head">
                <span class="app-head-icon">🛠</span>
                <span>
                  <strong>工具</strong>
                  <span class="muted">常用网页操作快捷入口</span>
                </span>
                <span class="app-chevron">›</span>
              </div>
              <div class="app-quick-actions">
                <button class="app-quick-chip" type="button" data-open-albums>▦ 图集</button>
                <button class="app-quick-chip" type="button" data-history-refresh>🕘 历史</button>
                <button class="app-quick-chip" type="button" data-open-grid>☁ 资源库</button>
                <button class="app-quick-chip" type="button" data-open-image-favorites>🖼 图片</button>
              </div>
            </section>
          </section>
        </div>
      `;
      viewEl.querySelectorAll('[data-open-grid]').forEach((button) => button.addEventListener('click', () => navigate('grid', { filter: 'all' }, true)));
      viewEl.querySelectorAll('[data-open-comics]').forEach((button) => button.addEventListener('click', () => navigate('grid', { filter: 'comics' }, true)));
      viewEl.querySelectorAll('[data-open-albums]').forEach((button) => button.addEventListener('click', () => navigate('grid', { filter: 'albums' }, true)));
      viewEl.querySelectorAll('[data-open-image-favorites]').forEach((button) => button.addEventListener('click', () => navigate('imageFavorites', {}, true)));
      viewEl.querySelectorAll('[data-history-refresh]').forEach((button) => button.addEventListener('click', (event) => {
        event.stopPropagation();
        renderDashboard();
      }));
      const historyTitle = viewEl.querySelector('[data-history-title]');
      if (historyTitle) {
        historyTitle.addEventListener('click', () => viewEl.querySelector('.app-history-strip')?.scrollIntoView({ block: 'nearest' }));
        historyTitle.addEventListener('keydown', (event) => {
          if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            historyTitle.click();
          }
        });
      }
      try {
        const currentSource = consoleApi.source.get();
        const hasGridForSource = state.grid.source === currentSource && state.grid.items.length;
        const [historyResult, itemsResult] = await Promise.all([
          loadDashboardHistory(),
          hasGridForSource ? Promise.resolve({ ok: true, value: { skip: true } }) : settle(fetchItemsForSource(currentSource)),
        ]);
        if (state.view.name !== 'dashboard') return;
        if (itemsResult.ok && !itemsResult.value.skip) {
          state.grid.source = currentSource;
          state.grid.items = itemsResult.value.items;
          state.grid.warning = itemsResult.value.warning;
        }
        renderEntryCards();
        if (historyResult.ok) {
          state.dashboard.items = normalizeHistoryPayload(historyResult.value);
          renderHistoryTitle();
          renderHistoryStrip();
        } else {
          state.dashboard.error = errorMessage(historyResult.error);
          renderHistoryTitle();
          renderHistoryStrip();
        }
      } finally {
        state.dashboard.loading = false;
        updateToolbar();
      }
    }

    function renderHistoryTitle() {
      const title = viewEl.querySelector('[data-history-title] strong');
      if (title) title.textContent = `历史记录(${number((state.dashboard.items || []).length)})`;
    }

    function loadDashboardHistory() {
      const token = consoleApi.auth.token() || 'legacy';
      state.dashboard.historyLoadingForToken = token;
      return settle(consoleApi.history.list(20)).then((result) => {
        if (result.ok && state.dashboard.historyLoadingForToken === token) {
          state.dashboard.historySessionKey = token;
        }
        return result;
      });
    }

    function gridToolbarSummary() {
      const filtered = visibleGridItems(state.grid.items, state.grid.filter, state.grid.query);
      const scopedTotal = gridItemsForFilter(state.grid.items, state.grid.filter).length;
      return `${gridFilterTitle(state.grid.filter)} · ${sourceLabel(consoleApi.source.get())} · ${number(filtered.length)} / ${number(scopedTotal)} 项`;
    }

    function entrySubtitle(filter) {
      const counts = gridCounts(state.grid.items);
      const hasCounts = state.grid.source === consoleApi.source.get() && counts.total;
      if (!hasCounts) return '点击加载';
      if (filter === 'comics') return `共 ${number(counts.comics)} 部漫画`;
      if (filter === 'albums') return `共 ${number(counts.albums)} 个图集`;
      return `共 ${number(counts.total)} 个资源`;
    }

    function renderEntryCards() {
      const comicsEntry = viewEl.querySelector('.app-comics-entry .muted');
      if (comicsEntry) comicsEntry.textContent = entrySubtitle('comics');
      const libraryEntry = viewEl.querySelector('.app-library-entry .muted');
      if (libraryEntry) libraryEntry.textContent = entrySubtitle('albums');
      const resourceEntry = viewEl.querySelector('.app-resource-entry .muted');
      if (resourceEntry) resourceEntry.textContent = entrySubtitle('all');
    }

    function renderHistoryStrip() {
      const strip = viewEl.querySelector('.app-history-strip');
      if (!strip) return;
      if (state.dashboard.error) {
        strip.innerHTML = `<div class="app-history-empty">历史服务未就绪：${escapeHtml(state.dashboard.error)}</div>`;
        return;
      }
      const items = state.dashboard.items || [];
      if (!items.length) {
        strip.innerHTML = '<div class="app-history-empty"><span class="app-history-empty-icon">▱</span><strong>暂无历史记录</strong><span class="muted">打开一本漫画后，这里会显示上次阅读位置。</span></div>';
        return;
      }
      strip.innerHTML = items.map((item) => historyCardHtml(item)).join('');
      strip.querySelectorAll('[data-open-history]').forEach((card) => {
        card.addEventListener('click', () => openHistory(card.dataset.openHistory));
      });
      bindImageFallbacks(strip);
    }

    function openHistory(target) {
      const record = (state.dashboard.items || []).find((item) => item.target === target);
      if (!record) return;
      navigate('reader', {
        id: record.target,
        origin: 'local',
        episodeIndex: numberValue(record.ep),
        pageIndex: numberValue(record.page),
      }, true);
    }

    function goGrid(clearHistory, params) {
      if (clearHistory) state.history = [];
      closeItemPanel();
      state.grid.source = consoleApi.source.get();
      state.grid.filter = normalizeGridFilter(params && params.filter);
      state.view = { name: 'grid', params: { filter: state.grid.filter } };
      updateToolbar();
      renderGrid(state.view.params);
    }

    function reloadCurrent() {
      if (state.view.name === 'dashboard') {
        renderDashboard();
      } else if (state.view.name === 'grid') {
        renderGrid(state.view.params);
      } else if (state.view.name === 'imageFavorites') {
        renderImageFavorites();
      } else if (state.view.name === 'detail') {
        renderDetail(state.view.params);
      } else if (state.view.name === 'reader') {
        renderReader(state.view.params);
      }
    }

    async function renderGrid(params) {
      cleanupReader();
      state.grid.filter = normalizeGridFilter(params && params.filter);
      state.view.params = { filter: state.grid.filter };
      state.grid.loading = true;
      state.grid.error = '';
      state.grid.warning = '';
      updateToolbar();
      viewEl.innerHTML = loadingCard('正在加载漫画列表...');
      const requestId = ++state.requestId;
      try {
        const source = consoleApi.source.get();
        remoteInput.value = consoleApi.remoteTarget.get();
        const result = await fetchItemsForSource(source);
        if (requestId !== state.requestId || state.view.name !== 'grid') return;
        state.grid.items = result.items;
        state.grid.source = source;
        state.grid.warning = result.warning;
      } catch (error) {
        if (requestId !== state.requestId || state.view.name !== 'grid') return;
        state.grid.error = errorMessage(error);
        state.grid.source = consoleApi.source.get();
        state.grid.items = [];
      } finally {
        if (requestId !== state.requestId || state.view.name !== 'grid') return;
        state.grid.loading = false;
        renderGridContent();
      }
    }

    function renderGridContent() {
      updateToolbar();
      if (state.grid.error) {
        viewEl.innerHTML = retryCard(state.grid.error, 'data-grid-retry');
        viewEl.querySelector('[data-grid-retry]').addEventListener('click', () => renderGrid(state.view.params));
        if (usesRemote(consoleApi.source.get()) && /远程地址/.test(state.grid.error)) remoteInput.focus();
        return;
      }
      const items = visibleGridItems(state.grid.items, state.grid.filter, state.grid.query);
      const scopedTotal = gridItemsForFilter(state.grid.items, state.grid.filter).length;
      const gridTitle = gridFilterTitle(state.grid.filter);
      if (!items.length) {
        viewEl.innerHTML = `
          <div class="app-list-view">
            <div class="app-view-head app-grid-view-head">
              <button class="ghost" type="button" data-back>← 返回</button>
              <strong>${escapeHtml(gridTitle)}</strong>
            </div>
            <div class="card app-empty">
              <div class="brand">${scopedTotal ? '没有匹配结果' : `暂无${escapeHtml(gridTitle)}`}</div>
              <div class="sub">${scopedTotal ? '换个关键词试试。' : '当前数据源没有返回可浏览项目。'}</div>
            </div>
          </div>
        `;
        viewEl.querySelector('[data-back]').addEventListener('click', back);
        return;
      }
      const listMode = state.grid.viewMode === 'detailed';
      viewEl.innerHTML = `
        <div class="app-list-view">
          <div class="app-view-head app-grid-view-head">
            <button class="ghost" type="button" data-back>← 返回</button>
            <strong>${escapeHtml(gridTitle)}</strong>
          </div>
          <div class="${listMode ? 'app-detailed-grid' : 'app-grid'}">
            ${items.map((item) => listMode ? gridDetailedCardHtml(item) : gridCardHtml(item)).join('')}
          </div>
        </div>
      `;
      viewEl.querySelector('[data-back]').addEventListener('click', back);
      viewEl.querySelectorAll('[data-open-detail]').forEach((card) => {
        card.addEventListener('click', () => openItemPanel({ id: card.dataset.openDetail, origin: card.dataset.origin }));
        card.addEventListener('keydown', (event) => {
          if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            card.click();
          }
        });
      });
      bindImageFallbacks(viewEl);
    }


    async function openItemPanel(params) {
      const requestId = ++state.inspector.requestId;
      state.inspector.open = true;
      state.inspector.loading = true;
      state.inspector.error = '';
      state.inspector.item = null;
      state.inspector.params = params || {};
      renderItemPanel();
      try {
        const adapter = buildAdapter(params.origin);
        const raw = await adapter.fetchDetail(params.id);
        if (requestId !== state.inspector.requestId || !state.inspector.open) return;
        state.inspector.item = normalizeItem(raw.item || raw, adapter, params.origin);
      } catch (error) {
        if (requestId !== state.inspector.requestId || !state.inspector.open) return;
        state.inspector.error = errorMessage(error);
      } finally {
        if (requestId !== state.inspector.requestId || !state.inspector.open) return;
        state.inspector.loading = false;
        renderItemPanel();
      }
    }

    function closeItemPanel() {
      if (!state.inspector.open && !panelRoot.innerHTML) return;
      state.inspector.open = false;
      state.inspector.loading = false;
      state.inspector.error = '';
      state.inspector.item = null;
      state.inspector.params = null;
      state.inspector.requestId += 1;
      panelRoot.innerHTML = '';
    }

    function renderItemPanel() {
      if (!state.inspector.open) {
        panelRoot.innerHTML = '';
        return;
      }
      const item = state.inspector.item;
      const params = state.inspector.params || {};
      const panelClass = isMobilePanel() ? 'app-item-panel-sheet' : 'app-item-panel-side';
      const panelChrome = `
        <div class="app-panel-grip" aria-hidden="true"></div>
        <div class="app-panel-head">
          <span class="app-panel-kicker">漫画信息</span>
          <button class="ghost app-panel-close" type="button" data-panel-close aria-label="关闭漫画信息">×</button>
        </div>
      `;
      panelRoot.innerHTML = `
        <div class="app-item-panel-backdrop" data-panel-close></div>
        <aside class="app-item-panel ${panelClass}" role="dialog" aria-modal="true" aria-label="漫画信息">
          ${state.inspector.loading ? `<div class="app-panel-content app-panel-content-state">${panelChrome}${loadingCard('正在加载漫画信息...')}</div>` : ''}
          ${state.inspector.error ? `<div class="app-panel-content app-panel-content-state">${panelChrome}${retryCard(state.inspector.error, 'data-panel-retry')}</div>` : ''}
          ${item ? itemPanelContentHtml(item) : ''}
        </aside>
      `;
      panelRoot.querySelectorAll('[data-panel-close]').forEach((button) => button.addEventListener('click', closeItemPanel));
      panelRoot.querySelector('[data-panel-retry]')?.addEventListener('click', () => openItemPanel(params));
      panelRoot.querySelector('[data-panel-detail]')?.addEventListener('click', () => {
        closeItemPanel();
        navigate('detail', { id: item.id, origin: item.__origin }, true);
      });
      panelRoot.querySelector('[data-panel-read]')?.addEventListener('click', () => {
        const episode = (item.episodes && item.episodes[0]) || makeFallbackEpisode(item);
        closeItemPanel();
        navigate('reader', { id: item.id, origin: item.__origin, item, episodeIndex: 0, episode, pageList: episode.pages && episode.pages.length ? episode.pages : null, pageSizes: episode.pageSizes || [] }, true);
      });
      panelRoot.querySelectorAll('[data-read-episode]').forEach((button) => {
        button.addEventListener('click', () => {
          const episodeIndex = Number(button.dataset.readEpisode || 0);
          const episode = (item.episodes || [])[episodeIndex] || makeFallbackEpisode(item);
          closeItemPanel();
          navigate('reader', { id: item.id, origin: item.__origin, item, episodeIndex, episode, pageList: episode.pages && episode.pages.length ? episode.pages : null, pageSizes: episode.pageSizes || [] }, true);
        });
      });
      bindImageFallbacks(panelRoot);
    }

    function itemPanelContentHtml(item) {
      const episodes = item.episodes.length ? item.episodes : [makeFallbackEpisode(item)];
      const primaryEpisode = episodes[0] || makeFallbackEpisode(item);
      const totalPages = episodes.reduce((sum, episode) => sum + numberValue(episode.imageCount || episode.pages.length), 0) || numberValue(item.imageCount);
      const visibleTags = (item.tags || []).slice(0, 8);
      const hiddenTagCount = Math.max(0, (item.tags || []).length - visibleTags.length);
      const sourceName = item.sourceDisplayName || originLabel(item.__origin);
      const displayId = item.displayId && item.displayId !== item.id ? item.displayId : '';
      return `
        <div class="app-panel-content">
          <div class="app-panel-grip" aria-hidden="true"></div>
          <div class="app-panel-head">
            <span class="app-panel-kicker">${escapeHtml(sourceName)}</span>
            <button class="ghost app-panel-close" type="button" data-panel-close aria-label="关闭漫画信息">×</button>
          </div>
          <section class="app-panel-hero app-panel-hero-app">
            <div class="app-panel-cover-wrap">${coverHtml(item, 'app-panel-cover')}</div>
            <div class="app-panel-info">
              ${displayId ? `<p class="app-panel-kicker">${escapeHtml(displayId)}</p>` : ''}
              <h2>${escapeHtml(item.title || item.id)}</h2>
              <p class="app-panel-subtitle muted">${escapeHtml(item.subtitle || sourceName || '')}</p>
              <div class="app-panel-meta-chips">
                <span class="badge">${originLabel(item.__origin)}</span>
                <span>${number(episodes.length)} 章</span>
                <span>${number(totalPages)} 图</span>
                <span>${formatBytes(item.totalBytes)}</span>
              </div>
            </div>
          </section>
          ${visibleTags.length ? `<section class="app-panel-tags" aria-label="标签">${visibleTags.map((tag) => `<span>${escapeHtml(tag)}</span>`).join('')}${hiddenTagCount ? `<span>+${hiddenTagCount}</span>` : ''}</section>` : ''}
          <section class="app-panel-episodes">
            <div class="app-panel-section-title"><strong>章节</strong><span>${number(episodes.length)} 章</span></div>
            <div class="app-panel-episode-list">
              ${episodes.map((episode, index) => `<button class="app-panel-episode ${index === 0 ? 'active' : ''}" type="button" data-read-episode="${index}"><span><strong>${escapeHtml(episode.title || `第 ${index + 1} 章`)}</strong></span><small>${index === 0 ? '当前' : `${number(episode.imageCount || episode.pages.length)} 图`}</small></button>`).join('')}
            </div>
          </section>
          <footer class="app-panel-footer">
            <button class="ghost" type="button" data-panel-detail>查看详情</button>
            <button class="action" type="button" data-panel-read>开始阅读</button>
          </footer>
        </div>
      `;
    }

    function isMobilePanel() {
      return !!(window.matchMedia && window.matchMedia('(max-width: 760px)').matches);
    }

    async function renderImageFavorites() {
      cleanupReader();
      state.imageFavorites.loading = true;
      state.imageFavorites.error = '';
      updateToolbar();
      viewEl.innerHTML = loadingCard('正在加载图片收藏...');
      const requestId = ++state.requestId;
      try {
        const data = await consoleApi.api.get('/api/library/image-favorites');
        if (requestId !== state.requestId || state.view.name !== 'imageFavorites') return;
        state.imageFavorites.items = normalizeImageFavoritesPayload(data);
      } catch (error) {
        if (requestId !== state.requestId || state.view.name !== 'imageFavorites') return;
        state.imageFavorites.error = errorMessage(error);
        state.imageFavorites.items = [];
      } finally {
        if (requestId !== state.requestId || state.view.name !== 'imageFavorites') return;
        state.imageFavorites.loading = false;
        renderImageFavoritesContent();
      }
    }

    function renderImageFavoritesContent() {
      updateToolbar();
      if (state.imageFavorites.error) {
        viewEl.innerHTML = retryCard(state.imageFavorites.error, 'data-image-favorites-retry', true);
        viewEl.querySelector('[data-back]').addEventListener('click', back);
        viewEl.querySelector('[data-image-favorites-retry]').addEventListener('click', renderImageFavorites);
        return;
      }
      const items = state.imageFavorites.items || [];
      viewEl.innerHTML = `
        <div class="app-list-view">
          <div class="app-view-head">
            <button class="ghost" type="button" data-back>← 返回</button>
            <div class="muted">${number(items.length)} 张图片收藏 · 真数据</div>
          </div>
          ${items.length ? `
            <div class="app-imgfav-grid">
              ${items.map((item) => imageFavoriteCardHtml(item)).join('')}
            </div>
          ` : `
            <div class="card app-empty">
              <div class="brand">暂无图片收藏</div>
              <div class="sub">收藏图片后，这里会显示真实缩略图。</div>
            </div>
          `}
        </div>
      `;
      viewEl.querySelector('[data-back]').addEventListener('click', back);
      viewEl.querySelectorAll('[data-open-image]').forEach((button) => {
        button.addEventListener('click', () => {
          const item = items.find((candidate) => candidate.__key === button.dataset.openImage);
          if (item && item.imageUrl) window.open(consoleApi.api.imageUrl(item.imageUrl), '_blank', 'noopener');
        });
      });
      bindImageFallbacks(viewEl);
    }

    async function renderDetail(params) {
      cleanupReader();
      state.detail.loading = true;
      state.detail.error = '';
      state.detail.item = null;
      updateToolbar();
      viewEl.innerHTML = loadingCard('正在加载详情...');
      const requestId = ++state.requestId;
      try {
        const adapter = buildAdapter(params.origin);
        const raw = await adapter.fetchDetail(params.id);
        if (requestId !== state.requestId || state.view.name !== 'detail') return;
        state.detail.item = normalizeItem(raw.item || raw, adapter, params.origin);
      } catch (error) {
        if (requestId !== state.requestId || state.view.name !== 'detail') return;
        state.detail.error = errorMessage(error);
      } finally {
        if (requestId !== state.requestId || state.view.name !== 'detail') return;
        state.detail.loading = false;
        renderDetailContent(params);
      }
    }

    function renderDetailContent(params) {
      updateToolbar();
      if (state.detail.error) {
        viewEl.innerHTML = retryCard(state.detail.error, 'data-detail-retry', true);
        viewEl.querySelector('[data-back]').addEventListener('click', back);
        viewEl.querySelector('[data-detail-retry]').addEventListener('click', () => renderDetail(params));
        return;
      }
      const item = state.detail.item;
      if (!item) return;
      const episodes = item.episodes.length ? item.episodes : [makeFallbackEpisode(item)];
      const totalPages = episodes.reduce((sum, ep) => sum + numberValue(ep.imageCount || ep.pages.length), 0) || numberValue(item.imageCount);
      viewEl.innerHTML = `
        <div class="app-detail-page">
          <div class="app-detail-sticky-head">
            <button class="ghost" type="button" data-back>← 返回</button>
            <strong>${escapeHtml(item.title || item.id)}</strong>
            <span class="muted">${originLabel(item.__origin)}</span>
          </div>
          <section class="card app-detail-info-hero">
            ${coverHtml(item, 'app-detail-cover-large')}
            <div class="app-detail-main">
              <h1>${escapeHtml(item.title || item.id)}</h1>
              <div class="sub">${escapeHtml(item.subtitle || item.sourceDisplayName || '')}</div>
              <div class="app-detail-chip-row">
                <span class="badge">${escapeHtml(item.sourceDisplayName || originLabel(item.__origin))}</span>
                <span class="badge">${number(episodes.length)} 章</span>
                <span class="badge">${number(totalPages)} 图</span>
                <span class="badge">${formatBytes(item.totalBytes)}</span>
              </div>
              <div class="app-detail-actions">
                <button class="action" type="button" data-read-episode="0">开始阅读</button>
                <button class="ghost" type="button" data-copy-title>复制标题</button>
              </div>
            </div>
          </section>
          <section class="card app-detail-section">
            <div class="app-section-head"><h3>信息</h3><span class="muted">本地条目详情</span></div>
            <div class="app-info-groups">
              ${infoChipHtml('ID', item.displayId || item.id)}
              ${infoChipHtml('作者/副标题', item.subtitle)}
              ${infoChipHtml('漫画源', item.sourceDisplayName || originLabel(item.__origin))}
              ${infoChipHtml('更新时间', item.updatedAt)}
              ${infoChipHtml('路径', item.path)}
              ${(item.tags || []).map((tag) => infoChipHtml('标签', tag)).join('')}
            </div>
          </section>
          <section class="card app-detail-section">
            <div class="app-section-head"><h3>章节</h3><span class="muted">共 ${number(episodes.length)} 章</span></div>
            <div class="app-episode-grid">
              ${episodes.map((episode, index) => `<button class="app-episode-tile" type="button" data-read-episode="${index}"><strong>${escapeHtml(episode.title || `第 ${index + 1} 章`)}</strong><span class="muted">${number(episode.imageCount || episode.pages.length)} 图 · ${formatBytes(episode.totalBytes)}</span></button>`).join('')}
            </div>
          </section>
          <section class="card app-detail-section app-recommendation-section">
            <div class="app-section-head"><h3>相关推荐</h3><button class="ghost" type="button" data-recommend-refresh>刷新</button></div>
            <div class="app-recommendation-body">${recommendationBodyHtml()}</div>
          </section>
        </div>
      `;
      viewEl.querySelector('[data-back]').addEventListener('click', back);
      viewEl.querySelector('[data-copy-title]')?.addEventListener('click', () => navigator.clipboard?.writeText(item.title || item.id));
      viewEl.querySelector('[data-recommend-refresh]')?.addEventListener('click', () => loadRecommendations(item));
      viewEl.querySelectorAll('[data-read-episode]').forEach((button) => {
        button.addEventListener('click', () => {
          const episodeIndex = Number(button.dataset.readEpisode || 0);
          const episode = episodes[episodeIndex] || episodes[0];
          navigate('reader', { id: item.id, origin: item.__origin, item, episodeIndex, episode, pageList: episode.pages && episode.pages.length ? episode.pages : null, pageSizes: episode.pageSizes || [] }, true);
        });
      });
      bindRecommendationClicks(item.__origin);
      bindImageFallbacks(viewEl);
      if (!state.detail.recommendations.length && !state.detail.recommendationsLoading) loadRecommendations(item);
    }

    async function loadRecommendations(item) {
      state.detail.recommendationsLoading = true;
      state.detail.recommendationsError = '';
      renderRecommendationBody();
      try {
        if (item.__origin === 'remote') throw new Error('remote fallback');
        const raw = await consoleApi.api.get(`/api/library/items/${encodeURIComponent(item.id)}/recommendations?limit=10`);
        state.detail.recommendations = normalizeRecommendationPayload(raw, buildAdapter(item.__origin), item.__origin);
      } catch (error) {
        state.detail.recommendations = fallbackRecommendations(item);
        state.detail.recommendationsError = state.detail.recommendations.length ? '' : errorMessage(error);
      } finally {
        state.detail.recommendationsLoading = false;
        renderRecommendationBody();
      }
    }

    function renderRecommendationBody() {
      const body = viewEl.querySelector('.app-recommendation-body');
      if (!body) return;
      body.innerHTML = recommendationBodyHtml();
      bindRecommendationClicks((state.detail.item && state.detail.item.__origin) || 'local');
      bindImageFallbacks(body);
    }

    function recommendationBodyHtml() {
      if (state.detail.recommendationsLoading) return loadingCard('正在生成推荐...');
      if (state.detail.recommendationsError) return `<div class="app-history-empty">暂无可推荐的本地漫画：${escapeHtml(state.detail.recommendationsError)}</div>`;
      const items = state.detail.recommendations || [];
      if (!items.length) return '<div class="app-history-empty">暂无可推荐的本地漫画</div>';
      return `<div class="app-recommendation-grid">${items.map(recommendationCardHtml).join('')}</div>`;
    }

    function bindRecommendationClicks(origin) {
      viewEl.querySelectorAll('[data-open-recommendation]').forEach((card) => {
        card.addEventListener('click', () => navigate('detail', { id: card.dataset.openRecommendation, origin: card.dataset.origin || origin }, true));
      });
    }

    function fallbackRecommendations(item) {
      const currentId = item && item.id;
      return (state.grid.items || [])
        .filter((candidate) => candidate.id && candidate.id !== currentId && candidate.__origin === item.__origin)
        .map((candidate) => Object.assign({}, candidate, { reason: recommendationReason(item, candidate), score: recommendationScore(item, candidate) }))
        .filter((candidate) => candidate.score > 0)
        .sort((a, b) => b.score - a.score)
        .slice(0, 10);
    }

    function recommendationScore(a, b) {
      const at = normalizeRecommendText(a.title);
      const bt = normalizeRecommendText(b.title);
      let score = 0;
      if (at && bt && (at.includes(bt) || bt.includes(at))) score += 80;
      (a.tags || []).forEach((tag) => { if ((b.tags || []).includes(tag)) score += 16; });
      if (a.subtitle && b.subtitle && a.subtitle === b.subtitle) score += 24;
      return score;
    }

    function recommendationReason(a, b) {
      if ((a.tags || []).some((tag) => (b.tags || []).includes(tag))) return '同标签';
      if (a.subtitle && b.subtitle && a.subtitle === b.subtitle) return '同作者/来源';
      return '名称相似';
    }

    async function renderReader(params) {
      cleanupReader();
      state.reader.loading = true;
      state.reader.error = '';
      state.reader.item = params.item || null;
      state.reader.episode = params.episode || null;
      state.reader.episodeIndex = numberValue(params.episodeIndex);
      state.reader.pageIndex = Math.max(0, numberValue(params.pageIndex));
      state.reader.prefs = readReaderPrefs();
      state.reader.mode = state.reader.prefs.readingMethod;
      state.reader.chromeVisible = !!state.reader.prefs.chromeVisible;
      state.reader.settingsOpen = false;
      state.reader.chaptersOpen = false;
      updateToolbar();
      viewEl.innerHTML = loadingCard('正在打开阅读器...');
      const requestId = ++state.requestId;
      try {
        const adapter = buildAdapter(params.origin);
        let item = params.item;
        let episode = params.episode;
        const episodeIndex = numberValue(params.episodeIndex);
        if (!item) {
          const rawDetail = await adapter.fetchDetail(params.id);
          item = normalizeItem(rawDetail.item || rawDetail, adapter, params.origin);
          episode = item.episodes[episodeIndex] || item.episodes[0] || makeFallbackEpisode(item);
        }
        const resolvedEpisodeIndex = resolveEpisodeIndex(item, episode, episodeIndex);
        if (!episode || !Array.isArray(episode.pages) || !episode.pages.length) {
          const rawEpisode = await adapter.fetchEpisode(params.id, resolvedEpisodeIndex);
          episode = normalizeEpisode(rawEpisode.episode || rawEpisode, resolvedEpisodeIndex);
        }
        if (requestId !== state.requestId || state.view.name !== 'reader') return;
        state.reader.item = item;
        state.reader.episode = episode;
        state.reader.episodeIndex = resolveEpisodeIndex(item, episode, episodeIndex);
        if (!episode.pages.length) throw new Error('章节没有可阅读图片');
        writeReaderHistoryNow();
      } catch (error) {
        if (requestId !== state.requestId || state.view.name !== 'reader') return;
        state.reader.error = errorMessage(error);
      } finally {
        if (requestId !== state.requestId || state.view.name !== 'reader') return;
        state.reader.loading = false;
        renderReaderContent(params);
      }
    }

    function renderReaderContent(params) {
      updateToolbar();
      disposeReaderBindings();
      if (state.reader.error) {
        viewEl.innerHTML = retryCard(state.reader.error, 'data-reader-retry', true);
        viewEl.querySelector('[data-back]').addEventListener('click', back);
        viewEl.querySelector('[data-reader-retry]').addEventListener('click', () => renderReader(params));
        return;
      }
      const item = state.reader.item;
      const episode = state.reader.episode;
      const pages = episode.pages || [];
      const adapter = buildAdapter(item.__origin || params.origin);
      const total = pages.length;
      const safeIndex = clamp(state.reader.pageIndex, 0, total - 1);
      state.reader.pageIndex = safeIndex;
      state.reader.prefs = readReaderPrefs();
      state.reader.mode = state.reader.prefs.readingMethod;
      state.reader.chromeVisible = !!(state.reader.chromeVisible || state.reader.settingsOpen || state.reader.chaptersOpen);
      const episodeIndex = state.reader.episodeIndex;
      const methodClass = `reader-method-${state.reader.mode}`;
      const chromeClass = state.reader.chromeVisible ? 'reader-chrome-visible' : 'reader-chrome-hidden';
      viewEl.innerHTML = `
        <div class="app-reader ${methodClass} ${chromeClass} ${state.reader.prefs.limitMaxWidth ? 'reader-limit-width' : 'reader-full-width'} ${state.reader.prefs.reduceBrightnessInDarkMode ? 'reader-dim-dark' : ''}" style="--reader-max-width:${clamp(numberValue(state.reader.prefs.maxWidthPx, 980), 600, 1600)}px" data-reader-root>
          <div class="reader-body" data-reader-body></div>
          <div class="reader-topbar reader-chrome" data-reader-chrome>
            <button class="ghost reader-back" type="button" data-reader-back>← 返回</button>
            <div class="reader-title">
              <strong>${escapeHtml(item.title || item.id)}</strong>
              <span class="muted">${escapeHtml(episode.title || `第 ${episodeIndex + 1} 章`)}</span>
            </div>
            <div class="reader-actions">
              <span class="reader-page-count">第 ${safeIndex + 1} / ${total}</span>
              <button class="ghost reader-icon-button" type="button" data-reader-settings aria-label="阅读设置">⚙</button>
            </div>
          </div>
          <div class="reader-page-info" ${state.reader.prefs.showPageInfo ? '' : 'hidden'} data-reader-page-info>第 ${safeIndex + 1} / ${total}</div>
          <div class="reader-bottombar reader-chrome" data-reader-chrome>
            <span class="reader-page-pill" data-reader-page-label>${readerPageLabel()}</span>
            <div class="reader-bottom-row reader-bottom-row-primary">
              <button class="ghost reader-icon-button" type="button" data-reader-chapter-prev aria-label="上一章" title="上一章">⏮</button>
              <label class="reader-slider-wrap" aria-label="阅读进度">
                <input type="range" min="1" max="${Math.max(1, total)}" value="${safeIndex + 1}" data-reader-slider>
              </label>
              <button class="ghost reader-icon-button" type="button" data-reader-chapter-next aria-label="下一章" title="下一章">⏭</button>
            </div>
            <div class="reader-bottom-row reader-bottom-row-tools">
              <button class="ghost reader-icon-button" type="button" data-reader-fullscreen aria-label="全屏" title="全屏">⛶</button>
              <button class="ghost reader-icon-button" type="button" data-reader-favorite aria-label="${state.reader.favoriteSaving ? '收藏中' : '收藏图片'}" title="${state.reader.favoriteSaving ? '收藏中' : '收藏图片'}">♡</button>
              <button class="ghost reader-icon-button" type="button" data-reader-auto aria-label="${state.reader.autoTurnTimer ? '停止自动翻页' : '自动翻页'}" title="${state.reader.autoTurnTimer ? '停止自动翻页' : '自动翻页'}">⏱</button>
              <button class="ghost reader-icon-button" type="button" data-reader-chapters aria-label="章节" title="章节">☷</button>
              <button class="ghost reader-icon-button" type="button" data-reader-download aria-label="保存图片" title="保存图片">⇩</button>
            </div>
          </div>
          <div class="reader-settings-panel" ${state.reader.settingsOpen ? '' : 'hidden'} data-reader-settings-panel>${readerSettingsHtml()}</div>
          <div class="reader-chapters-panel" ${state.reader.chaptersOpen ? '' : 'hidden'} data-reader-chapters-panel>${readerChaptersHtml(item, episodeIndex)}</div>
          <div class="app-toast" hidden></div>
        </div>
      `;
      if (isScrollReaderMode(state.reader.mode)) renderScrollReader(adapter, pages, episode.pageSizes || []);
      else renderPagedReader(adapter, pages, episode.pageSizes || []);
      bindReaderChrome(adapter, pages, params);
      updateReaderPageCount();
    }

    function switchReaderMode(method) {
      const current = currentReaderPage();
      if (current != null) state.reader.pageIndex = current;
      const prefs = readReaderPrefs();
      const next = method || (isScrollReaderMode(prefs.readingMethod) ? 'ltr' : 'scroll-continuous');
      writeReaderPrefs(Object.assign({}, prefs, { readingMethod: next }));
      state.reader.methodPickerOpen = false;
      state.reader.prefs = readReaderPrefs();
      state.reader.mode = state.reader.prefs.readingMethod;
      cleanupReader(false, false);
      renderReaderContent(state.view.params);
      if (isScrollReaderMode(state.reader.mode)) {
        window.requestAnimationFrame(() => scrollToPage(state.reader.pageIndex));
      }
    }

    function renderScrollReader(adapter, pages, pageSizes) {
      const body = viewEl.querySelector('.reader-body');
      body.innerHTML = `<div class="reader-scroll"><div class="reader-zoom-layer" data-reader-zoom-layer><div class="reader-strip">${pages.map((page, index) => scrollPageHtml(adapter, page, pageSizes[index], index)).join('')}</div></div></div>`;
      const pageEls = Array.from(body.querySelectorAll('.reader-page'));
      const images = Array.from(body.querySelectorAll('img[data-src]'));
      const imageObserver = makeObserver((entry) => {
        if (entry.isIntersecting) {
          const img = entry.target;
          setImageSrc(img, img.dataset.src);
          imageObserver.unobserve(img);
        }
      }, '900px 0px');
      const pageObserver = makeObserver((entry) => {
        if (entry.isIntersecting) {
          const index = Number(entry.target.dataset.pageIndex || 0);
          state.reader.pageIndex = index;
          updateReaderPageCount();
          scheduleReaderHistoryWrite();
        }
      }, '-35% 0px -55% 0px');
      const resizeHandler = () => scheduleSnapReaderPageHeights();
      images.forEach((img) => imageObserver.observe(img));
      pageEls.forEach((page) => pageObserver.observe(page));
      bindRetryImages(body);
      bindReaderZoom(body);
      scheduleSnapReaderPageHeights();
      window.addEventListener('resize', resizeHandler);
      state.readerCleanup = () => {
        imageObserver.disconnect();
        pageObserver.disconnect();
        window.removeEventListener('resize', resizeHandler);
        if (state.reader.resizeRaf) window.cancelAnimationFrame(state.reader.resizeRaf);
        if (state.reader.longPressTimer) window.clearTimeout(state.reader.longPressTimer);
        state.reader.resizeRaf = 0;
        state.reader.longPressTimer = null;
      };
      window.requestAnimationFrame(() => scrollToPage(state.reader.pageIndex));
    }

    function renderPagedReader(adapter, pages, pageSizes) {
      const body = viewEl.querySelector('.reader-body');
      drawPaged();

      function drawPaged() {
        const index = clamp(state.reader.pageIndex, 0, pages.length - 1);
        state.reader.pageIndex = index;
        body.innerHTML = `
          <div class="reader-paged">
            <div class="reader-zoom-layer" data-reader-zoom-layer>
              <div class="reader-paged-stage">
                ${pagedReaderImagesHtml(adapter, pages, pageSizes, index)}
              </div>
            </div>
          </div>
        `;
        bindRetryImages(body);
        bindReaderZoom(body);
        updateReaderPageCount();
        scheduleReaderHistoryWrite();
        preload(adapter, pages, index - 1);
        preload(adapter, pages, index + 1);
        if (isTwoPageMode(state.reader.mode)) preload(adapter, pages, index + 2);
      }
      state.reader.drawPaged = drawPaged;
      addReaderCleanup(() => { delete state.reader.drawPaged; });
    }

    function cleanupReader(clearRoute = true, resetPanels = true) {
      state.reader.zoom = defaultReaderZoomState();
      state.reader.lastTapTime = 0;
      resetReaderGesture();
      if (state.reader.historyTimer) {
        window.clearTimeout(state.reader.historyTimer);
        state.reader.historyTimer = null;
      }
      stopAutoTurn(false);
      disposeReaderBindings();
      if (resetPanels) {
        state.reader.settingsOpen = false;
        state.reader.chaptersOpen = false;
      }
      if (clearRoute) setReaderRouteActive(false);
    }

    function disposeReaderBindings() {
      if (state.readerCleanup) {
        try { state.readerCleanup(); } catch (error) { console.error(error); }
        state.readerCleanup = null;
      }
    }

    function addReaderCleanup(dispose) {
      const previous = state.readerCleanup;
      state.readerCleanup = () => {
        if (previous) previous();
        dispose();
      };
    }

    function scheduleReaderHistoryWrite() {
      if (state.reader.historyTimer) window.clearTimeout(state.reader.historyTimer);
      state.reader.historyTimer = window.setTimeout(() => {
        state.reader.historyTimer = null;
        writeReaderHistoryNow();
      }, 1500);
    }

    async function writeReaderHistoryNow() {
      if (!consoleApi.auth.isLoggedIn()) return;
      const item = state.reader.item;
      const episode = state.reader.episode;
      if (!item || !item.id || !episode) return;
      const pages = episode.pages || [];
      const episodeIndex = numberValue(state.reader.episodeIndex);
      const body = {
        target: item.id,
        ep: episodeIndex,
        page: clamp(numberValue(state.reader.pageIndex), 0, Math.max(0, pages.length - 1)),
        maxPage: pages.length,
        readEpisode: [episodeIndex],
        title: item.title || item.id,
        subtitle: episode.title || item.subtitle || item.sourceDisplayName || '',
        cover: item.coverUrl || episode.coverUrl || '',
      };
      const key = `${body.target}:${body.ep}:${body.page}:${body.maxPage}`;
      if (state.reader.lastHistoryKey === key) return;
      state.reader.lastHistoryKey = key;
      try {
        await consoleApi.history.save(body);
      } catch (_) {
        window.setTimeout(() => consoleApi.history.save(body).catch(() => null), 1800);
      }
    }

    function currentScrollPage() {
      const pages = Array.from(viewEl.querySelectorAll('.reader-page'));
      if (!pages.length) return null;
      const top = window.innerHeight * 0.35;
      let best = 0;
      let bestDistance = Infinity;
      pages.forEach((page) => {
        const rect = page.getBoundingClientRect();
        const distance = Math.abs(rect.top - top);
        if (distance < bestDistance) {
          bestDistance = distance;
          best = Number(page.dataset.pageIndex || 0);
        }
      });
      return best;
    }

    function scrollToPage(index) {
      const page = viewEl.querySelector(`.reader-page[data-page-index="${index}"]`);
      if (page) page.scrollIntoView({ block: 'start' });
    }

    function updateReaderPageCount() {
      const total = readerTotalPages();
      const page = clamp(numberValue(state.reader.pageIndex), 0, Math.max(0, total - 1));
      const count = viewEl.querySelector('.reader-page-count');
      const label = viewEl.querySelector('[data-reader-page-label]');
      const info = viewEl.querySelector('[data-reader-page-info]');
      const slider = viewEl.querySelector('[data-reader-slider]');
      if (count) count.textContent = `第 ${page + 1} / ${total}`;
      if (label) label.textContent = readerPageLabel();
      if (info) {
        info.textContent = `第 ${page + 1} / ${total}`;
        info.hidden = !(state.reader.prefs && state.reader.prefs.showPageInfo);
      }
      if (slider) {
        slider.max = String(Math.max(1, total));
        slider.value = String(page + 1);
      }
    }

    function isTwoPageMode(mode) {
      const actual = mode || state.reader.mode;
      return actual === 'two-page' || actual === 'two-page-reversed';
    }

    function readerModeDirection(delta) {
      const mode = state.reader.mode;
      if (mode === 'rtl' || mode === 'two-page-reversed') return -delta;
      return delta;
    }

    function pagedSpread(index, total, mode) {
      const start = clamp(index, 0, Math.max(0, total - 1));
      if (!isTwoPageMode(mode)) return [start];
      const second = start + 1;
      const pages = second < total ? [start, second] : [start];
      return mode === 'two-page-reversed' ? pages.reverse() : pages;
    }

    function scheduleSnapReaderPageHeights() {
      if (state.reader.resizeRaf) return;
      state.reader.resizeRaf = window.requestAnimationFrame(() => {
        state.reader.resizeRaf = 0;
        snapReaderPageHeights();
      });
    }

    function snapReaderPageHeights() {
      const strip = viewEl.querySelector('.reader-strip');
      if (!strip) return;
      const width = strip.getBoundingClientRect().width;
      if (!width) return;
      const ratio = window.devicePixelRatio || 1;
      strip.querySelectorAll('.reader-page[data-width][data-height]').forEach((page) => {
        const sourceWidth = numberValue(page.dataset.width);
        const sourceHeight = numberValue(page.dataset.height);
        if (!sourceWidth || !sourceHeight) return;
        const height = width * sourceHeight / sourceWidth;
        const snapped = Math.max(1, Math.round(height * ratio) / ratio);
        page.style.setProperty('--reader-page-height', `${snapped}px`);
      });
    }

    function bindReaderZoom(root) {
      if (!root) return;
      applyReaderZoomState();
    }

    function defaultReaderZoomState() {
      return { activePageIndex: null, scale: 1, originX: 50, originY: 50, originMode: 'viewport', panX: 0, panY: 0, transientLongPress: false };
    }

    function resetReaderGesture() {
      if (state.reader.longPressTimer) window.clearTimeout(state.reader.longPressTimer);
      if (state.reader.tapTimer) window.clearTimeout(state.reader.tapTimer);
      state.reader.longPressTimer = null;
      state.reader.tapTimer = null;
      state.reader.gesture = null;
    }

    function resetReaderZoom(transientOnly) {
      const zoom = state.reader.zoom || defaultReaderZoomState();
      if (transientOnly && !zoom.transientLongPress) return;
      state.reader.zoom = defaultReaderZoomState();
      applyReaderZoomState();
    }

    function toggleReaderZoomAt(event, page) {
      const prefs = state.reader.prefs || readReaderPrefs();
      if (!prefs.doubleClickZoomEnabled) return false;
      const targetPage = page || pageFromEvent(event) || activeReaderPageElement();
      if (!targetPage) return false;
      const current = state.reader.zoom || defaultReaderZoomState();
      if (current.scale !== 1 && !current.transientLongPress) {
        state.reader.zoom = defaultReaderZoomState();
      } else {
        state.reader.zoom = zoomStateForPoint(targetPage, event, false);
      }
      applyReaderZoomState();
      return true;
    }

    function startReaderLongPressZoom(event, page) {
      const targetPage = page || pageFromEvent(event) || activeReaderPageElement();
      if (!targetPage) return false;
      state.reader.zoom = zoomStateForPoint(targetPage, event, true);
      applyReaderZoomState();
      if (state.reader.gesture) {
        state.reader.gesture.longPressTriggered = true;
        state.reader.gesture.suppressNextTap = true;
      }
      return true;
    }

    function zoomStateForPoint(page, event, transientLongPress) {
      const body = viewEl.querySelector('[data-reader-body]') || viewEl.querySelector('[data-reader-root]');
      const rect = body ? body.getBoundingClientRect() : (page ? page.getBoundingClientRect() : { left: 0, top: 0, width: 0, height: 0 });
      const x = rect.width ? ((event.clientX - rect.left) / rect.width) * 100 : 50;
      const y = rect.height ? ((event.clientY - rect.top) / rect.height) * 100 : 50;
      const eventPage = pageFromEvent(event);
      const activeIndex = eventPage ? numberValue(eventPage.dataset.pageIndex) : (page ? numberValue(page.dataset.pageIndex) : numberValue(currentReaderPage()));
      return {
        activePageIndex: activeIndex,
        scale: 1.75,
        originX: clamp(x, 0, 100),
        originY: clamp(y, 0, 100),
        originMode: 'viewport',
        panX: 0,
        panY: 0,
        transientLongPress: !!transientLongPress,
      };
    }

    function applyReaderZoomState() {
      const zoom = state.reader.zoom || defaultReaderZoomState();
      viewEl.querySelectorAll('.reader-page-inner').forEach((inner) => {
        inner.classList.remove('is-zoomed', 'is-longpress-zoomed');
        inner.style.removeProperty('--zoom-origin-x');
        inner.style.removeProperty('--zoom-origin-y');
        inner.style.removeProperty('--zoom-scale');
      });
      viewEl.querySelectorAll('[data-reader-zoom-layer]').forEach((layer) => {
        const active = zoom.scale !== 1;
        layer.classList.toggle('is-reader-zoomed', active && !zoom.transientLongPress);
        layer.classList.toggle('is-reader-longpress-zoomed', active && zoom.transientLongPress);
        if (active) {
          layer.style.setProperty('--reader-zoom-origin-x', `${zoom.originX}%`);
          layer.style.setProperty('--reader-zoom-origin-y', `${zoom.originY}%`);
          layer.style.setProperty('--reader-zoom-scale', String(zoom.scale));
          layer.style.setProperty('--reader-zoom-pan-x', `${numberValue(zoom.panX)}px`);
          layer.style.setProperty('--reader-zoom-pan-y', `${numberValue(zoom.panY)}px`);
        } else {
          layer.style.removeProperty('--reader-zoom-origin-x');
          layer.style.removeProperty('--reader-zoom-origin-y');
          layer.style.removeProperty('--reader-zoom-scale');
          layer.style.removeProperty('--reader-zoom-pan-x');
          layer.style.removeProperty('--reader-zoom-pan-y');
        }
      });
    }

    function panReaderZoom(dx, dy) {
      const zoom = state.reader.zoom || defaultReaderZoomState();
      if (zoom.scale === 1) return false;
      const viewport = window.visualViewport;
      const maxX = ((viewport && viewport.width) || window.innerWidth || 1200) * 0.75;
      const maxY = ((viewport && viewport.height) || window.innerHeight || 900) * 0.75;
      zoom.panX = clamp(numberValue(zoom.panX) + dx, -maxX, maxX);
      zoom.panY = clamp(numberValue(zoom.panY) + dy, -maxY, maxY);
      state.reader.zoom = zoom;
      applyReaderZoomState();
      return true;
    }

    function pageFromEvent(event) {
      return event && event.target && event.target.closest ? event.target.closest('.reader-page') : null;
    }

    function activeReaderPageElement() {
      const index = isScrollReaderMode(state.reader.mode) ? currentScrollPage() : state.reader.pageIndex;
      return viewEl.querySelector(`.reader-page[data-page-index="${numberValue(index)}"]`);
    }

    function showToast(message) {
      const toast = viewEl.querySelector('.app-toast');
      if (!toast) return;
      toast.textContent = message;
      toast.hidden = false;
      if (state.toastTimer) window.clearTimeout(state.toastTimer);
      state.toastTimer = window.setTimeout(() => { toast.hidden = true; }, 1200);
    }

    function bindReaderChrome(adapter, pages, params) {
      const root = viewEl.querySelector('[data-reader-root]');
      if (!root) return;
      viewEl.querySelector('[data-reader-back]')?.addEventListener('click', back);
      viewEl.querySelectorAll('[data-reader-settings]').forEach((button) => button.addEventListener('click', (event) => {
        event.stopPropagation();
        state.reader.settingsOpen = !state.reader.settingsOpen;
        state.reader.chaptersOpen = false;
        renderReaderContent(state.view.params);
      }));
      viewEl.querySelectorAll('[data-reader-chapters]').forEach((button) => button.addEventListener('click', (event) => {
        event.stopPropagation();
        state.reader.chaptersOpen = !state.reader.chaptersOpen;
        state.reader.settingsOpen = false;
        renderReaderContent(state.view.params);
      }));
      viewEl.querySelector('[data-reader-chapter-prev]')?.addEventListener('click', () => jumpReaderChapter(-1));
      viewEl.querySelector('[data-reader-chapter-next]')?.addEventListener('click', () => jumpReaderChapter(1));
      viewEl.querySelector('[data-reader-fullscreen]')?.addEventListener('click', toggleFullscreen);
      viewEl.querySelector('[data-reader-favorite]')?.addEventListener('click', () => favoriteCurrentImage(adapter));
      viewEl.querySelector('[data-reader-auto]')?.addEventListener('click', toggleAutoTurn);
      viewEl.querySelector('[data-reader-download]')?.addEventListener('click', () => downloadCurrentImage(adapter));
      viewEl.querySelector('[data-reader-method-toggle]')?.addEventListener('click', (event) => {
        event.stopPropagation();
        state.reader.methodPickerOpen = !state.reader.methodPickerOpen;
        renderReaderContent(state.view.params);
      });
      const slider = viewEl.querySelector('[data-reader-slider]');
      if (slider) slider.addEventListener('input', () => { stopAutoTurn(true); jumpReaderPage(numberValue(slider.value) - 1); });
      viewEl.querySelectorAll('[data-reader-setting]').forEach((input) => bindReaderSettingInput(input));
      viewEl.querySelectorAll('[data-reader-method]').forEach((button) => button.addEventListener('click', () => { stopAutoTurn(true); switchReaderMode(button.dataset.readerMethod); }));
      viewEl.querySelectorAll('[data-reader-open-episode]').forEach((button) => button.addEventListener('click', () => navigateReaderChapter(numberValue(button.dataset.readerOpenEpisode))));
      const pointerDownHandler = (event) => handleReaderPointerDown(event, root);
      const pointerMoveHandler = (event) => handleReaderPointerMove(event, root);
      const pointerUpHandler = (event) => handleReaderPointerUp(event, root);
      const pointerCancelHandler = (event) => {
        if (event && state.reader.activePointers) state.reader.activePointers.delete(event.pointerId);
        state.reader.lastTapTime = 0;
        finishReaderPointer(true, true);
      };
      const pointerReleaseHandler = (event) => {
        if (event && state.reader.activePointers) state.reader.activePointers.delete(event.pointerId);
        finishReaderPointer(true, false);
      };
      root.addEventListener('pointerdown', pointerDownHandler);
      root.addEventListener('pointermove', pointerMoveHandler);
      root.addEventListener('pointerup', pointerUpHandler);
      root.addEventListener('pointercancel', pointerCancelHandler);
      root.addEventListener('lostpointercapture', pointerReleaseHandler);
      const releaseHandler = () => {
        finishReaderPointer(true, false);
      };
      const cancelReleaseHandler = () => {
        state.reader.lastTapTime = 0;
        finishReaderPointer(true, true);
      };
      document.addEventListener('pointerup', releaseHandler);
      document.addEventListener('pointercancel', cancelReleaseHandler);
      const visibilityHandler = () => { if (document.hidden) cancelReleaseHandler(); };
      window.addEventListener('blur', releaseHandler);
      document.addEventListener('visibilitychange', visibilityHandler);
      const keyHandler = (event) => handleReaderKeydown(event);
      window.addEventListener('keydown', keyHandler);
      addReaderCleanup(() => {
        root.removeEventListener('pointerdown', pointerDownHandler);
        root.removeEventListener('pointermove', pointerMoveHandler);
        root.removeEventListener('pointerup', pointerUpHandler);
        root.removeEventListener('pointercancel', pointerCancelHandler);
        root.removeEventListener('lostpointercapture', pointerReleaseHandler);
        document.removeEventListener('pointerup', releaseHandler);
        document.removeEventListener('pointercancel', cancelReleaseHandler);
        window.removeEventListener('blur', releaseHandler);
        document.removeEventListener('visibilitychange', visibilityHandler);
        window.removeEventListener('keydown', keyHandler);
        resetReaderGesture();
        resetReaderZoom(true);
      });
    }

    function bindReaderSettingInput(input) {
      const key = input.dataset.readerSetting;
      const handler = () => {
        const prefs = readReaderPrefs();
        let value = input.type === 'checkbox' ? input.checked : input.value;
        if (input.type === 'range' || input.type === 'number') value = numberValue(value);
        if (key === 'autoTurnSeconds') value = clamp(value, 1, 60);
        if (key === 'tapZonePercent') value = clamp(value, 5, 45);
        if (key === 'maxWidthPx') value = clamp(value, 600, 1600);
        writeReaderPrefs(Object.assign({}, prefs, { [key]: value }));
        state.reader.prefs = readReaderPrefs();
        if (key === 'maxWidthPx') {
          const root = viewEl.querySelector('[data-reader-root]');
          if (root) root.style.setProperty('--reader-max-width', `${state.reader.prefs.maxWidthPx}px`);
        }
        if (key === 'limitMaxWidth' || key === 'reduceBrightnessInDarkMode' || key === 'showPageInfo') renderReaderContent(state.view.params);
        else {
          updateReaderPageCount();
          const output = input.closest('.reader-setting-row')?.querySelector('output');
          if (output) output.textContent = settingOutputText(key, value);
        }
      };
      input.addEventListener('change', handler);
      input.addEventListener('input', () => {
        const output = input.closest('.reader-setting-row')?.querySelector('output');
        if (output) output.textContent = settingOutputText(key, numberValue(input.value));
        if (key === 'maxWidthPx') handler();
      });
    }

    function handleReaderPointerDown(event, root) {
      if (event.button != null && event.button !== 0) return;
      if (event.isPrimary === false) return;
      if (!isReaderContentTarget(event.target, root)) return;
      if (event.target === root) {
        const activePage = activeReaderPageElement();
        if (activePage) state.reader.lastPointerPage = activePage;
      }
      if (isReaderInteractiveTarget(event.target)) return;
      resetReaderGesture();
      const pointers = state.reader.activePointers || (state.reader.activePointers = new Set());
      pointers.clear();
      pointers.add(event.pointerId);
      const prefs = state.reader.prefs || readReaderPrefs();
      const page = pageFromEvent(event) || state.reader.lastPointerPage || activeReaderPageElement();
      state.reader.gesture = {
        pointerId: event.pointerId,
        pointerType: event.pointerType || 'mouse',
        downX: event.clientX,
        downY: event.clientY,
        lastX: event.clientX,
        lastY: event.clientY,
        downTime: Date.now(),
        moved: false,
        longPressTriggered: false,
        suppressNextTap: false,
        page,
      };
      if (root && root.setPointerCapture) {
        try { root.setPointerCapture(event.pointerId); } catch (_) {}
      }
      if (prefs.longPressZoomEnabled && page) {
        const point = { clientX: event.clientX, clientY: event.clientY, pointerId: event.pointerId };
        state.reader.longPressTimer = window.setTimeout(() => {
          const gesture = state.reader.gesture;
          const active = state.reader.activePointers && state.reader.activePointers.size === 1;
          if (!gesture || gesture.pointerId !== point.pointerId || gesture.moved || !active || !page.isConnected) return;
          startReaderLongPressZoom(point, page);
        }, 300);
      }
    }

    function handleReaderPointerMove(event) {
      const gesture = state.reader.gesture;
      if (!gesture || gesture.pointerId !== event.pointerId) return;
      const dx = event.clientX - gesture.lastX;
      const dy = event.clientY - gesture.lastY;
      gesture.lastX = event.clientX;
      gesture.lastY = event.clientY;
      const distance = Math.hypot(event.clientX - gesture.downX, event.clientY - gesture.downY);
      const slop = gesture.pointerType === 'touch' ? readerGestureConfig.tapSlopTouch : readerGestureConfig.tapSlopMouse;
      if (distance > slop) {
        gesture.moved = true;
        if (state.reader.longPressTimer) window.clearTimeout(state.reader.longPressTimer);
        state.reader.longPressTimer = null;
      }
      if (gesture.moved && state.reader.zoom && state.reader.zoom.scale !== 1) {
        gesture.suppressNextTap = true;
        event.preventDefault();
        panReaderZoom(dx, dy);
      }
    }

    function handleReaderPointerUp(event, root) {
      const gesture = state.reader.gesture;
      if (state.reader.activePointers) state.reader.activePointers.delete(event.pointerId);
      if (!gesture || gesture.pointerId !== event.pointerId) return;
      event.stopPropagation();
      if (root && root.releasePointerCapture) {
        try { root.releasePointerCapture(event.pointerId); } catch (_) {}
      }
      if (state.reader.longPressTimer) window.clearTimeout(state.reader.longPressTimer);
      state.reader.longPressTimer = null;
      if (gesture.longPressTriggered) {
        finishReaderPointer(true);
        return;
      }
      if (gesture.suppressNextTap) {
        finishReaderPointer(false);
        return;
      }
      if (gesture.moved) {
        const dx = event.clientX - gesture.downX;
        const dy = event.clientY - gesture.downY;
        if (handleReaderSwipe(dx, dy)) {
          finishReaderPointer(false);
          return;
        }
        finishReaderPointer(false);
        return;
      }
      handleReaderTap(event, root, gesture);
      finishReaderPointer(false);
    }

    function finishReaderPointer(resetLongPressZoom, clearTapTimer = resetLongPressZoom) {
      if (state.reader.longPressTimer) window.clearTimeout(state.reader.longPressTimer);
      state.reader.longPressTimer = null;
      if (clearTapTimer && state.reader.tapTimer) {
        window.clearTimeout(state.reader.tapTimer);
        state.reader.tapTimer = null;
      }
      if (resetLongPressZoom) resetReaderZoom(true);
      state.reader.gesture = null;
    }

    function handleReaderSwipe(dx, dy) {
      const absX = Math.abs(dx);
      const absY = Math.abs(dy);
      if (state.reader.zoom && state.reader.zoom.scale !== 1) return false;
      if (absX >= readerGestureConfig.swipeDistance && absX >= absY * readerGestureConfig.swipeDominance) {
        stopAutoTurn(true);
        moveReaderPage(readerModeDirection(dx > 0 ? -1 : 1));
        return true;
      }
      if ((state.reader.mode === 'ttb' || state.reader.mode === 'scroll-continuous') && absY >= readerGestureConfig.swipeDistance && absY >= absX * readerGestureConfig.swipeDominance) {
        stopAutoTurn(true);
        moveReaderPage(dy > 0 ? -1 : 1);
        return true;
      }
      return false;
    }

    function handleReaderTap(event, root, gesture) {
      if (isReaderInteractiveTarget(event.target)) return;
      const prefs = state.reader.prefs || readReaderPrefs();
      const now = Date.now();
      const lastTime = state.reader.lastTapTime || 0;
      const lastX = state.reader.lastTapX || 0;
      const lastY = state.reader.lastTapY || 0;
      const isDoubleTap = prefs.doubleClickZoomEnabled && now - lastTime <= 240 && Math.hypot(event.clientX - lastX, event.clientY - lastY) <= 36;
      if (isDoubleTap) {
        if (state.reader.tapTimer) window.clearTimeout(state.reader.tapTimer);
        state.reader.tapTimer = null;
        state.reader.lastTapTime = 0;
        if (toggleReaderZoomAt(event, gesture && gesture.page)) return;
      }
      state.reader.lastTapTime = now;
      state.reader.lastTapX = event.clientX;
      state.reader.lastTapY = event.clientY;
      if (state.reader.tapTimer) window.clearTimeout(state.reader.tapTimer);
      state.reader.tapTimer = window.setTimeout(() => {
        state.reader.tapTimer = null;
        finishReaderTap(event, root, prefs);
      }, prefs.doubleClickZoomEnabled ? 245 : 0);
    }

    function finishReaderTap(event, root, prefs) {
      if (state.reader.settingsOpen || state.reader.chaptersOpen) {
        state.reader.settingsOpen = false;
        state.reader.chaptersOpen = false;
        state.reader.chromeVisible = false;
        renderReaderContent(state.view.params);
        return;
      }
      if (!state.reader.chromeVisible && (prefs || state.reader.prefs || readReaderPrefs()).tapTurnEnabled) {
        if (handleReaderTapTurn(event, root, prefs)) return;
      }
      setReaderChromeVisible(!state.reader.chromeVisible);
    }

    function handleReaderTapTurn(event, root, prefs) {
      const actualPrefs = prefs || state.reader.prefs || readReaderPrefs();
      const rect = root.getBoundingClientRect();
      const edge = clamp(numberValue(actualPrefs.tapZonePercent, 25), 5, 45) / 100;
      let x = event.clientX - rect.left;
      let y = event.clientY - rect.top;
      let width = rect.width;
      let height = rect.height;
      if (isScrollReaderMode(state.reader.mode)) {
        const viewport = window.visualViewport;
        width = (viewport && viewport.width) || window.innerWidth || rect.width;
        height = (viewport && viewport.height) || window.innerHeight || rect.height;
        x = event.clientX;
        y = event.clientY;
      }
      const delta = tapDeltaForPoint(x, y, width, height, edge, actualPrefs);
      if (!delta) return false;
      stopAutoTurn(true);
      moveReaderPage(delta);
      return true;
    }

    function setReaderChromeVisible(visible) {
      state.reader.chromeVisible = !!visible;
      const root = viewEl.querySelector('[data-reader-root]');
      if (!root) return;
      root.classList.toggle('reader-chrome-visible', state.reader.chromeVisible);
      root.classList.toggle('reader-chrome-hidden', !state.reader.chromeVisible);
    }

    function isReaderInteractiveTarget(target) {
      return !!(target && target.closest && target.closest([
        '.reader-chrome',
        '.reader-settings-panel',
        '.reader-chapters-panel',
        '.reader-toast',
        '.app-toast',
        '.reader-retry',
        'button',
        'input',
        'select',
        'textarea',
        'a',
        '[data-reader-control]',
      ].join(',')));
    }

    function isReaderContentTarget(target, root) {
      if (!target || isReaderInteractiveTarget(target)) return false;
      if (target === root) return true;
      return !!(target.closest && (
        target.closest('[data-reader-body]')
        || target.closest('.reader-scroll')
        || target.closest('.reader-paged')
        || target.closest('.reader-zoom-layer')
        || target.closest('.reader-strip')
        || target.closest('.reader-page')
      ));
    }

    function tapDeltaForPoint(x, y, width, height, edge, prefs) {
      const mode = prefs.readingMethod;
      let delta = 0;
      if (mode === 'rtl' || mode === 'two-page-reversed') { if (x <= width * edge) delta = 1; else if (x >= width * (1 - edge)) delta = -1; }
      else if (mode === 'ttb' || mode === 'scroll-continuous') { if (y <= height * edge) delta = -1; else if (y >= height * (1 - edge)) delta = 1; }
      else { if (x <= width * edge) delta = -1; else if (x >= width * (1 - edge)) delta = 1; }
      return prefs.reverseTapTurn ? -delta : delta;
    }

    function handleReaderKeydown(event) {
      if (!state.reader.prefs.keyboardPageTurnEnabled) return;
      const target = event.target;
      if (target && target.closest && target.closest('input, textarea, select, button, [contenteditable="true"]')) return;
      let delta = 0;
      const mode = state.reader.prefs.readingMethod;
      if (event.key === 'PageDown' || event.key === ' ') delta = 1;
      if (event.key === 'PageUp') delta = -1;
      if (event.key === 'ArrowRight') delta = (mode === 'rtl' || mode === 'two-page-reversed') ? -1 : 1;
      if (event.key === 'ArrowLeft') delta = (mode === 'rtl' || mode === 'two-page-reversed') ? 1 : -1;
      if (event.key === 'ArrowDown') delta = 1;
      if (event.key === 'ArrowUp') delta = -1;
      if (!delta) return;
      event.preventDefault();
      stopAutoTurn(true);
      moveReaderPage(state.reader.prefs.reverseTapTurn ? -delta : delta);
    }

    function moveReaderPage(delta) {
      const step = isTwoPageMode(state.reader.mode) ? 2 : 1;
      const current = isTwoPageMode(state.reader.mode) ? spreadStart(state.reader.pageIndex) : state.reader.pageIndex;
      const next = current + delta * step;
      if (next < 0) { if (jumpReaderChapter(-1, true)) return; showToast('已经是第一页'); return; }
      if (next >= readerTotalPages()) { if (jumpReaderChapter(1, true)) return; showToast('已经是最后一页'); stopAutoTurn(false); return; }
      jumpReaderPage(next);
    }

    function jumpReaderPage(index) {
      const total = readerTotalPages();
      const raw = clamp(numberValue(index), 0, Math.max(0, total - 1));
      state.reader.pageIndex = isTwoPageMode(state.reader.mode) ? spreadStart(raw) : raw;
      resetReaderZoom(false);
      if (isScrollReaderMode(state.reader.mode)) scrollToPage(state.reader.pageIndex);
      else if (state.reader.drawPaged) state.reader.drawPaged();
      updateReaderPageCount();
      scheduleReaderHistoryWrite();
    }

    function spreadStart(index) {
      return Math.max(0, Math.floor(numberValue(index) / 2) * 2);
    }

    function jumpReaderChapter(delta, silent) {
      const next = state.reader.episodeIndex + delta;
      const episodes = (state.reader.item && state.reader.item.episodes) || [];
      if (next < 0 || next >= episodes.length) { if (!silent) showToast(delta < 0 ? '没有上一章' : '没有下一章'); return false; }
      navigateReaderChapter(next);
      return true;
    }

    function navigateReaderChapter(episodeIndex) {
      stopAutoTurn(true);
      const item = state.reader.item;
      const origin = (item && item.__origin) || (state.view.params && state.view.params.origin) || 'local';
      state.reader.pageIndex = 0;
      state.reader.episodeIndex = episodeIndex;
      state.view.params = { id: item.id, origin, item, episode: item.episodes[episodeIndex], episodeIndex, pageIndex: 0 };
      renderReader(state.view.params);
    }

    function toggleAutoTurn() {
      if (state.reader.autoTurnTimer) { stopAutoTurn(true); renderReaderContent(state.view.params); return; }
      const seconds = clamp(numberValue(state.reader.prefs.autoTurnSeconds, 1), 1, 60);
      state.reader.autoTurnTimer = window.setInterval(() => {
        if (state.reader.autoTurnTimer) moveReaderPage(1);
      }, seconds * 1000);
      showToast(`自动翻页：${seconds} 秒`);
      renderReaderContent(state.view.params);
    }

    function stopAutoTurn(showMessage) {
      if (!state.reader.autoTurnTimer) return;
      window.clearInterval(state.reader.autoTurnTimer);
      state.reader.autoTurnTimer = null;
      if (showMessage) showToast('已停止自动翻页');
    }

    function toggleFullscreen() {
      const root = viewEl.querySelector('[data-reader-root]');
      if (!document.fullscreenElement && root && root.requestFullscreen) root.requestFullscreen().catch(() => showToast('无法进入全屏'));
      else if (document.exitFullscreen) document.exitFullscreen().catch(() => null);
    }

    async function favoriteCurrentImage(adapter) {
      if (state.reader.favoriteSaving) return;
      if ((state.reader.item && state.reader.item.__origin) === 'remote') { showToast('远程图片收藏待接入'); return; }
      const pagePath = currentPagePath();
      if (!pagePath) return;
      state.reader.favoriteSaving = true;
      try {
        await consoleApi.api.post('/api/library/image-favorites', { id: state.reader.item.id, imagePath: pagePath, title: state.reader.item.title || state.reader.item.id, ep: state.reader.episodeIndex, page: state.reader.pageIndex, otherInfo: { episodeTitle: state.reader.episode && state.reader.episode.title, page: state.reader.pageIndex + 1 } });
        showToast('已收藏当前图片');
      } catch (error) { showToast(`收藏失败：${errorMessage(error)}`); }
      finally { state.reader.favoriteSaving = false; }
    }

    function downloadCurrentImage(adapter) {
      const pagePath = currentPagePath();
      if (!pagePath) return;
      const link = document.createElement('a');
      link.href = adapter.imageUrl(pagePath);
      link.download = safeFileName(`${state.reader.item.title || state.reader.item.id}-E${state.reader.episodeIndex + 1}-P${state.reader.pageIndex + 1}.jpg`);
      document.body.appendChild(link);
      link.click();
      link.remove();
      showToast('已触发保存图片');
    }

    function currentPagePath() {
      const pages = (state.reader.episode && state.reader.episode.pages) || [];
      const page = pages[clamp(state.reader.pageIndex, 0, Math.max(0, pages.length - 1))];
      if (!page) showToast('当前页不可用');
      return page;
    }

    function currentReaderPage() { return isScrollReaderMode(state.reader.mode) ? currentScrollPage() : state.reader.pageIndex; }
    function readerTotalPages() { return (state.reader.episode && state.reader.episode.pages && state.reader.episode.pages.length) || 0; }
    function readerPageLabel() { const totalEpisodes = ((state.reader.item && state.reader.item.episodes) || []).length; const page = state.reader.pageIndex + 1; return totalEpisodes > 1 ? `E${state.reader.episodeIndex + 1} : P${page}` : `P${page}`; }
    function isScrollReaderMode(mode) { return (mode || state.reader.mode) === 'scroll-continuous'; }

    function pagedReaderImagesHtml(adapter, pages, pageSizes, index) {
      if (state.reader.mode !== 'two-page' && state.reader.mode !== 'two-page-reversed') return pagedImageHtml(adapter, pages[index], pageSizes[index], index);
      const other = index + 1;
      const items = [pagedImageHtml(adapter, pages[index], pageSizes[index], index)];
      if (other < pages.length) items.push(pagedImageHtml(adapter, pages[other], pageSizes[other], other));
      if (state.reader.mode === 'two-page-reversed') items.reverse();
      return `<div class="reader-spread">${items.join('')}</div>`;
    }

    function readerSettingsHtml() {
      const prefs = state.reader.prefs || readReaderPrefs();
      const methods = readerMethodOptions();
      const currentMethod = methods.find(([value]) => value === prefs.readingMethod) || methods[3];
      const methodOpen = !!state.reader.methodPickerOpen;
      return `
        <div class="reader-panel-head"><strong>阅读设置</strong><button class="ghost" type="button" data-reader-settings>关闭</button></div>
        <section class="reader-method-section ${methodOpen ? 'is-open' : ''}">
          <button class="reader-method-toggle" type="button" data-reader-method-toggle aria-expanded="${methodOpen ? 'true' : 'false'}">
            <span class="reader-setting-icon">${currentMethod[2]}</span>
            <span class="reader-method-title"><strong>阅读模式</strong><em>${currentMethod[1]}</em></span>
            <span class="reader-method-chevron">⌄</span>
          </button>
          <div class="reader-method-list" ${methodOpen ? '' : 'hidden'}>${methods.map(([value, label, icon]) => `<button type="button" class="${prefs.readingMethod === value ? 'active' : ''}" data-reader-method="${value}"><span class="reader-setting-icon">${icon}</span><span>${label}</span></button>`).join('')}</div>
        </section>
        ${settingSwitchHtml('点按翻页', 'tapTurnEnabled', prefs.tapTurnEnabled, '👆')}
        ${settingRangeHtml('点按翻页识别范围', 'tapZonePercent', prefs.tapZonePercent, 5, 45, 1, '%', '▥')}
        ${settingSwitchHtml('反转点按翻页', 'reverseTapTurn', prefs.reverseTapTurn, '⇄')}
        ${settingSwitchHtml('使用键盘/Page 键翻页', 'keyboardPageTurnEnabled', prefs.keyboardPageTurnEnabled, '⌨')}
        ${settingRangeHtml('自动翻页时间间隔', 'autoTurnSeconds', prefs.autoTurnSeconds, 1, 60, 1, ' 秒', '⏱')}
        ${settingSwitchHtml('深色模式下降低图片亮度', 'reduceBrightnessInDarkMode', prefs.reduceBrightnessInDarkMode, '◐')}
        ${settingSwitchHtml('双击缩放', 'doubleClickZoomEnabled', prefs.doubleClickZoomEnabled, '🔎')}
        ${settingSwitchHtml('限制图片最大显示宽度', 'limitMaxWidth', prefs.limitMaxWidth, '↔')}
        ${prefs.limitMaxWidth ? settingRangeHtml('图片最大显示宽度', 'maxWidthPx', prefs.maxWidthPx, 600, 1600, 20, 'px', '▭') : ''}
        ${settingSwitchHtml('长按缩放', 'longPressZoomEnabled', prefs.longPressZoomEnabled, '＋')}
        ${settingSwitchHtml('显示页面信息', 'showPageInfo', prefs.showPageInfo, 'ℹ')}
      `;
    }

    function readerMethodOptions() {
      return [['ltr', '从左至右', '→'], ['rtl', '从右至左', '←'], ['ttb', '从上至下', '↓'], ['scroll-continuous', '从上至下（连续）', '↡'], ['two-page', '双页', '▭▭'], ['two-page-reversed', '双页（反向）', '▭▭']];
    }

    function readerChaptersHtml(item, current) {
      const episodes = (item && item.episodes) || [];
      return `<div class="reader-panel-head"><strong>章节列表</strong><button class="ghost" type="button" data-reader-chapters>关闭</button></div><div class="reader-chapter-list">${episodes.map((episode, index) => `<button type="button" class="${index === current ? 'active' : ''}" data-reader-open-episode="${index}"><span>${escapeHtml(episode.title || `第 ${index + 1} 章`)}</span><em>${number(episode.imageCount || (episode.pages || []).length)} 页</em></button>`).join('')}</div>`;
    }

    function settingSwitchHtml(label, key, checked, icon = '•') { return `<label class="reader-setting-row reader-setting-switch"><span class="reader-setting-icon">${icon}</span><span class="reader-setting-label">${label}</span><input type="checkbox" data-reader-setting="${key}" ${checked ? 'checked' : ''}><span class="reader-switch-ui" aria-hidden="true"></span></label>`; }
    function settingRangeHtml(label, key, value, min, max, step, suffix, icon = '•') { return `<label class="reader-setting-row reader-setting-range"><span class="reader-setting-icon">${icon}</span><span class="reader-setting-label">${label}</span><input type="range" min="${min}" max="${max}" step="${step}" value="${value}" data-reader-setting="${key}"><output>${settingOutputText(key, value, suffix)}</output></label>`; }
    function settingOutputText(key, value, suffix) { if (suffix) return `${value}${suffix}`; if (key === 'tapZonePercent') return `${value}%`; if (key === 'autoTurnSeconds') return `${value} 秒`; if (key === 'maxWidthPx') return `${value}px`; return String(value); }
    function resolveEpisodeIndex(item, episode, fallback) {
      const episodes = (item && item.episodes) || [];
      const explicit = numberValue(fallback, -1);
      if (explicit >= 0 && explicit < episodes.length) return explicit;
      if (episode) {
        const byIdentity = episodes.findIndex((entry) => entry === episode);
        if (byIdentity >= 0) return byIdentity;
        const byIndex = episodes.findIndex((entry) => numberValue(entry.index) === numberValue(episode.index));
        if (byIndex >= 0) return byIndex;
      }
      return clamp(numberValue(fallback), 0, Math.max(0, episodes.length - 1));
    }

    function buildAdapter(origin) {
      const actual = origin === 'remote' ? 'remote' : 'local';
      if (actual === 'remote') {
        const target = consoleApi.remoteTarget.get().trim();
        if (!target) throw new Error('未配置远程地址');
        return {
          origin: 'remote',
          target,
          fetchItems: () => consoleApi.remote.get(target, '/api/library/items'),
          fetchDetail: (id) => consoleApi.remote.get(target, `/api/library/items/${encodeURIComponent(id)}`),
          fetchEpisode: (id, ep) => consoleApi.remote.get(target, `/api/library/items/${encodeURIComponent(id)}/episodes/${encodeURIComponent(ep)}`),
          imageUrl: (path) => consoleApi.remote.imageUrl(target, path),
        };
      }
      return {
        origin: 'local',
        fetchItems: () => consoleApi.api.get('/api/library/items'),
        fetchDetail: (id) => consoleApi.api.get(`/api/library/items/${encodeURIComponent(id)}`),
        fetchEpisode: (id, ep) => consoleApi.api.get(`/api/library/items/${encodeURIComponent(id)}/episodes/${encodeURIComponent(ep)}`),
        imageUrl: (path) => consoleApi.api.imageUrl(path),
      };
    }

    async function fetchItemsForSource(source) {
      if (source === 'remote') {
        const adapter = buildAdapter('remote');
        const data = await adapter.fetchItems();
        return { items: normalizeItemsPayload(data, adapter, 'remote'), warning: '' };
      }
      if (source === 'merged') {
        const localAdapter = buildAdapter('local');
        let remoteAdapter = null;
        try { remoteAdapter = buildAdapter('remote'); } catch (error) { remoteAdapter = null; }
        const jobs = [settle(localAdapter.fetchItems())];
        if (remoteAdapter) jobs.push(settle(remoteAdapter.fetchItems()));
        else jobs.push(Promise.resolve({ ok: false, error: new Error('未配置远程地址') }));
        const results = await Promise.all(jobs);
        const items = [];
        const warnings = [];
        if (results[0].ok) items.push(...normalizeItemsPayload(results[0].value, localAdapter, 'local'));
        else warnings.push(`本地加载失败：${errorMessage(results[0].error)}`);
        if (results[1].ok) items.push(...normalizeItemsPayload(results[1].value, remoteAdapter, 'remote'));
        else warnings.push(`远程加载失败：${errorMessage(results[1].error)}`);
        if (!items.length && warnings.length) throw new Error(warnings.join('；'));
        return { items, warning: warnings.join('；') };
      }
      const adapter = buildAdapter('local');
      const data = await adapter.fetchItems();
      return { items: normalizeItemsPayload(data, adapter, 'local'), warning: '' };
    }
  }

  function settle(promise) {
    return promise.then((value) => ({ ok: true, value }), (error) => ({ ok: false, error }));
  }

  function normalizeItemsPayload(data, adapter, origin) {
    const rawItems = firstArray(data, ['items', 'data', 'comics', 'books', 'entries']);
    return rawItems.map((item) => normalizeItem(item, adapter, origin)).filter((item) => item.id);
  }

  function normalizeItem(raw, adapter, origin) {
    const item = raw && typeof raw === 'object' ? raw : {};
    const id = stringValue(firstValue(item, ['id', 'comicId', 'bookId', 'uuid', 'key', 'path']));
    const title = stringValue(firstValue(item, ['title', 'name', 'displayName', 'sourceTitle'])) || id;
    const tags = arrayValue(firstValue(item, ['tags', 'categories', 'labels'])).map((tag) => stringValue(tag)).filter(Boolean);
    const episodes = firstArray(item, ['episodes', 'chapters', 'volumes']).map((episode, index) => normalizeEpisode(episode, index));
    const coverUrl = stringValue(firstValue(item, ['coverUrl', 'cover', 'thumbnail', 'thumbnailUrl', 'image', 'imageUrl']));
    return Object.assign({}, item, {
      id,
      title,
      subtitle: stringValue(firstValue(item, ['subtitle', 'description', 'desc', 'summary'])),
      sourceDisplayName: stringValue(firstValue(item, ['sourceDisplayName', 'displayName', 'sourceTitle'])),
      displayId: stringValue(firstValue(item, ['displayId', 'comicId', 'bookId', 'code'])),
      tags,
      path: stringValue(firstValue(item, ['path', 'relativePath', 'filePath'])),
      imageCount: numberValue(firstValue(item, ['imageCount', 'pageCount', 'pagesCount', 'count'])),
      totalBytes: numberValue(firstValue(item, ['totalBytes', 'bytes', 'size'])),
      updatedAt: stringValue(firstValue(item, ['updatedAt', 'modifiedAt', 'mtime', 'lastModified'])),
      coverUrl,
      episodes,
      __origin: origin,
      __imageUrl: (path) => adapter.imageUrl(path),
    });
  }

  function normalizeEpisode(raw, fallbackIndex) {
    const episode = raw && typeof raw === 'object' ? raw : {};
    const index = numberValue(firstValue(episode, ['index', 'order', 'episodeIndex', 'chapterIndex']), fallbackIndex);
    const pages = firstArray(episode, ['pages', 'images', 'files']).map((page) => stringValue(page)).filter(Boolean);
    return Object.assign({}, episode, {
      index,
      title: stringValue(firstValue(episode, ['title', 'name', 'displayName'])) || `第 ${index + 1} 章`,
      path: stringValue(firstValue(episode, ['path', 'relativePath'])),
      imageCount: numberValue(firstValue(episode, ['imageCount', 'pageCount', 'pagesCount']), pages.length),
      totalBytes: numberValue(firstValue(episode, ['totalBytes', 'bytes', 'size'])),
      coverUrl: stringValue(firstValue(episode, ['coverUrl', 'cover', 'thumbnail', 'thumbnailUrl'])),
      pages,
      pageSizes: firstArray(episode, ['pageSizes', 'sizes', 'imageSizes']),
    });
  }

  function makeFallbackEpisode(item) {
    return normalizeEpisode({ index: 0, title: '正文', imageCount: item.imageCount, totalBytes: item.totalBytes }, 0);
  }

  function filterItems(items, query) {
    const keyword = String(query || '').trim().toLowerCase();
    if (!keyword) return items;
    return items.filter((item) => [item.title, item.subtitle, item.sourceDisplayName, item.displayId, ...(item.tags || [])]
      .some((value) => String(value || '').toLowerCase().includes(keyword)));
  }

  function normalizeImageFavoritesPayload(data) {
    const rawItems = firstArray(data, ['items', 'data', 'favorites', 'images']);
    return rawItems.map((raw, index) => {
      const item = raw && typeof raw === 'object' ? raw : {};
      const id = stringValue(firstValue(item, ['id', 'comicId', 'target']));
      const ep = numberValue(firstValue(item, ['ep', 'episode', 'episodeIndex']));
      const page = numberValue(firstValue(item, ['page', 'pageIndex']));
      const title = stringValue(firstValue(item, ['title', 'name'])) || id || `图片 ${index + 1}`;
      const imageUrl = stringValue(firstValue(item, ['imageUrl', 'url', 'path']));
      return Object.assign({}, item, {
        id,
        title,
        ep,
        page,
        otherInfo: stringValue(firstValue(item, ['otherInfo', 'subtitle', 'description'])),
        imageUrl,
        __key: `${id}:${ep}:${page}:${index}`,
      });
    }).filter((item) => item.id || item.imageUrl);
  }

  function gridCounts(items) {
    const all = Array.isArray(items) ? items : [];
    let comics = 0;
    let albums = 0;
    all.forEach((item) => {
      if (isAlbumItem(item)) albums += 1;
      else comics += 1;
    });
    return { total: all.length, comics, albums };
  }

  function visibleGridItems(items, filter, query) {
    return filterItems(gridItemsForFilter(items, filter), query);
  }

  function gridItemsForFilter(items, filter) {
    const all = Array.isArray(items) ? items : [];
    const normalized = normalizeGridFilter(filter);
    if (normalized === 'comics') return all.filter((item) => !isAlbumItem(item));
    if (normalized === 'albums') return all.filter((item) => isAlbumItem(item));
    return all;
  }

  function isAlbumItem(item) {
    return stringValue(item && item.rootId).startsWith('custom_');
  }

  function normalizeGridFilter(filter) {
    return filter === 'comics' || filter === 'albums' ? filter : 'all';
  }

  function gridFilterTitle(filter) {
    const normalized = normalizeGridFilter(filter);
    if (normalized === 'comics') return '已下载';
    if (normalized === 'albums') return '图集';
    return '资源库';
  }

  function normalizeHistoryPayload(data) {
    const rawItems = firstArray(data, ['items', 'history', 'data', 'entries']);
    return rawItems.map((raw) => {
      const item = raw && typeof raw === 'object' ? raw : {};
      const target = stringValue(firstValue(item, ['target', 'id', 'itemId']));
      return Object.assign({}, item, {
        target,
        title: stringValue(firstValue(item, ['title', 'name'])) || target,
        subtitle: stringValue(firstValue(item, ['subtitle', 'sourceDisplayName', 'readEpisode'])),
        coverUrl: stringValue(firstValue(item, ['coverUrl', 'cover', 'thumbnail'])),
        ep: numberValue(firstValue(item, ['ep', 'episode', 'episodeIndex'])),
        page: numberValue(firstValue(item, ['page', 'pageIndex'])),
        maxPage: numberValue(firstValue(item, ['maxPage', 'pageCount'])),
        readEpisode: String(firstValue(item, ['readEpisode', 'episodeTitle']) || ''),
        updatedAt: stringValue(firstValue(item, ['updatedAt', 'updated_at'])),
      });
    }).filter((item) => item.target);
  }

  function infoChipHtml(label, value) {
    if (value == null || String(value).trim() === '') return '';
    return `<span class="app-info-chip"><b>${escapeHtml(label)}</b><em>${escapeHtml(value)}</em></span>`;
  }

  function normalizeRecommendationPayload(data, adapter, origin) {
    const rawItems = firstArray(data, ['items', 'recommendations', 'data']);
    return rawItems.map((raw) => Object.assign(normalizeItem(raw, adapter, origin), {
      reason: stringValue(firstValue(raw, ['reason'])) || '相关漫画',
      score: numberValue(firstValue(raw, ['score'])),
    })).filter((item) => item.id);
  }

  function historyCardHtml(item) {
    const page = numberValue(item.page) + 1;
    const maxPage = numberValue(item.maxPage);
    const cover = item.coverUrl || item.cover;
    return `
      <button class="app-history-item" type="button" data-open-history="${escapeAttr(item.target)}">
        ${cover ? `<span class="app-cover-wrap app-history-cover"><img loading="lazy" src="${escapeAttr(window.PicaKeepConsole.api.imageUrl(cover))}" alt="${escapeAttr(item.title)}" data-fallback="▱"></span>` : '<span class="app-cover-fallback app-history-cover">▱</span>'}
        <span class="app-history-meta">
          <strong>${escapeHtml(item.title || item.target)}</strong>
          <span class="muted">${escapeHtml(item.readEpisode || item.subtitle || '')}</span>
          <span class="muted">第 ${number(page)}${maxPage ? ` / ${number(maxPage)}` : ''} 页</span>
        </span>
      </button>
    `;
  }

  function gridCardHtml(item) {
    return `
      <article class="app-card" data-open-detail="${escapeAttr(item.id)}" data-origin="${escapeAttr(item.__origin)}" tabindex="0" role="button">
        ${coverHtml(item, 'app-card-cover')}
        <div class="app-card-body">
          <h3>${escapeHtml(item.title || item.id)}</h3>
          <div class="muted app-card-sub">${escapeHtml(item.subtitle || item.sourceDisplayName || '')}</div>
          <div class="app-card-meta">
            <span class="badge">${originLabel(item.__origin)}</span>
            <span class="muted">${number(item.imageCount)} 图 · ${formatBytes(item.totalBytes)}</span>
          </div>
        </div>
      </article>
    `;
  }

  function gridDetailedCardHtml(item) {
    const tags = (item.tags || []).slice(0, 3);
    return `
      <article class="app-detailed-card" data-open-detail="${escapeAttr(item.id)}" data-origin="${escapeAttr(item.__origin)}" tabindex="0" role="button">
        ${coverHtml(item, 'app-detailed-cover')}
        <div class="app-detailed-body">
          <div class="app-detailed-title">${escapeHtml(item.title || item.id)}</div>
          <div class="muted app-detailed-sub">${escapeHtml(item.subtitle || item.sourceDisplayName || item.displayId || '')}</div>
          <div class="app-detailed-meta">
            <span class="badge">${originLabel(item.__origin)}</span>
            <span class="muted">${number(item.imageCount)} 图</span>
            <span class="muted">${formatBytes(item.totalBytes)}</span>
            ${item.updatedAt ? `<span class="muted">${escapeHtml(item.updatedAt)}</span>` : ''}
          </div>
          ${tags.length ? `<div class="app-detailed-tags">${tags.map((tag) => `<span>${escapeHtml(tag)}</span>`).join('')}</div>` : ''}
        </div>
        <span class="app-chevron">›</span>
      </article>
    `;
  }

  function recommendationCardHtml(item) {
    return `
      <article class="app-recommendation-card" data-open-recommendation="${escapeAttr(item.id)}" data-origin="${escapeAttr(item.__origin)}" role="button" tabindex="0">
        ${coverHtml(item, 'app-recommendation-cover')}
        <div class="app-recommendation-info">
          <strong>${escapeHtml(item.title || item.id)}</strong>
          <span class="muted">${escapeHtml(item.subtitle || item.sourceDisplayName || '')}</span>
          <span class="app-recommendation-reason">${escapeHtml(item.reason || '相关漫画')}</span>
          <span class="muted">${escapeHtml(item.displayId || item.id)}</span>
        </div>
      </article>
    `;
  }

  function imageFavoriteCardHtml(item) {
    const meta = `EP${number(numberValue(item.ep) + 1)} · Page${number(numberValue(item.page) + 1)}`;
    return `
      <button class="app-imgfav-card" type="button" data-open-image="${escapeAttr(item.__key)}">
        ${item.imageUrl ? `
          <span class="app-cover-wrap app-imgfav-thumb">
            <img loading="lazy" src="${escapeAttr(window.PicaKeepConsole.api.imageUrl(item.imageUrl))}" alt="${escapeAttr(item.title)}" data-fallback="${escapeAttr(firstLetter(item.title))}">
          </span>
        ` : `<span class="app-cover-fallback app-imgfav-thumb">${escapeHtml(firstLetter(item.title))}</span>`}
        <span class="app-imgfav-meta">
          <strong>${escapeHtml(item.title || item.id)}</strong>
          <span class="muted">${escapeHtml(meta)}</span>
          ${item.otherInfo ? `<span class="muted">${escapeHtml(item.otherInfo)}</span>` : ''}
        </span>
      </button>
    `;
  }

  function coverHtml(item, className) {
    const title = item.title || item.id || '?';
    if (!item.coverUrl || !item.__imageUrl) {
      return `<div class="app-cover-fallback ${className}">${escapeHtml(firstLetter(title))}</div>`;
    }
    return `
      <div class="app-cover-wrap ${className}">
        <img loading="lazy" src="${escapeAttr(item.__imageUrl(item.coverUrl))}" alt="${escapeAttr(title)}" data-fallback="${escapeAttr(firstLetter(title))}">
      </div>
    `;
  }

  function scrollPageHtml(adapter, page, size, index) {
    const style = aspectStyle(size);
    const dimensions = imageDimensionsAttrs(size);
    const src = adapter.imageUrl(page);
    return `
      <section class="reader-page" data-page-index="${index}"${dimensions} ${style ? `style="${style}"` : ''}>
        <div class="reader-page-inner">
          <div class="reader-page-label">${index + 1}</div>
          <img class="reader-img" alt="第 ${index + 1} 页" data-src="${escapeAttr(src)}" data-raw-src="${escapeAttr(src)}" loading="lazy">
          <button class="ghost reader-retry" type="button" hidden>重试加载</button>
        </div>
      </section>
    `;
  }

  function pagedImageHtml(adapter, page, size, index) {
    const style = aspectStyle(size);
    const dimensions = imageDimensionsAttrs(size);
    const src = adapter.imageUrl(page);
    return `
      <div class="reader-page reader-paged-page" data-page-index="${index}"${dimensions} ${style ? `style="${style}"` : ''}>
        <div class="reader-page-inner">
          <img class="reader-img" alt="第 ${index + 1} 页" src="${escapeAttr(src)}" data-raw-src="${escapeAttr(src)}">
          <button class="ghost reader-retry" type="button" hidden>重试加载</button>
        </div>
      </div>
    `;
  }

  function bindImageFallbacks(root) {
    root.querySelectorAll('img[data-fallback]').forEach((img) => {
      img.addEventListener('error', () => {
        const fallback = document.createElement('div');
        fallback.className = img.parentElement.className.replace('app-cover-wrap', 'app-cover-fallback');
        fallback.textContent = img.dataset.fallback || '?';
        img.parentElement.replaceWith(fallback);
      }, { once: true });
    });
  }

  function bindRetryImages(root) {
    root.querySelectorAll('.reader-img').forEach((img) => {
      const retry = img.parentElement.querySelector('.reader-retry');
      img.addEventListener('load', () => {
        img.classList.remove('is-error');
        if (retry) retry.hidden = true;
      });
      img.addEventListener('error', () => {
        img.classList.add('is-error');
        if (retry) retry.hidden = false;
      });
      if (retry) {
        retry.addEventListener('click', () => {
          retry.hidden = true;
          img.classList.remove('is-error');
          setImageSrc(img, cacheBust(img.dataset.rawSrc || img.src));
        });
      }
    });
  }

  function setImageSrc(img, src) {
    if (!img || !src) return;
    img.src = src;
  }

  function preload(adapter, pages, index) {
    if (index < 0 || index >= pages.length) return;
    const img = new Image();
    img.src = adapter.imageUrl(pages[index]);
  }

  function makeObserver(callback, rootMargin) {
    if ('IntersectionObserver' in window) return new IntersectionObserver((entries) => entries.forEach(callback), { root: null, rootMargin, threshold: 0.01 });
    return {
      observe(target) { callback({ target, isIntersecting: true }); },
      unobserve() {},
      disconnect() {},
    };
  }

  function retryCard(message, actionAttr, withBack) {
    return `
      <div class="card app-error">
        <div class="brand">加载失败</div>
        <div class="sub bad">${escapeHtml(message)}</div>
        <div class="toolbar">
          ${withBack ? '<button class="ghost" type="button" data-back>← 返回</button>' : ''}
          <button class="action" type="button" ${actionAttr}>重试</button>
        </div>
      </div>
    `;
  }

  function loadingCard(text) {
    return `<div class="card app-loading"><span class="app-spinner"></span>${escapeHtml(text)}</div>`;
  }

  function viewTitle(view) {
    if (view.name === 'dashboard') return 'Dashboard';
    if (view.name === 'detail') return '详情';
    if (view.name === 'reader') return '阅读器';
    if (view.name === 'grid') return gridFilterTitle(view.params && view.params.filter);
    if (view.name === 'imageFavorites') return '图片收藏';
    return '--';
  }

  function usesRemote(source) { return source === 'remote' || source === 'merged'; }
  function sourceLabel(source) { return source === 'remote' ? '远程' : (source === 'merged' ? '聚合' : '本地'); }
  function originLabel(origin) { return origin === 'remote' ? '远程' : '本地'; }

  function readReaderMode() {
    return normalizeReaderMode(readReaderPrefs().readingMethod);
  }

  function writeReaderMode(mode) {
    const normalized = normalizeReaderMode(mode);
    try { window.localStorage.setItem(readerModeKey, normalized === 'scroll-continuous' ? 'scroll' : normalized); } catch (_) {}
    const prefs = readReaderPrefs();
    prefs.readingMethod = normalized;
    writeReaderPrefs(prefs);
  }

  function defaultReaderPrefs() {
    return {
      readingMethod: 'scroll-continuous',
      tapTurnEnabled: true,
      tapZonePercent: 25,
      reverseTapTurn: false,
      keyboardPageTurnEnabled: true,
      autoTurnSeconds: 1,
      reduceBrightnessInDarkMode: false,
      doubleClickZoomEnabled: true,
      limitMaxWidth: true,
      maxWidthPx: 980,
      longPressZoomEnabled: true,
      showPageInfo: true,
      chromeVisible: false,
    };
  }

  function readReaderPrefs() {
    const defaults = defaultReaderPrefs();
    try {
      const raw = window.localStorage.getItem(readerPrefsKey);
      if (raw) {
        const parsed = JSON.parse(raw);
        const next = Object.assign(defaults, parsed, { readingMethod: normalizeReaderMode(parsed.readingMethod) });
        next.maxWidthPx = clamp(numberValue(next.maxWidthPx, 980), 600, 1600);
        return next;
      }
      const legacy = window.localStorage.getItem(readerModeKey);
      defaults.readingMethod = normalizeReaderMode(legacy);
    } catch (_) {}
    return defaults;
  }

  function writeReaderPrefs(prefs) {
    try {
      const next = Object.assign(defaultReaderPrefs(), prefs || {});
      next.readingMethod = normalizeReaderMode(next.readingMethod);
      next.maxWidthPx = clamp(numberValue(next.maxWidthPx, 980), 600, 1600);
      window.localStorage.setItem(readerPrefsKey, JSON.stringify(next));
    } catch (_) {}
  }

  function normalizeReaderMode(mode) {
    if (mode === 'scroll' || mode === 'scroll-continuous') return 'scroll-continuous';
    if (mode === 'paged' || mode === 'ltr') return 'ltr';
    if (mode === 'rtl' || mode === 'ttb' || mode === 'two-page' || mode === 'two-page-reversed') return mode;
    return 'scroll-continuous';
  }

  function imageDimensions(size) {
    if (!size || typeof size !== 'object') return { width: 0, height: 0 };
    return { width: numberValue(size.width || size.w), height: numberValue(size.height || size.h) };
  }

  function imageDimensionsAttrs(size) {
    const dimensions = imageDimensions(size);
    if (!dimensions.width || !dimensions.height) return '';
    return ` data-width="${escapeAttr(dimensions.width)}" data-height="${escapeAttr(dimensions.height)}"`;
  }

  function normalizeGridViewMode(mode) {
    return mode === 'list' || mode === 'detailed' ? 'detailed' : 'poster';
  }

  function readGridViewMode() {
    try { return normalizeGridViewMode(window.localStorage.getItem(gridViewModeKey)); } catch (_) { return 'poster'; }
  }

  function writeGridViewMode(mode) {
    try { window.localStorage.setItem(gridViewModeKey, normalizeGridViewMode(mode)); } catch (_) {}
  }

  function normalizeRecommendText(value) { return String(value || '').toLowerCase().replace(/\s+/g, ''); }

  function firstValue(object, keys) {
    for (const key of keys) {
      if (object && object[key] !== undefined && object[key] !== null) return object[key];
    }
    return undefined;
  }

  function firstArray(object, keys) {
    const value = firstValue(object, keys);
    return Array.isArray(value) ? value : [];
  }

  function arrayValue(value) {
    if (Array.isArray(value)) return value;
    if (typeof value === 'string' && value.trim()) return value.split(/[，,]/).map((item) => item.trim());
    return [];
  }

  function stringValue(value) { return value == null ? '' : String(value); }

  function numberValue(value, fallback) {
    const number = Number(value);
    return Number.isFinite(number) ? number : (fallback || 0);
  }

  function number(value) { return new Intl.NumberFormat('zh-CN').format(numberValue(value)); }

  function formatBytes(value) {
    const bytes = numberValue(value);
    if (!bytes) return '--';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    let size = bytes;
    let unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit += 1;
    }
    return `${size >= 10 || unit === 0 ? size.toFixed(0) : size.toFixed(1)} ${units[unit]}`;
  }

  function aspectStyle(size) {
    const dimensions = imageDimensions(size);
    if (!dimensions.width || !dimensions.height) return '';
    return `aspect-ratio:${dimensions.width}/${dimensions.height};--reader-page-ratio:${dimensions.width}/${dimensions.height}`;
  }

  function cacheBust(src) {
    if (!src) return src;
    const joiner = src.includes('?') ? '&' : '?';
    return `${src}${joiner}__retry=${Date.now()}`;
  }

  function firstLetter(text) {
    return String(text || '?').trim().slice(0, 1).toUpperCase() || '?';
  }

  function clamp(value, min, max) { return Math.max(min, Math.min(max, value)); }

  function errorMessage(error) { return error instanceof Error ? error.message : String(error || '未知错误'); }

  function safeFileName(value) { return String(value || 'image').replace(/[\\/:*?"<>|]+/g, '_').slice(0, 120) || 'image'; }

  function escapeHtml(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function escapeAttr(value) { return escapeHtml(value); }

  window.renderApp = renderApp;
  window.unmountApp = function unmountApp(rootEl) {
    const cleanup = cleanupByRoot.get(rootEl);
    if (cleanup) cleanup();
  };
})();
