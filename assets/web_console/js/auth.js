(function () {
  'use strict';

  const mask = document.getElementById('login-mask');
  const shell = document.getElementById('console-shell');
  const api = window.PicaKeepConsole;

  function renderLogin() {
    const shouldShowWarning = readEmptyPasswordWarning();
    mask.innerHTML = `
      <div class="login-card">
        <div class="brand">PicaKeep Console</div>
        <div class="sub">请输入网页账号与密码。旧服务端可留空用户名，继续使用后台密码登录；未设置密码时仅应在可信局域网中使用。</div>
        <div id="login-warning" class="login-warning" ${shouldShowWarning ? '' : 'hidden'}>未设置后台密码：局域网内任何人都可能访问本后台，请尽快在服务配置中设置密码。</div>
        <form id="login-form">
          <label>用户名
            <input id="login-username" type="text" autocomplete="username" placeholder="admin / 留空兼容旧后台" autofocus>
          </label>
          <label>密码
            <input id="login-password" type="password" autocomplete="current-password">
          </label>
          <button class="action" type="submit">登录</button>
          <div id="login-error" class="login-error"></div>
        </form>
      </div>
    `;
    const form = document.getElementById('login-form');
    form.addEventListener('submit', onSubmit);
  }

  function readEmptyPasswordWarning() {
    try {
      return window.localStorage.getItem('pk-console-empty-password-warning') === '1';
    } catch (_) {
      return false;
    }
  }

  function setEmptyPasswordWarning(value) {
    try {
      if (value) window.localStorage.setItem('pk-console-empty-password-warning', '1');
      else window.localStorage.removeItem('pk-console-empty-password-warning');
    } catch (_) {}
    const warning = document.getElementById('login-warning');
    if (warning) warning.hidden = !value;
  }

  function showLogin(message) {
    renderLogin();
    shell.hidden = true;
    mask.hidden = false;
    mask.style.display = 'flex';
    const error = document.getElementById('login-error');
    if (message && error) error.textContent = message;
    const input = document.getElementById('login-username');
    if (input) setTimeout(() => input.focus(), 0);
  }

  function showShell() {
    mask.hidden = true;
    mask.style.display = 'none';
    shell.hidden = false;
    window.dispatchEvent(new CustomEvent('pk-console-auth-ready'));
  }

  async function onSubmit(event) {
    event.preventDefault();
    const button = event.target.querySelector('button[type="submit"]');
    const error = document.getElementById('login-error');
    const username = document.getElementById('login-username').value.trim();
    const password = document.getElementById('login-password').value;
    if (error) error.textContent = '';
    if (button) button.disabled = true;
    try {
      const response = await fetch('/api/console/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' },
        body: JSON.stringify({ username, password }),
      });
      const payload = await response.json().catch(() => ({}));
      if (!response.ok || !payload.token) {
        throw new Error(payload.error || '登录失败');
      }
      api.auth.setToken(payload.token);
      api.auth.setUser(payload.user || (username ? { id: username, username, role: 'admin' } : null));
      setEmptyPasswordWarning(!!payload.emptyPassword);
      await api.auth.refreshMe().catch(() => null);
      window.location.reload();
    } catch (err) {
      if (error) error.textContent = err instanceof Error ? err.message : String(err || '登录失败');
    } finally {
      if (button) button.disabled = false;
    }
  }

  async function boot() {
    renderLogin();
    window.addEventListener('pk-console-auth-required', () => showLogin('登录已失效，请重新登录。'));
    if (!api.auth.isLoggedIn()) {
      showLogin('');
      return;
    }
    showShell();
    try {
      await api.auth.refreshMe();
    } catch (_) {
      // A 401 is handled by common.js. Other failures keep the legacy token path usable until plan A lands.
    }
  }

  window.PicaKeepAuthUi = Object.freeze({ showLogin, showShell });
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot, { once: true });
  } else {
    boot();
  }
})();
