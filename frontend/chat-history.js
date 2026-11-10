'use strict';

var state = { list: [], current: null, session: null, models: [], kbDraft: null, verifying: false, trash: [], showTrash: false, viewGen: 0 };

function $(s) { return document.querySelector(s); }

async function loadModels() {
  try {
    var res = await fetch('/api/models');
    if (!res.ok) throw new Error('HTTP ' + res.status);
    var data = await res.json();
    state.models = data.models || [];
  } catch (e) {
    state.models = [];
    console.error('加载模型列表失败', e);
  }
}

async function loadList(q) {
  // 视图代际（对抗审查）：列表/回收站两个视图共用 #session-list，慢响应不得
  // 把已切换视图的渲染覆盖掉（切换时 viewGen++，过期响应直接丢弃）
  var gen = state.viewGen;
  try {
    var url = '/api/chat-history' + (q ? '?q=' + encodeURIComponent(q) : '');
    var res = await fetch(url);
    if (!res.ok) throw new Error('HTTP ' + res.status);
    var data = await res.json();
    state.list = data.sessions || [];
    if (gen === state.viewGen && !state.showTrash) renderList();
  } catch (e) {
    if (gen !== state.viewGen || state.showTrash) return; // 视图已切换，错误提示不串台
    state.list = [];
    $('#session-list').innerHTML = '<div class="hint">加载失败，请检查服务是否正常后点击「刷新」重试。</div>';
    console.error('加载聊天记录失败', e);
  }
}

function renderList() {
  var ul = $('#session-list');
  ul.innerHTML = '';
  if (!state.list.length) {
    ul.innerHTML = '<div class="hint">暂无聊天记录，去「聊天」页点「保存对话」。</div>';
    return;
  }
  state.list.forEach(function (s) {
    var li = document.createElement('li');
    li.className = 'list-item' + (s.id === state.current ? ' active' : '');
    li.textContent = s.title;
    var tooltip = '保存于 ' + s.saved_at + ' · ' + s.message_count + ' 条消息';
    if (s.usage && (s.usage.total_tokens || s.usage.cost)) {
      tooltip += ' · ' + s.usage.total_tokens + ' tokens · 约 ¥' + (s.usage.cost || 0).toFixed(4);
      var sub = document.createElement('div');
      sub.style.fontSize = '11px';
      sub.style.color = '#8a8a8a';
      sub.style.marginTop = '2px';
      sub.textContent = '🔢 ' + s.usage.total_tokens + ' tokens · 约 ¥' + (s.usage.cost || 0).toFixed(4);
      li.appendChild(sub);
    }
    var del = document.createElement('button');
    del.className = 'btn btn-sm btn-danger';
    del.textContent = '🗑';
    del.title = '删除会话（可从回收站恢复）';
    del.setAttribute('aria-label', '删除会话「' + s.title + '」');
    del.addEventListener('click', function (e) {
      e.stopPropagation();
      deleteSessionById(s.id, s.title);
    });
    li.appendChild(del);
    li.title = tooltip;
    li.addEventListener('click', function () { openSession(s.id); });
    ul.appendChild(li);
  });
}

async function openSession(id) {
  state.current = id;
  renderList();
  var res = await fetch('/api/chat-history/' + encodeURIComponent(id));
  if (!res.ok) { $('#session-detail').innerHTML = '<div class="hint">加载失败</div>'; return; }
  state.session = await res.json();
  renderDetail();
}

