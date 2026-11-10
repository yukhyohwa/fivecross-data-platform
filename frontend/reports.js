'use strict';

var state = {
  models: [], skills: [], docs: [], sqls: [],
  subs: [], currentSub: null,
  reportList: [], currentReport: null, reportDetail: null,
};

function $(s) { return document.querySelector(s); }

// ---- 基础加载 ----

async function init() {
  try {
    var res = await Promise.all([
      fetch('/api/models'),
      fetch('/api/knowledge'),
      fetch('/api/admin/sqls'),
      fetch('/api/reports/subscriptions'),
    ]);
    var models = await res[0].json();
    var kb = await res[1].json();
    var sqls = await res[2].json();
    var subs = await res[3].json();
    state.models = models.models || [];
    state.skills = kb.skills || [];
    state.docs = kb.docs || [];
    state.sqls = (sqls.sqls || []).map(function (s) { return s.name; });
    state.subs = subs.subscriptions || [];
    renderSubList();
  } catch (e) {
    var msg = '初始化失败，无法加载数据：' + (e && e.message ? e.message : e) + '。请刷新页面重试。';
    var el = $('#sub-list');
    if (el) {
      el.innerHTML = '';
      var hint = document.createElement('div');
      hint.className = 'hint';
      hint.textContent = msg;
      el.appendChild(hint);
    }
  }
}

// ---- 标签切换 ----

function switchTab(tab) {
  document.querySelectorAll('.tab').forEach(function (b) {
    b.classList.toggle('active', b.dataset.tab === tab);
  });
  $('#tab-sub').hidden = tab !== 'sub';
  $('#tab-history').hidden = tab !== 'history';
  if (tab === 'history') loadReports();
}

// ---- 订阅列表 ----

function renderSubList() {
  var ul = $('#sub-list');
  ul.innerHTML = '';
  if (!state.subs.length) {
    ul.innerHTML = '<div class="hint">暂无订阅，去「聊天」里订阅一个吧。</div>';
    return;
  }
  state.subs.forEach(function (s) {
    var li = document.createElement('li');
    li.className = 'list-item' + (state.currentSub && s.id === state.currentSub.id ? ' active' : '');
    li.textContent = s.name + (s.skill ? '  · ' + s.skill : '');
    li.title = '创建于 ' + (s.created_at || '');
    li.addEventListener('click', function () { selectSub(s.id); });
    ul.appendChild(li);
  });
}

function findSub(id) {
  var found = null;
  state.subs.forEach(function (s) { if (s.id === id) found = s; });
  return found;
}

async function selectSub(id) {
  var s = findSub(id);
  if (!s) return;
  // 取完整记录（含 extra_prompt）
  try {
    var res = await fetch('/api/reports/subscriptions/' + id);
    if (res.ok) s = await res.json();
  } catch (e) { /* 用列表里的字段兜底 */ }
  state.currentSub = s;
  renderSubList();
  renderSubDetail();
  renderSubHistory();
}

function renderSubDetail() {
  var s = state.currentSub;
  $('#sub-empty').hidden = true;
  $('#sub-detail').hidden = false;
  $('#s-name').value = s.name || '';
  renderSkillSelect('#s-skill', s.skill || '');
  renderSqlCheckboxes(s.sqls || []);
  renderDocsSelect(s.docs || []);
  $('#s-extra').value = s.extra_prompt || '';
}

function renderSkillSelect(sel, value) {
  var el = $(sel);
  el.innerHTML = '';
  var none = document.createElement('option');
  none.value = '';
  none.textContent = '（不指定）';
  el.appendChild(none);
  state.skills.forEach(function (k) {
    var o = document.createElement('option');
    o.value = k;
    o.textContent = k;
    el.appendChild(o);
  });
  el.value = value || '';
}

function renderSqlCheckboxes(selected) {
  var box = $('#s-sqls');
  box.innerHTML = '';
  if (!state.sqls.length) {
    box.innerHTML = '<div class="hint">还没有任何 SQL 文件，先去「SQL数据」新建。</div>';
    return;
  }
  state.sqls.forEach(function (n) {
    var label = document.createElement('label');
    label.className = 'assoc-item';
    var cb = document.createElement('input');
    cb.type = 'checkbox';
    cb.value = n;
    cb.checked = (selected || []).indexOf(n) >= 0;
    label.appendChild(cb);
    label.appendChild(document.createTextNode(' ' + n));
    box.appendChild(label);
  });
}

