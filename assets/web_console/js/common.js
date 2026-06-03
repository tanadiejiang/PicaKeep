/*
PicaKeepConsole contract (implemented by this file; plans 2/3 must only depend on this surface):

PicaKeepConsole = {
  api: {
    get(path)            -> Promise<any(JSON)>
    post(path, body?)    -> Promise<any(JSON)>
    put(path, body?)     -> Promise<any(JSON)>
    del(path)            -> Promise<any(JSON)>
    imageUrl(path)       -> string
  },
  remote: {
    get(targetBase, subPath)        -> Promise<any(JSON)>
    imageUrl(targetBase, subPath)   -> string
  },
  mode: {
    get()        -> 'admin'|'app'
    set(v)       -> void
    onChange(cb) -> unsubscribe()
  },
  source: {
    get()  -> 'local'|'merged'|'remote'
    set(v) -> void
    onChange(cb) -> unsubscribe()
  },
  remoteTarget: {
    get()    -> string
    set(url) -> void
  },
  auth: {
    token()      -> string|null
    isLoggedIn() -> boolean
    logout()     -> Promise<void>
    user()       -> {id,username,role}|null
    isAdmin()    -> boolean
    setUser(u)   -> void
    refreshMe()  -> Promise<user|null>
  },
  history: {
    list(limit?)       -> Promise<any(JSON)>
    save(body)         -> Promise<any(JSON)>
    remove(target)     -> Promise<any(JSON)>
    clear()            -> Promise<any(JSON)>
  }
};

View mount contract:
  window.renderAdmin(rootEl)
  window.renderApp(rootEl)

Contract implemented with the signatures above.
*/
(function () {
  'use strict';

  const keys = Object.freeze({
    token: 'pk-console-token',
    user: 'pk-console-user',
    mode: 'pk-console-mode',
    source: 'pk-console-source',
    remoteTarget: 'pk-console-remote-target',
  });

  const modeValues = new Set(['admin', 'app']);
  const sourceValues = new Set(['local', 'merged', 'remote']);
  const modeListeners = new Set();
  const sourceListeners = new Set();
  const authListeners = new Set();

  function readStorage(key, fallback) {
    try {
      const value = window.localStorage.getItem(key);
      return value == null ? fallback : value;
    } catch (_) {
      return fallback;
    }
  }

  function writeStorage(key, value) {
    try {
      window.localStorage.setItem(key, value);
    } catch (_) {}
  }

  function removeStorage(key) {
    try {
      window.localStorage.removeItem(key);
    } catch (_) {}
  }

  function notify(listeners, value) {
    listeners.forEach((listener) => {
      try { listener(value); } catch (error) { console.error(error); }
    });
  }

  function token() {
    const value = readStorage(keys.token, '');
    return value ? value : null;
  }

  function user() {
    const raw = readStorage(keys.user, '');
    if (!raw) return null;
    try {
      const parsed = JSON.parse(raw);
      return parsed && typeof parsed === 'object' ? parsed : null;
    } catch (_) {
      return null;
    }
  }

  function setUser(value) {
    if (value && typeof value === 'object') writeStorage(keys.user, JSON.stringify(value));
    else removeStorage(keys.user);
    notify(authListeners, { token: token(), user: user() });
  }

  function setToken(value) {
    if (value) writeStorage(keys.token, value);
    else removeStorage(keys.token);
    if (!value) removeStorage(keys.user);
    notify(authListeners, { token: token(), user: user() });
  }

  function withTokenUrl(path) {
    const currentToken = token();
    if (!currentToken) return path;
    const url = new URL(path, window.location.origin);
    url.searchParams.set('__token', currentToken);
    return `${url.pathname}${url.search}${url.hash}`;
  }

  async function parseResponse(response, path) {
    const contentType = response.headers.get('content-type') || '';
    let payload = null;
    if (contentType.includes('application/json')) {
      payload = await response.json().catch(() => null);
    } else {
      payload = await response.text().catch(() => '');
    }
    if (!response.ok) {
      if (response.status === 401) {
        setToken('');
        setUser(null);
        window.dispatchEvent(new CustomEvent('pk-console-auth-required'));
      }
      const message = payload && typeof payload === 'object' && payload.error
        ? payload.error
        : `${path} -> ${response.status}`;
      throw new Error(message);
    }
    return payload;
  }

  async function requestJson(method, path, body) {
    const headers = { 'Accept': 'application/json' };
    const currentToken = token();
    if (currentToken) headers.Authorization = `Bearer ${currentToken}`;
    const options = { method, headers };
    if (body !== undefined) {
      headers['Content-Type'] = 'application/json';
      options.body = JSON.stringify(body);
    }
    const response = await fetch(path, options);
    return parseResponse(response, path);
  }

  function setRouteMode(value) {
    if (!modeValues.has(value)) return;
    currentMode = value;
    writeStorage(keys.mode, value);
    notify(modeListeners, value);
  }

  async function refreshMe() {
    if (!token()) return null;
    const payload = await requestJson('GET', '/api/console/me');
    const nextUser = payload && payload.user ? payload.user : payload;
    if (nextUser && typeof nextUser === 'object' && nextUser.username) {
      setUser(nextUser);
      return nextUser;
    }
    return user();
  }

  async function logout() {
    try {
      if (token()) await requestJson('POST', '/api/console/logout');
    } catch (_) {
      // Logging out must still clear the local session when the new endpoint is not ready.
    } finally {
      setToken('');
      setUser(null);
      window.dispatchEvent(new CustomEvent('pk-console-auth-required'));
    }
  }

  function normalizeRemoteTarget(targetBase) {
    return String(targetBase || '').trim().replace(/\/+$/, '');
  }

  function normalizeSubPath(subPath) {
    const value = String(subPath || '').trim();
    if (!value) return '/';
    return value.startsWith('/') ? value : `/${value}`;
  }

  function remoteProxyUrl(targetBase, subPath) {
    const target = normalizeRemoteTarget(targetBase);
    const path = normalizeSubPath(subPath);
    const url = new URL('/api/remote/proxy', window.location.origin);
    url.searchParams.set('target', target);
    url.searchParams.set('path', path);
    const currentToken = token();
    if (currentToken) url.searchParams.set('__token', currentToken);
    return `${url.pathname}${url.search}`;
  }

  function routeMode() {
    const path = window.location.pathname;
    return path === '/admin-view' || path === '/admin' ? 'admin' : 'app';
  }

  let currentMode = routeMode();

  function makeValueStore(storageKey, allowed, fallback, listeners, reader) {
    return Object.freeze({
      get() {
        const value = reader ? reader() : readStorage(storageKey, fallback);
        return allowed.has(value) ? value : fallback;
      },
      set(value) {
        if (!allowed.has(value)) return;
        writeStorage(storageKey, value);
        notify(listeners, value);
      },
      onChange(callback) {
        listeners.add(callback);
        return () => listeners.delete(callback);
      },
    });
  }

  const consoleApi = {
    api: Object.freeze({
      get(path) { return requestJson('GET', path); },
      post(path, body) { return requestJson('POST', path, body); },
      put(path, body) { return requestJson('PUT', path, body); },
      del(path) { return requestJson('DELETE', path); },
      imageUrl(path) { return withTokenUrl(path); },
    }),
    remote: Object.freeze({
      get(targetBase, subPath) { return requestJson('GET', remoteProxyUrl(targetBase, subPath)); },
      imageUrl(targetBase, subPath) { return remoteProxyUrl(targetBase, subPath); },
    }),
    mode: Object.freeze({
      get() { return currentMode; },
      set: setRouteMode,
      onChange(callback) {
        modeListeners.add(callback);
        return () => modeListeners.delete(callback);
      },
    }),
    source: makeValueStore(keys.source, sourceValues, 'local', sourceListeners),
    remoteTarget: Object.freeze({
      get() { return readStorage(keys.remoteTarget, ''); },
      set(url) { writeStorage(keys.remoteTarget, String(url || '').trim()); },
    }),
    auth: Object.freeze({
      token,
      isLoggedIn() { return !!token(); },
      logout,
      setToken,
      user,
      isAdmin() { const current = user(); return !!current && current.role === 'admin'; },
      setUser,
      refreshMe,
      onChange(callback) {
        authListeners.add(callback);
        return () => authListeners.delete(callback);
      },
    }),
    history: Object.freeze({
      list(limit) { return requestJson('GET', `/api/library/history?limit=${encodeURIComponent(limit || 20)}`); },
      save(body) { return requestJson('POST', '/api/library/history', body || {}); },
      remove(target) { return requestJson('DELETE', `/api/library/history?target=${encodeURIComponent(target)}`); },
      clear() { return requestJson('DELETE', '/api/library/history'); },
    }),
  };

  window.PicaKeepConsole = Object.freeze(consoleApi);
})();