function renderDetail() {
  var s = state.session;
  var box = $('#session-detail');
  box.innerHTML = '';

  var header = document.createElement('div');
  header.className = 'toolbar';
  var title = document.createElement('div');
  title.className = 'field-label';
  title.style.flex = '1';
  var headerText = s.title + '（' + s.saved_at + '）';
  if (s.usage && (s.usage.total_tokens || s.usage.cost)) {
    headerText += ' · 🔢 ' + s.usage.total_tokens + ' tokens · 约 ¥' + (s.usage.cost || 0).toFixed(4);
  }
  title.textContent = headerText;
  header.appendChild(title);
  var resume = document.createElement('button');
  resume.className = 'btn btn-primary btn-sm';
  resume.textContent = '💬 继续聊天';
  resume.title = '回到聊天窗口继续这段对话，并保留上下文';
  resume.addEventListener('click', function () {
    location.href = '/app/chat.html?session=' + encodeURIComponent(state.current);
  });
  header.appendChild(resume);
  box.appendChild(header);

  // AI 生成知识库工具条
  var gen = document.createElement('div');
  gen.className = 'panel-box';
  gen.style.marginTop = '12px';
  var genTitle = document.createElement('div');
  genTitle.className = 'field-label';
  genTitle.textContent = '🤖 AI 生成（文档 / 专项 / SQL / 订阅报告）';
  gen.appendChild(genTitle);

  var row = document.createElement('div');
  row.className = 'toolbar';
  row.style.marginTop = '8px';

  var modelSel = document.createElement('select');
  modelSel.id = 'kb-model';
  modelSel.className = 'control';
  modelSel.style.flex = '0 0 200px';
  if (!state.models.length) {
    var mo = document.createElement('option'); mo.value = ''; mo.textContent = '模型列表加载失败'; modelSel.appendChild(mo);
  } else {
    state.models.forEach(function (m) {
      var o = document.createElement('option'); o.value = m; o.textContent = m; modelSel.appendChild(o);
    });
  }

  var kindSel = document.createElement('select');
  kindSel.id = 'kb-kind';
  kindSel.className = 'control';
  kindSel.style.flex = '0 0 150px';
  [['docs', '生成到「文档」'], ['skills', '生成到「专项」'], ['sql', '生成到「SQL」'], ['report', '生成到「订阅报告」']].forEach(function (k) {
    var o = document.createElement('option'); o.value = k[0]; o.textContent = k[1]; kindSel.appendChild(o);
  });

  var levelSel = document.createElement('select');
  levelSel.id = 'kb-level';
  levelSel.className = 'control';
  levelSel.style.flex = '0 0 110px';
  ['通用', '项目', '个人'].forEach(function (lv) {
    var o = document.createElement('option'); o.value = lv; o.textContent = '层级：' + lv; levelSel.appendChild(o);
  });
  function toggleLevel() { levelSel.style.display = (kindSel.value === 'docs') ? '' : 'none'; }
  kindSel.addEventListener('change', toggleLevel);
  toggleLevel();

  var go = document.createElement('button');
  go.className = 'btn btn-primary';
  go.textContent = 'AI 生成草稿';
  go.addEventListener('click', generateKb);

  var confirmBtn = document.createElement('button');
  confirmBtn.id = 'kb-confirm';
  confirmBtn.className = 'btn btn-success';
  confirmBtn.textContent = '✓ 确认保存';
  confirmBtn.style.display = 'none';
  confirmBtn.title = '预览无误后落盘保存（写入个人级资产）';
  confirmBtn.addEventListener('click', confirmKb);

  // 审计 P1-2：草稿交深度分析 Agent 审阅（口径/逻辑/遗漏），结果就地展示
  var verifyBtn = document.createElement('button');
  verifyBtn.id = 'kb-verify';
  verifyBtn.className = 'btn';
  verifyBtn.textContent = '🔍 深度验证';
  verifyBtn.style.display = 'none';
  verifyBtn.title = '把这份草稿交给深度分析 Agent 审阅：检查口径、逻辑与遗漏，给出修改建议';
  verifyBtn.addEventListener('click', verifyKb);

  var del = document.createElement('button');
  del.className = 'btn btn-danger';
  del.textContent = '🗑 删除记录';
  del.addEventListener('click', deleteSession);

  row.appendChild(modelSel);
  row.appendChild(kindSel);
  row.appendChild(levelSel);
  row.appendChild(go);
  row.appendChild(confirmBtn);
  row.appendChild(verifyBtn);
  row.appendChild(del);
  gen.appendChild(row);

  var result = document.createElement('div');
  result.id = 'kb-result';
  result.className = 'hint';
  result.style.marginTop = '8px';
  gen.appendChild(result);

  var preview = document.createElement('div');
  preview.id = 'kb-preview';
  preview.style.display = 'none';
  preview.style.marginTop = '8px';
  var previewTitle = document.createElement('div');
  previewTitle.className = 'field-label';
  previewTitle.textContent = '📝 草稿预览（确认后才会保存）';
  preview.appendChild(previewTitle);
  var previewBody = document.createElement('textarea');
  previewBody.id = 'kb-preview-body';
  previewBody.className = 'control';
  previewBody.readOnly = true;
  previewBody.style.width = '100%';
  previewBody.style.height = '180px';
  previewBody.style.fontFamily = 'Consolas, monospace';
  previewBody.style.fontSize = '12px';
  previewBody.style.marginTop = '4px';
  previewBody.style.resize = 'vertical';
  preview.appendChild(previewBody);
  gen.appendChild(preview);

  // 深度验证输出区（审计 P1-2：状态行 + 工具步骤 + 审阅意见，随 SSE 流式更新）
  var verifyOut = document.createElement('div');
  verifyOut.id = 'kb-verify-out';
  verifyOut.style.display = 'none';
  verifyOut.style.marginTop = '8px';
  gen.appendChild(verifyOut);
  box.appendChild(gen);

  // 对话内容
  var msgs = document.createElement('div');
  msgs.style.marginTop = '12px';
  s.messages.forEach(function (m) {
    if (m.role === 'user') {
      var u = document.createElement('div');
      u.className = 'msg user';
      u.style.maxWidth = '100%';
      u.textContent = '🙋 ' + m.text;
      msgs.appendChild(u);
    } else {
      var a = document.createElement('div');
      a.className = 'msg assistant';
      a.style.maxWidth = '100%';
      if (m.usage && (m.usage.total_tokens || m.usage.cost)) {
        var u = document.createElement('div');
        u.style.fontSize = '11px';
        u.style.color = '#8a8a8a';
        u.style.marginBottom = '4px';
        u.textContent = '🔢 ' + m.usage.total_tokens + ' tokens · 约 ¥' + (m.usage.cost || 0).toFixed(4);
        a.appendChild(u);
      }
      if (m.sql) {
        var sqlPre = document.createElement('pre');
        sqlPre.className = 'sql-code';
        sqlPre.textContent = m.sql;
        a.appendChild(sqlPre);
      }
      if (m.answer) {
        var ans = document.createElement('div');
        ans.className = 'markdown-body';
        ans.innerHTML = sanitizeHtml(m.answer);
        a.appendChild(ans);
      }
      msgs.appendChild(a);
    }
  });
  box.appendChild(msgs);
}

