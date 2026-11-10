'use strict';
/* 顶部导航：读取当前页路径，渲染并高亮；右侧放「三模型配置」入口 + 游戏切换器。
   每个页面顶部放 <nav id="topnav"></nav> 并引入本脚本。 */

// ---- 全局游戏切换：所有请求自动带 X-Game 头 ----
(function () {
  var KEY = 'chatbi.game';
  function currentKey() {
    try { return localStorage.getItem(KEY) || ''; } catch (e) { return ''; }
  }
  function setKey(key) {
    try {
      if (key) { localStorage.setItem(KEY, key); } else { localStorage.removeItem(KEY); }
    } catch (e) {}
  }
  window.currentGameKey = currentKey;
  window.setGameKey = setKey;

  // 聊天页「不选游戏」哨兵判定（本文件自持定义，不依赖 app.js——reports.js/chat-history.js
  // 只加载 nav.js）。chatbi.game.mode=none 且当前页是聊天页时，对聊天端点下发
  // X-Game: __any__（后端识别哨兵后提问绑定游戏，而不是回落默认游戏）。
  window.__chatGameSentinel = function (url) {
    var mode = '';
    try { mode = localStorage.getItem('chatbi.game.mode') || ''; } catch (e) {}
    if (mode !== 'none') return '';
    var path = location.pathname || '';
    if (!/chat\.html$/.test(path)) return '';
    var u = String(url == null ? '' : url).split('?')[0];
    if (u.indexOf('/') !== 0) u = '/' + u;
    // 边界：'/api/chat' 后必须是 '/'、'?' 或结尾——排除 '/api/chat-history'；
    // 含 suggest/gap-*/export-csv 等附属端点（后端对哨兵均容忍 None/提问）。
    if (u === '/api/agent/chat/stream') return '__any__';
    if (u.slice(0, 9) === '/api/chat' && (u.length === 9 || u[9] === '/' || u[9] === '?')) {
      return '__any__';
    }
    return '';
  };

  var _fetch = window.fetch;
  window.fetch = function (url, opts) {
    opts = opts || {};
    var sentinel = window.__chatGameSentinel(url);
    if (sentinel) {
      var sh = opts.headers;
      if (sh instanceof Headers) {
        sh.set('X-Game', sentinel);
      } else {
        sh = sh || {};
        sh['X-Game'] = sentinel;
        opts.headers = sh;
      }
      return _fetch.call(window, url, opts);
    }
    var key = currentKey();
    if (key) {
      var headers = opts.headers;
      if (headers instanceof Headers) {
        headers.set('X-Game', key);
      } else {
        headers = headers || {};
        headers['X-Game'] = key;
        opts.headers = headers;
      }
    }
    return _fetch.call(window, url, opts);
  };
})();