function renderDocsSelect(selected) {
  var sel = $('#s-docs');
  sel.innerHTML = '';
  state.docs.forEach(function (d) {
    var o = document.createElement('option');
    o.value = d;
    o.textContent = d;
    sel.appendChild(o);
  });
  Array.from(sel.options).forEach(function (o) {
    o.selected = (selected || []).indexOf(o.value) >= 0;
  });
}

function collectSub() {
  var sqls = [];
  document.querySelectorAll('#s-sqls input:checked').forEach(function (cb) { sqls.push(cb.value); });
  return {
    name: $('#s-name').value.trim() || '未命名订阅',
    skill: $('#s-skill').value || null,
    sqls: sqls,
    docs: Array.from($('#s-docs').selectedOptions).map(function (o) { return o.value; }),
    extra_prompt: $('#s-extra').value,
  };
}

// ---- 审计 P2-2：保存订阅前预览「聊天里 AI 现写的 SQL」清单，用户确认后才落盘 ----

async function fetchRawSqlPreview(payload) {
  try {
    var res = await fetch('/api/reports/subscriptions/preview', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    if (!res.ok) {
      var err = await res.json().catch(function () { return {}; });
      throw new Error(err.detail || ('HTTP ' + res.status));
    }
    var data = await res.json();
    return data.raw_sqls || [];
  } catch (e) {
    alert('AI 现写 SQL 清单预览失败，已中止保存：' + (e && e.message ? e.message : e));
    return null; // null 表示预览失败，中止保存
  }
}

function confirmRawSqls(list, onConfirm) {
  var ov = document.createElement('div');
  ov.className = 'modal-overlay';
  var box = document.createElement('div');
  box.className = 'modal modal-wide';

  var head = document.createElement('div');
  head.className = 'modal-head';
  var title = document.createElement('div');
  title.className = 'modal-title';
  title.textContent = '📄 确认保存 AI 现写的 SQL（' + list.length + ' 条）';
  head.appendChild(title);
  box.appendChild(head);

  var tip = document.createElement('p');
  tip.className = 'hint';
  tip.style.cssText = 'margin:8px 0;font-size:12px;';
  tip.textContent = '保存订阅会将以下 SQL 写入个人 SQL 库（仅自己可见），请确认内容后继续。';
  box.appendChild(tip);

  var body = document.createElement('div');
  body.style.cssText = 'max-height:320px;overflow:auto;border:1px solid var(--border);border-radius:8px;';
  list.forEach(function (item) {
    var itemBox = document.createElement('div');
    itemBox.style.cssText = 'padding:8px 10px;border-bottom:1px solid var(--border);';
    var nm = document.createElement('div');
    nm.style.cssText = 'font-weight:600;font-size:13px;color:var(--text);';
    nm.textContent = item.name;
    var sq = document.createElement('pre');
    sq.style.cssText = 'margin:4px 0 0;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px;white-space:pre-wrap;word-break:break-all;color:var(--muted);';
    sq.textContent = item.sql + (item.truncated ? ' …（已截断）' : '');
    itemBox.appendChild(nm);
    itemBox.appendChild(sq);
    body.appendChild(itemBox);
  });
  box.appendChild(body);

  var btnRow = document.createElement('div');
  btnRow.style.cssText = 'display:flex;justify-content:flex-end;gap:8px;margin-top:12px;';
  var okBtn = document.createElement('button');
  okBtn.className = 'btn btn-primary';
  okBtn.textContent = '✅ 确认并保存';
  var cancelBtn = document.createElement('button');
  cancelBtn.className = 'btn';
  cancelBtn.textContent = '取消';
  btnRow.appendChild(cancelBtn);
  btnRow.appendChild(okBtn);
  box.appendChild(btnRow);

  ov.appendChild(box);
  document.body.appendChild(ov);

  var esc = function (e) { if (e.key === 'Escape') close(); };
  function close() {
    document.removeEventListener('keydown', esc);
    ov.remove();
  }
  document.addEventListener('keydown', esc);
  okBtn.addEventListener('click', function () { close(); onConfirm(); });
  cancelBtn.addEventListener('click', close);
  ov.addEventListener('click', function (e) { if (e.target === ov) close(); });
}

async function saveSub() {
  var c = collectSub();
  var payload = Object.assign({}, c, { id: state.currentSub ? state.currentSub.id : null, source: state.currentSub ? state.currentSub.source : 'manual' });
  // 审计 P2-2：先预览 AI 现写 SQL 清单；为空直接保存，非空弹确认框，确认后才真正创建订阅
  var raw = await fetchRawSqlPreview(payload);
  if (raw === null) return; // 预览失败已提示，中止保存
  if (raw.length) {
    confirmRawSqls(raw, function () { doSaveSub(payload); });
  } else {
    await doSaveSub(payload);
  }
}

async function doSaveSub(payload) {
  var res = await fetch('/api/reports/subscriptions', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    var err = await res.json().catch(function () { return {}; });
    alert('保存失败：' + (err.detail || res.status));
    return;
  }
  await refreshSubs();
  selectSub(payload.id || (await res.json()).id);
}

async function newSub() {
  var name = prompt('订阅名称：', '');
  if (name === null) return;
  var res = await fetch('/api/reports/subscriptions', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name: name || '未命名订阅', source: 'manual' }),
  });
  if (!res.ok) { alert('新建失败'); return; }
  var rec = await res.json();
  await refreshSubs();
  selectSub(rec.id);
}