async function generateKb() {
  if (!state.current) return;
  var result = $('#kb-result');
  var confirmBtn = $('#kb-confirm');
  var verifyBtn = $('#kb-verify');
  var verifyOut = $('#kb-verify-out');
  var preview = $('#kb-preview');
  var previewBody = $('#kb-preview-body');
  state.kbDraft = null;
  confirmBtn.style.display = 'none';
  if (verifyBtn) verifyBtn.style.display = 'none';
  if (verifyOut) verifyOut.style.display = 'none';
  preview.style.display = 'none';
  result.textContent = 'AI 正在生成草稿…';
  var resp = await fetch('/api/chat-history/' + encodeURIComponent(state.current) + '/to-kb', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model: $('#kb-model').value, kind: $('#kb-kind').value, level: $('#kb-level').value }),
  });
  if (!resp.ok) {
    var err = await resp.json().catch(function () { return {}; });
    result.textContent = '失败：' + (err.detail || resp.status);
    return;
  }
  var data = await resp.json();
  if (data.phase !== 'draft') {
    result.textContent = '失败：服务未返回草稿';
    return;
  }
  state.kbDraft = {
    kind: data.kind,
    model: $('#kb-model').value,
    name: data.name || '',
    title: data.title || '',
    draft: data.draft || '',
    fields: data.fields || [],
    subscription: data.subscription || {}
  };
  if (data.kind === 'report' && data.subscription) {
    var sub = data.subscription;
    previewBody.value = '订阅名：' + sub.name + '\n专项：' + (sub.skill || '（无）') +
      '\nSQL：' + (sub.sqls.length ? sub.sqls.join('、') : '（无）') +
      '\n文档：' + (sub.docs.length ? sub.docs.join('、') : '（无）') +
      '\n补充说明：' + (sub.extra_prompt || '（无）');
    result.textContent = '✅ 已生成订阅报告草稿，请预览后点「确认保存」。';
  } else {
    previewBody.value = data.draft || '';
    result.textContent = '✅ 已生成' + ({ docs: '文档', skills: '专项', sql: 'SQL' }[data.kind] || '') + '草稿「' + (data.name || data.title || '') + '」，请预览后点「确认保存」。';
  }
  preview.style.display = '';
  confirmBtn.style.display = '';
  var vBtn = $('#kb-verify');
  if (vBtn) vBtn.style.display = '';
}

