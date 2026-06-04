(function () {
  'use strict';

  const modes = [
    { value: 'app', label: '应用面板', icon: '▦', path: '/' },
    { value: 'admin', label: '管理面板', icon: '⚙', path: '/admin-view' },
  ];
  const collapseKey = 'pk-console-topbar-collapsed';
  const themeKeys = Object.freeze({
    accent: 'pk-console-theme-color',
    mode: 'pk-console-theme-mode',
    pureBlack: 'pk-console-pure-black',
  });
  const themeModes = [
    { value: 'system', label: '跟随系统' },
    { value: 'light', label: '浅色' },
    { value: 'dark', label: '深色' },
  ];
  const accentOptions = [
    { value: 'dynamic', label: '动态/默认' },
    { value: 'blue', label: '蓝色' },
    { value: 'red', label: '红色' },
    { value: 'pink', label: '粉色' },
    { value: 'purple', label: '紫色' },
    { value: 'indigo', label: '靛蓝' },
    { value: 'cyan', label: '青色' },
    { value: 'teal', label: '蓝绿' },
    { value: 'green', label: '绿色' },
    { value: 'lime', label: '青柠' },
    { value: 'yellow', label: '黄色' },
    { value: 'amber', label: '琥珀' },
    { value: 'orange', label: '橙色' },
  ];

  const api = window.PicaKeepConsole;
  const root = document.getElementById('console-root');
  const shell = document.getElementById('console-shell');
  const topbar = document.getElementById('topbar');
  const toggleButton = document.getElementById('topbar-toggle');
  const switcher = document.getElementById('mode-switch');
  const avatarWrap = document.getElementById('topbar-avatar-wrap');
  const avatarButton = document.getElementById('top-avatar');
  const avatarMenu = document.getElementById('top-avatar-menu');
  let started = false;
  let avatarCloseTimer = null;

  applyTheme();
  bindSystemThemeListener();
  bindMobileViewportMetrics();

  function start() {
    if (started) return;
    started = true;
    applyRouteMode(false);
    setCollapsed(readCollapsed());
    renderModeSwitch();
    renderAvatarMenu();
    bindTopbar();
    api.mode.onChange((mode) => {
      syncPath(mode);
      renderModeSwitch();
      renderAvatarMenu();
      renderCurrentMode();
    });
    api.auth.onChange(() => renderAvatarMenu());
    window.addEventListener('popstate', (event) => {
      if (event.state && event.state.__picaKeepAppView) return;
      applyRouteMode(true);
    });
    renderCurrentMode();
  }

  function bindTopbar() {
    toggleButton.addEventListener('click', () => {
      if (isReaderActive()) return;
      setCollapsed(!readCollapsed());
    });
    topbar.addEventListener('click', (event) => {
      if (isReaderActive()) return;
      if (isTopbarFunctionalTarget(event.target)) return;
      setCollapsed(!readCollapsed());
    });
    avatarButton.addEventListener('click', (event) => {
      event.stopPropagation();
      if (isReaderActive()) return;
      if (isCoarsePointer()) toggleAvatarMenu();
      else openAvatarMenu();
    });
    avatarWrap.addEventListener('mouseenter', () => {
      if (!isCoarsePointer() && !isReaderActive()) openAvatarMenu();
    });
    avatarWrap.addEventListener('mouseleave', () => {
      if (!isCoarsePointer()) scheduleCloseAvatarMenu();
    });
    avatarMenu.addEventListener('mouseenter', cancelCloseAvatarMenu);
    avatarMenu.addEventListener('mouseleave', () => {
      if (!isCoarsePointer()) scheduleCloseAvatarMenu();
    });
    document.addEventListener('click', (event) => {
      if (!avatarWrap.contains(event.target)) closeAvatarMenu();
      if (isReaderActive() || readCollapsed()) return;
      if (topbar.contains(event.target)) return;
      if (!document.querySelector('#console-root')?.contains(event.target)) return;
      setCollapsed(true);
    });
    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape') closeAvatarMenu();
    });
    window.addEventListener('pk-console-reader-route', (event) => {
      if (event.detail && event.detail.active) {
        closeAvatarMenu();
        setCollapsed(true, { persist: false });
      } else {
        setCollapsed(readCollapsed(), { persist: false });
      }
    });
  }

  function readCollapsed() {
    try { return window.localStorage.getItem(collapseKey) !== '0'; } catch (_) { return true; }
  }

  function setCollapsed(value, options) {
    const persist = !options || options.persist !== false;
    if (persist) {
      try { window.localStorage.setItem(collapseKey, value ? '1' : '0'); } catch (_) {}
    }
    topbar.classList.toggle('topbar-collapsed', value);
    topbar.classList.toggle('topbar-expanded', !value);
    if (shell) shell.classList.toggle('console-nav-expanded', !value);
    toggleButton.setAttribute('aria-expanded', String(!value));
    toggleButton.textContent = value ? '☰' : '×';
  }

  function modeFromPath() {
    const path = window.location.pathname;
    return path === '/admin-view' || path === '/admin' ? 'admin' : 'app';
  }

  function applyRouteMode(render) {
    const next = modeFromPath();
    if (api.mode.get() !== next) api.mode.set(next);
    if (render) {
      renderModeSwitch();
      renderAvatarMenu();
      renderCurrentMode();
    }
  }

  function syncPath(mode) {
    const item = modes.find((entry) => entry.value === mode) || modes[0];
    if (window.location.pathname !== item.path) {
      window.history.pushState({ mode }, '', item.path);
    }
  }

  function renderModeSwitch() {
    const current = api.mode.get();
    switcher.innerHTML = modes.map((mode) => `
      <button type="button" data-mode="${mode.value}" class="${mode.value === current ? 'active' : ''}" title="${escapeAttr(mode.label)}"><span class="mode-icon">${escapeHtml(mode.icon || '')}</span><span class="mode-label">${mode.label}</span></button>
    `).join('');
    switcher.querySelectorAll('button').forEach((button) => {
      button.addEventListener('click', (event) => {
        event.stopPropagation();
        api.mode.set(button.dataset.mode);
      });
    });
  }

  function renderAvatarMenu() {
    const user = api.auth.user();
    const label = user && user.username ? user.username : '网页用户';
    const role = user && user.role ? user.role : 'legacy';
    const currentMode = api.mode.get();
    const theme = readTheme();
    const darkActive = effectiveTheme(theme.mode) === 'dark';
    const initial = firstLetter(label);

    avatarButton.innerHTML = `<span>${escapeHtml(initial)}</span>`;
    avatarButton.title = `${label} · 用户菜单`;
    avatarButton.setAttribute('aria-label', `打开 ${label} 的用户菜单`);

    avatarMenu.innerHTML = `
      <div class="avatar-menu-profile">
        <div class="avatar-menu-face">${escapeHtml(initial)}</div>
        <div class="avatar-menu-info">
          <strong>${escapeHtml(label)}</strong>
          <span class="muted">网页账号历史独立 · 图集与收藏共享</span>
          <span class="badge">${escapeHtml(role)}${api.auth.isAdmin() ? ' · 管理员' : ''}</span>
        </div>
      </div>

      <div class="avatar-menu-section">
        <div class="avatar-menu-title">面板</div>
        <div class="avatar-menu-segment" role="group" aria-label="面板切换">
          ${modes.map((mode) => `
            <button type="button" data-menu-mode="${mode.value}" class="${mode.value === currentMode ? 'active' : ''}">${mode.label}</button>
          `).join('')}
        </div>
      </div>

      <div class="avatar-menu-section">
        <div class="avatar-menu-title">操作</div>
        <div class="avatar-menu-actions">
          <button type="button" class="avatar-menu-item" data-menu-refresh><span>↻</span><strong>刷新当前面板</strong></button>
          ${api.auth.isAdmin() ? '<button type="button" class="avatar-menu-item" data-menu-users><span>👥</span><strong>用户管理</strong></button>' : ''}
          <button type="button" class="avatar-menu-item danger" data-menu-logout><span>⏻</span><strong>登出</strong></button>
        </div>
      </div>

      <div class="avatar-menu-section">
        <div class="avatar-menu-title">主题模式</div>
        <div class="avatar-menu-segment theme-mode-segment" role="group" aria-label="主题模式">
          ${themeModes.map((mode) => `
            <button type="button" data-theme-mode="${mode.value}" class="${mode.value === theme.mode ? 'active' : ''}">${mode.label}</button>
          `).join('')}
        </div>
        <button type="button" class="avatar-menu-switch ${darkActive && theme.pureBlack ? 'active' : ''}" data-pure-black aria-pressed="${darkActive && theme.pureBlack ? 'true' : 'false'}" ${darkActive ? '' : 'disabled'}>
          <span>纯黑模式</span>
          <i>${darkActive ? (theme.pureBlack ? '开' : '关') : '仅暗色可用'}</i>
        </button>
      </div>

      <div class="avatar-menu-section">
        <div class="avatar-menu-title">主题色</div>
        <div class="avatar-accent-grid" role="group" aria-label="主题色选择">
          ${accentOptions.map((accent) => `
            <button type="button" data-theme-accent="${accent.value}" class="accent-dot accent-${accent.value} ${accent.value === theme.accent ? 'active' : ''}" title="${escapeAttr(accent.label)}" aria-label="${escapeAttr(accent.label)}">
              <span></span>
            </button>
          `).join('')}
        </div>
      </div>
    `;

    avatarMenu.querySelectorAll('[data-menu-mode]').forEach((button) => {
      button.addEventListener('click', () => {
        api.mode.set(button.dataset.menuMode);
        closeAvatarMenu();
      });
    });
    const refresh = avatarMenu.querySelector('[data-menu-refresh]');
    if (refresh) refresh.addEventListener('click', () => {
      renderCurrentMode();
      closeAvatarMenu();
    });
    const users = avatarMenu.querySelector('[data-menu-users]');
    if (users) users.addEventListener('click', () => {
      api.mode.set('admin');
      setCollapsed(false);
      window.dispatchEvent(new CustomEvent('pk-console-users-open'));
      closeAvatarMenu();
    });
    const logout = avatarMenu.querySelector('[data-menu-logout]');
    if (logout) logout.addEventListener('click', () => api.auth.logout());
    avatarMenu.querySelectorAll('[data-theme-mode]').forEach((button) => {
      button.addEventListener('click', () => updateTheme({ mode: button.dataset.themeMode }));
    });
    avatarMenu.querySelectorAll('[data-theme-accent]').forEach((button) => {
      button.addEventListener('click', () => updateTheme({ accent: button.dataset.themeAccent }));
    });
    const pureBlack = avatarMenu.querySelector('[data-pure-black]');
    if (pureBlack) pureBlack.addEventListener('click', () => updateTheme({ pureBlack: !readTheme().pureBlack }));
  }

  function renderCurrentMode() {
    const mode = api.mode.get();
    if (window.unmountApp) window.unmountApp(root);
    if (window.__picaKeepAdminCleanup) window.__picaKeepAdminCleanup();
    root.innerHTML = '';
    if (mode === 'admin') {
      window.renderAdmin(root);
      return;
    }
    window.renderApp(root);
  }

  function openAvatarMenu() {
    cancelCloseAvatarMenu();
    avatarMenu.hidden = false;
    avatarButton.setAttribute('aria-expanded', 'true');
    avatarWrap.classList.add('is-open');
  }

  function closeAvatarMenu() {
    cancelCloseAvatarMenu();
    avatarMenu.hidden = true;
    avatarButton.setAttribute('aria-expanded', 'false');
    avatarWrap.classList.remove('is-open');
  }

  function toggleAvatarMenu() {
    if (avatarMenu.hidden) openAvatarMenu();
    else closeAvatarMenu();
  }

  function scheduleCloseAvatarMenu() {
    cancelCloseAvatarMenu();
    avatarCloseTimer = window.setTimeout(closeAvatarMenu, 150);
  }

  function cancelCloseAvatarMenu() {
    if (!avatarCloseTimer) return;
    window.clearTimeout(avatarCloseTimer);
    avatarCloseTimer = null;
  }

  function isTopbarFunctionalTarget(target) {
    return !!(target && target.closest && target.closest('#topbar-toggle, #mode-switch, #topbar-avatar-wrap, #top-avatar-menu'));
  }

  function isReaderActive() {
    return document.documentElement.classList.contains('pk-reader-active');
  }

  function isCoarsePointer() {
    return !!(window.matchMedia && window.matchMedia('(hover: none), (pointer: coarse)').matches);
  }

  function isMobileShell() {
    return !!(window.matchMedia && window.matchMedia('(max-width: 760px)').matches);
  }

  function readTheme() {
    const mode = readThemeStorage(themeKeys.mode, 'system');
    const accent = readThemeStorage(themeKeys.accent, 'dynamic');
    const pureBlack = readThemeStorage(themeKeys.pureBlack, '0') === '1';
    return {
      mode: themeModes.some((item) => item.value === mode) ? mode : 'system',
      accent: accentOptions.some((item) => item.value === accent) ? accent : 'dynamic',
      pureBlack,
    };
  }

  function updateTheme(patch) {
    const current = readTheme();
    const next = Object.assign({}, current, patch || {});
    writeThemeStorage(themeKeys.mode, next.mode);
    writeThemeStorage(themeKeys.accent, next.accent);
    writeThemeStorage(themeKeys.pureBlack, next.pureBlack ? '1' : '0');
    applyTheme();
    renderAvatarMenu();
    openAvatarMenu();
  }

  function applyTheme() {
    const theme = readTheme();
    const effective = effectiveTheme(theme.mode);
    const doc = document.documentElement;
    doc.dataset.themeMode = theme.mode;
    doc.dataset.effectiveTheme = effective;
    doc.dataset.accent = theme.accent;
    doc.dataset.pureBlack = theme.pureBlack ? '1' : '0';
  }

  function effectiveTheme(mode) {
    if (mode === 'light' || mode === 'dark') return mode;
    if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) return 'dark';
    return 'light';
  }

  function bindSystemThemeListener() {
    if (!window.matchMedia) return;
    const media = window.matchMedia('(prefers-color-scheme: dark)');
    const onChange = () => {
      if (readTheme().mode === 'system') {
        applyTheme();
        if (started) renderAvatarMenu();
      }
    };
    if (media.addEventListener) media.addEventListener('change', onChange);
    else if (media.addListener) media.addListener(onChange);
  }

  function bindMobileViewportMetrics() {
    const doc = document.documentElement;
    const viewport = window.visualViewport;
    let raf = 0;
    let minHeight = 0;
    let maxHeight = 0;
    let orientationKey = '';
    const clamp = (value, min, max) => Math.max(min, Math.min(max, value));
    const update = () => {
      raf = 0;
      const isMobile = window.matchMedia && window.matchMedia('(max-width: 760px)').matches;
      const visibleHeight = Math.round(viewport ? viewport.height : window.innerHeight);
      doc.style.setProperty('--mobile-viewport-height', `${Math.max(320, visibleHeight || window.innerHeight || 0)}px`);
      if (!isMobile) {
        doc.style.setProperty('--mobile-browser-chrome-pad', '0px');
        return;
      }
      const nextOrientationKey = `${window.innerWidth > window.innerHeight ? 'landscape' : 'portrait'}:${Math.round(window.innerWidth / 10)}`;
      if (nextOrientationKey !== orientationKey) {
        orientationKey = nextOrientationKey;
        minHeight = visibleHeight;
        maxHeight = visibleHeight;
      } else {
        minHeight = minHeight ? Math.min(minHeight, visibleHeight) : visibleHeight;
        maxHeight = maxHeight ? Math.max(maxHeight, visibleHeight) : visibleHeight;
      }
      const range = Math.max(0, maxHeight - minHeight);
      const expanded = range < 24 ? true : visibleHeight <= minHeight + range * 0.45;
      const learnedPad = range >= 24 ? clamp(Math.round(range * 0.55), 64, 84) : 64;
      doc.style.setProperty('--mobile-browser-chrome-pad', expanded ? `${learnedPad}px` : '0px');
    };
    const schedule = () => {
      if (raf) return;
      raf = window.requestAnimationFrame(update);
    };
    update();
    window.addEventListener('resize', schedule, { passive: true });
    window.addEventListener('orientationchange', schedule, { passive: true });
    if (viewport) {
      viewport.addEventListener('resize', schedule, { passive: true });
      viewport.addEventListener('scroll', schedule, { passive: true });
    }
  }

  function readThemeStorage(key, fallback) {
    try {
      const value = window.localStorage.getItem(key);
      return value == null ? fallback : value;
    } catch (_) {
      return fallback;
    }
  }

  function writeThemeStorage(key, value) {
    try { window.localStorage.setItem(key, value); } catch (_) {}
  }

  function firstLetter(value) {
    const text = String(value || '').trim();
    return text ? Array.from(text)[0].toUpperCase() : 'P';
  }

  function escapeHtml(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function escapeAttr(value) {
    return escapeHtml(value).replace(/`/g, '&#96;');
  }

  window.addEventListener('pk-console-auth-ready', start);
  if (api.auth.isLoggedIn()) start();
})();