async function delSub() {
  if (!state.currentSub) return;
  if (!confirm('确定删除订阅「' + state.currentSub.name + '」吗？')) return;
  var res = await fetch('/api/reports/subscriptions/' + encodeURIComponent(state.currentSub.id), { method: 'DELETE' });
  if (!res.ok) { alert('删除失败'); return; }
  state.currentSub = null;
  await refreshSubs();
  $('#sub-empty').hidden = false;
  $('#sub-detail').hidden = true;
}

async function refreshSubs() {
  var res = await fetch('/api/reports/subscriptions');
  var data = await res.json();
  state.subs = data.subscriptions || [];
  renderSubList();
}

// ---- 生成报告 ----

async function streamFetch(url, body, onEvent, signal) {
  var resp = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
    signal: signal,
  });
  if (!resp.ok) {
    var detail = await resp.text().catch(function () { return ''; });
    throw new Error('HTTP ' + resp.status + ' ' + detail);
  }
  var reader = resp.body.getReader();
  var decoder = new TextDecoder();
  var buf = '';
  while (true) {
    var r = await reader.read();
    if (r.done) break;
    buf += decoder.decode(r.value, { stream: true }).replace(/\r\n/g, '\n');
    var idx;
    while ((idx = buf.indexOf('\n\n')) >= 0) {
      var chunk = buf.slice(0, idx);
      buf = buf.slice(idx + 2);
      var line = chunk.split('\n').find(function (l) { return l.indexOf('data: ') === 0; });
      if (line) {
        try { onEvent(JSON.parse(line.slice(6))); } catch (e) { /* 坏行跳过 */ }
      }
    }
  }
  // 结尾可能没有 \n\n，flush 残余 buffer
  var tail = buf.trim();
  if (tail) {
    var tailLine = tail.split('\n').find(function (l) { return l.indexOf('data: ') === 0; });
    if (tailLine) {
      try { onEvent(JSON.parse(tailLine.slice(6))); } catch (e) { /* 坏行跳过 */ }
    }
  }
}

function setFinal(markdown, title) {
  var box = $('#final-report');
  box.hidden = false;
  // 报告存档事件会再次调用 setFinal：若深度验证正在流式进行，先把输出区摘下来，清空重建后再放回，
  // 避免 innerHTML='' 把流式审阅连同节点一起抹掉（对抗审查 low）
  var inFlight = deepVerifyRunning ? box.querySelector('.deep-verify-out') : null;
  if (inFlight) inFlight.remove();
  box.innerHTML = '';
  var t = document.createElement('div');
  t.className = 'field-label';
  t.textContent = title;
  box.appendChild(t);
  var md = document.createElement('div');
  md.className = 'markdown-body';
  md.style.marginTop = '8px';
  md.innerHTML = sanitizeHtml(markdown || '');
  box.appendChild(md);
  // 审计 P1-2：最终报告交深度分析 Agent 审阅（口径/逻辑/结论支撑），结果就地展示
  var verifyBtn = document.createElement('button');
  verifyBtn.className = 'btn deep-verify-btn';
  verifyBtn.textContent = '🔍 深度验证';
  verifyBtn.title = '把这份报告交给深度分析 Agent 审阅：检查口径、逻辑与结论支撑，给出修改建议';
  verifyBtn.style.marginTop = '8px';
  verifyBtn.addEventListener('click', function () {
    verifyBtn.disabled = true;
    runDeepVerify(box, markdown, '报告', function () { verifyBtn.disabled = false; });
  });
  box.appendChild(verifyBtn);
  if (inFlight) box.appendChild(inFlight);
}