async function confirmKb() {
  if (!state.kbDraft) return;
  var result = $('#kb-result');
  var confirmBtn = $('#kb-confirm');
  result.textContent = '正在保存…';
  var resp = await fetch('/api/chat-history/to-kb/confirm', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(state.kbDraft),
  });
  if (!resp.ok) {
    var err = await resp.json().catch(function () { return {}; });
    result.textContent = '保存失败：' + (err.detail || resp.status);
    return;
  }
  var data = await resp.json();
  state.kbDraft = null;
  confirmBtn.style.display = 'none';
  if (data.kind === 'report' && data.subscription) {
    result.textContent = '✅ 已保存订阅报告：「' + data.subscription.name + '」，可到「订阅报告」页查看。';
  } else if (data.kind === 'sql') {
    result.textContent = '✅ 已保存到 SQL：「' + data.name + '」，可到「SQL数据」页查看编辑。';
  } else {
    result.textContent = '✅ 已保存到知识库「' + data.name + '」，可到「' + (data.kind === 'skills' ? '专项' : '知识库') + '」页查看编辑。';
  }
}

// ---- 深度验证：把生成草稿交给深度分析 Agent 审阅（审计 P1-2，就地流式展示）----

async function verifyKb() {
  var d = state.kbDraft;
  var vBtn = $('#kb-verify');
  var out = $('#kb-verify-out');
  if (!d || !out || state.verifying) return;
  state.verifying = true;
  vBtn.disabled = true;
  vBtn.textContent = '⏳ 验证中…';
  out.style.display = '';
  out.innerHTML = '';

  var title = document.createElement('div');
  title.className = 'field-label';
  title.textContent = '🔍 深度验证（Agent 审阅草稿）';
  out.appendChild(title);

  var status = document.createElement('div');
  status.className = 'hint';
  status.textContent = '启动中…';
  out.appendChild(status);

  var steps = document.createElement('pre');
  steps.className = 'sql-code';
  steps.style.maxHeight = '200px';
  steps.style.overflowY = 'auto';
  steps.style.display = 'none';
  out.appendChild(steps);

  var answer = document.createElement('div');
  answer.className = 'markdown-body';
  out.appendChild(answer);

  var kindLabel = ({ docs: '知识库文档', skills: '专项', sql: 'SQL', report: '订阅报告' })[d.kind] || '知识库';
  var draftText = d.kind === 'report' ? JSON.stringify(d.subscription, null, 2) : d.draft;
  var history = ((state.session && state.session.messages) || []).map(function (m) {
    return {
      role: m.role === 'user' ? 'user' : 'assistant',
      content: m.role === 'user' ? (m.text || '') : (m.answer || m.sql || m.text || ''),
    };
  });
  var prompt = '请审阅下面这份' + kindLabel + '草稿：检查数据口径是否有误、逻辑是否自洽、有没有明显遗漏或冗余，'
    + '并逐条给出修改建议（不改写全文）。草稿内容：\n\n' + draftText;
  var answerRaw = '';  // 流式增量累积（answer.delta / 整段 answer.text），answer_cancel 时清空重建
  try {
    var resp = await fetch('/api/agent/chat/stream', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ message: prompt, history: history }),
    });
    if (!resp.ok) {
      var err = await resp.json().catch(function () { return {}; });
      status.textContent = '❌ 深度验证失败：' + (err.detail || resp.status);
      return;
    }
    var reader = resp.body.getReader();
    var decoder = new TextDecoder();
    var buf = '';
    while (true) {
      var r = await reader.read();
      if (r.done) break;
      buf += decoder.decode(r.value, { stream: true });
      var lines = buf.split('\n');
      buf = lines.pop();
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim();
        if (line.indexOf('data:') !== 0) continue;
        var payload = line.slice(5).trim();
        if (payload === '[DONE]') continue;
        var ev = null;
        try { ev = JSON.parse(payload); } catch (e2) { continue; }
        if (!ev || !ev.type) continue;
        if (ev.type === 'agent_start') {
          status.textContent = '🧠 深度分析已启动（库 ' + (ev.db || '') + '）';
        } else if (ev.type === 'plan_text') {
          status.textContent = '📋 ' + ev.text;
        } else if (ev.type === 'tool_start') {
          status.textContent = '🔧 ' + (ev.name || '工具执行中') + '…';
        } else if (ev.type === 'tool_done') {
          steps.style.display = '';
          steps.textContent += (ev.ok ? '✅' : '⚠️') + ' ' + (ev.name || '') + '：' + (ev.summary || '完成') + '\n';
        } else if (ev.type === 'answer') {
          status.textContent = '✍️ 审阅意见：';
          // 流式增量（delta，Agent 边想边写）与整段（text，兜底非流式路径）两种形态都支持；
          // 逐增量全量重渲染 markdown（与 app.js 主流程同口径，sanitizeHtml 已消毒）
          answerRaw += ev.delta || ev.text || '';
          answer.innerHTML = sanitizeHtml(answerRaw);
        } else if (ev.type === 'answer_cancel') {
          // Agent 清空已流出的半截内容（换模型重试/超时），本地同步清空，等待重试结果或 final 兜底
          answerRaw = '';
          answer.innerHTML = '';
        } else if (ev.type === 'error') {
          status.textContent = '❌ 深度验证出错：' + (ev.message || '');
        } else if (ev.type === 'final') {
          if (!answer.textContent.trim() && ev.reply) answer.innerHTML += sanitizeHtml(ev.reply);
          status.textContent = ev.success ? '✅ 深度验证完成' : ('⚠️ 深度验证未完成' + (ev.error ? '：' + ev.error : ''));
        }
      }
    }
  } catch (e3) {
    status.textContent = '❌ 深度验证失败：' + (e3.message || '网络错误');
  } finally {
    state.verifying = false;
    vBtn.disabled = false;
    vBtn.textContent = '🔍 深度验证';
  }
}

