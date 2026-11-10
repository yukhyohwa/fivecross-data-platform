// 统一鉴权：可选登录（JWT）+ 共享令牌网关（X-Auth-Token，可选）。
// 所有 /api/* 请求自动携带 Authorization: Bearer <JWT>（若已登录）与 X-Auth-Token（若配置）。
// 登录/登出/身份状态经 window.auth 暴露，供顶栏/侧边栏挂「登录」入口。
// 必须在其它业务脚本之前加载，才能在它们的 fetch 发出前接管 window.fetch。
(function () {
  var GATEWAY_KEY = 'wb_auth_token'; // 共享网关令牌（X-Auth-Token）
  var JWT_KEY = 'wb_jwt_token';      // access token
  var USER_KEY = 'wb_jwt_user';      // {id, username, role}

  function lsGet(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }
  function lsSet(k, v) { try { if (v) localStorage.setItem(k, v); else localStorage.removeItem(k); } catch (e) {} }

  function getGatewayToken() { return lsGet(GATEWAY_KEY) || ''; }
  function setGatewayToken(t) { lsSet(GATEWAY_KEY, t); }
  function getJwt() { return lsGet(JWT_KEY) || ''; }
  function setJwt(t) { lsSet(JWT_KEY, t); }
  function getUser() { var u = lsGet(USER_KEY); if (!u) return null; try { return JSON.parse(u); } catch (e) { return null; } }
  function setUser(u) { lsSet(USER_KEY, u ? JSON.stringify(u) : ''); }
  function clearSession() { setJwt(''); setUser(null); }

  var origFetch = window.fetch ? window.fetch.bind(window) : null;
  if (!origFetch) return;

  var prompting = false;

  function urlOf(input) {
    if (typeof input === 'string') return input;
    if (input && typeof input.url === 'string') return input.url;
    return '';
  }
  function isAuthPath(input) {
    var p = urlOf(input).split('?')[0];
    return p.indexOf('/api/auth/login') === 0 || p.indexOf('/api/auth/refresh') === 0;
  }

  window.fetch = function (input, init) {
    init = init || {};
    var headers = new Headers(init.headers || {});
    var gt = getGatewayToken();
    if (gt && !headers.has('X-Auth-Token')) headers.set('X-Auth-Token', gt);
    var jwt = getJwt();
    if (jwt && !headers.has('Authorization')) headers.set('Authorization', 'Bearer ' + jwt);
    init.headers = headers;
    return origFetch(input, init).then(function (resp) {
      if (resp.status === 401 && !isAuthPath(input)) {
        if (getJwt()) {
          clearSession();          // 登录态过期 → 回登录态（与 sql-ide 前端协议一致）
          window.location.reload();
        } else if (!prompting) {
          prompting = true;        // 网关模式兜底：输入共享令牌
          var t = window.prompt('需要访问令牌（后端 .env 里的 AUTH_TOKEN）：');
          prompting = false;
          if (t && t.trim()) { setGatewayToken(t.trim()); window.location.reload(); }
        }
      }
      return resp;
    });
  };

  function api(method, path, body, auth) {
    var headers = { 'Content-Type': 'application/json' };
    if (auth) headers['Authorization'] = 'Bearer ' + auth;
    // 统一走 window.fetch 包装（自动附 JWT/网关令牌 + 统一 401 行为），不再直连 origFetch（审计 P1-13）
    return window.fetch(path, { method: method, headers: headers, body: body ? JSON.stringify(body) : undefined })
      .then(function (r) { return r.json().then(function (d) { return { status: r.status, data: d }; }); });
  }

  window.auth = {
    isLoggedIn: function () { return !!getJwt(); },
    getUser: getUser,
    login: function (username, password) {
      return api('POST', '/api/auth/login', { username: username, password: password }).then(function (res) {
        if (res.status === 200 && res.data && res.data.access_token) {
          setJwt(res.data.access_token);
          setUser(res.data.user || { username: username });
          return { ok: true };
        }
        return { ok: false, error: (res.data && res.data.detail) || '登录失败' };
      }).catch(function () { return { ok: false, error: '网络错误' }; });
    },
    logout: function () {
      var jwt = getJwt();
      if (jwt) { api('POST', '/api/auth/logout', null, jwt).catch(function () {}); }
      clearSession();
      window.location.reload();
    },
    openLoginModal: function () { openLoginModal(); },
    renderLoginButton: renderLoginButton,
  };

  // ── 登录弹窗（单例） ───────────────────────────────────────────
  function buildModal() {
    if (document.getElementById('auth-modal')) return;
    var overlay = document.createElement('div');
    overlay.id = 'auth-modal';
    overlay.className = 'modal-overlay';
    overlay.hidden = true;
    overlay.innerHTML =
      '<div class="modal">' +
      '  <div class="modal-head"><div class="modal-title">登录 FiveCross 数据平台</div></div>' +
      '  <div class="field" style="margin-top:14px;"><label class="field-label" for="auth-username">用户名</label><input id="auth-username" class="control" autocomplete="username"></div>' +
      '  <div class="field" style="margin-top:10px;"><label class="field-label" for="auth-password">密码</label><input id="auth-password" class="control" type="password" autocomplete="current-password"></div>' +
      '  <div id="auth-error" style="color:var(--error);font-size:12px;margin-top:10px;display:none;"></div>' +
      '  <div class="toolbar" style="margin-top:16px;margin-bottom:0;">' +
      '    <button id="auth-submit" class="btn btn-primary">登录</button>' +
      '    <button id="auth-close" class="btn">取消</button>' +
      '  </div>' +
      '</div>';
    document.body.appendChild(overlay);
    overlay.addEventListener('click', function (e) { if (e.target === overlay) closeModal(); });
    document.getElementById('auth-close').addEventListener('click', closeModal);
    document.getElementById('auth-submit').addEventListener('click', submitLogin);
    document.getElementById('auth-password').addEventListener('keydown', function (e) { if (e.key === 'Enter') submitLogin(); });
  }
  function openLoginModal() {
    buildModal();
    var o = document.getElementById('auth-modal');
    o.hidden = false;
    document.getElementById('auth-error').style.display = 'none';
    document.getElementById('auth-username').value = '';
    document.getElementById('auth-password').value = '';
    document.getElementById('auth-username').focus();
  }
  function closeModal() { var o = document.getElementById('auth-modal'); if (o) o.hidden = true; }
  function submitLogin() {
    var u = document.getElementById('auth-username').value.trim();
    var p = document.getElementById('auth-password').value;
    if (!u || !p) return;
    var btn = document.getElementById('auth-submit');
    var err = document.getElementById('auth-error');
    btn.disabled = true;
    window.auth.login(u, p).then(function (res) {
      if (res.ok) { window.location.reload(); }
      else { err.textContent = res.error; err.style.display = ''; btn.disabled = false; }
    });
  }

  // ── 登录按钮（🔑 登录 / 👤 用户名 + 退出） ─────────────────────
  function renderLoginButton(container) {
    if (!container) return;
    container.innerHTML = '';
    var b = document.createElement('button');
    b.className = 'btn btn-sm';
    if (window.auth.isLoggedIn()) {
      var user = getUser() || {};
      b.textContent = '👤 ' + (user.username || '已登录');
      b.title = '退出登录';
      b.addEventListener('click', function () { window.auth.logout(); });
    } else {
      b.textContent = '🔑 登录';
      b.title = '登录';
      b.addEventListener('click', function () { openLoginModal(); });
    }
    container.appendChild(b);
  }

  function renderAll() {
    renderLoginButton(document.getElementById('wb-auth'));
    renderLoginButton(document.getElementById('nav-auth'));
  }

  // ── 启动：渲染入口 + 校验已存 token ───────────────────────────
  function init() {
    renderAll();
    var jwt = getJwt();
    if (!jwt) return;
    api('GET', '/api/auth/me', null, jwt).then(function (res) {
      if (res.status === 200 && res.data) {
        setUser({ id: res.data.id, username: res.data.username, role: res.data.role });
      } else {
        clearSession();
      }
      renderAll();
    }).catch(function () {});
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