// ---- 深度验证：把生成报告交给深度分析 Agent 审阅（审计 P1-2，就地流式展示）----

var deepVerifyRunning = false;

function runDeepVerify(targetBox, markdown, kindLabel, done) {
  // 防重入：已有验证在跑时直接放行（并恢复按钮），否则二次点击的按钮会永久禁用（对抗审查 MEDIUM）
  if (deepVerifyRunning) {
    // 跨视图二次点击被拦下时给可见反馈，避免用户误以为验证已启动（对抗审查 low）
    if (targetBox) {
      var prevHint = targetBox.querySelector('.deep-verify-busy');
      if (prevHint) prevHint.remove();
      var hint = document.createElement('div');
      hint.className = 'hint deep-verify-busy';
      hint.textContent = '⏳ 已有深度验证进行中，请等待完成后再试。';
      targetBox.appendChild(hint);
    }
    if (done) done();
    return;
  }
  if (!markdown || !markdown.trim()) { alert('内容为空，无法验证'); if (done) done(); return; }
  deepVerifyRunning = true;
  var out = targetBox.querySelector('.deep-verify-out');
  if (!out) {
    out = document.createElement('div');
    out.className = 'panel-box deep-verify-out';
    out.style.marginTop = '12px';
    targetBox.appendChild(out);
  } else {
    out.innerHTML = '';
  }
  var title = document.createElement('div');
  title.className = 'field-label';
  title.textContent = '🔍 深度验证（Agent 审阅' + kindLabel + '）';
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
  answer.style.marginTop = '8px';
  out.appendChild(answer);
  var prompt = '请审阅下面这份' + kindLabel + '：检查数据口径是否有误、分析逻辑是否自洽、结论是否有数据支撑、'
    + '有没有明显遗漏，并逐条给出修改建议（不改写全文）。内容：\n\n' + markdown;
  var answerRaw = '';  // 流式增量累积（answer.delta / 整段 answer.text），answer_cancel 时清空重建
  (async function () {
    try {
      await streamFetch('/api/agent/chat/stream', { message: prompt, history: [] }, function (ev) {
        if (!ev || !ev.type) return;
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
      });
    } catch (e) {
      status.textContent = '❌ 深度验证失败：' + (e.message || '网络错误');
    } finally {
      deepVerifyRunning = false;
      if (targetBox) {
        var busyHint = targetBox.querySelector('.deep-verify-busy');
        if (busyHint) busyHint.remove();
      }
      if (done) done();
    }
  })();
}

function addRound(stage, markdown) {
  var labels = { generate: '生成轮结论', verify: '验证轮审核意见' };
  var wrap = document.createElement('div');
  wrap.className = 'panel-box';
  wrap.style.marginTop = '12px';
  var t = document.createElement('div');
  t.className = 'field-label';
  t.textContent = '🔍 ' + (labels[stage] || stage);
  wrap.appendChild(t);
  var md = document.createElement('div');
  md.className = 'markdown-body';
  md.style.marginTop = '8px';
  md.innerHTML = sanitizeHtml(markdown || '');
  wrap.appendChild(md);
  $('#rounds').appendChild(wrap);
}

var runCtrl = null;   // 进行中的报告生成 AbortController