async function deleteSessionById(id, title) {
  if (!id) return;
  if (!confirm('删除「' + (title || '未命名对话') + '」？删除后可从回收站恢复（保留 30 天）。')) return;
  var resp = await fetch('/api/chat-history/' + encodeURIComponent(id), { method: 'DELETE' });
  if (!resp.ok) { alert('删除失败'); return; }
  state.list = state.list.filter(function (s) { return s.id !== id; });
  if (state.current === id) {
    state.current = null;
    state.session = null;
    $('#session-detail').innerHTML = '<div class="hint">选择左侧会话查看，并可让 AI 生成知识库。</div>';
  }
  renderList();
}

async function deleteSession() {
  if (!state.current) return;
  var selected = state.list.find(function (s) { return s.id === state.current; });
  await deleteSessionById(state.current, selected && selected.title);
}

/* ── 回收站（建议 10）：软删会话列表，可恢复 / 彻底删除 ── */

async function loadTrash() {
  var gen = state.viewGen; // 视图代际：过期响应不渲染（与 loadList 同口径）
  try {
    var res = await fetch('/api/chat-history/trash');
    if (!res.ok) throw new Error('HTTP ' + res.status);
    var data = await res.json();
    state.trash = data.sessions || [];
  } catch (e) {
    state.trash = [];
    console.error('加载回收站失败', e);
  }
  if (gen === state.viewGen && state.showTrash) renderTrash();
}