// ---- 三模型配置弹窗（全局生效，供各页右上角入口使用） ----
(function () {
  function buildModal() {
    if (document.getElementById('config-modal')) return;
    var overlay = document.createElement('div');
    overlay.id = 'config-modal';
    overlay.className = 'modal-overlay';
    overlay.hidden = true;
    overlay.innerHTML =
      '<div class="modal">' +
      '  <div class="field-label">三模型配置（生成 / 验证 / 汇总，全局生效）</div>' +
      '  <div class="split" style="margin-top:12px;">' +
      '    <div class="field" style="flex:1;"><label class="field-label" for="cfg-gen">生成轮模型 A</label><select id="cfg-gen" class="control"></select></div>' +
      '    <div class="field" style="flex:1;"><label class="field-label" for="cfg-ver">验证轮模型 B</label><select id="cfg-ver" class="control"></select></div>' +
      '    <div class="field" style="flex:1;"><label class="field-label" for="cfg-sum">汇总模型 C</label><select id="cfg-sum" class="control"></select></div>' +
      '  </div>' +
      '  <div class="toolbar" style="margin-top:16px;">' +
      '    <button id="cfg-save" class="btn btn-primary">💾 保存配置</button>' +
      '    <button id="cfg-close" class="btn">关闭</button>' +
      '  </div>' +
      '</div>';
    document.body.appendChild(overlay);

    overlay.addEventListener('click', function (e) { if (e.target === overlay) close(); });
    document.getElementById('cfg-close').addEventListener('click', close);
    document.getElementById('cfg-save').addEventListener('click', saveConfig);
  }

  function open() {
    buildModal();
    var overlay = document.getElementById('config-modal');
    overlay.hidden = false;
    var saveBtn = document.getElementById('cfg-save');
    if (saveBtn) saveBtn.disabled = true;
    // 填充模型列表
    window.fetch('/api/models')
      .then(function (r) { return r.json(); })
      .then(function (d) {
        fillSelect('#cfg-gen', d.models || [], 0);
        fillSelect('#cfg-ver', d.models || [], 1);
        fillSelect('#cfg-sum', d.models || [], 0);
        return window.fetch('/api/reports/config');
      })
      .then(function (r) { return r.json(); })
      .then(function (cfg) {
        if (cfg.model_gen) document.getElementById('cfg-gen').value = cfg.model_gen;
        if (cfg.model_ver) document.getElementById('cfg-ver').value = cfg.model_ver;
        if (cfg.model_sum) document.getElementById('cfg-sum').value = cfg.model_sum;
        if (saveBtn) saveBtn.disabled = false;
      })
      .catch(function () {
        if (saveBtn) saveBtn.disabled = false;
      });
  }

  function close() {
    var overlay = document.getElementById('config-modal');
    if (overlay) overlay.hidden = true;
  }

  function fillSelect(sel, options, defaultIndex) {
    var el = document.querySelector(sel);
    if (!el) return;
    el.innerHTML = '';
    options.forEach(function (m) {
      var o = document.createElement('option');
      o.value = m;
      o.textContent = m;
      el.appendChild(o);
    });
    if (el.options.length) el.selectedIndex = Math.min(defaultIndex, el.options.length - 1);
  }

  function saveConfig() {
    var gen = document.getElementById('cfg-gen').value;
    var ver = document.getElementById('cfg-ver').value;
    var sum = document.getElementById('cfg-sum').value;
    if (!gen || !ver || !sum) { alert('模型列表尚未加载完成，请稍候再试'); return; }
    window.fetch('/api/reports/config', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model_gen: gen,
        model_ver: ver,
        model_sum: sum,
      }),
    })
      .then(function (r) {
        if (!r.ok) { alert('保存配置失败'); return; }
        alert('✅ 三模型配置已保存');
        close();
      });
  }

  window.openConfigModal = open;
})();