async function run() {
  var btn = $('#btn-run');

  // 已在运行中 → 本次点击视为取消
  if (runCtrl) {
    runCtrl.abort();
    return;
  }

  if (!state.currentSub) { alert('请先选择一个订阅'); return; }
  var c = collectSub();
  var start = $('#s-start').value || null;
  var end = $('#s-end').value || null;

  var body = {
    sqls: c.sqls,
    mods: {},
    skill: c.skill,
    docs: c.docs,
    extra_prompt: c.extra_prompt,
    start_date: start,
    end_date: end,
    subscription_id: state.currentSub.id,
    source: 'subscription',
    deep_thinking: !!(document.getElementById('s-deep-think') && document.getElementById('s-deep-think').checked),
  };

  var log = $('#run-log');
  log.textContent = '';
  $('#run-log-box').hidden = false;
  $('#rounds').innerHTML = '';
  $('#final-report').hidden = true;
  runCtrl = new AbortController();
  btn.textContent = '⏹ 取消';

  try {
    await streamFetch('/api/reports/run', body, function (ev) {
      if (ev.type === 'stage') {
        log.textContent += ev.message + '\n';
        log.scrollTop = log.scrollHeight;
      } else if (ev.type === 'markdown') {
        if (ev.stage === 'final') setFinal(ev.markdown, '📋 最终报告');
        else addRound(ev.stage, ev.markdown);
      } else if (ev.type === 'report') {
        setFinal(ev.report_md, '📋 最终报告（已存档 ' + ev.run_id + '）');
      } else if (ev.type === 'error') {
        log.textContent += '❌ ' + ev.message + '\n';
        log.scrollTop = log.scrollHeight;
      }
    }, runCtrl.signal);
    renderSubHistory();
  } catch (e) {
    if (e && e.name === 'AbortError') {
      log.textContent += '⏹ 已取消\n';
    } else {
      log.textContent += '请求失败：' + e.message + '\n';
    }
  } finally {
    runCtrl = null;
    btn.textContent = '🚀 生成报告';
  }
}

// ---- 订阅历史 ----

async function renderSubHistory() {
  var ul = $('#sub-history');
  ul.innerHTML = '<div class="hint">加载中…</div>';
  if (!state.currentSub) return;
  try {
    var res = await fetch('/api/reports');
    var data = await res.json();
    var mine = (data.reports || []).filter(function (r) { return r.subscription_id === state.currentSub.id; });
    ul.innerHTML = '';
    if (!mine.length) {
      ul.innerHTML = '<div class="hint">该订阅还没有生成过报告。</div>';
      return;
    }
    mine.forEach(function (r) {
      var li = document.createElement('li');
      li.className = 'list-item';
      li.textContent = r.id + '（' + (r.generated_at || '') + '）';
      li.title = (r.start_date || '') + ' ~ ' + (r.end_date || '');
      li.addEventListener('click', function () { openReport(r.id); });
      ul.appendChild(li);
    });
  } catch (e) {
    ul.innerHTML = '<div class="hint">加载失败</div>';
  }
}

// ---- 历史报告（合并原 history.js） ----

async function loadReports() {
  var res = await fetch('/api/reports');
  var data = await res.json();
  state.reportList = data.reports || [];
  renderReportList();
}

function renderReportList() {
  var ul = $('#report-list');
  ul.innerHTML = '';
  if (!state.reportList.length) {
    ul.innerHTML = '<div class="hint">暂无历史报告。</div>';
    return;
  }
  state.reportList.forEach(function (r) {
    var li = document.createElement('li');
    li.className = 'list-item' + (r.id === state.currentReport ? ' active' : '');
    li.textContent = r.id + '（' + (r.generated_at || '') + '）';
    li.addEventListener('click', function () { openReport(r.id); });
    ul.appendChild(li);
  });
}

async function openReport(id) {
  state.currentReport = id;
  renderReportList();
  var res = await fetch('/api/reports/' + encodeURIComponent(id));
  if (!res.ok) { $('#report-detail').innerHTML = '<div class="hint">加载失败</div>'; return; }
  state.reportDetail = await res.json();
  renderReportDetail();
}