function renderTrash() {
  var ul = $('#session-list');
  ul.innerHTML = '';
  var q = ($('#search-input') && $('#search-input').value || '').trim().toLowerCase();
  var items = state.trash.filter(function (s) { return !q || (s.title || '').toLowerCase().indexOf(q) >= 0; });
  if (!items.length) {
    var hint = document.createElement('div');
    hint.className = 'hint';
    hint.textContent = q ? '无匹配「' + q + '」的会话。' : '回收站为空。';
    ul.appendChild(hint);
    return;
  }
  items.forEach(function (s) {
    var trashedAt = s.trashed_at || s.saved_at; // 进入回收站时刻；老条目无字段时按保存时间兜底
    var li = document.createElement('li');
    li.className = 'list-item';
    li.title = '删除于 ' + trashedAt + ' · ' + s.message_count + ' 条消息';
    var head = document.createElement('div');
    head.style.display = 'flex';
    head.style.alignItems = 'center';
    head.style.gap = '4px';
    var titleSpan = document.createElement('span');
    titleSpan.style.flex = '1';
    titleSpan.style.minWidth = '0';
    titleSpan.style.overflow = 'hidden';
    titleSpan.style.textOverflow = 'ellipsis';
    titleSpan.style.whiteSpace = 'nowrap';
    titleSpan.textContent = s.title;
    head.appendChild(titleSpan);
    var restoreBtn = document.createElement('button');
    restoreBtn.className = 'btn btn-sm btn-success';
    restoreBtn.textContent = '恢复';
    restoreBtn.title = '恢复到正常列表（重新计入保留期）';
    restoreBtn.addEventListener('click', function (e) { e.stopPropagation(); restoreTrash(s.id); });
    head.appendChild(restoreBtn);
    var purgeBtn = document.createElement('button');
    purgeBtn.className = 'btn btn-sm btn-danger';
    purgeBtn.textContent = '彻底删除';
    purgeBtn.title = '彻底删除（不可恢复）';
    purgeBtn.addEventListener('click', function (e) { e.stopPropagation(); purgeTrash(s.id); });
    head.appendChild(purgeBtn);
    li.appendChild(head);
    var sub = document.createElement('div');
    sub.style.fontSize = '11px';
    sub.style.color = '#8a8a8a';
    sub.style.marginTop = '2px';
    sub.textContent = '删除于 ' + trashedAt + ' · ' + s.message_count + ' 条消息';
    li.appendChild(sub);
    ul.appendChild(li);
  });
}

async function restoreTrash(sid) {
  var resp = await fetch('/api/chat-history/' + encodeURIComponent(sid) + '/restore', { method: 'POST' });
  if (!resp.ok) {
    var body = null;
    try { body = await resp.json(); } catch (e) {}
    alert(body && body.detail ? body.detail : '恢复失败');
    return;
  }
  await loadTrash();
}

async function purgeTrash(sid) {
  if (!confirm('彻底删除后不可恢复。确认彻底删除这条聊天记录吗？')) return;
  var resp = await fetch('/api/chat-history/' + encodeURIComponent(sid) + '/purge', { method: 'DELETE' });
  if (!resp.ok) { alert('彻底删除失败'); return; }
  await loadTrash();
}

function toggleTrash() {
  state.showTrash = !state.showTrash;
  state.viewGen++; // 作废在途的列表/回收站请求渲染（对抗审查：两视图共用 #session-list）
  // 搜索词只作用于当前视图：切换时清空，避免残留词把另一视图过滤成空/误导
  var si = $('#search-input');
  if (si) si.value = '';
  var btn = $('#btn-trash');
  if (btn) btn.textContent = state.showTrash ? '📋 返回列表' : '🗑 回收站';
  if (state.showTrash) {
    state.current = null;
    state.session = null;
    $('#session-detail').innerHTML = '<div class="hint">回收站中的会话可恢复或彻底删除（保留 30 天）。</div>';
    loadTrash();
  } else {
    loadList();
  }
}

$('#btn-refresh').addEventListener('click', function () {
  if (state.showTrash) { loadTrash(); return; }
  loadList().then(function () { if (state.current) openSession(state.current); });
});

var trashBtn = $('#btn-trash');
if (trashBtn) trashBtn.addEventListener('click', toggleTrash);

// 全文搜索：输入防抖后按关键字过滤会话列表（标题 + 消息内容）；回收站视图则前端过滤
var searchTimer = null;
var searchInput = $('#search-input');
if (searchInput) {
  searchInput.addEventListener('input', function () {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(function () {
      if (state.showTrash) { renderTrash(); return; }
      state.current = null;
      loadList(searchInput.value.trim());
    }, 250);
  });
}

Promise.all([loadModels(), loadList()]);