(function () {
  // 在 iframe 内（React 壳嵌入）不渲染导航/游戏切换/配置/登录入口——这些由壳顶栏统一提供；
  // 本文件顶部的 X-Game 头注入仍生效，保证 iframe 内页面取数用对游戏。
  if (window.self !== window.top) return;
  var PAGES = [
    { href: '/', label: '🏠 回到工作台' },
    { href: '/app/chat.html', label: '💬 聊天窗口' },
    // 聊天记录已迁入 React 壳内 tab（MERGE-1），不再列独立导航；
    // 订阅报告已并入 React 壳「个人定制」tab，不再列独立导航
  ];
  var nav = document.getElementById('topnav');
  if (!nav) return;
  var path = location.pathname;
  var current = path === '/' ? 'index.html' : path.split('/').pop();
  var links = PAGES.map(function (p) {
    var file = p.href === '/' ? 'index.html' : p.href.split('/').pop();
    var active = file === current ? 'active' : '';
    return '<a href="' + p.href + '" class="' + active + '">' + p.label + '</a>';
  }).join('');
  nav.innerHTML =
    '<div class="nav-brand">FiveCross 数据平台</div>' +
    '<div class="nav-links">' + links + '</div>' +
    '<div class="nav-right">' +
    '  <span id="nav-auth"></span>' +
    '  <button id="nav-config-btn" class="btn btn-sm" title="三模型配置">⚙️ 配置</button>' +
    '  <div class="nav-game"><span>数据源</span><select id="source-select" title="筛选数据源">' +
    '    <option value="all">全部</option><option value="ta_cn">数数中国</option><option value="ta_global">数数海外</option><option value="odps_cn">阿里云中国</option><option value="odps_global">阿里云海外</option><option value="backup">本地备份</option>' +
    '  </select></div>' +
    '  <div class="nav-game"><span>游戏</span><select id="game-family-select" title="筛选游戏"></select><select id="game-select" title="选择游戏项目"></select></div>' +
    '</div>';

  document.getElementById('nav-config-btn').addEventListener('click', function () {
    window.openConfigModal && window.openConfigModal();
  });

  // 登录入口（可选登录；auth.js 已在 nav.js 之前加载）
  if (window.auth && window.auth.renderLoginButton) {
    window.auth.renderLoginButton(document.getElementById('nav-auth'));
  }

  var sourceSel = document.getElementById('source-select');
  var familySel = document.getElementById('game-family-select');
  var sel = document.getElementById('game-select');
  var SOURCE_KEY = 'chatbi.data.source';
  function sourceOf(g) {
    if (g.source_type === 'local_backup' || g.source_group === '本地备份') return 'backup';
    if (g.source_group === '数数中国') return 'ta_cn';
    if (g.source_group === '数数海外') return 'ta_global';
    if (g.source_group === '阿里云中国') return 'odps_cn';
    if (g.source_group === '阿里云海外') return 'odps_global';
    if (g.client_engine === 'ta') return g.client_region === 'china' ? 'ta_cn' : 'ta_global';
    if (g.client_engine === 'odps') return g.client_region === 'china' ? 'odps_cn' : 'odps_global';
    return 'backup';
  }
  function familyOf(g) {
    return (g.key || '').replace(/_(cn_ali|tc|gl|kr|sea|jp|global)$/, '') || g.key;
  }
  function familyLabel(g) {
    var name = String(g.name || g.key || '');
    return name.replace(/[（(](CN|TC|GL|KR|SEA|JP|GLOBAL|中国|台湾|全球|韩国|日本|东南亚|海外)[^）)]*[）)]$/, '') || name;
  }
  window.fetch('/api/games')
    .then(function (r) { return r.json(); })
    .then(function (data) {
      var games = data.games || [];
      if (!games.length) {
        familySel.innerHTML = '<option value="">无游戏权限</option>';
        sel.innerHTML = '<option value="">无游戏权限</option>';
        sourceSel.disabled = familySel.disabled = sel.disabled = true;
        return;
      }
      var def = data.default || '';
      var chosen = window.currentGameKey();
      if (!chosen || !games.some(function (g) { return g.key === chosen; })) {
        chosen = def;
        window.setGameKey(chosen);
      }
      var current = games.find(function (g) { return g.key === chosen; }) || games[0];
      var storedSource = '';
      try { storedSource = localStorage.getItem(SOURCE_KEY) || ''; } catch (e) {}
      sourceSel.value = storedSource || sourceOf(current) || 'all';
      function escapeHtml(s) {
        return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
          return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
        });
      }
      function visibleGames() {
        var source = sourceSel.value;
        return games.filter(function (g) { return source === 'all' || sourceOf(g) === source; });
      }
      function renderFamilies() {
        var visible = visibleGames();
        var families = [];
        visible.forEach(function (g) {
          var key = familyOf(g);
          if (!families.some(function (x) { return x.key === key; })) families.push({ key: key, label: familyLabel(g) });
        });
        var currentFamily = familyOf(games.find(function (g) { return g.key === chosen; }) || visible[0] || {});
        if (!families.some(function (x) { return x.key === currentFamily; })) currentFamily = families[0] && families[0].key;
        familySel.innerHTML = families.map(function (f) {
          return '<option value="' + escapeHtml(f.key) + '"' + (f.key === currentFamily ? ' selected' : '') + '>' + escapeHtml(f.label) + '</option>';
        }).join('');
        renderProjects(currentFamily);
      }
      function renderProjects(family) {
        var visible = visibleGames().filter(function (g) { return familyOf(g) === family; });
        sel.innerHTML = visible.map(function (g) {
          var label = (g.name && g.name !== g.key) ? g.name : g.key;
          return '<option value="' + escapeHtml(g.key) + '"' + (g.key === chosen ? ' selected' : '') + '>' + escapeHtml(label) + '</option>';
        }).join('') || '<option value="">该数据源暂无项目</option>';
        sel.disabled = !visible.length;
      }
      renderFamilies();
      sourceSel.addEventListener('change', function () {
        try { localStorage.setItem(SOURCE_KEY, sourceSel.value); } catch (e) {}
        renderFamilies();
      });
      familySel.addEventListener('change', function () { renderProjects(familySel.value); });
    })
    .catch(function () {
      familySel.innerHTML = '<option value="">加载失败</option>';
      sel.innerHTML = '<option value="">加载失败</option>';
    });

  sel.addEventListener('change', function () {
    if (!sel.value) return;
    window.setGameKey(sel.value);
    location.reload();
  });
})();

// ---- 侧边栏面板折叠：点击 .panel-toggle 折叠/展开同面板内的 .panel-body ----
(function () {
  document.addEventListener('click', function (e) {
    var t = e.target;
    while (t && t !== document && !(t.classList && t.classList.contains('panel-toggle'))) {
      t = t.parentElement;
    }
    if (!t || t === document) return;
    var panel = t.closest('.panel');
    var body = panel && panel.querySelector('.panel-body');
    if (!body) return;
    var collapsed = !body.hidden;
    body.hidden = collapsed;
    t.classList.toggle('collapsed', collapsed);
  });
})();