function renderReportDetail() {
  var d = state.reportDetail;
  var box = $('#report-detail');
  box.innerHTML = '';
  var header = document.createElement('div');
  header.className = 'toolbar';
  var title = document.createElement('div');
  title.className = 'field-label';
  title.textContent = '报告 ' + d.id;
  var exportBtn = document.createElement('button');
  exportBtn.className = 'btn';
  exportBtn.textContent = '🖼️ 导出 HTML';
  exportBtn.addEventListener('click', exportHtml);
  // 审计 P1-2：已存档报告同样支持交深度分析 Agent 审阅
  var verifyBtn = document.createElement('button');
  verifyBtn.className = 'btn';
  verifyBtn.textContent = '🧠 深度验证';
  verifyBtn.title = '把这份报告交给深度分析 Agent 审阅：检查口径、逻辑与结论支撑，给出修改建议';
  verifyBtn.addEventListener('click', function () {
    verifyBtn.disabled = true;
    var target = $('#deep-verify-result');
    runDeepVerify(target, d.report_md || '', '报告', function () { verifyBtn.disabled = false; });
  });
  header.appendChild(title);
  var spacer = document.createElement('div');
  spacer.style.flex = '1';
  header.appendChild(spacer);
  header.appendChild(verifyBtn);
  header.appendChild(exportBtn);
  box.appendChild(header);

  var meta = d.meta || {};
  if (Object.keys(meta).length) {
    var cap = document.createElement('div');
    cap.className = 'hint';
    var models = meta.models || {};
    cap.textContent = '模型 ' + (models.generate || '') + ' → ' + (models.verify || '') + ' → ' + (models.summarize || '')
      + (meta.skill ? '；专项：' + meta.skill : '')
      + (meta.start_date && meta.end_date ? '；数据区间：' + meta.start_date + ' ~ ' + meta.end_date : '')
      + ((meta.selected_docs && meta.selected_docs.length) ? '；文档：' + meta.selected_docs.join('、') : '');
    cap.style.marginBottom = '12px';
    box.appendChild(cap);
  }

  if (!d.report_md) {
    var empty = document.createElement('div');
    empty.className = 'hint';
    empty.textContent = '该目录下没有 report.md';
    box.appendChild(empty);
  } else {
    var body = document.createElement('div');
    body.className = 'panel-box markdown-body';
    body.innerHTML = sanitizeHtml(d.report_md);
    box.appendChild(body);
  }

  [['generate_md', '生成轮结论'], ['verify_md', '验证轮审核意见']].forEach(function (pair) {
    var key = pair[0], label = pair[1];
    if (!d[key]) return;
    var details = document.createElement('details');
    details.className = 'panel-box';
    details.style.marginTop = '12px';
    var summary = document.createElement('summary');
    summary.className = 'field-label';
    summary.style.cursor = 'pointer';
    summary.textContent = '中间轮次：' + label;
    details.appendChild(summary);
    var md = document.createElement('div');
    md.className = 'markdown-body';
    md.style.marginTop = '8px';
    md.innerHTML = sanitizeHtml(d[key]);
    details.appendChild(md);
    box.appendChild(details);
  });


  // 深度验证输出区（审计 P1-2：状态行 + 工具步骤 + 审阅意见，随 SSE 流式更新）
  var verifyWrap = document.createElement('div');
  verifyWrap.id = 'deep-verify-result';
  verifyWrap.style.marginTop = '12px';
  box.appendChild(verifyWrap);
}

function exportHtml() {
  var d = state.reportDetail;
  if (!d) return;
  var bodyHtml = sanitizeHtml(d.report_md || '');
  // d.id 由服务端生成（如日期戳），但为防注入仍转义后再进 <title>/文件名
  var escId = String(d.id || '').replace(/[&<>"']/g, function (c) {
    return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c];
  });
  var html = '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8"><title>' + escId + '</title><style>'
    + 'body{font-family:-apple-system,"Microsoft YaHei",sans-serif;max-width:960px;margin:40px auto;padding:0 20px;line-height:1.6;}'
    + 'table{border-collapse:collapse;width:100%;margin:16px 0;}th,td{border:1px solid #ddd;padding:6px 10px;text-align:left;}'
    + 'th{background:#f5f5f5;}code{background:#f5f5f5;padding:2px 4px;border-radius:3px;}'
    + 'pre{background:#f5f5f5;padding:10px;border-radius:6px;overflow-x:auto;}'
    + '</style></head><body>' + bodyHtml + '</body></html>';
  var blob = new Blob([html], { type: 'text/html' });
  var a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = d.id + '.html';
  document.body.appendChild(a);
  a.click();
  a.remove();
  // 延迟释放，避免部分浏览器在点击与下载开始之间就回收了 blob 导致下载失败
  setTimeout(function () { URL.revokeObjectURL(a.href); }, 1000);
}

// ---- 绑定 ----

function bind() {
  document.querySelectorAll('.tab').forEach(function (b) {
    b.addEventListener('click', function () { switchTab(b.dataset.tab); });
  });
  $('#btn-new-sub').addEventListener('click', newSub);
  $('#btn-refresh-sub').addEventListener('click', refreshSubs);
  $('#btn-save-sub').addEventListener('click', saveSub);
  $('#btn-del-sub').addEventListener('click', delSub);
  $('#btn-run').addEventListener('click', run);
}

bind();
init();
