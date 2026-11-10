'use strict';

const CDN = {
  echarts: [
    'https://cdn.jsdelivr.net/npm/echarts@5.5.0/dist/echarts.min.js',
    'https://cdn.bootcdn.net/ajax/libs/echarts/5.4.3/echarts.min.js',
  ],
  marked: [
    'https://cdn.jsdelivr.net/npm/marked@4.3.0/marked.min.js',
    'https://cdn.bootcdn.net/ajax/libs/marked/4.3.0/marked.min.js',
  ],
};

const state = {
  model: null,
  modelExplicit: false,  // 用户是否在顶部下拉显式改选过模型；未改选时不回传，由后端按「主对话」槽位解析（2026-10-26）
  skill: null,
  table: null,
  chartSpec: null,
  sessionList: [],
  historyOffset: 0,        // 聊天记录侧边栏已加载条数（分页累计）
  historyTruncated: false,  // 后端提示还有更多记录未加载（渲染「加载更多」）
  historyLoading: false,    // 侧边栏请求在途标记：防双击「加载更多」并发翻页
};

const $ = (sel) => document.querySelector(sel);

let transcript = [];      // 已累积的对话（用于保存 / 生成知识库）
let currentSql = null;
let currentAnswer = null;
let currentMeta = null;   // 命中专项或 AI 兜底的 meta 事件
let lastQuestion = null;  // 最近一次用户提问
let cacheSid = null;      // 当前自动缓存会话 id（一次对话一个会话）
let lastReport = null;         // 最近一次专项官方报告 markdown
let lastReportSkill = null;    // 该报告对应的专项名
let currentContextReport = null; // 本次请求是否带上一版报告上下文
let currentSubs = null;        // 本次命中专项的订阅报告列表
let pendingConfirm = null;     // 二次确认状态 {skill, msg, text}
let confirmTimer = null;       // 二次确认自动超时计时器
const CONFIRM_AUTO_SECONDS = 60; // 命中专项后 N 秒未选择，自动按该专项执行
let pendingGameConfirm = null; // 游戏/项目二次确认状态 {games, target_game, current, question, msg, text}
let pendingForecastConfirm = null; // 预测二次确认状态 {method, question, target_game, start, end, year, month, year_ambiguous, past, label, years, msg, text}
let pendingCandidates = null; // 候选卡状态 {candidates, question, game, msg, text}
let pendingAiReportConfirm = null; // AI 自动生成报告二次确认状态 {question, game, msg, text}
let pendingRewriteConfirm = null; // 就近改写二次确认状态 {sql_name, question, game, msg, text}
let pendingGenerateConfirm = null; // 生成专项草稿二次确认状态 {question, game, msg, text}
let currentUsage = null;       // 本次请求的 usage 事件
let currentHistory = [];       // 本次请求携带的历史（当前用户提问之前的对话）
let sessionUsage = { tokens: 0, cost: 0, prompt: 0, completion: 0 }; // 本次会话累计 token/费用
let skillNames = [];           // 专项名缓存（供确认卡「换专项」下拉）
let docNames = [];             // 知识库文档名缓存（供提炼卡「合并到现有」下拉）
let sqlNames = [];             // SQL 文件名缓存（供提炼卡「合并到现有」下拉）
let modelNames = [];           // 外部模型名缓存（供提炼卡模型行「合并到现有」下拉）
let currentSuggestion = null;  // 本次请求的 suggest 事件
let sending = false;           // 发送锁：流式请求进行中，禁止并发发送
let activeAbort = null;        // 当前进行中请求的 AbortController（点「停止」时 abort）
let activeRunId = null;        // 当前深度分析 Agent 运行的 run_id（点「停止」/超时中止时向后端发取消）

// ---- 「不选游戏」模式（chatbi.game.mode=none）：提问时多选游戏 ----
let pendingGameSelect = null; // 多选卡状态 {games, preselected, question, reason, msg, text}
let sessionGames = [];        // 本会话普通聊天已绑定游戏 key（sessionStorage 持久化，键带用户戳）
let deepSessionGames = [];    // 本会话深度分析已绑定游戏 key（同上）
let zeroPerm = false;         // 当前用户无任何游戏权限（禁发送 + 横幅提示 + 不渲染起始建议）

function loadScript(src) {
  return new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = src;
    s.onload = resolve;
    s.onerror = reject;
    document.head.appendChild(s);
  });
}

async function ensureLibs() {
  if (typeof echarts === 'undefined') {
    for (const src of CDN.echarts) {
      try { await loadScript(src); if (typeof echarts !== 'undefined') break; } catch (e) { /* try next */ }
    }
  }
  if (typeof marked === 'undefined') {
    for (const src of CDN.marked) {
      try { await loadScript(src); if (typeof marked !== 'undefined') break; } catch (e) { /* try next */ }
    }
  }
}

// ---- 数据加载 ----

async function loadModels() {
  const res = await fetch('/api/models');
  const data = await res.json();
  const sel = $('#model-select');
  sel.innerHTML = '';
  data.models.forEach((m) => {
    const o = document.createElement('option');
    o.value = m;
    o.textContent = m;
    sel.appendChild(o);
  });
  state.model = data.default || data.models[0];
  // 默认展示主对话槽位模型；用户未显式改选时不回传 model，后端按槽位解析（模型管理改动即时生效）
  state.modelExplicit = false;
  sel.value = state.model;
}

async function loadSkills() {
  const res = await fetch('/api/knowledge');
  const data = await res.json();
  skillNames = data.skills || [];
  docNames = data.docs || [];
  const sel = $('#skill-select');
  sel.innerHTML = '<option value="">（自由提问）</option>';
  (data.skills || []).forEach((s) => {
    const o = document.createElement('option');
    o.value = s;
    o.textContent = s;
    sel.appendChild(o);
  });
  sel.value = state.skill || '';
}

async function loadSqlNames() {
  try {
    const res = await fetch('/api/admin/sqls');
    const data = await res.json();
    sqlNames = (data.sqls || []).map((s) => s.name);
  } catch (e) { /* 忽略 */ }
}

async function loadModelNames() {
  try {
    const res = await fetch('/api/admin/models');
    const data = await res.json();
    modelNames = (data.models || []).filter((m) => m.source === 'external').map((m) => m.name);
  } catch (e) { /* 忽略 */ }
}

// ---- 消息渲染 ----

function appendUser(text) {
  const box = $('#messages');
  const welcome = box.querySelector('.welcome');
  if (welcome) welcome.remove();
  const div = document.createElement('div');
  div.className = 'msg user';
  div.textContent = text;
  box.appendChild(div);
  box.scrollTop = box.scrollHeight;
  transcript.push({ role: 'user', text: text });
}

function appendAssistant() {
  const box = $('#messages');
  const div = document.createElement('div');
  div.className = 'msg assistant';
  div._t0 = performance.now(); // 记录本条消息开始时间，用于「运行过程」里各阶段的耗时
  div.innerHTML =
    '<div class="status"><span class="dot"></span><span class="status-text">处理中…</span></div>' +
    '<div class="body">' +
    '<div class="meta-badge" hidden></div>' +
    '<div class="report-card" hidden>' +
      '<div class="report-head"><div class="report-head-main"><div class="report-title"></div><div class="report-sub"></div></div><button class="report-zoom btn btn-sm" hidden>🔍 放大</button></div>' +
      '<div class="viz" hidden></div>' +
    '</div>' +
    '<div class="answer" hidden></div>' +
    '<div class="report-actions" hidden></div>' +
    '<div class="sql-block" hidden></div>' +
    '<details class="process"><summary class="process-summary">运行过程</summary><ol class="process-list"></ol></details>' +
    '<div class="msg-meta" hidden><span class="resp-time"></span><span class="usage"></span></div>' +
    '<div class="msg-actions" hidden><button class="btn btn-sm subscribe-btn">📡 订阅报告</button></div>' +
    '</div>';
  box.appendChild(div);
  box.scrollTop = box.scrollHeight;
  return div;
}

function setStatus(msg, text, error) {
  const status = msg.querySelector('.status');
  status.querySelector('.status-text').textContent = text;
  status.classList.toggle('error', !!error);
}

function buildSqlCollapse(sql) {
  // SQL 代码默认折叠，点「查看 SQL」展开
  const details = document.createElement('details');
  details.className = 'sql-details';
  const summary = document.createElement('summary');
  summary.className = 'sql-summary';
  summary.textContent = '查看 SQL';
  const pre = document.createElement('pre');
  pre.className = 'sql-code';
  pre.textContent = sql;
  details.appendChild(summary);
  details.appendChild(pre);
  return details;
}

function renderSql(msg, sql, explain) {
  const block = msg.querySelector('.sql-block');
  block.hidden = false;
  block.innerHTML = '';
  // 多步执行（专项）会连续触发多个 sql 事件，逐条累加；这里合到一块、左右分页切换，避免垂直堆叠过长
  const items = (msg._sqls && msg._sqls.length) ? msg._sqls : [{ sql }];
  if (msg._sqlIdx == null || msg._sqlIdx < 0 || msg._sqlIdx >= items.length) {
    msg._sqlIdx = 0;
  }

  const header = document.createElement('div');
  header.className = 'block-title';
  header.textContent = 'SQL';
  const copy = document.createElement('button');
  copy.className = 'copy-btn';
  copy.textContent = '复制';
  copy.addEventListener('click', () => navigator.clipboard.writeText(items.map((s) => s.sql).join('\n\n')));
  header.appendChild(copy);
  block.appendChild(header);

  if (items.length > 1) {
    const nav = document.createElement('div');
    nav.className = 'sql-nav';
    const prev = document.createElement('button');
    prev.className = 'sql-nav-btn';
    prev.textContent = '‹ 上一条';
    prev.disabled = msg._sqlIdx === 0;
    prev.addEventListener('click', () => {
      if (msg._sqlIdx > 0) { msg._sqlIdx--; renderSql(msg, items[msg._sqlIdx].sql, items[msg._sqlIdx].explain); }
    });
    const idx = document.createElement('span');
    idx.className = 'sql-idx';
    idx.textContent = (msg._sqlIdx + 1) + ' / ' + items.length;
    const next = document.createElement('button');
    next.className = 'sql-nav-btn';
    next.textContent = '下一条 ›';
    next.disabled = msg._sqlIdx >= items.length - 1;
    next.addEventListener('click', () => {
      if (msg._sqlIdx < items.length - 1) { msg._sqlIdx++; renderSql(msg, items[msg._sqlIdx].sql, items[msg._sqlIdx].explain); }
    });
    nav.appendChild(prev);
    nav.appendChild(idx);
    nav.appendChild(next);
    block.appendChild(nav);
  }

  const s = items[msg._sqlIdx];
  if (s.name) {
    const nm = document.createElement('div');
    nm.className = 'sql-step';
    nm.textContent = '📄 ' + s.name;
    block.appendChild(nm);
  }
  if (s.explain) {
    const exp = document.createElement('div');
    exp.className = 'sql-explain';
    exp.textContent = '💬 ' + s.explain;
    block.appendChild(exp);
  }
  block.appendChild(buildSqlCollapse(s.sql));
}

// 渲染 markdown 到元素：marked 可用走 sanitizeHtml；不可用时降级纯文本，绝不把原始 markdown 当 HTML（防 XSS）。
function renderMarkdownInto(el, md) {
  if (typeof marked !== 'undefined') {
    el.innerHTML = sanitizeHtml(md);
  } else {
    el.textContent = (md == null) ? '' : String(md);
  }
}

function renderAnswer(msg, markdown) {
  const ans = msg.querySelector('.answer');
  ans.hidden = false;
  renderMarkdownInto(ans, markdown);
  structureSections(ans, msg._meta && msg._meta.fold);
  // 数据轮（有 SQL/表格）才套报告卡片框架；闲聊/澄清直接展示文字
  if (msg._sql || msg._table) {
    msg.querySelector('.report-card').hidden = false;
    renderReportHead(msg);
  }
}

function renderReportHead(msg) {
  const title = msg.querySelector('.report-title');
  const sub = msg.querySelector('.report-sub');
  const meta = msg._meta;
  title.textContent = (msg._question || '分析报告').trim().slice(0, 60);
  let subText;
  if (meta && meta.source === 'skill') {
    subText = '🎯 专项 · ' + (meta.skill || '');
  } else if (meta && meta.source === 'sql') {
    subText = '📄 既有SQL · ' + (meta.skill || '');
  } else if (meta && meta.source === 'model') {
    subText = '🔮 算法预测 · ' + (meta.skill || '');
  } else if (meta && meta.source === 'deep') {
    subText = '🧠 深度分析';
  } else if (msg._deep && msg._deepMeta) {
    subText = '🧠 深度分析 · ' + (msg._deepMeta.model || '');
  } else {
    subText = '⚠️ AI 生成 SQL';
  }
  if (state.model) subText += ' · ' + state.model;
  sub.textContent = subText;
  const zoom = msg.querySelector('.report-zoom');
  if (zoom) zoom.addEventListener('click', () => openReportOverlay(msg));
}

function sectionKind(text) {
  const t = text || '';
  if (t.includes('概览')) return 'conclusion';
  if (t.includes('成因') || t.includes('结论')) return 'conclusion';
  if (t.includes('下钻') || t.includes('明细') || t.includes('解读')) return 'analysis';
  if (t.includes('预测') || t.includes('风险')) return 'risk';
  if (t.includes('建议')) return 'suggestion';
  return 'default';
}

// 专项「报告展示配置」的默认折叠/展开：锚定词与章节标题做子串匹配。
// 命中 expand → 默认展开；命中 collapse → 默认折叠；都没命中 → 沿用默认 defaultExpand。
// 无 foldCfg 时直接返回 defaultExpand（完全沿用现状）。
function foldSectionExpand(title, foldCfg, defaultExpand) {
  const t = (title || '').replace(/\s+/g, '');
  if (foldCfg) {
    const hit = (tokens) => (tokens || []).some((tok) => tok && t.includes(String(tok).replace(/\s+/g, '')));
    if (hit(foldCfg.expand)) return true;
    if (hit(foldCfg.collapse)) return false;
  }
  return defaultExpand;
}

function structureSections(ans, foldCfg) {
  const h2s = Array.from(ans.querySelectorAll(':scope > h2'));
  if (!h2s.length) return;
  const isOverview = (t) => /概览|总览|概述|overview/i.test(t || '');
  const hasOverview = h2s.some((h2) => isOverview(h2.textContent));
  h2s.forEach((h2, idx) => {
    const sec = document.createElement('div');
    sec.className = 'report-section kind-' + sectionKind(h2.textContent) + ' collapsible';
    // 默认：高亮块（概览）展开；没有概览时展开第一节，其余折叠。
    // 专项可写「报告展示配置」覆盖：命中「默认展开」→ 展开，命中「默认折叠」→ 折叠。
    const expand = foldSectionExpand(h2.textContent, foldCfg, isOverview(h2.textContent) || (!hasOverview && idx === 0));
    if (!expand) sec.classList.add('collapsed');
    h2.parentNode.insertBefore(sec, h2);
    let node = h2;
    while (node) {
      const next = node.nextSibling;
      sec.appendChild(node);
      if (next && next.nodeType === 1 && next.tagName === 'H2') break;
      node = next;
    }
    h2.addEventListener('click', () => sec.classList.toggle('collapsed'));
  });
}

function buildVizBlock(spec, table, i, sql) {
  const block = document.createElement('div');
  block.className = 'viz-block';

  const seriesNames = (spec.series || []).map((s) => s.name).join(' · ');
  const capText = (spec.x ? spec.x + ' 维度' : '') + (seriesNames ? (spec.x ? ' · ' : '') + seriesNames : '');
  const title = document.createElement('div');
  title.className = 'viz-title';
  title.textContent = (spec.name || ('图表 ' + (i + 1))) + (capText ? '：' + capText : '');
  title.title = title.textContent;  // 指标多时单行省略，悬浮显示完整标题
  block.appendChild(title);

  const tools = document.createElement('div');
  tools.className = 'chart-tools';
  block.appendChild(tools);

  const chartEl = document.createElement('div');
  chartEl.className = 'chart';
  block.appendChild(chartEl);

  const tableEl = document.createElement('div');
  tableEl.className = 'table-wrap';
  tableEl.hidden = true;
  block.appendChild(tableEl);

  const current = { type: spec.chart_type };

  function refresh() {
    tools.querySelectorAll('button').forEach((b) => {
      b.classList.toggle('active', b.dataset.t === current.type);
    });
    if (current.type === 'table') {
      chartEl.hidden = true;
      tableEl.hidden = false;
      if (table) renderTable(tableEl, table, sql, spec.name);
      else tableEl.innerHTML = '<div class="hint">无数据</div>';
    } else {
      tableEl.hidden = true;
      chartEl.hidden = false;
      renderChart(chartEl, spec, current.type);
    }
  }

  [['line', '折线'], ['bar', '柱状'], ['stack_bar', '堆叠柱状'], ['pie', '饼图'], ['table', '表格']].forEach(([t, label]) => {
    const b = document.createElement('button');
    b.className = 'tool-btn';
    b.dataset.t = t;
    b.textContent = label;
    b.addEventListener('click', () => { current.type = t; refresh(); });
    tools.appendChild(b);
  });

  block._name = spec.name || null;  // 记录图表名，放大视图据此把图表归位到对应小节
  block._refresh = refresh;  // 待插入可见 DOM 后再初始化 echarts（避免 0 尺寸）
  return block;
}

// 从 SQL 头部注释抽取【步骤名】（= 图表名）：概览里图左表右时，图的标题用它（如「分周流水达成趋势」），
// 与数据表标题「SQL 文件名：维度 · 指标」区分。缺失回 null。
function sqlStepName(sql) {
  if (!sql) return null;
  const m = /^\s*--\s*【步骤名】\s*(.+)$/m.exec(sql);
  return m ? m[1].trim() : null;
}

// 放大视图专用：分析表 + 图表 并排（图表模块=标题+切换+图，可在表格/折线/柱状/堆叠柱状/饼图间切换）。
// 默认表格左、图表右；chartLeft=true 时图表左、表格右；chartOnly=true 只留图表（概览去表，图全宽）。
function buildVizSideBySide(spec, table, i, sql, leftNode, chartLeft, chartOnly) {
  const block = document.createElement('div');
  block.className = 'viz-block viz-sbs';

  const seriesNames = (spec.series || []).map((s) => s.name).join(' · ');
  // 周对比（2 根周期柱 × 分类堆叠）图：标题只标周期 + 指标，不罗列各分类
  const capText = spec.stack_pct_label
    ? ('周期 维度' + (spec.stack_metric ? ' · ' + spec.stack_metric : ''))
    : ((spec.x ? spec.x + ' 维度' : '') + (seriesNames ? (spec.x ? ' · ' : '') + seriesNames : ''));
  // 「名称：维度 · 指标」完整标题（明细下钻图用）
  const capTitle = (spec.name || ('图表 ' + (i + 1))) + (capText ? '：' + capText : '');
  // 概览：图标题用 SQL 头部注释的【步骤名】（= 图表名），不带维度后缀（概览只留图、无数据表）。
  const stepName = sqlStepName(sql);
  const title = document.createElement('div');
  title.className = 'viz-title';
  title.textContent = chartLeft ? (stepName || (spec.name || ('图表 ' + (i + 1)))) : capTitle;
  title.title = capTitle;  // 指标多时单行省略，悬浮显示完整标题

  const tools = document.createElement('div');
  tools.className = 'chart-tools';

  const grid = document.createElement('div');
  grid.className = 'viz-sbs-grid';
  if (chartOnly) grid.classList.add('viz-sbs-grid-single');
  block.appendChild(grid);

  // 表列（markdown 分析表走「等高折叠」，数据表走 renderTable 自带折叠/滚动）
  const tableCol = document.createElement('div');
  tableCol.className = 'viz-sbs-table';
  const tableEl = document.createElement('div');
  tableEl.className = 'table-wrap';
  tableCol.appendChild(tableEl);

  // 图列：标题 + 切换 + 图（图跟在切换按钮下面）
  const chartCol = document.createElement('div');
  chartCol.className = 'viz-sbs-chart';
  chartCol.appendChild(title);
  chartCol.appendChild(tools);
  const chartEl = document.createElement('div');
  chartEl.className = 'chart';
  chartCol.appendChild(chartEl);

  // 默认表格左、图表右；chartLeft 时图表左、表格右；chartOnly 只留图表（概览去表）
  if (chartOnly) {
    grid.appendChild(chartCol);
  } else if (chartLeft) {
    grid.appendChild(chartCol);
    grid.appendChild(tableCol);
  } else {
    grid.appendChild(tableCol);
    grid.appendChild(chartCol);
  }

  // 左表：markdown 表加等高折叠；否则 renderTable（数据表）；chartOnly 只留图表、不渲染表
  let markdownWrap = null;
  let foldBtn = null;
  if (chartOnly) {
    // 概览去表：不渲染数据表
  } else if (leftNode) {
    markdownWrap = document.createElement('div');
    markdownWrap.className = 'table-scroll';
    markdownWrap.appendChild(leftNode);
    tableEl.appendChild(markdownWrap);
  } else if (table) {
    renderTable(tableEl, table, sql, spec.name);
  } else {
    tableEl.innerHTML = '<div class="hint">无数据</div>';
  }

  const base = spec.chart_type && spec.chart_type !== 'auto' ? spec.chart_type : 'line';
  const current = { type: base };

  function refresh() {
    tools.querySelectorAll('button').forEach((b) => {
      b.classList.toggle('active', b.dataset.t === current.type);
    });
    if (current.type === 'table') {
      chartEl.style.height = 'auto';   // 表格模式：图列随内容自适应高度，避免被固定 360px 截断/溢出
      renderTable(chartEl, table, sql, spec.name);   // renderTable 内部会先释放旧图表实例
    } else {
      chartEl.style.height = '';       // 图表模式：恢复固定高度（.viz-sbs-grid .chart { height:360px }）
      renderChart(chartEl, spec, current.type);
    }
  }

  // 分析表默认与右侧图等高（360px），超出部分折叠，可展开/收起。
  // 幂等：foldBtn 已存在说明已量过，不再重复测量/追加按钮（refresh 会反复触发）。
  function setupFold() {
    if (!markdownWrap || foldBtn) return;
    markdownWrap.style.maxHeight = '360px';
    markdownWrap.style.overflow = 'hidden';
    if (markdownWrap.scrollHeight <= markdownWrap.clientHeight + 2) {
      markdownWrap.style.maxHeight = '';
      markdownWrap.style.overflow = '';
      return;
    }
    let folded = true;
    foldBtn = document.createElement('button');
    foldBtn.className = 'btn btn-sm';
    foldBtn.style.marginTop = '8px';
    foldBtn.textContent = '展开全部';
    foldBtn.addEventListener('click', () => {
      folded = !folded;
      markdownWrap.style.maxHeight = folded ? '360px' : 'none';
      markdownWrap.style.overflow = folded ? 'hidden' : 'auto';
      foldBtn.textContent = folded ? '展开全部' : '收起';
    });
    tableEl.appendChild(foldBtn);
  }

  [['line', '折线'], ['bar', '柱状'], ['stack_bar', '堆叠柱状'], ['pie', '饼图'], ['table', '表格']].forEach(([t, label]) => {
    const b = document.createElement('button');
    b.className = 'tool-btn';
    b.dataset.t = t;
    b.textContent = label;
    b.addEventListener('click', () => { current.type = t; refresh(); });
    tools.appendChild(b);
  });

  function refreshAll() {
    setupFold();
    refresh();
  }

  block._name = spec.name || null;
  block._refresh = refreshAll;
  return block;
}

function renderViz(msg) {
  const viz = msg.querySelector('.viz');
  const card = msg.querySelector('.report-card');
  if (card) card.hidden = false;

  let charts = msg._charts || [];
  const tables = msg._tables || [];
  viz.innerHTML = '';
  viz.hidden = true;

  // 小图按大报告顺序（概览 → 明细下钻 → 预测）排序，与放大视图一致，避免乱序
  charts = charts.slice().sort((a, b) => chartSectionRank(a.name) - chartSectionRank(b.name));

  // 每张表格各配一个可切换图：按 name 配对表格，无 name 时按顺序回退
  const blocks = charts.map((spec, i) => {
    const hit = (spec.name && tables.find((t) => t.name === spec.name)) || tables[i] || null;
    const table = hit ? hit.table : null;  // tables 存的是 {name, table, sql}，取内层 table
    const sql = hit ? hit.sql : null;      // 该表对应的最终 SQL（用于导出全量）
    return buildVizBlock(spec, table, i, sql);
  });
  if (!blocks.length) return;

  // 有图表即可放大查看（左右结构）
  const zoom = msg.querySelector('.report-zoom');
  if (zoom) zoom.hidden = false;

  blocks.forEach((b) => viz.appendChild(b));
  viz.hidden = false;
  // 所有块都插入 DOM 后再渲染，保证 echarts 能取到容器尺寸
  blocks.forEach((b) => b._refresh && b._refresh());
}

// ---- 报告放大（四层结构：概览 → 成因结论 → 明细下钻 → 预测，上下堆叠、各层内左右分栏）----

let reportOverlay = null;

function getReportOverlay() {
  if (reportOverlay) return reportOverlay;
  const themeOpts = [
    ['chatbi', '默认（蓝灰）'],
    ['macarons', '马卡龙'],
    ['shine', '商务蓝'],
    ['infographic', '信息图'],
    ['vintage', '复古'],
  ].map(([v, l]) => '<option value="' + v + '">' + l + '</option>').join('');
  const ov = document.createElement('div');
  ov.className = 'report-overlay';
  ov.setAttribute('hidden', '');
  ov.innerHTML =
    '<div class="report-overlay-backdrop"></div>' +
    '<div class="report-overlay-dialog">' +
      '<div class="report-overlay-header">' +
        '<div class="report-overlay-title"></div>' +
        '<div class="report-overlay-tools">' +
          '<label class="ov-theme-label" title="切换图表主题">主题' +
            '<select class="ov-theme-select">' + themeOpts + '</select></label>' +
          '<button class="report-overlay-export btn btn-sm" title="导出为单文件 HTML">⬇ 导出报告</button>' +
        '</div>' +
        '<button class="report-overlay-close btn btn-sm">✕ 关闭</button>' +
      '</div>' +
      '<div class="report-overlay-body answer"></div>' +
    '</div>';
  document.body.appendChild(ov);
  ov.querySelector('.report-overlay-close').addEventListener('click', closeReportOverlay);
  ov.querySelector('.report-overlay-backdrop').addEventListener('click', closeReportOverlay);
  const sel = ov.querySelector('.ov-theme-select');
  sel.value = getChartTheme();
  sel.addEventListener('change', () => setChartTheme(sel.value));
  ov.querySelector('.report-overlay-export').addEventListener('click', exportReport);
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeReportOverlay(); });
  reportOverlay = ov;
  return ov;
}

function closeReportOverlay() {
  if (reportOverlay) reportOverlay.setAttribute('hidden', '');
  document.body.classList.remove('overlay-open');
}

/* 导出报告：把放大视图正文 + 图表 PNG 快照 + 内联样式打包成单文件 HTML 下载（零后端、零依赖）。 */
async function exportReport() {
  const ov = getReportOverlay();
  const body = ov.querySelector('.report-overlay-body');
  if (!body || !body.childNodes.length) return;

  const urls = snapshotChartUrls(body);   // 先给原图快照（不改原报告，保持可交互）
  const clone = body.cloneNode(true);
  applyChartSnapshots(clone, urls);       // 克隆体里换成静态 <img>

  let css = '';
  try { css = await (await fetch('style.css')).text(); } catch (e) { css = ''; }

  const title = (ov.querySelector('.report-overlay-title').textContent || '分析报告').trim();
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const safeName = title.replace(/[\\/:*?"<>|\r\n]+/g, '_').slice(0, 80) || '分析报告';
  const doc = '<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width, initial-scale=1">' +
    '<title>' + esc(title) + '</title>' +
    '<style>' + css + '</style></head>' +
    '<body class="ov-export-body"><div class="answer">' + clone.innerHTML + '</div></body></html>';

  const blob = new Blob([doc], { type: 'text/html;charset=utf-8' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = safeName + '.html';
  document.body.appendChild(a);
  a.click();
  setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
}

// 依据小节标题归类：overview/cause/forecast 为章节性结论（横向全宽），trend/drilldown 为图表小节（左右分栏）
function classifyReportLayer(title) {
  const t = (title || '').replace(/[^一-龥a-zA-Z0-9]/g, '');
  if (/概览|总览|概述|overview/i.test(t)) return 'overview';
  if (/预测|forecast|projec/i.test(t)) return 'forecast';
  if (/分周|周趋势|趋势/i.test(t)) return 'trend';
  if (/下钻|明细|分解|drilldown|detail|图表集|切换|分日|分国家|分商品|dau|arpu|数据解读|解读/i.test(t)) return 'drilldown';
  if (/成因|归因|cause|attribution|结论/i.test(t)) return 'cause';
  return 'default';
}

// 依据图表名（= 步骤名 / SQL 文件名）归位到报告小节：预测→预测，分周/趋势→概览，其余→明细下钻
function chartSectionOfName(name) {
  const n = name || '';
  if (/预测|forecast|projec/i.test(n)) return 'forecast';
  if (/分周|周趋势|趋势/i.test(n)) return 'trend';
  return 'drilldown';
}

// 小图展示顺序：按大报告顺序（概览 → 明细下钻 → 预测）排序
const CHART_SECTION_ORDER = { trend: 0, drilldown: 1, forecast: 2 };
function chartSectionRank(name) {
  const r = CHART_SECTION_ORDER[chartSectionOfName(name)];
  return r != null ? r : 3;
}

// 把明细下钻小节按 ①~⑤（h3，或段落/加粗开头的 ①~⑤ / 1. 等序号）拆成子项；识别不到返回 null
function splitDrilldownSubitems(sectionNode) {
  const kids = Array.from(sectionNode.childNodes);
  const h2Idx = kids.findIndex((n) => n && n.nodeType === 1 && n.tagName === 'H2');
  const start = h2Idx >= 0 ? h2Idx + 1 : 0;
  const isMarker = (n) => {
    if (!n || n.nodeType !== 1) return false;
    if (n.tagName === 'H3') return true;
    const t = (n.textContent || '').trim();
    return /^[①-⑤]/.test(t) || /^[1-5][.、)）]/.test(t);
  };
  const intro = [];
  const subitems = [];
  let cur = null;
  kids.slice(start).forEach((n) => {
    if (isMarker(n)) {
      if (cur) subitems.push(cur);
      cur = { heading: n, body: [] };
    } else if (cur) {
      cur.body.push(n);
    } else {
      intro.push(n);
    }
  });
  if (cur) subitems.push(cur);
  if (!subitems.length) return null;
  return { intro, subitems };
}

// 明细下钻小节：h2 + intro 全宽；每个子项 = 标题(全宽) + [分析表|图表 并排] + 结论(全宽)；识别不到子项则正文全宽、图并排堆其下
function renderDrilldownBand(sectionNode, drillData, sbsAll) {
  const band = document.createElement('div');
  band.className = 'ov-band ov-drilldown';

  const appendRich = (container, nodes) => {
    nodes.forEach((n) => {
      if (n.nodeType === 3 && !(n.textContent || '').trim()) return;
      container.appendChild(n.cloneNode(true));
    });
  };

  // 从子项正文抽出第一个 <table> 作为「分析表」（左表用），并从正文移除，避免下方结论重复展示
  const extractTable = (bodyNodes) => {
    for (let i = 0; i < bodyNodes.length; i++) {
      const n = bodyNodes[i];
      if (!n || n.nodeType !== 1) continue;
      if (n.tagName === 'TABLE') { bodyNodes.splice(i, 1); return n; }
      const tbl = n.querySelector('table');
      if (tbl) { tbl.parentNode.removeChild(tbl); return tbl; }
    }
    return null;
  };

  const buildBlock = (d, i, leftNode) => {
    const block = buildVizSideBySide(d.spec, d.table, i, d.sql, leftNode);
    if (sbsAll) sbsAll.push(block);
    return block;
  };

  const info = splitDrilldownSubitems(sectionNode);
  if (!info) {
    const text = document.createElement('div');
    text.className = 'ov-band-text';
    text.appendChild(sectionNode.cloneNode(true));
    band.appendChild(text);
    const charts = document.createElement('div');
    charts.className = 'ov-charts-full';
    (drillData || []).forEach((d, i) => charts.appendChild(buildBlock(d, i, null)));
    band.appendChild(charts);
    return band;
  }

  const h2 = sectionNode.querySelector(':scope > h2');
  if (h2) {
    const t = document.createElement('div');
    t.className = 'ov-drilldown-title';
    t.appendChild(h2.cloneNode(true));
    band.appendChild(t);
  }
  if (info.intro.length) {
    const t = document.createElement('div');
    t.className = 'ov-drilldown-intro';
    appendRich(t, info.intro);
    band.appendChild(t);
  }

  info.subitems.forEach((sub, idx) => {
    const d = (drillData || [])[idx] || null;

    const h = document.createElement('div');
    h.className = 'ov-drilldown-heading';
    h.appendChild(sub.heading.cloneNode(true));

    // 结论（抽掉表格后的正文）用高亮块放在表格/图表上方
    const bodyWrap = document.createElement('div');
    const tbl = d ? extractTable(sub.body) : null;
    if (sub.body.length) {
      const b = document.createElement('div');
      b.className = 'ov-conclusion';
      appendRich(b, sub.body);
      bodyWrap.appendChild(b);
    }

    if (d) {
      const v = document.createElement('div');
      v.className = 'ov-drilldown-viz';
      v.appendChild(buildBlock(d, idx, tbl));
      bodyWrap.appendChild(v);
    }

    // 每个维度（①~⑤）二级折叠，默认展开
    band.appendChild(makeSubCollapse(h, bodyWrap, true));
  });

  // 多出来的图（子项比图少时）：补到末尾全宽
  const leftover = (drillData || []).slice(info.subitems.length);
  if (leftover.length) {
    const c = document.createElement('div');
    c.className = 'ov-charts-full';
    leftover.forEach((d, i) => c.appendChild(buildBlock(d, info.subitems.length + i, null)));
    band.appendChild(c);
  }

  return band;
}

// 概览小节：h2 全宽；上方高亮块 = 一句话结论 + 核心指标卡；下方「分周流水达成趋势」= 分周明细表（左）+ 趋势折线（右）并排
function renderOverviewBand(sectionNode, trendData, sbsAll) {
  const band = document.createElement('div');
  band.className = 'ov-band ov-overview';

  const kids = Array.from(sectionNode.childNodes);

  // 标题（概览 h2）
  const h2 = kids.find((n) => n && n.nodeType === 1 && n.tagName === 'H2');
  if (h2) {
    const t = document.createElement('div');
    t.className = 'ov-drilldown-title';
    t.appendChild(h2.cloneNode(true));
    band.appendChild(t);
  }

  const body = kids.filter((n) => n !== h2);

  // 从 nodes 里抽出第一张 <table>（抽完从正文移除）
  const extractTable = (nodes) => {
    for (let i = 0; i < nodes.length; i++) {
      const n = nodes[i];
      if (!n || n.nodeType !== 1) continue;
      if (n.tagName === 'TABLE') { nodes.splice(i, 1); return n; }
      const tbl = n.querySelector('table');
      if (tbl) { tbl.parentNode.removeChild(tbl); return tbl; }
    }
    return null;
  };

  // 「分周流水达成趋势」的标题式标记：h2~h4 标题，或含「分周/趋势」的加粗段（如 **分周流水达成趋势**（折线 + 右轴达成率））。
  // 它常是 <strong> 段落而非 h2~h4，若只按标题找会把分周明细表误留在高亮块里。
  const isTrendMarker = (n) => {
    if (!n || n.nodeType !== 1) return false;
    if (/^H[2-4]$/.test(n.tagName)) return /分周|趋势/.test(n.textContent || '');
    const strong = n.querySelector && n.querySelector('strong');
    return !!(strong && /分周|趋势/.test(strong.textContent || ''));
  };

  const d = (trendData || [])[0] || null;
  // 小节 h2 本身若是「分周流水达成趋势」（独立趋势小节），则没有「一句话结论 + 指标卡」，直接从正文抽表。
  const h2IsTrend = !!(h2 && /分周|趋势/.test(h2.textContent || ''));

  // 有趋势图时：定位「分周流水达成趋势」标记，抽出其后的分周明细表做左半图；
  // 标记之前（一句话结论 + 核心指标卡）留作顶部高亮块；标记之后除表外的正文（四周达成率总结）放图下方。
  let topNodes = body.slice();
  let tailNodes = [];
  let trendTable = null;
  let sideBySide = false;
  if (d) {
    const trendIdx = h2IsTrend ? 0 : body.findIndex(isTrendMarker);
    if (trendIdx >= 0) {
      const after = body.slice(trendIdx);
      trendTable = extractTable(after);      // 抽出分周明细表（左半图）
      if (!h2IsTrend) after.splice(0, 1);    // 移除「分周流水达成趋势」标记（图表标题已展示）
      topNodes = body.slice(0, trendIdx);
      tailNodes = after;
      sideBySide = true;
    }
  }

  // 上方高亮块（一句话结论 + 核心指标卡）：单独二级折叠，默认展开
  const hasConclusion = topNodes.length > 0;
  if (hasConclusion) {
    const c = document.createElement('div');
    c.className = 'ov-conclusion';
    topNodes.forEach((n) => {
      if (n.nodeType === 3 && !(n.textContent || '').trim()) return;
      c.appendChild(n.cloneNode(true));
    });
    const h = document.createElement('div');
    h.className = 'ov-sub-label';
    h.textContent = '核心结论';
    band.appendChild(makeSubCollapse(h, c, true));
  }

  // 下方图表/表格（分周明细表 + 趋势折线 + 四周达成率总结）：
  // 概览（有结论高亮块）时单独二级折叠、默认折叠；独立趋势小节（无结论）时直接平铺、默认展开。
  if (d || tailNodes.length || (trendData || []).length > 1) {
    const trendBody = document.createElement('div');
    if (d) {
      const v = document.createElement('div');
      v.className = 'ov-drilldown-viz';
      const block = sideBySide
        ? buildVizSideBySide(d.spec, d.table, 0, d.sql, trendTable, false, false)  // 表左图右
        : buildVizSideBySide(d.spec, d.table, 0, d.sql, null, true, true);         // 只留图全宽
      // 概览趋势图标题用【步骤名】（如「分周流水达成趋势」），不带「文件名：维度·指标」后缀
      const stepName = sqlStepName(d.sql);
      const titleEl = block.querySelector('.viz-title');
      if (titleEl && stepName) titleEl.textContent = stepName;
      if (sbsAll) sbsAll.push(block);
      v.appendChild(block);
      trendBody.appendChild(v);
    }
    if (tailNodes.length) {
      const note = document.createElement('div');
      note.className = 'ov-trend-note';
      tailNodes.forEach((n) => {
        if (n.nodeType === 3 && !(n.textContent || '').trim()) return;
        note.appendChild(n.cloneNode(true));
      });
      trendBody.appendChild(note);
    }
    const leftover = (trendData || []).slice(1);
    if (leftover.length) {
      const c = document.createElement('div');
      c.className = 'ov-charts-full';
      leftover.forEach((d2, i) => c.appendChild(buildVizSideBySide(d2.spec, d2.table, i + 1, d2.sql, null, true, true)));
      trendBody.appendChild(c);
    }
    if (hasConclusion) {
      const h = document.createElement('div');
      h.className = 'ov-sub-label';
      h.textContent = '分周流水达成趋势';
      band.appendChild(makeSubCollapse(h, trendBody, false));
    } else {
      band.appendChild(trendBody);
    }
  }

  return band;
}

// 给放大视图的模块加折叠：标题(头部)可点击切换；概览(高亮块)默认展开、其余默认折叠。
// 概览/下钻模块：标题是 .ov-drilldown-title（首子元素），其余包进 .ov-band-body 折叠。
// 结论/预测模块(full)：克隆的 .report-section 里 h2 做头部，正文与图一起折叠。
function attachBandCollapse(band, expanded) {
  const drTitle = band.querySelector('.ov-drilldown-title');
  if (drTitle) {
    const body = document.createElement('div');
    body.className = 'ov-band-body';
    Array.from(band.childNodes).filter((n) => n !== drTitle).forEach((n) => body.appendChild(n));
    band.appendChild(body);
    drTitle.classList.add('ov-band-header');
    band.classList.add('ov-band-collapsible');
    if (!expanded) band.classList.add('collapsed');
    drTitle.addEventListener('click', () => {
      const willExpand = band.classList.contains('collapsed');
      band.classList.toggle('collapsed');
      if (willExpand) resizeBandCharts(band);
    });
    return;
  }
  const sec = band.querySelector('.report-section');
  const h2 = sec && sec.querySelector(':scope > h2');
  if (!sec || !h2) return;
  sec.classList.add('ov-sec-collapsible');
  if (!expanded) sec.classList.add('ov-sec-collapsed');
  h2.addEventListener('click', () => {
    const willExpand = sec.classList.contains('ov-sec-collapsed');
    sec.classList.toggle('ov-sec-collapsed');
    if (willExpand) resizeBandCharts(band);
  });
}

// 展开折叠时重绘内部图表：折叠期间（display:none）初始化的 ECharts 尺寸为 0，展开后必须重渲染，
// 否则图表挤压成窄条（表现为「向左边挤压」）。
function resizeBandCharts(root) {
  (root.querySelectorAll('.viz-block') || []).forEach((b) => {
    if (b._refresh) b._refresh();
  });
}

// 二级折叠：header 可点切换，body 收进 .ov-sub-body；expanded=false 时默认折叠。返回包裹后的 holder。
function makeSubCollapse(header, body, expanded) {
  const holder = document.createElement('div');
  holder.className = 'ov-sub-collapsible';
  header.classList.add('ov-sub-header');
  body.classList.add('ov-sub-body');
  holder.appendChild(header);
  holder.appendChild(body);
  if (!expanded) holder.classList.add('collapsed');
  header.addEventListener('click', () => {
    const willExpand = holder.classList.contains('collapsed');
    holder.classList.toggle('collapsed');
    if (willExpand) resizeBandCharts(holder);
  });
  return holder;
}

function openReportOverlay(msg) {
  const ov = getReportOverlay();
  ov.querySelector('.report-overlay-title').textContent = (msg._question || '分析报告').trim().slice(0, 60);

  const body = ov.querySelector('.report-overlay-body');
  body.innerHTML = '';
  const foldCfg = msg._meta && msg._meta.fold;  // 专项「报告展示配置」：默认折叠/展开

  // 正文小节（.report-section，剔除已内嵌图表）；h2 之前的游离内容并入开头引言
  let preamble = null;
  const sections = [];
  const answerNode = msg.querySelector('.answer');
  if (answerNode && !answerNode.hidden) {
    const clone = answerNode.cloneNode(true);
    clone.querySelectorAll('.viz-block').forEach((b) => b.remove());
    const loose = document.createElement('div');
    loose.className = 'ov-preamble';
    Array.from(clone.children).forEach((c) => {
      if (c.classList && c.classList.contains('report-section')) {
        c.classList.remove('collapsible', 'collapsed');   // 内嵌折叠态不带入放大视图（放大有自己的模块折叠）
        sections.push(c);
      }
      else loose.appendChild(c);
    });
    if (loose.childNodes.length) preamble = loose;
  }

  // 图表块（每块带 _name，供按名归位）
  const charts = msg._charts || [];
  const tables = msg._tables || [];
  const allBlocks = charts.map((spec, i) => {
    const hit = (spec.name && tables.find((t) => t.name === spec.name)) || tables[i] || null;
    const table = hit ? hit.table : null;
    const sql = hit ? hit.sql : null;
    return buildVizBlock(spec, table, i, sql);
  });

  // 图表归属：预测图 → 预测小节，分周/趋势图 → 概览，其余 → 明细下钻小节
  const chartSectionOf = (block) => chartSectionOfName(block._name);
  const used = new Set();

  // 结论小节：横向全宽（正文横贯左右；若有图，排在其下全宽）
  const full = (sectionNode, blocks) => {
    const band = document.createElement('div');
    band.className = 'ov-band ov-full';
    band.appendChild(sectionNode.cloneNode(true));
    if (blocks && blocks.length) {
      const c = document.createElement('div');
      c.className = 'ov-charts-full';
      blocks.forEach((b) => { c.appendChild(b); used.add(b); });
      band.appendChild(c);
    }
    return band;
  };

  if (preamble) body.appendChild(preamble);

  const sbsAll = [];  // 明细下钻的「表格左 + 图表右」并排块，最后统一渲染
  let trendRendered = false;  // 趋势图只在首个概览/趋势小节渲染一次，避免「概览」与「分周趋势」两节重复出整套趋势图

  sections.forEach((s) => {
    const h2 = s.querySelector(':scope > h2') || s.querySelector('h2');
    const title = h2 ? h2.textContent : '';
    const kind = classifyReportLayer(title);
    let band = null;
    if (kind === 'cause') {
      // 成因结论：横向全宽
      band = full(s, null);
    } else if (kind === 'forecast') {
      // 预测：横向全宽，预测图排在其下
      const fcBlocks = allBlocks.filter((b) => !used.has(b) && chartSectionOf(b) === 'forecast');
      band = full(s, fcBlocks);
    } else if (kind === 'overview' || kind === 'trend') {
      // 概览 / 分周趋势：结论高亮块置顶，分析表左 + 趋势图右（同明细下钻的并排布局）
      let trendData = [];
      if (!trendRendered) {
        trendRendered = true;
        const trendSpecs = (msg._charts || []).filter((c) => chartSectionOfName(c.name) === 'trend');
        trendData = trendSpecs.map((spec) => {
          const hit = (spec.name && tables.find((t) => t.name === spec.name)) || null;
          return { spec, table: hit ? hit.table : null, sql: hit ? hit.sql : null };
        });
      }
      allBlocks.forEach((b) => { if (!used.has(b) && chartSectionOf(b) === 'trend') used.add(b); });
      band = renderOverviewBand(s, trendData, sbsAll);
    } else if (kind === 'drilldown') {
      // 明细下钻：每个子项 = 标题(全宽) + [分析表|图表 并排] + 结论(全宽)
      const drillSpecs = (msg._charts || []).filter((c) => chartSectionOfName(c.name) === 'drilldown');
      const drillData = drillSpecs.map((spec) => {
        const hit = (spec.name && tables.find((t) => t.name === spec.name)) || null;
        return { spec, table: hit ? hit.table : null, sql: hit ? hit.sql : null };
      });
      // 明细下钻对应的 toggle 块标记已用，避免残留到末尾「未归位」区
      allBlocks.forEach((b) => { if (!used.has(b) && chartSectionOf(b) === 'drilldown') used.add(b); });
      band = renderDrilldownBand(s, drillData, sbsAll);
    } else {
      // 无法归类的小节：按结论式横向全宽（不配图）
      band = full(s, null);
    }
    if (band) {
      // 概览/高亮块默认展开，其余模块默认折叠；专项「报告展示配置」可覆盖
      attachBandCollapse(band, foldSectionExpand(title, foldCfg, kind === 'overview' || kind === 'trend'));
      body.appendChild(band);
    }
  });

  // 仍有未归位的图表：补到末尾全宽
  const leftover = allBlocks.filter((b) => !used.has(b));
  if (leftover.length) {
    const band = document.createElement('div');
    band.className = 'ov-band ov-full';
    const c = document.createElement('div');
    c.className = 'ov-charts-full';
    leftover.forEach((b) => c.appendChild(b));
    band.appendChild(c);
    body.appendChild(band);
  }

  if (!body.childNodes.length) {
    body.innerHTML = '<div class="hint">本报告无可放大内容</div>';
  }

  document.body.classList.add('overlay-open');
  ov.removeAttribute('hidden');
  allBlocks.forEach((b) => b._refresh && b._refresh());
  sbsAll.forEach((b) => b._refresh && b._refresh());
}

function showBadge(msg, text, flagged) {
  const badge = msg.querySelector('.meta-badge');
  badge.hidden = false;
  badge.textContent = text;
  badge.classList.toggle('badge-flagged', !!flagged);
}

function addProcessStep(msg, text, extra) {
  const proc = msg.querySelector('.process');
  if (!proc) return;
  const list = proc.querySelector('.process-list');
  const li = document.createElement('li');
  let tText = '';
  if (msg._t0) {
    tText = ((performance.now() - msg._t0) / 1000).toFixed(1) + 's';
    const t = document.createElement('span');
    t.className = 'step-time';
    t.textContent = tText;
    li.appendChild(t);
    li.appendChild(document.createTextNode(' ' + text));
  } else {
    li.textContent = text;
  }
  if (extra) { // 可选附加节点（如导出工具的下载链接），只渲染不随 _steps 持久化
    li.appendChild(document.createTextNode(' '));
    li.appendChild(extra);
  }
  list.appendChild(li);
  proc.hidden = false;
  // 同步累积到消息对象上，保存聊天记录时随消息一起持久化，供历史回放「运行过程」
  (msg._steps = msg._steps || []).push({ time: tText, text: text });
}

function handleEvent(msg, ev) {
  if (msg._deep) { handleDeepEvent(msg, ev); return; }
  switch (ev.type) {
    case 'stage':
      setStatus(msg, ev.message);
      addProcessStep(msg, ev.message);
      break;
    case 'progress':
      // 长耗时 LLM 调用期间的心跳：只更新状态行，不追加运行过程，避免刷屏
      setStatus(msg, ev.message);
      break;
    case 'meta':
      currentMeta = ev;
      msg._meta = ev;
      if (ev.source === 'skill') {
        showBadge(msg, '🎯 专项：' + ev.skill, false);
        addProcessStep(msg, '🎯 引用专项分析方法：' + ev.skill);
      } else if (ev.source === 'sql') {
        showBadge(msg, '📄 既有SQL：' + ev.skill, false);
        addProcessStep(msg, '📄 命中既有 SQL「' + ev.skill + '」，直接运行');
      } else if (ev.source === 'model') {
        showBadge(msg, '🔮 算法预测：' + ev.skill, false);
        addProcessStep(msg, '🔮 命中预测能力「' + ev.skill + '」，取数并预测');
      } else if (ev.source === 'candidates') {
        showBadge(msg, '🔍 多个候选，请选择', false);
        addProcessStep(msg, '🔍 命中多个候选，等待选择');
      } else if (ev.source === 'clarify') {
        showBadge(msg, '🤔 需要澄清', false);
        addProcessStep(msg, '🤔 信息不足，需要澄清');
      } else if (ev.source === 'rewrite') {
        showBadge(msg, '🔧 就近改写：' + ev.skill + ' · 准确率无法保证', true);
        addProcessStep(msg, '🔧 基于就近 SQL「' + ev.skill + '」改写后执行（准确率无法保证）');
      } else if (ev.source === 'deep') {
        showBadge(msg, '🧠 智能路由：深度分析', false);
        addProcessStep(msg, '🧠 识别为探索性分析问题，自动切换深度分析');
      } else {
        showBadge(msg, '⚠️ AI 生成 SQL · 准确率无法保证', true);
        addProcessStep(msg, '⚠️ 未命中既有 SQL，AI 生成（准确率无法保证）');
      }
      break;
    case 'subscriptions':
      currentSubs = ev.subscriptions || [];
      renderSubActions(msg);
      break;
    case 'confirm':
      pendingConfirm = { skill: ev.skill, msg: msg, text: lastQuestion, question: ev.question || lastQuestion, game: ev.game || null };
      renderConfirmCard(msg, ev.skill, ev.summary || '');
      setStatus(msg, '待确认');
      break;
    case 'game_confirm':
      pendingGameConfirm = {
        games: ev.games || [], target_game: ev.target_game || null,
        current: ev.current || null, question: ev.question || lastQuestion,
        source: ev.source || null,
        msg: msg, text: lastQuestion,
      };
      renderGameConfirmCard(msg, ev);
      setStatus(msg, '待确认分析项目');
      break;
    case 'forecast_confirm':
      pendingForecastConfirm = {
        method: ev.method, question: ev.question || lastQuestion,
        target_game: ev.target_game || null,
        start: ev.start, end: ev.end,
        year: ev.year, month: ev.month,
        year_ambiguous: ev.year_ambiguous, past: ev.past,
        label: ev.label, years: ev.years || [],
        msg: msg, text: lastQuestion,
      };
      renderForecastConfirmCard(msg, ev);
      break;
    case 'candidates':
      pendingCandidates = {
        candidates: ev.candidates || [],
        question: ev.question || lastQuestion,
        game: ev.game || null,
        msg: msg, text: lastQuestion,
      };
      renderCandidatesCard(msg, ev);
      setStatus(msg, '待选择候选');
      break;
    case 'ai_report_confirm':
      pendingAiReportConfirm = {
        question: ev.question || lastQuestion,
        game: ev.game || null,
        msg: msg, text: lastQuestion,
      };
      renderAiReportConfirmCard(msg, ev);
      setStatus(msg, '待确认是否生成报告');
      break;
    case 'generate_confirm':
      pendingGenerateConfirm = {
        question: ev.question || lastQuestion,
        game: ev.target_game || null,
        msg: msg, text: lastQuestion,
      };
      renderGenerateConfirmCard(msg, ev);
      setStatus(msg, '待确认是否生成专项草稿');
      break;
    case 'rewrite_confirm':
      pendingRewriteConfirm = {
        sql_name: ev.sql_name || null,
        question: ev.question || lastQuestion,
        game: ev.game || null,
        msg: msg, text: lastQuestion,
      };
      renderRewriteConfirmCard(msg, ev);
      setStatus(msg, '待确认是否改写就近SQL');
      break;
    case 'route_deep':
      // 智能路由：普通模式判定为探索性/开放性问题 → 流结束后自动切深度分析（runStream 收尾触发）
      msg._routeDeep = { question: ev.question || lastQuestion, refined: ev.refined_question || null };
      setStatus(msg, '识别为探索性分析问题，正在切换深度分析…');
      break;
    case 'game_select':
      // 「不选游戏」模式提问后的游戏多选卡（后端 _sentinel_ensure 发出）
      // 先清旧卡（对抗审查二轮）：新卡到达前可能残留旧待选择卡，不清理会出现两张卡并存
      clearPendingGameSelect('已取消');
      pendingGameSelect = {
        games: ev.games || [], preselected: ev.preselected || [],
        question: ev.question || lastQuestion, reason: ev.reason || null,
        msg: msg, text: lastQuestion,
      };
      renderGameSelectCard(msg, ev);
      setStatus(msg, '待选择分析游戏…');
      break;
    case 'bound_games':
      // 哨兵直接绑定路径（无多选卡）回传实际绑定游戏：与 executeGameSelect 写会话游戏同源，
      // 点名/专项绑定/恰1款自动绑/确认链重发后，提炼、合并、追问都能拿得到会话游戏
      // （对抗审查三轮 [5][6][8][9]：此前只有多选卡路径写 sessionGames/deepSessionGames）
      {
        const keys = Array.isArray(ev.games) ? ev.games.filter((k) => typeof k === 'string') : [];
        if (!keys.length) break;
        if (msg._deep) { deepSessionGames = keys.slice(); } else { sessionGames = keys.slice(); }
        storeSessionGames();
      }
      break;
    case 'sql':
      currentSql = ev.sql;
      msg._sql = ev.sql;
      msg._sqlDb = ev.db || null;  // 单库时供 CSV 导出回传 db（哨兵「不选游戏」单库绑定也需显式库）
      if (!msg._sqls) msg._sqls = [];
      msg._sqls.push({ name: ev.name || null, sql: ev.sql, explain: ev.explain || null, db: ev.db || null });
      renderSql(msg, ev.sql, ev.explain);
      break;
    case 'data':
      state.table = ev.table;
      msg._table = ev.table;
      if (!msg._tables) msg._tables = [];
      // currentSql 是紧邻本次 data 之前的 sql 事件值（apply_db 后的最终 SQL），供导出全量
      msg._tables.push({ name: ev.name || null, table: ev.table, sql: currentSql || null, export: ev.export || null });
      // 多游戏拼接表：把逐库 SQL 清单挂到表格对象上（charts.js 导出按钮读 table.__export 按库重查拼表导出）
      if (ev.export && ev.export.length) ev.table.__export = ev.export;
      // 单库：把库名挂到表格对象（导出按钮回传 db，哨兵模式下后端无 game 需显式指定）
      if (msg._sqlDb) ev.table.__db = msg._sqlDb;
      break;
    case 'answer':
      currentAnswer = ev.markdown;
      msg._answer = ev.markdown;
      renderAnswer(msg, ev.markdown);
      // 首轮三模型官方报告 → 记录为后续追问的上下文
      if (!currentContextReport && currentMeta && currentMeta.source === 'skill') {
        lastReport = ev.markdown;
        lastReportSkill = currentMeta.skill || state.skill;
      }
      break;
    case 'charts': state.charts = ev.charts; msg._charts = ev.charts; renderViz(msg); break;
    case 'usage': currentUsage = ev; break;
    case 'suggest': currentSuggestion = ev; renderSuggestionCard(msg, ev); break;
    case 'generate': renderGenerateCard(msg, ev); break;
    case 'caveats':
      // 数据提示事件（与深度模式同协议）：多地区拼接有失败地区跳过等提醒，
      // 渲染成消息体内的黄色提示块。多步骤专项每步失败各发一条 caveats，
      // 旧实现 replace 语义会丢掉前面步骤的警示（对抗审查三轮 [0]）——改为累积：
      // 按提示文本去重后追加进已有块，同一事件重复到达不产生重复条目
      {
        const caveBody = msg.querySelector('.body');
        if (!caveBody) break;
        let caveBox = caveBody.querySelector('.caveat-block');
        if (!caveBox) {
          caveBox = document.createElement('div');
          caveBox.className = 'caveat-block';
          const caveTitle = document.createElement('div');
          caveTitle.className = 'caveat-title';
          caveTitle.textContent = '⚠️ 数据提示';
          caveBox.appendChild(caveTitle);
          caveBody.appendChild(caveBox);
        }
        const seen = new Set(Array.from(caveBox.querySelectorAll('.hint')).map((h) => h.textContent));
        (ev.items || []).forEach((it) => {
          if (!it) return;
          const text = '【' + (it.category || '') + '】' + (it.text || '');
          if (seen.has(text)) return;
          seen.add(text);
          const h = document.createElement('div');
          h.className = 'hint';
          h.textContent = text;  // textContent 赋值防注入
          caveBox.appendChild(h);
        });
      }
      break;
    case 'error': setStatus(msg, '出错：' + ev.message, true); break;
    case 'done':
      // 累计本次会话用量（确认阶段与执行阶段都算）
      if (currentUsage) {
        sessionUsage.tokens += currentUsage.total_tokens || 0;
        sessionUsage.cost += currentUsage.cost || 0;
        sessionUsage.prompt += currentUsage.prompt_tokens || 0;
        sessionUsage.completion += currentUsage.completion_tokens || 0;
        renderSessionUsage();
      }
      // 二次确认阶段（命中专项 / 待确认项目 / 候选卡 / AI报告确认 / 游戏多选卡）：不当作完整回合，不自动缓存
      if (!currentSql && !currentAnswer &&
          ((pendingConfirm && pendingConfirm.msg === msg) || (pendingGameConfirm && pendingGameConfirm.msg === msg) || (pendingForecastConfirm && pendingForecastConfirm.msg === msg) || (pendingAiReportConfirm && pendingAiReportConfirm.msg === msg) || (pendingRewriteConfirm && pendingRewriteConfirm.msg === msg) || (pendingGenerateConfirm && pendingGenerateConfirm.msg === msg) || (pendingGameSelect && pendingGameSelect.msg === msg))) {
        break;
      }
      // 候选确认回合：写入历史（标记 candidates 来源），供后端「多轮候选→强制兜底」闸门计数；
      // 用 _confirmOnly 标记，不持久化、不渲染为正式消息。
      if (!currentSql && !currentAnswer && pendingCandidates && pendingCandidates.msg === msg) {
        transcript.push({ role: 'assistant', text: '', sql: '', answer: '', meta: { source: 'candidates' }, _confirmOnly: true });
        break;
      }
      // 以消息元素上实际累积的内容为准（确认执行等二次流也可靠），模块级 currentSql/currentAnswer 仅作兜底
      const ans = msg._answer || currentAnswer || '';
      const sqlv = msg._sql || currentSql || '';
      const errored = msg.querySelector('.status').classList.contains('error');
      if (!errored) {
        setStatus(msg, '完成');
        renderTimeBadge(msg, ev.elapsed);
      }
      // 对抗审查修复：整轮看门狗可能在报告已完整交付后才补发 error——answer 已产出时照常
      // 入库（状态保留出错提示即可），避免完整报告因超时标签丢出历史。
      if (sqlv || ans || (msg._charts && msg._charts.length) || (msg._tables && msg._tables.length)) {
        transcript.push({ role: 'assistant', text: ans, sql: sqlv, answer: ans, charts: msg._charts || null, tables: msg._tables || null, meta: msg._meta || null, usage: currentUsage ? { prompt_tokens: currentUsage.prompt_tokens || 0, completion_tokens: currentUsage.completion_tokens || 0, total_tokens: currentUsage.total_tokens || 0, cost: currentUsage.cost || 0 } : null, process: (msg._steps && msg._steps.length) ? msg._steps : null });
        msg._ti = transcript.length - 1;  // 复验 R3：记录本条在 transcript 的索引，供 🔍 深度分析精确剔除对应提问
        renderUsageBadge(msg, currentUsage);
        if (ans) renderSuggestButton(msg);
        if (ans && !msg._deep) renderDeepButton(msg);
        // 2026-10-26：「查看报告缺口与补数建议」从聊天窗口（to-C）移除，仅保留在
        // 分析配置→专项管理内执行专项后于 AI 源生侧栏弹出（to-B 工程收口）
        if (msg._sql) {
          const actions = msg.querySelector('.msg-actions');
          actions.hidden = false;
          const btn = actions.querySelector('.subscribe-btn');
          btn.addEventListener('click', () => subscribeReport(msg));
        }
      }
      autoSave();
      break;
  }
}

// ---- 深度分析（agentic 循环）事件渲染 ----

const DEEP_TOOL_LABELS = {
  query_database: '查表取数',
  list_tables: '列出表',
  describe_table: '查看表结构',
  search_columns: '搜字段',
  search_knowledge: '检索知识库',
  read_kb_doc: '读知识库文档',
  read_sql: '读已存 SQL',
  list_special_skills: '列专项',
  read_special_skill: '读专项',
  search_memory: '检索记忆',
  save_memory: '保存记忆',
  search_indicators: '检索指标',
  read_indicator: '读指标',
  read_result_rows: '分页读回数据',
  convert_sql_to_flexsql: '生成报表模板',
};

function deepToolLabel(name) {
  return DEEP_TOOL_LABELS[name] || name;
}

function deepToolArgsSummary(name, args) {
  if (!args) return '';
  if (name === 'query_database') {
    const sql = (args.sql || '').replace(/\s+/g, ' ').trim();
    return sql ? '：' + (sql.length > 80 ? sql.slice(0, 80) + '…' : sql) : '';
  }
  if (name === 'describe_table') return '：' + (args.table || '');
  if (name === 'search_columns' || name === 'search_knowledge' || name === 'read_kb_doc' || name === 'read_sql' || name === 'read_special_skill') {
    return '：' + (args.term || args.query || args.name || '');
  }
  if (name === 'search_memory' || name === 'search_indicators') return '：' + (args.query || '');
  if (name === 'read_indicator') return '：' + (args.indicator_id || '');
  if (name === 'read_result_rows') {
    // 结果分页读回：result_id 本身就是 r0/r1/… 短编号，超长时截断防御
    const rid = args.result_id != null ? String(args.result_id) : '';
    return rid ? '：' + (rid.length > 12 ? rid.slice(0, 8) + '…' : rid) : '';
  }
  return '';
}

// 导出工具的下载链接：后端在 result 里带 download_url / file_name 时，工具行后追加下载按钮
function deepDownloadLink(artifact) {
  if (!artifact || !artifact.download_url || !artifact.file_name) return null;
  const a = document.createElement('a');
  a.className = 'btn btn-sm';
  a.href = artifact.download_url; // 无 JS 兜底（仅匿名会话可用，见下）
  a.textContent = '⬇️ 下载 ' + artifact.file_name; // textContent 赋值防注入
  // 点击必须走带 JWT 的 fetch（auth.js 的 window.fetch 补丁自动附 Authorization）再 blob 下载：
  // 裸 <a> 导航是浏览器跳转、不带任何头，后端 get_current_user 只认 Bearer → 请求落 anonymous
  // 目录，而产物写在真实用户目录 → 登录用户必 404。export_query 与报表模板文件交付共用此路径。
  a.addEventListener('click', function (ev) {
    ev.preventDefault();
    fetch(artifact.download_url).then(function (resp) {
      if (!resp.ok) throw new Error('HTTP ' + resp.status);
      return resp.blob();
    }).then(function (blob) {
      const url = URL.createObjectURL(blob);
      const tmp = document.createElement('a');
      tmp.href = url;
      tmp.download = artifact.file_name;
      document.body.appendChild(tmp);
      tmp.click();
      tmp.remove();
      setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
    }).catch(function () {
      // fetch 失败（网络/登录态异常）回退裸导航：匿名会话下仍能下载
      window.location.href = artifact.download_url;
    });
  });
  return a;
}

function handleDeepEvent(msg, ev) {
  switch (ev.type) {
    case 'agent_start':
      msg._deepMeta = { model: ev.model, db: ev.db, game: ev.game };
      msg._runId = ev.run_id || null;  // 本次 Agent 运行 id（随消息保存，收口时清空）
      activeRunId = ev.run_id || null; // 模块级记录：点「停止」/超时中止时据此向后端发取消
      showBadge(msg, '🧠 深度分析' + (ev.model ? ' · ' + ev.model : ''), false);
      setStatus(msg, '深度分析：规划中…');
      addProcessStep(msg, '🧠 深度分析已启动（库 ' + (ev.db || '') + '）');
      const proc0 = msg.querySelector('.process');
      if (proc0) proc0.open = true; // 深度分析：步骤日志即主内容，默认展开
      break;
    case 'plan_text':
      addProcessStep(msg, '📋 ' + ev.text);
      break;
    case 'progress':
      setStatus(msg, ev.text || '推理中…');
      break;
    case 'tool_start':
      setStatus(msg, '执行：' + deepToolLabel(ev.name));
      addProcessStep(msg, '🔧 ' + deepToolLabel(ev.name) + deepToolArgsSummary(ev.name, ev.args));
      break;
    case 'tool_done':
      addProcessStep(msg, (ev.ok ? '✅ ' : '⚠️ ') + deepToolLabel(ev.name) + '：' + (ev.summary || '完成'), deepDownloadLink(ev.artifact));
      break;
    case 'answer':
      if (ev.delta != null) {
        // 流式增量（审计·聊天优化块 A）：边想边写，实时呈现
        if (!msg._answerStreaming) {
          msg._answerStreaming = true;
          const ans0 = msg.querySelector('.answer');
          ans0.hidden = false;
          ans0.innerHTML = '';
          msg._answer = '';
          currentAnswer = '';
        }
        msg._answer += ev.delta;
        currentAnswer = msg._answer;
        renderMarkdownInto(msg.querySelector('.answer'), msg._answer);
      } else {
        // 整段输出（兜底非流式路径）
        msg._answerStreaming = false;
        currentAnswer = ev.text;
        msg._answer = ev.text;
        renderAnswer(msg, ev.text);
      }
      break;
    case 'answer_cancel':
      // 流出的思考文字已移作「计划」展示（plan_text），答案区清空留给最终结论
      msg._answerStreaming = false;
      msg._answer = '';
      currentAnswer = '';
      {
        const ac = msg.querySelector('.answer');
        ac.innerHTML = '';
        ac.hidden = true;
      }
      break;
    case 'data':
      msg._table = ev.table;
      if (!msg._tables) msg._tables = [];
      // 深度取数的表格：sql 来自 data 事件自身（普通聊天取自 currentSql，深度模式无 sql 事件）；
      // 多游戏时 export 为逐库 SQL 清单、单库时 db 为库名，挂到表格对象供 charts.js 导出重查
      if (ev.export && ev.export.length) ev.table.__export = ev.export;
      if (ev.db) ev.table.__db = ev.db;
      msg._tables.push({ name: ev.name || null, table: ev.table, sql: ev.sql || null, export: ev.export || null });
      break;
    case 'game_select':
      // 深度分析「不选游戏」提问后的多选卡：置位特判标记 + 同款卡渲染
      // 先清旧卡（对抗审查二轮）：同普通模式，新卡到达前清理残留旧卡
      clearPendingGameSelect('已取消');
      msg._gameSelect = {
        question: ev.question || '', games: ev.games || [],
        preselected: ev.preselected || [], reason: ev.reason || null,
      };
      pendingGameSelect = {
        games: ev.games || [], preselected: ev.preselected || [],
        question: ev.question || lastQuestion, reason: ev.reason || null,
        msg: msg, text: lastQuestion,
      };
      renderGameSelectCard(msg, ev);
      setStatus(msg, '待选择分析游戏…');
      break;
    case 'charts':
      msg._charts = ev.charts;
      renderViz(msg);
      break;
    case 'question':
      // ask_user 提问（对抗审查修复）：记录问题与选项，final 收口渲染正文后挂可点选项卡；
      // 选项为 null/空时只展示文本（自动化流程降级可见，交互卡不适用时也安全）
      msg._askQuestion = ev.question || '';
      msg._askOptions = (ev.options && ev.options.length) ? ev.options : null;
      break;
    case 'error':
      // 收口：出错即结束本次运行，运行 id 失效（取消不再有意义）
      msg._runId = null;
      activeRunId = null;
      setStatus(msg, '深度分析出错：' + (ev.message || ''), true);
      break;
    case 'caveats':
      // 数据提示事件（如后端对超长取数结果做了「浓缩喂给 AI」等处理时的提醒）：
      // 渲染成消息体内的黄色提示块；重复到达时先移除旧块再插入（幂等）。
      {
        const body = msg.querySelector('.body');
        if (!body) break;
        const old = body.querySelector('.caveat-block');
        if (old) old.remove();
        const box = document.createElement('div');
        box.className = 'caveat-block';
        const title = document.createElement('div');
        title.className = 'caveat-title';
        title.textContent = '⚠️ 数据提示';
        box.appendChild(title);
        (ev.items || []).forEach((it) => {
          if (!it) return;
          const h = document.createElement('div');
          h.className = 'hint';
          h.textContent = '【' + (it.category || '') + '】' + (it.text || '');  // textContent 赋值防注入
          box.appendChild(h);
        });
        body.appendChild(box);
      }
      break;
    case 'final':
      if (!msg._answer && ev.reply) {
        currentAnswer = ev.reply;
        msg._answer = ev.reply;
        // 提问轮的 reply 末尾带「1. xxx / 2. yyy」编号选项行：正文渲染剥掉（选项卡另渲染），
        // 但 msg._answer 保留全文入库——选完后续聊时模型要对照编号选项理解用户所选。
        // game_select 多选卡的编号游戏行同理剥掉（卡另渲染，正文不重复）
        const stripOpts = msg._askOptions || (msg._gameSelect ? gameOptionLines(msg._gameSelect.games) : null);
        renderAnswer(msg, stripAskOptionLines(ev.reply, stripOpts));
      }
      if (ev.sqls && ev.sqls.length) {
        msg._sqls = ev.sqls.map((s) => ({ name: null, sql: s }));
        msg._sql = ev.sqls[0];
        renderSql(msg, ev.sqls[0], null);
      }
      // 收口：流式累积的内容整段重渲染一次（套折叠小节结构，放大视图按 .report-section 分带）；
      // 有结论且有数据（SQL/表格）时补上报告卡片框架（标题/副标题/放大按钮）
      if (msg._answerStreaming && msg._answer) {
        msg._answerStreaming = false;
        const stripOpts2 = msg._askOptions || (msg._gameSelect ? gameOptionLines(msg._gameSelect.games) : null);
        renderAnswer(msg, stripAskOptionLines(msg._answer, stripOpts2));
      } else if (msg._answer && (msg._sql || msg._table)) {
        msg.querySelector('.report-card').hidden = false;
        renderReportHead(msg);
      }
      // 对抗审查修复：先按 ev.status 分支。success=answered 只在 status='success' 时为真，
      // canceled/partial/timeout 恒 success=False，原「if (ev.success) 包住状态细化」写法让
      // canceled/partial 两个分支成死代码，用户主动停止被误标成出错
      if (ev.status === 'canceled') {
        // 后端确认本次运行已取消：与前端 abort 路径观感一致，显式标记「已停止」
        showBadge(msg, '⏹ 已停止', true);
        setStatus(msg, '已停止', true);
      } else if (ev.status === 'partial') {
        // 部分完成（如超最大轮数但仍有产出）：提示徽标 + 状态带说明
        showBadge(msg, '⚠️ ' + (ev.status_text || '部分完成'), true);
        setStatus(msg, ev.status_text || '完成');
      } else if (ev.status === 'timeout') {
        // 超时：error 事件已带完整详情，这里收口为「超时」状态（保留原因），不再走通用未完成文案
        setStatus(msg, '超时' + (ev.error ? '：' + ev.error : ''), true);
      } else if (ev.success) {
        // 正常完成（status='success'）：error 样式已在 error 事件里上过则不再覆盖
        if (!msg.querySelector('.status').classList.contains('error')) setStatus(msg, ev.status_text || '完成');
      } else {
        setStatus(msg, '未完成' + (ev.error ? '：' + ev.error : ''), true);
      }
      // 收口：本轮深度运行结束，运行 id 失效
      msg._runId = null;
      activeRunId = null;
      // 「不选游戏」提问轮（game_select 短流收口）：状态保持「待选择游戏…」，不挂 ask_user 选项卡
      if (msg._gameSelect) {
        setStatus(msg, '待选择分析游戏…');
      } else if (msg._askOptions && msg._askOptions.length) {
        renderAskOptionsCard(msg);
      }
      finalizeDeepMessage(msg);
      break;
  }
}

function finalizeDeepMessage(msg) {
  // 对抗审查修复：final 事件与 abort/请求失败收尾可能先后触发（如流刚结束即超时中止），
  // 幂等防护防重复入历史。
  // 取消联动收口：无论本次运行以何种方式结束，运行 id 都已失效，避免后续误发取消
  if (msg._runId || activeRunId) { msg._runId = null; activeRunId = null; }
  if (msg._finalized) return;
  msg._finalized = true;
  const ans = msg._answer || '';
  // 对抗审查修复（round-2）：无任何产出（无答案/SQL/图表/表格，如空步就中止）时不入历史——
  // 防止空气泡，也防止空 assistant 条目泄漏进普通多轮 buildHistory 喂给 /api/chat。
  if (!ans && !msg._sql && !(msg._charts && msg._charts.length) && !(msg._tables && msg._tables.length)) {
    autoSave();  // 复验 R2：提问已由 appendUser 入 transcript，仍要落盘（守卫只拦空 assistant 条目）
    return;
  }
  transcript.push({
    role: 'assistant',
    text: ans,
    sql: msg._sql || '',
    answer: ans,
    charts: msg._charts || null,
    tables: msg._tables || null,
    meta: { source: 'deep' },
    usage: null,
    process: (msg._steps && msg._steps.length) ? msg._steps : null,
  });
  msg._ti = transcript.length - 1;  // 复验 R3：记录本条目在 transcript 的索引，供 🔍 深度分析精确剔除对应提问
  // 提问轮（ask_user 选项卡 / 游戏多选卡）不挂「提炼到个人知识库」按钮：问题不是分析结论
  if (ans && !(msg._askOptions && msg._askOptions.length) && !msg._gameSelect) renderSuggestButton(msg);
  autoSave();
}

// ---- 深度分析 ask_user 提问选项卡（对抗审查修复）----

// 剥掉提问正文末尾的编号选项行（「1. xxx」…），正文与选项卡各渲染一遍会重复
function stripAskOptionLines(content, options) {
  if (!options || !options.length) return content;
  const lines = String(content || '').split('\n');
  let end = lines.length;
  for (let i = options.length; i >= 1; i--) {
    const expect = (i + '. ' + options[i - 1]).trim();
    if ((lines[end - 1] || '').trim() === expect) end -= 1;
    else break;
  }
  return end === lines.length ? content : lines.slice(0, end).join('\n');
}

// game_select 多选卡的编号选项行（与 ask_user 同协议，但选项是游戏条目）：
// final reply 末尾带「1. 拳皇（kof）…」，正文渲染时同样剥掉（多选卡另渲染）。
// 与后端 agent.py _game_option_line 同规则：label（region_label）已含（key）时不再重复拼接，
// 保证 stripAskOptionLines 能精确对齐剔除编号行
function gameOptionLines(games) {
  return (games || []).map((g) => {
    if (!g) return '';
    const label = String(g.label || g.name || '').trim();
    const key = String(g.key || '').trim();
    if (!key || !label || label === key) return label || key;
    return label.endsWith('（' + key + '）') ? label : label + '（' + key + '）';
  });
}

// 在消息体末尾挂选项按钮卡（复用 confirm-card 样式）。不设自动倒计时：
// ask_user 的目的就是等用户补充信息，默认选中会违背提问本意
function renderAskOptionsCard(msg) {
  const opts = msg._askOptions;
  if (!opts || !opts.length) return;
  const body = msg.querySelector('.body');
  if (!body || body.querySelector('[data-role="ask-options"]')) return;
  const card = document.createElement('div');
  card.className = 'confirm-card';
  card.setAttribute('data-role', 'ask-options');

  const q = document.createElement('div');
  q.className = 'confirm-q';
  q.textContent = '💬 ' + (msg._askQuestion || '请选择');
  card.appendChild(q);

  const note = document.createElement('div');
  note.className = 'confirm-note';
  note.textContent = '点选一项继续，或直接在输入框补充信息后发送';
  card.appendChild(note);

  const row = document.createElement('div');
  row.className = 'confirm-actions';
  opts.forEach((opt, idx) => {
    const b = document.createElement('button');
    b.className = 'btn btn-sm';
    b.textContent = (idx + 1) + '. ' + opt;
    b.addEventListener('click', () => {
      if (sending) return;
      card.remove();
      msg._askOptions = null;
      pickDeepOption(msg, idx, opt);
    });
    row.appendChild(b);
  });
  card.appendChild(row);
  body.appendChild(card);
}

// 用户点选：以「我选第 N 项：…」新起一轮深度分析。上一轮助手提问（含编号选项全文）
// 已在 finalize 入库，本轮历史携带它，模型可对照用户所选继续执行
async function pickDeepOption(msg, idx, opt) {
  // 对抗审查三轮 [7]：深度入口统一收口——摘掉仍在倒计时的旧游戏多选卡
  clearPendingGameSelect('已取消');
  const text = '我选第 ' + (idx + 1) + ' 项：' + opt;
  appendUser(text);
  const dmsg = appendAssistant();
  dmsg._deep = true;
  dmsg._question = text;
  state.table = null;
  state.chartSpec = null;
  currentSql = null;
  currentAnswer = null;
  currentMeta = null;
  currentSubs = null;
  currentUsage = null;
  currentSuggestion = null;
  lastQuestion = text;
  // 选择气泡刚 append、尚未入库（_ti 未挂）：buildDeepHistory 回落尾部同文剔除，
  // 恰好删掉本轮刚 append 的用户选择；上一轮助手提问保留在历史里
  const req = { message: text, history: buildDeepHistory(text, dmsg._ti) };
  if (currentGameMode() === 'none' && deepSessionGames.length) req.session_games = deepSessionGames;
  await runStream(req, dmsg, '/api/agent/chat/stream');
}

function isDeepMode() {
  const el = $('#deep-mode');
  return !!(el && el.checked);
}

function buildDeepHistory(currentMessage, fromTi) {
  const out = [];
  for (let ti = 0; ti < transcript.length; ti++) {
    const m = transcript[ti];
    if (m._confirmOnly) continue;
    let content = '';
    if (m.role === 'user') content = m.text || '';
    else if (m.role === 'assistant') content = m.answer || m.text || '';
    if (!content) continue;
    out.push({ role: m.role, content: content, _ti: ti });
  }
  // 审计·聊天优化块 B：深度分析带最近约 10 轮对话（用户+助手各算一条消息）。
  // 对抗审查修复（round-2）：剔除「与本次提问同文的那条用户消息」（body.message 已单独携带），
  // 而不是固定 slice(0,-1)——后者只在 sendMessage（先 appendUser 再调用）成立，在
  // 「🔍 深度分析」等入口会把上一条真实消息（当前普通答案）误删，且提问仍被喂两遍。
  // 复验 R3：同一问题文本出现多轮时，按「锚点条目的紧邻提问」精确剔除——fromTi 由
  // msg._ti（done/finalize 入库时记录的 transcript 索引）传入，从锚点前一条 user 开始、
  // 只查紧邻一条（不同文即停，绝不跨轮误删）；无 fromTi（sendMessage）时从尾部找。
  if (currentMessage) {
    const cur = String(currentMessage).trim();
    const fallback = () => {
      for (let i = out.length - 1; i >= 0; i--) {
        if (out[i].role === 'user' && (out[i].content || '').trim() === cur) { out.splice(i, 1); break; }
      }
    };
    if (fromTi != null) {
      let anchor = -1;
      for (let i = out.length - 1; i >= 0; i--) {
        if (out[i]._ti === fromTi) { anchor = i; break; }
      }
      if (anchor >= 0) {
        for (let j = anchor - 1; j >= 0; j--) {
          if (out[j].role === 'user') {
            const full = (out[j].content || '').trim();
            if (full === cur) {
              out.splice(j, 1);
            } else if (state.skill) {
              // 复验 R4：预设专项模式下 transcript 里的用户条目带「【预设专项 X】」前缀
              // （sendMessage 拼接 userText），而 question 是原始输入——按「专项前缀 + 原文」
              // 与「专项生成语」两种变体匹配，否则预设专项路径剔除永不命中、提问仍被喂两遍。
              const pref = '【预设专项 ' + state.skill + '】';
              if (full === (pref + currentMessage).trim()
                  || (full === (pref + '生成分析').trim() && cur === ('用深度分析跑一遍专项「' + state.skill + '」').trim())) {
                out.splice(j, 1);
              }
            }
            break;  // 只查锚点条目的紧邻提问；不匹配也不继续往前（不跨轮误删）
          }
        }
      } else {
        fallback();  // 锚点缺失（异常路径/历史消息）回落尾部查找
      }
    } else {
      fallback();
    }
  }
  return out.slice(-20).map((o) => ({ role: o.role, content: o.content }));
}

// ---- 发送与 SSE ----

async function sendMessage() {
  if (sending) return;
  const input = $('#input');
  const text = input.value.trim();

  if (!state.skill && !text) return;

  // 组装历史（当前提问之前的对话）供多轮上下文
  currentHistory = buildHistory();

  const deepMode = isDeepMode();
  const deepText = text || (state.skill ? ('用深度分析跑一遍专项「' + state.skill + '」') : '');

  const userText = deepMode
    ? deepText
    : (state.skill
        ? (text ? ('【预设专项 ' + state.skill + '】' + text) : ('【预设专项 ' + state.skill + '】生成分析'))
        : text);

  appendUser(userText);
  input.value = '';

  let req;
  let streamUrl;
  if (deepMode) {
    // 深度分析：独立 agentic 端点，历史仅带 role/content（不含 sql/answer 等冗余）；
    // 「不选游戏」模式带会话已绑定游戏延续（后端点名优先于 session_games）
    req = { message: deepText, history: buildDeepHistory(deepText) };
    if (currentGameMode() === 'none' && deepSessionGames.length) req.session_games = deepSessionGames;
    streamUrl = '/api/agent/chat/stream';
  } else {
    // 首轮（首次问某专项）→ 严格三模型报告；后续追问 → 带上一版报告自由发散
    const isFirstForSkill = state.skill && (lastReportSkill !== state.skill);
    const contextReport = (state.skill && !isFirstForSkill) ? lastReport : null;
    currentContextReport = contextReport || null;

    req = {
      ...(state.modelExplicit ? { model: state.model } : {}),
      message: text,
      mode: state.skill ? 'preset' : 'auto',
      preset_skill: state.skill,
      chart_type: 'auto',
      docs: [],
      context_report: contextReport || null,
      history: currentHistory,
      confirm: null,
    };
    // 「不选游戏」模式：带会话已绑定游戏延续（后端点名优先于 session_games）
    if (currentGameMode() === 'none' && sessionGames.length) req.session_games = sessionGames;
  }

  const msg = appendAssistant();
  msg._deep = deepMode;
  state.table = null;
  state.chartSpec = null;
  currentSql = null;
  currentAnswer = null;
  currentMeta = null;
  currentSubs = null;
  currentUsage = null;
  currentSuggestion = null;
  pendingConfirm = null;
  pendingGameConfirm = null;
  pendingForecastConfirm = null;
  pendingCandidates = null;
  pendingAiReportConfirm = null;
  pendingRewriteConfirm = null;
  pendingGenerateConfirm = null;
  // 评审 M4/A2：清掉旧的待选择卡——卡可能还挂在之前的气泡上（新消息发出 = 用户改变主意），
  // 不先摘卡+收口状态，旧气泡会一直停在「处理中…」且卡残留
  clearPendingGameSelect('已取消');
  lastQuestion = text;
  // 深度模式：放大视图/报告标题回显的是实际喂给 Agent 的提问（含专项名触发语）
  msg._question = deepMode ? deepText : text;

  await runStream(req, msg, streamUrl);
}

async function streamChat(reqBody, onEvent, url, signal) {
  url = url || '/api/chat';
  const resp = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(reqBody),
    signal: signal,
  });
  if (!resp.ok) {
    const detail = await resp.text().catch(() => '');
    throw new Error('HTTP ' + resp.status + ' ' + detail);
  }
  const reader = resp.body.getReader();
  const decoder = new TextDecoder();
  let buf = '';

  // 消费缓冲区里已完整的事件（分隔符支持 \n\n 与 \r\n\r\n），坏行跳过继续
  const drain = () => {
    while (buf.length) {
      const iLf = buf.indexOf('\n\n');
      const iCrlf = buf.indexOf('\r\n\r\n');
      let sep = -1, sepLen = 2;
      if (iLf >= 0 && (iCrlf < 0 || iLf <= iCrlf)) { sep = iLf; sepLen = 2; }
      else if (iCrlf >= 0) { sep = iCrlf; sepLen = 4; }
      if (sep < 0) break;
      const chunk = buf.slice(0, sep);
      buf = buf.slice(sep + sepLen);
      const line = chunk.split('\n').map((l) => l.replace(/\r$/, '')).find((l) => l.startsWith('data: '));
      if (line) {
        try { onEvent(JSON.parse(line.slice(6))); } catch (e) { /* 坏行跳过，继续 */ }
      }
    }
  };

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += decoder.decode(value, { stream: true });
    drain();
  }
  // 流结束：flush 解码器残余字节，并处理最后一个未以分隔符结尾的事件
  buf += decoder.decode();
  drain();
  if (buf.trim()) {
    const line = buf.split('\n').map((l) => l.replace(/\r$/, '')).find((l) => l.startsWith('data: '));
    if (line) {
      try { onEvent(JSON.parse(line.slice(6))); } catch (e) { /* 坏行跳过 */ }
    }
    buf = '';
  }
}

function isAbortError(e) {
  return !!(e && (e.name === 'AbortError' || e.name === 'DOMException'));
}

// 发送锁 + 停止按钮状态切换：busy=true 时禁用发送、显示「停止」
function setComposerBusy(busy) {
  const sendBtn = $('#send');
  const stopBtn = $('#stop');
  if (sendBtn) { sendBtn.disabled = busy; sendBtn.hidden = busy; }
  if (stopBtn) stopBtn.hidden = !busy;
}

// 前端兜底静默上限（审计·聊天优化块 C）：服务端整轮看门狗 ~900s 封顶总时长，前端按
// 「930s 无事件」才强制中断（每事件重置，见 runStream），恢复「跑到超时会自己停」的观感；
// 点「停止」仍可手动提前中断。
const AUTO_STOP_SECONDS = 930;

// 统一的流式请求封装：管理 AbortController、按钮状态、异常/取消的收尾
async function runStream(req, msg, url) {
  sending = true;
  activeAbort = new AbortController();
  setComposerBusy(true);
  let autoStopped = false;
  // 审计·聊天优化块 C：服务端整轮看门狗（~900s）+ 各阻塞调用 300s 读预算已能封顶总时长，
  // 前端兜底改为「930s 无事件静默」才中止——每收到一个事件重置计时。绝对时长一刀切会把
  // 持续产出但临近成功的运行误杀（对抗审查 HIGH）；真死流（服务端崩溃）仍在静默上限内被中止。
  let autoTimer = null;
  const armAutoTimer = () => {
    clearTimeout(autoTimer);
    autoTimer = setTimeout(() => {
      autoStopped = true;
      if (activeRunId) { fireCancel(); }  // 自动超时中止也通知后端取消深度运行
      if (activeAbort) activeAbort.abort();
    }, AUTO_STOP_SECONDS * 1000);
  };
  armAutoTimer();
  try {
    await streamChat(req, (ev) => { armAutoTimer(); handleEvent(msg, ev); }, url, activeAbort.signal);
    // 智能路由：普通流以 route_deep 事件收尾 → 无缝切换深度分析（同一消息继续渲染深度事件）
    if (msg._routeDeep) {
      clearTimeout(autoTimer);  // 本轮的静默计时已结束，深度分析用 runStream 自己新的看门狗
      await startAutoDeep(msg);
    }
  } catch (e) {
    if (isAbortError(e)) {
      // 深度分析被中止（点停止/看门狗）时流已断开，后端 final(status=canceled) 无法送达，
      // 这里直接渲染「⏹ 已停止」徽标，与后端取消收口的观感一致，避免把主动停止误标成出错
      if (msg._deep) showBadge(msg, '⏹ 已停止', true);
      setStatus(msg, autoStopped ? '运行超时，已自动停止（可缩小范围后重试）' : '已停止', true);
    } else {
      setStatus(msg, '请求失败：' + e.message, true);
    }
    // 对抗审查修复：深度模式异常/中止时也把已有内容收进历史（正常跑完走 final 分支的
    // finalizeDeepMessage，这里兜住 abort/请求失败路径，防半截成果与提问一起丢失；
    // finalizeDeepMessage 有幂等防护与内容守卫，与 final 分支不会重复入库、空产出不入库）
    if (msg._deep) finalizeDeepMessage(msg);
  } finally {
    clearTimeout(autoTimer);
    sending = false;
    activeAbort = null;
    setComposerBusy(false);
  }
}

// 深度分析取消联动：通知后端取消当前 Agent 运行（POST /api/agent/cancel）。
// 与 streamChat 相同的认证方式（auth.js 包装的 window.fetch 自动附 JWT/网关令牌，
// 这里只需显式给 Content-Type）；fire-and-forget，不阻塞前端收尾，失败静默忽略。
function fireCancel() {
  const rid = activeRunId;
  if (!rid) return;
  try {
    fetch('/api/agent/cancel', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ run_id: rid }),
      keepalive: true,
    }).catch(function () {});
  } catch (e) { /* 取消是尽力而为，忽略发送异常 */ }
}

// 用户点击「停止」：中断当前流式请求（前端立即停止渲染，后端在下一个事件点停止）
function stopGeneration() {
  if (!sending || !activeAbort) return;
  if (activeRunId) { fireCancel(); }  // 深度分析进行中：同时向后端发取消
  activeAbort.abort();
}

function buildHistory() {
  return transcript.slice(-12).map((m) => ({
    role: m.role,
    text: m.text || '',
    sql: m.sql || '',
    answer: m.answer || '',
    meta: m.meta || null,
  }));
}

// 把一条历史消息渲染进聊天区（仅展示，不带运行过程/订阅等交互）
function renderHistoryMessage(m, i) {
  const box = $('#messages');
  const welcome = box.querySelector('.welcome');
  if (welcome) welcome.remove();
  if (m.role === 'user') {
    const div = document.createElement('div');
    div.className = 'msg user';
    div.textContent = m.text || '';
    box.appendChild(div);
  } else {
    const div = document.createElement('div');
    div.className = 'msg assistant';
    div.innerHTML =
      '<div class="status"><span class="status-text">历史记录</span><span class="usage"></span></div>' +
      '<div class="body">' +
      '<div class="report-card" hidden>' +
        '<div class="report-head"><div class="report-head-main"><div class="report-title"></div><div class="report-sub"></div></div><button class="report-zoom btn btn-sm" hidden>🔍 放大</button></div>' +
        '<div class="viz" hidden></div>' +
      '</div>' +
      '<div class="answer" hidden></div>' +
      '<div class="sql-block" hidden></div>' +
      '<details class="process"><summary class="process-summary">运行过程</summary><ol class="process-list"></ol></details>' +
      '</div>';
    // 放大：与实时报告一致，绑定到放大视图；标题回显上一条用户提问
    const zoom = div.querySelector('.report-zoom');
    if (zoom) zoom.addEventListener('click', () => openReportOverlay(div));
    if (m.usage && (m.usage.total_tokens || m.usage.cost)) {
      const u = div.querySelector('.usage');
      if (u) u.textContent = ' 🔢 ' + m.usage.total_tokens + ' tokens · 约 ¥' + (m.usage.cost || 0).toFixed(4);
    }
    div._question = (i > 0 && transcript[i - 1] && transcript[i - 1].role === 'user') ? (transcript[i - 1].text || '') : '';
    div._meta = m.meta || null;  // 恢复专项来源/报告展示配置，放大视图折叠与副标题据此还原
    const title = div.querySelector('.report-title');
    if (title) title.textContent = div._question.trim().slice(0, 60) || '分析报告';
    if (m.sql) {
      const block = div.querySelector('.sql-block');
      block.hidden = false;
      block.appendChild(buildSqlCollapse(m.sql));
    }
    if (m.answer) {
      const ans = div.querySelector('.answer');
      ans.hidden = false;
      renderMarkdownInto(ans, m.answer);
      structureSections(ans, m.meta && m.meta.fold);
    }
    // 恢复图表/表格（专项报告的可切换卡片）
    box.appendChild(div);
    div._charts = m.charts || [];
    div._tables = m.tables || [];
    if (div._charts.length || div._tables.length) {
      div.querySelector('.report-card').hidden = false;
      renderViz(div);
    }
    // 恢复「运行过程」折叠面板（旧记录无 process 字段则跳过）
    if (m.process && m.process.length) {
      const proc = div.querySelector('.process');
      const list = proc.querySelector('.process-list');
      m.process.forEach(function (s) {
        const li = document.createElement('li');
        if (s.time) {
          const t = document.createElement('span');
          t.className = 'step-time';
          t.textContent = s.time;
          li.appendChild(t);
          li.appendChild(document.createTextNode(' ' + (s.text || '')));
        } else {
          li.textContent = s.text || '';
        }
        list.appendChild(li);
      });
    }
  }
  box.scrollTop = box.scrollHeight;
}

// 从 URL ?session=<id> 恢复一段历史会话，继续聊天并保留上下文
async function restoreSessionFromUrl() {
  const sid = new URLSearchParams(location.search).get('session');
  if (sid) await loadSession(sid);
}

// 加载指定会话到聊天区，可直接继续对话（供「最近聊天」侧边栏与 URL 参数共用）
async function loadSession(sid) {
  if (!sid) return false;
  let data;
  try {
    const res = await fetch('/api/chat-history/' + encodeURIComponent(sid));
    if (!res.ok) return false;
    data = await res.json();
  } catch (e) { return false; }

  cacheSid = sid;
  transcript = data.messages || [];
  $('#messages').innerHTML = '';
  transcript.forEach((m, i) => renderHistoryMessage(m, i));

  // 更新地址栏（刷新仍停留在此会话），并同步侧边栏高亮
  const url = new URL(location.href);
  url.searchParams.set('session', sid);
  history.replaceState(null, '', url);
  markActiveSession(sid);

  // 恢复本会话已累计的 token/费用（记忆），继续聊天时接着累计、不再从 0 起算
  if (data.usage && (data.usage.total_tokens || data.usage.cost)) {
    sessionUsage = {
      tokens: data.usage.total_tokens || 0,
      cost: data.usage.cost || 0,
      prompt: data.usage.prompt_tokens || 0,
      completion: data.usage.completion_tokens || 0,
    };
  }
  renderSessionUsage();

  const bar = $('#session-bar');
  if (bar) {
    bar.hidden = false;
    bar.innerHTML = '';
    const span = document.createElement('span');
    span.textContent = '↩️ 继续会话：' + (data.title || '');
    bar.appendChild(span);
    const back = document.createElement('button');
    back.className = 'btn btn-sm';
    back.textContent = '🆕 新对话';
    back.addEventListener('click', newConversation);
    bar.appendChild(back);
  }
  return true;
}

// ---- 侧边栏「最近聊天」列表 ----
async function loadSidebarHistory(reset) {
  const ul = $('#sidebar-history');
  if (!ul) return;
  if (state.historyLoading) return; // 在途请求未完成：不叠加发起（offset 只在通过此闸门后动）
  if (reset !== false) state.historyOffset = 0; // 默认整页刷新；「加载更多」传 false 才翻页累计
  else state.historyOffset += 30; // 翻页：先占位新 offset（失败在 catch 回滚供重试）
  const offset = state.historyOffset;
  state.historyLoading = true;
  try {
    const res = await fetch('/api/chat-history?limit=30&offset=' + offset);
    if (!res.ok) throw new Error('HTTP ' + res.status);
    const data = await res.json();
    state.sessionList = offset === 0 ? (data.sessions || []) : (state.sessionList || []).concat(data.sessions || []);
    state.historyTruncated = !!data.truncated;
  } catch (e) {
    if (offset === 0) {
      state.sessionList = [];
      state.historyTruncated = false;
    } else {
      state.historyOffset -= 30; // 分页失败回滚：下次点击重试同一页，而不是永久跳过
    }
  } finally {
    state.historyLoading = false;
  }
  renderSidebarHistory();
}

function renderSidebarHistory() {
  const ul = $('#sidebar-history');
  if (!ul) return;
  ul.innerHTML = '';
  const list = state.sessionList || [];
  if (!list.length) {
    const li = document.createElement('li');
    li.className = 'list-item';
    li.textContent = '暂无聊天记录';
    li.style.cursor = 'default';
    ul.appendChild(li);
    return;
  }
  list.forEach((s) => {
    const li = document.createElement('li');
    li.className = 'list-item' + (s.id === cacheSid ? ' active' : '');
    li.dataset.sid = s.id;
    li.title = '保存于 ' + s.saved_at + ' · ' + s.message_count + ' 条消息';
    const t = document.createElement('span');
    t.className = 'hist-title';
    t.textContent = s.title;
    li.appendChild(t);
    // 重命名按钮：stopPropagation 防止冒泡触发整行「打开会话」
    const edit = document.createElement('button');
    edit.className = 'btn btn-sm';
    edit.textContent = '✏️';
    edit.title = '重命名会话';
    edit.addEventListener('click', (e) => {
      e.stopPropagation();
      renameSession(s.id, s.title, t);
    });
    li.appendChild(edit);
    // 删除按钮：stopPropagation 防止冒泡打开会话；后端按 owner 做鉴权
    const del = document.createElement('button');
    del.className = 'btn btn-sm btn-danger';
    del.textContent = '🗑';
    del.title = '删除会话（可从回收站恢复）';
    del.setAttribute('aria-label', '删除会话「' + s.title + '」');
    del.addEventListener('click', (e) => {
      e.stopPropagation();
      deleteRecentSession(s.id, s.title);
    });
    li.appendChild(del);
    li.addEventListener('click', () => loadSession(s.id));
    ul.appendChild(li);
  });
  if (state.historyTruncated) {
    const more = document.createElement('li');
    more.className = 'list-item';
    more.textContent = '加载更多';
    more.addEventListener('click', () => loadSidebarHistory(false));
    ul.appendChild(more);
  }
}

// 删除最近聊天：确认后调用现有软删 endpoint；当前会话清空且不触发自动新建/重存
async function deleteRecentSession(sid, title) {
  if (!confirm('删除「' + (title || '未命名对话') + '」？删除后可从回收站恢复（保留 30 天）。')) return;
  try {
    const res = await fetch('/api/chat-history/' + encodeURIComponent(sid), { method: 'DELETE' });
    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      alert(body.detail || '删除失败');
      return;
    }
    state.sessionList = (state.sessionList || []).filter((s) => s.id !== sid);
    if (cacheSid === sid) {
      // 先清空 transcript，再复用「新对话」清理 UI；这样 autoSave 不会把已删会话重建
      transcript = [];
      newConversation();
    } else {
      renderSidebarHistory();
    }
  } catch (e) {
    alert('删除失败，请检查服务是否正常');
  }
}

// 重命名会话：取消或空标题不动；成功后就地更新标题，不整表重载（保留已翻页加载的范围）
async function renameSession(sid, currentTitle, titleEl) {
  const title = prompt('重命名会话', currentTitle);
  if (title == null || title.trim() === '') return;
  try {
    const res = await fetch('/api/chat-history/' + encodeURIComponent(sid) + '/rename', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ title: title.trim() }),
    });
    if (res.ok) {
      // 以后端清洗后的 title 为准（截断/过滤后可能与输入不同），避免刷新后标题「凭空变了」
      const data = await res.json().catch(() => null);
      const finalTitle = (data && typeof data.title === 'string' && data.title) ? data.title : title.trim();
      const item = (state.sessionList || []).find((x) => x.id === sid);
      if (item) item.title = finalTitle; // 同步状态：后续打开会话/再次渲染用新标题
      if (titleEl) titleEl.textContent = finalTitle;
      else loadSidebarHistory(); // 兜底：找不到对应节点才整页刷新
    }
  } catch (e) { /* 重命名失败静默忽略 */ }
}

function markActiveSession(sid) {
  const ul = $('#sidebar-history');
  if (!ul) return;
  ul.querySelectorAll('.list-item').forEach((li) => {
    li.classList.toggle('active', li.dataset.sid === sid);
  });
}

function renderConfirmCard(msg, skill, summary) {
  showBadge(msg, '🎯 命中专项：' + skill, false);
  addProcessStep(msg, '🎯 检索到专项「' + skill + '」' + (summary ? '：' + summary : ''));

  const body = msg.querySelector('.body');
  const card = document.createElement('div');
  card.className = 'confirm-card';

  const q = document.createElement('div');
  q.className = 'confirm-q';
  q.textContent = '我判断这属于「' + skill + '」专项，是否按该专项的分析方法执行？';
  card.appendChild(q);

  const note = document.createElement('div');
  note.className = 'confirm-note';
  card.appendChild(note);

  const row = document.createElement('div');
  row.className = 'confirm-actions';

  const yes = document.createElement('button');
  yes.className = 'btn btn-sm btn-primary';
  yes.textContent = '✨ 自动生成';
  yes.title = '默认：首次完整三模型，之后复用上次报告结构';
  yes.addEventListener('click', () => executeConfirmed(skill, false));
  row.appendChild(yes);

  const full = document.createElement('button');
  full.className = 'btn btn-sm';
  full.textContent = '🔄 完整生成';
  full.title = '忽略上次报告结构，重新走完整三模型生成';
  full.addEventListener('click', () => executeConfirmed(skill, true));
  row.appendChild(full);

  const free = document.createElement('button');
  free.className = 'btn btn-sm';
  free.textContent = '⚡ 只生成SQL';
  free.title = '快速只查数据，不跑报告';
  free.addEventListener('click', () => executeConfirmed('', false));
  row.appendChild(free);

  const sel = document.createElement('select');
  sel.className = 'control confirm-select';
  const ph = document.createElement('option');
  ph.value = ''; ph.textContent = '🔀 换专项…';
  sel.appendChild(ph);
  skillNames.forEach((s) => {
    const o = document.createElement('option');
    o.value = s; o.textContent = s;
    sel.appendChild(o);
  });
  sel.addEventListener('change', () => { if (sel.value) executeConfirmed(sel.value, false); });
  row.appendChild(sel);

  card.appendChild(row);
  body.appendChild(card);

  // 倒计时：N 秒内未选择，自动按命中专项执行（倒计时可见，超时后自动确认并说明）
  stopConfirmTimer(); // 清理可能残留的旧计时器
  let remaining = CONFIRM_AUTO_SECONDS;
  const updateNote = () => {
    note.textContent = '✨自动：首次完整三模型，之后复用上次报告结构'
      + (remaining > 0
        ? (' ⏳ ' + remaining + 's 后默认「自动生成」')
        : (' ⏳ 已超时，按「自动生成」执行…'));
  };
  updateNote();
  confirmTimer = setInterval(() => {
    remaining -= 1;
    updateNote();
    if (remaining <= 0) {
      stopConfirmTimer();
      if (pendingConfirm && pendingConfirm.msg === msg) {
        addProcessStep(msg, '⏳ ' + CONFIRM_AUTO_SECONDS + 's 未选择，已自动按「' + skill + '」专项执行（自动生成）');
        executeConfirmed(skill, false);
      }
    }
  }, 1000);
}

function stopConfirmTimer() {
  if (confirmTimer) { clearInterval(confirmTimer); confirmTimer = null; }
}

function armConfirmCountdown(msg, action, guard, label) {
  // 通用 60s 自动确认：未操作则按「第一个选项」执行（guard 校验该卡仍处于待确认状态，防重复/误触发）
  stopConfirmTimer();
  const card = msg.querySelector('.confirm-card');
  if (!card) return;
  let note = card.querySelector('.confirm-note');
  if (!note) {
    note = document.createElement('div');
    note.className = 'confirm-note';
    card.appendChild(note);
  }
  const what = label || '第一个选项';
  let remaining = CONFIRM_AUTO_SECONDS;
  const render = () => { note.textContent = '⏳ ' + remaining + 's 未操作将自动「' + what + '」'; };
  render();
  confirmTimer = setInterval(() => {
    remaining -= 1;
    if (remaining <= 0) {
      stopConfirmTimer();
      if (guard()) {
        note.textContent = '⏳ 已超时，已自动「' + what + '」';
        action();
      }
    } else {
      render();
    }
  }, 1000);
}

async function executeConfirmed(skillOrNone, fullReport) {
  const pc = pendingConfirm;
  if (!pc) return;
  pendingConfirm = null;
  stopConfirmTimer();

  const msg = pc.msg;
  const text = pc.text;
  const card = msg.querySelector('.confirm-card');
  if (card) card.remove();
  setStatus(msg, '处理中…');
  msg._t0 = performance.now(); // 二次确认后重新计时（本轮实际执行耗时）

  state.table = null;
  state.chartSpec = null;
  currentSql = null;
  currentAnswer = null;
  currentMeta = null;
  currentSubs = null;
  currentUsage = null;
  currentSuggestion = null;

  const req = {
    ...(state.modelExplicit ? { model: state.model } : {}),
    message: pc.question || pc.text,
    mode: 'auto',
    preset_skill: null,
    chart_type: 'auto',
    docs: [],
    context_report: null,
    history: currentHistory,
    confirm: skillOrNone,  // "" = 只查SQL；否则为确认/换选的专项名
    full_report: !!fullReport,  // true=强制完整三模型（忽略上次报告结构记忆）
    target_game: pc.game || null,
  };
  maybeThreadSessionGames(req);

  // 执行阶段同样锁定输入，避免并发发送重置本轮上下文
  await runStream(req, msg);
}

// ---- 游戏模式：① 单游戏项目（默认）/ ② 无项目限制（需多步确认）+ 提问多选卡 ----

function currentGameMode() {
  // 默认 ① 单游戏项目（右上角切换）：未选择/旧空值一律按 follow 处理
  try { return localStorage.getItem('chatbi.game.mode') || 'follow'; } catch (e) { return 'follow'; }
}

function sessionUserStamp() {
  // auth.js 的 window.auth.getUser()：登录用户 {id,...}；匿名回落 'anonymous'
  try {
    const u = (window.auth && window.auth.getUser && window.auth.getUser()) || null;
    return (u && u.id) ? String(u.id) : 'anonymous';
  } catch (e) { return 'anonymous'; }
}

const SESSION_GAMES_KEYS = { chat: 'chatbi.sessionGames', deep: 'chatbi.sessionGamesDeep' };

function loadStoredSessionGames() {
  // 会话级游戏绑定（sessionStorage 持久化，壳同标签切游戏会 reloadKey 重挂 iframe 清空内存态，
  // sessionStorage 跨重载存活保证绑定延续；键带用户戳，跨账号打开不留串）
  try {
    const stamp = sessionUserStamp();
    const read = (k) => {
      const raw = sessionStorage.getItem(k);
      if (!raw) return [];
      try {
        const obj = JSON.parse(raw);
        return (obj && obj.stamp === stamp && Array.isArray(obj.games)) ? obj.games : [];
      } catch (e) { return []; }
    };
    sessionGames = read(SESSION_GAMES_KEYS.chat);
    deepSessionGames = read(SESSION_GAMES_KEYS.deep);
  } catch (e) { sessionGames = []; deepSessionGames = []; }
}

function storeSessionGames() {
  try {
    const stamp = sessionUserStamp();
    sessionStorage.setItem(SESSION_GAMES_KEYS.chat, JSON.stringify({ stamp: stamp, games: sessionGames }));
    sessionStorage.setItem(SESSION_GAMES_KEYS.deep, JSON.stringify({ stamp: stamp, games: deepSessionGames }));
  } catch (e) {}
}

function maybeThreadSessionGames(req) {
  // 确认链重发（confirm/candidates/forecast/ai_report/rewrite/generate 各 execute*）：
  // 「不选游戏」模式且本会话已绑定游戏时附 target_games，防确认后重发再弹多选卡。
  // 对抗审查三轮 [5]：sessionGames 由 bound_games 事件与 executeGameSelect 双路径实时同步，
  // 与确认卡的 target_game 恒一致——家族主键 target_game（如 kof）重发时也一并回传，
  // 后端 target_games 优先级最高，直接按原多选集合执行，不再重新展开家族弹多选卡、
  // 也不再静默丢弃用户此前多选的非主游戏
  if (currentGameMode() === 'none' && sessionGames.length) {
    req.target_games = sessionGames.slice();
  }
}

function renderGameModePanel() {
  const panel = $('#game-mode-panel');
  if (!panel) return;
  const mode = currentGameMode();
  panel.querySelectorAll('input[name="game-mode"]').forEach((r) => { r.checked = r.value === mode; });
  updateGameModeHint();
}

function updateGameModeHint() {
  const hint = $('#game-mode-hint');
  if (!hint) return;
  const mode = currentGameMode();
  if (mode === 'none') {
    hint.textContent = '提问时可在所有有权限的游戏中多选，逐游戏查询后拼接结果。';
  } else if (mode === 'follow') {
    hint.textContent = '默认模式：始终跟随右上角选择的单游戏项目。';
  } else {
    hint.textContent = '尚未选择模式：默认按右上角游戏查询，提问点名其它游戏时会先确认。';
  }
}

function initGamePanel() {
  loadStoredSessionGames();
  renderGameModePanel();
  // 「无项目限制」多步确认：勾选了解 + 再点确认才生效；取消回退上一模式
  const confirmBox = $('#game-mode-confirm');
  const confirmCheck = $('#game-mode-confirm-check');
  const confirmOk = $('#game-mode-confirm-ok');
  const confirmCancel = $('#game-mode-confirm-cancel');
  const resetConfirm = () => {
    if (confirmBox) confirmBox.hidden = true;
    if (confirmCheck) confirmCheck.checked = false;
    if (confirmOk) confirmOk.disabled = true;
  };
  if (confirmCheck && confirmOk) {
    confirmCheck.addEventListener('change', () => { confirmOk.disabled = !confirmCheck.checked; });
  }
  if (confirmOk) {
    confirmOk.addEventListener('click', () => {
      try { localStorage.setItem('chatbi.game.mode', 'none'); } catch (e) {}
      resetConfirm();
      updateGameModeHint();
    });
  }
  if (confirmCancel) {
    confirmCancel.addEventListener('click', () => {
      resetConfirm();
      renderGameModePanel(); // 勾选回退到仍存储的上一模式
    });
  }
  const radios = document.querySelectorAll('#game-mode-panel input[name="game-mode"]');
  radios.forEach((r) => {
    r.addEventListener('change', () => {
      if (!r.checked) return;
      if (r.value === 'none') {
        // ② 需多步确认，确认前不落存储、不动提示文案
        if (confirmBox) confirmBox.hidden = false;
        if (confirmOk) confirmOk.disabled = !(confirmCheck && confirmCheck.checked);
      } else {
        try { localStorage.setItem('chatbi.game.mode', r.value); } catch (e) {}
        updateGameModeHint();
      }
    });
  });
  // 跟随模式：右上角切游戏（nav.js 写 chatbi.game 后整页 reload，或跨页 storage 事件）时
  // 面板无需本地改任何值——① 读的就是右上角当前值；此处重渲染只同步勾选态。
  window.addEventListener('storage', (e) => {
    if (e.key === 'chatbi.game' || e.key === 'chatbi.game.mode') renderGameModePanel();
  });
  // 零权限：横幅 + 禁发送 + 不渲染起始建议（后端对所有取数端点 403 硬拦，前端先显式告知）。
  // 返回 fetch promise 供 init 等待：loadSuggestions 依赖 zeroPerm 判定，避免竞态
  return window.fetch('/api/games')
    .then((r) => r.json())
    .then((data) => {
      const games = data.games || [];
      if (!games.length) {
        zeroPerm = true;
        const banner = $('#no-perm-banner');
        if (banner) banner.hidden = false;
        const sendBtn = $('#send');
        const input = $('#input');
        if (sendBtn) sendBtn.disabled = true;
        if (input) {
          input.disabled = true;
          input.placeholder = '您没有任何游戏的数据权限，无法查询数据，请联系管理员开通';
        }
      }
    })
    .catch(() => {});
}

function renderGameSelectCard(msg, ev) {
  const body = msg.querySelector('.body');
  const card = document.createElement('div');
  card.className = 'confirm-card game-select-card';
  // 对抗审查二轮：卡归属登记——勾选监听/倒计时 guard 都要校验事件来自「当前待选择卡」，
  // 防旧卡（已被清理但仍挂在 DOM 或事件队列里）污染新一轮 pendingGameSelect
  if (pendingGameSelect) pendingGameSelect.card = card;

  const q = document.createElement('div');
  q.className = 'confirm-q';
  q.textContent = ev.question || '请选择要查询的游戏（可多选）';
  card.appendChild(q);

  if (ev.reason) {
    const why = document.createElement('p');
    why.className = 'hint';
    why.textContent = ev.reason;  // textContent 赋值防注入
    card.appendChild(why);
  }

  const list = document.createElement('div');
  list.className = 'game-select-list';
  const games = ev.games || [];
  games.forEach((g) => {
    const key = g && g.key ? String(g.key) : '';
    if (!key) return;
    const lab = document.createElement('label');
    lab.className = 'game-select-item';
    const cb = document.createElement('input');
    cb.type = 'checkbox';
    cb.value = key;
    cb.checked = (ev.preselected || []).indexOf(key) >= 0;
    // 评审 L3：用户手动改过勾选 → 打 touched 标记，倒计时不再用预选兜底（防「取消预选后仍按预选执行」）；
    // 对抗审查二轮：只有仍是当前待选择卡时才打标（旧卡事件不得污染新一轮状态）
    cb.addEventListener('change', () => {
      if (pendingGameSelect && pendingGameSelect.card === card) pendingGameSelect.touched = true;
    });
    const span = document.createElement('span');
    span.textContent = g.label || g.name || key;  // 后端已带 label（region_label 现算）
    lab.appendChild(cb);
    lab.appendChild(span);
    list.appendChild(lab);
  });
  card.appendChild(list);

  const row = document.createElement('div');
  row.className = 'confirm-actions';
  const ok = document.createElement('button');
  ok.className = 'btn btn-sm btn-primary';
  ok.textContent = '✅ 按所选游戏查询';
  ok.addEventListener('click', () => executeGameSelect());
  const cancel = document.createElement('button');
  cancel.className = 'btn btn-sm';
  cancel.textContent = '✋ 取消';
  cancel.addEventListener('click', () => cancelGameSelect());
  row.appendChild(ok);
  row.appendChild(cancel);
  card.appendChild(row);
  body.appendChild(card);

  // 有预选时 60s 自动按预选执行（guard 校验卡仍待选择，防双击/其它卡计时串扰）；无预选不自动
  if ((ev.preselected || []).length) {
    armConfirmCountdown(
      msg,
      () => executeGameSelect(true),
      () => pendingGameSelect && pendingGameSelect.msg === msg,
      '预选游戏'
    );
  }
}

// 清掉待选择卡并收口原气泡状态（评审 M4/A2 统一收口点）：
// 新消息发出 / 新卡到达 / 显式取消都走这里，保证卡摘除、状态收口、计时器停止、特判标记清理
// 四件事原子完成，不留「卡还在但状态已不匹配」的中间态
function clearPendingGameSelect(statusText) {
  const pg = pendingGameSelect;
  pendingGameSelect = null;
  stopConfirmTimer();
  if (!pg || !pg.msg) return;
  const stale = pg.msg.querySelector('.game-select-card');
  if (stale) stale.remove();
  setStatus(pg.msg, statusText || '已取消');
  if (pg.msg._deep) pg.msg._gameSelect = null;  // 取消后不残留「待选择游戏…」特判
}

function cancelGameSelect() {
  clearPendingGameSelect('已取消');
}

async function executeGameSelect(usePreselected) {
  const pg = pendingGameSelect;
  if (!pg) return;
  // 对抗审查三轮 [7]：60s 倒计时可能在深度分析进行中触发——sending=true 时直接放弃执行
  // （深度入口启动时已摘卡清计时，这里是双保险：防并发第二条 SSE 流覆盖 activeAbort/activeRunId）
  if (sending) return;
  const msg = pg.msg;
  const card = msg.querySelector('.game-select-card');
  // 评审 A2：卡必须仍属于当前待选择状态且仍在消息体里——sendMessage 已把 pendingGameSelect
  // 置空并摘卡，这里双保险防「发出新消息后倒计时仍触发旧卡执行」
  if (!card || pendingGameSelect !== pg) return;
  // 先读勾选再移除卡（card.remove 后 checkbox 读不到值）
  let checked = [];
  if (card) {
    card.querySelectorAll('input[type="checkbox"]:checked').forEach((cb) => { checked.push(cb.value); });
  }
  // 评审 L3：只有用户没碰过勾选（touched 未打标）时，倒计时才可用预选兜底；
  // 用户取消过预选（0 勾选 + touched）→ 提示，不再悄悄按预选执行
  if (!checked.length && usePreselected && pg.preselected && pg.preselected.length && !pg.touched) {
    checked = pg.preselected.slice();
  }
  if (!checked.length) {
    // 对抗审查二轮：用户显式点「按所选游戏查询」却 0 勾选时先停倒计时并清提示文案——
    // 否则 60s 倒计时随后仍按预选悄悄执行，与用户「先不选」的意图相悖（卡仍在，可继续勾选）
    stopConfirmTimer();
    const noteEl = card.querySelector('.confirm-note');
    if (noteEl) noteEl.textContent = '';
    alert('请先勾选至少一个游戏');
    return;
  }
  pendingGameSelect = null;
  stopConfirmTimer();
  if (card) card.remove();
  setStatus(msg, '处理中…');

  if (msg._deep) {
    // 深度模式：延续同一条消息，回传 games（不含游戏名，防 resolve_cross_game 误命中点名）
    const idxText = checked.map((k, i) => (i + 1)).join('、');
    const text = '我选择第 ' + idxText + ' 项游戏';
    appendUser(text);
    // 评审 L4：原提问气泡收口为终态提示（「处理中…」若停在原气泡上，新流结束后它仍转圈）
    setStatus(msg, '已按所选 ' + checked.length + ' 个游戏发起分析，见下方');
    if (msg._gameSelect) msg._gameSelect = null;
    const dmsg = appendAssistant();
    dmsg._deep = true;
    dmsg._question = text;
    deepSessionGames = checked.slice();
    storeSessionGames();
    state.table = null;
    state.chartSpec = null;
    currentSql = null;
    currentAnswer = null;
    currentMeta = null;
    currentSubs = null;
    currentUsage = null;
    currentSuggestion = null;
    lastQuestion = text;
    // 选择气泡刚 append、尚未入库（_ti 未挂）：buildDeepHistory 回落尾部同文剔除，恰好删掉本轮选择；
    // 上一轮 game_select 提问的 assistant 条目保留在历史里，模型能对照「第 N 项」理解所选
    const req = {
      message: text,
      history: buildDeepHistory(text, dmsg._ti),
      games: checked,
      session_games: deepSessionGames,
    };
    await runStream(req, dmsg, '/api/agent/chat/stream');
    return;
  }

  // 普通模式：以原问题 + 所选游戏重发（后端按 target_games 绑定执行），会话记忆所选供后续追问延续
  sessionGames = checked.slice();
  storeSessionGames();
  state.table = null;
  state.chartSpec = null;
  currentSql = null;
  currentAnswer = null;
  currentMeta = null;
  currentSubs = null;
  currentUsage = null;
  currentSuggestion = null;
  msg._t0 = performance.now();  // 选择后重新计时（本轮实际执行耗时）
  const req = {
    ...(state.modelExplicit ? { model: state.model } : {}),
    message: pg.question || pg.text,
    mode: state.skill ? 'preset' : 'auto',
    preset_skill: state.skill,
    chart_type: 'auto',
    docs: [],
    context_report: currentContextReport || null,
    history: currentHistory,
    confirm: null,
    target_games: checked,
    session_games: sessionGames,
  };
  await runStream(req, msg);
}

function renderCandidatesCard(msg, ev) {
  const body = msg.querySelector('.body');
  const card = document.createElement('div');
  card.className = 'confirm-card candidates-card';

  const q = document.createElement('div');
  q.className = 'confirm-q';
  q.textContent = '我理解你的需求，可能有以下几种对应，请选择最符合的：';
  card.appendChild(q);

  const list = document.createElement('div');
  list.className = 'candidates-list';
  (ev.candidates || []).forEach((c) => {
    const chip = document.createElement('button');
    chip.className = 'btn btn-sm candidate-chip';
    const label = c.label || c.type || '';
    const summary = c.summary ? (' — ' + c.summary) : '';
    chip.textContent = (label ? '[' + label + '] ' : '') + (c.name || '') + summary;
    chip.addEventListener('click', () => executeCandidate({ type: c.type, name: c.name }));
    list.appendChild(chip);
  });
  card.appendChild(list);

  const row = document.createElement('div');
  row.className = 'confirm-actions';

  const ai = document.createElement('button');
  ai.className = 'btn btn-sm btn-primary';
  ai.textContent = '✨ 都猜错，AI 现写 SQL';
  ai.title = '忽略以上候选，直接让 AI 现写一条 SQL 取数';
  ai.addEventListener('click', () => executeCandidate(''));
  row.appendChild(ai);

  const deep = document.createElement('button');
  deep.className = 'btn btn-sm deep-handoff';
  deep.textContent = '🧠 交给深度分析';
  deep.title = '候选不匹配时，把当前问题连同对话历史交给深度分析 Agent 多步检索取数（结果直接渲染在本条消息）';
  deep.addEventListener('click', () => executeCandidateDeep());
  row.appendChild(deep);

  card.appendChild(row);
  body.appendChild(card);

  const _first = (ev.candidates || [])[0];
  armConfirmCountdown(
    msg,
    () => executeCandidate(_first ? { type: _first.type, name: _first.name } : ''),
    () => pendingCandidates && pendingCandidates.msg === msg,
    _first ? (_first.name || '第一个候选') : 'AI 现写 SQL'
  );
}

async function executeCandidate(choice) {
  const pc = pendingCandidates;
  if (!pc) return;
  pendingCandidates = null;

  const msg = pc.msg;
  const card = msg.querySelector('.candidates-card');
  if (card) card.remove();
  setStatus(msg, '处理中…');
  msg._t0 = performance.now(); // 选候选后重新计时

  state.table = null;
  state.chartSpec = null;
  currentSql = null;
  currentAnswer = null;
  currentMeta = null;
  currentSubs = null;
  currentUsage = null;
  currentSuggestion = null;

  const req = {
    ...(state.modelExplicit ? { model: state.model } : {}),
    message: pc.question || pc.text,
    mode: 'auto',
    preset_skill: null,
    chart_type: 'auto',
    docs: [],
    context_report: null,
    history: currentHistory,
    candidate: choice === '' ? '' : JSON.stringify(choice),  // {"type","name"}；""=都猜错
    target_game: pc.game || null,
  };
  maybeThreadSessionGames(req);

  await runStream(req, msg);
}

// 候选卡「🧠 交给深度分析」：检索不满意时一键把当前问题（带历史）交给深度分析 Agent，
// 复用同一条消息渲染（无需手动开深度开关重问）
async function executeCandidateDeep() {
  const pc = pendingCandidates;
  if (!pc) return;
  pendingCandidates = null;
  stopConfirmTimer();
  // 对抗审查三轮 [7]：深度入口统一收口——摘掉仍在倒计时的旧游戏多选卡
  clearPendingGameSelect('已取消');
  const msg = pc.msg;
  const card = msg.querySelector('.candidates-card');
  if (card) card.remove();
  setStatus(msg, '切换深度分析…');
  msg._t0 = performance.now();  // 深度分析阶段重新计时
  msg._deep = true;
  const question = pc.question || pc.text;
  msg._question = question;
  state.table = null;
  state.chartSpec = null;
  currentSql = null;
  currentAnswer = null;
  currentMeta = null;
  currentSubs = null;
  currentUsage = null;
  currentSuggestion = null;
  lastQuestion = question;
  // 候选卡流未发 done 就返回，msg 尚未入库（_ti 未挂）：buildDeepHistory 回落尾部同文剔除本轮提问
  const req = { message: question, history: buildDeepHistory(question, msg._ti) };
  if (currentGameMode() === 'none' && deepSessionGames.length) req.session_games = deepSessionGames;
  await runStream(req, msg, '/api/agent/chat/stream');
}

function renderAiReportConfirmCard(msg, ev) {
  showBadge(msg, '🤖 AI 自动生成报告？', false);
  addProcessStep(msg, '未命中既有工件，待确认是否由 AI 自动生成报告');

  const body = msg.querySelector('.body');
  const card = document.createElement('div');
  card.className = 'confirm-card ai-report-confirm-card';

  const q = document.createElement('div');
  q.className = 'confirm-q';
  q.textContent = '未命中既有专项 / SQL / 模型 / 知识库。AI 将自动：① 读表结构+知识库 → ② 写 SQL 取数 → ③ 三模型交叉验证出报告（约几分钟）。⚠️ AI 生成结果不稳定、准确率无法保证，请人工复核。';
  card.appendChild(q);

  const row = document.createElement('div');
  row.className = 'confirm-actions';

  const yes = document.createElement('button');
  yes.className = 'btn btn-sm btn-primary';
  yes.textContent = '✅ 生成报告';
  yes.addEventListener('click', () => executeAiReportConfirm('ok'));
  row.appendChild(yes);

  const sqlOnly = document.createElement('button');
  sqlOnly.className = 'btn btn-sm';
  sqlOnly.textContent = '⚡ 只查SQL';
  sqlOnly.addEventListener('click', () => executeAiReportConfirm(''));
  row.appendChild(sqlOnly);

  const cancel = document.createElement('button');
  cancel.className = 'btn btn-sm';
  cancel.textContent = '✋ 取消';
  cancel.addEventListener('click', () => cancelAiReportConfirm());
  row.appendChild(cancel);

  card.appendChild(row);
  body.appendChild(card);
  setStatus(msg, '待确认是否生成报告');
  armConfirmCountdown(
    msg,
    () => executeAiReportConfirm('ok'),
    () => pendingAiReportConfirm && pendingAiReportConfirm.msg === msg,
    '生成报告'
  );
}

async function executeAiReportConfirm(choice) {
  const pc = pendingAiReportConfirm;
  if (!pc) return;
  pendingAiReportConfirm = null;

  const msg = pc.msg;
  const card = msg.querySelector('.ai-report-confirm-card');
  if (card) card.remove();
  setStatus(msg, '处理中…');
  msg._t0 = performance.now(); // 二次确认后重新计时

  state.table = null;
  state.chartSpec = null;
  currentSql = null;
  currentAnswer = null;
  currentMeta = null;
  currentSubs = null;
  currentUsage = null;
  currentSuggestion = null;
  pendingConfirm = null;
  pendingGameConfirm = null;
  pendingForecastConfirm = null;
  pendingCandidates = null;

  const req = {
    ...(state.modelExplicit ? { model: state.model } : {}),
    message: pc.question || pc.text,
    mode: 'auto',
    preset_skill: null,
    chart_type: 'auto',
    docs: [],
    context_report: null,
    history: currentHistory,
    confirm: null,
    game_confirm: null,
    target_game: pc.game || null,
    forecast_confirm: null,
    candidate: null,
    ai_report_confirm: choice,  // "ok"=生成报告；""=只查SQL
  };
  maybeThreadSessionGames(req);

  await runStream(req, msg);
}

function cancelAiReportConfirm() {
  const pc = pendingAiReportConfirm;
  if (!pc) return;
  pendingAiReportConfirm = null;
  stopConfirmTimer();
  const card = pc.msg.querySelector('.ai-report-confirm-card');
  if (card) card.remove();
  setStatus(pc.msg, '已取消');
}

function renderGenerateConfirmCard(msg, ev) {
  showBadge(msg, '🛠️ 生成专项草稿？', false);
  addProcessStep(msg, '生成专项草稿耗时较长，待确认是否继续');

  const body = msg.querySelector('.body');
  const card = document.createElement('div');
  card.className = 'confirm-card generate-confirm-card';

  const q = document.createElement('div');
  q.className = 'confirm-q';
  q.textContent = '将扫描所有 SQL / 知识库 / 模型，生成「专项方法说明 + 快照」草稿，耗时较长（数分钟）。生成后仅作草稿展示，点「保存」才会写入。是否继续？';
  card.appendChild(q);

  const row = document.createElement('div');
  row.className = 'confirm-actions';

  const yes = document.createElement('button');
  yes.className = 'btn btn-sm btn-primary';
  yes.textContent = '✅ 继续生成';
  yes.addEventListener('click', () => executeGenerateConfirm('ok'));
  row.appendChild(yes);

  const cancel = document.createElement('button');
  cancel.className = 'btn btn-sm';
  cancel.textContent = '✋ 取消';
  cancel.addEventListener('click', () => cancelGenerateConfirm());
  row.appendChild(cancel);

  card.appendChild(row);
  body.appendChild(card);
  setStatus(msg, '待确认是否生成专项草稿');
}

async function executeGenerateConfirm(choice) {
  const pc = pendingGenerateConfirm;
  if (!pc) return;
  pendingGenerateConfirm = null;

  const msg = pc.msg;
  const card = msg.querySelector('.generate-confirm-card');
  if (card) card.remove();
  setStatus(msg, '处理中…');
  msg._t0 = performance.now();

  state.table = null;
  state.chartSpec = null;
  currentSql = null;
  currentAnswer = null;
  currentMeta = null;
  currentSubs = null;
  currentUsage = null;
  currentSuggestion = null;
  pendingConfirm = null;
  pendingGameConfirm = null;
  pendingForecastConfirm = null;
  pendingCandidates = null;
  pendingAiReportConfirm = null;
  pendingRewriteConfirm = null;
  pendingGenerateConfirm = null;

  const req = {
    ...(state.modelExplicit ? { model: state.model } : {}),
    message: pc.question || pc.text,
    mode: 'auto',
    preset_skill: null,
    chart_type: 'auto',
    docs: [],
    context_report: null,
    history: currentHistory,
    confirm: null,
    game_confirm: null,
    target_game: pc.game || null,
    forecast_confirm: null,
    candidate: null,
    ai_report_confirm: null,
    rewrite_confirm: null,
    generate_confirm: choice,  // "ok"=确认生成专项草稿
  };
  maybeThreadSessionGames(req);

  await runStream(req, msg);
}

function cancelGenerateConfirm() {
  const pc = pendingGenerateConfirm;
  if (!pc) return;
  pendingGenerateConfirm = null;
  stopConfirmTimer();
  const card = pc.msg.querySelector('.generate-confirm-card');
  if (card) card.remove();
  setStatus(pc.msg, '已取消');
}

function renderRewriteConfirmCard(msg, ev) {
  showBadge(msg, '🔧 就近改写？', false);
  addProcessStep(msg, '未精准命中，找到就近 SQL「' + (ev.sql_name || '') + '」，待确认是否改写');

  const body = msg.querySelector('.body');
  const card = document.createElement('div');
  card.className = 'confirm-card rewrite-confirm-card';

  const q = document.createElement('div');
  q.className = 'confirm-q';
  q.textContent = '未精准命中既有专项 / SQL，但找到最接近的既有 SQL「' + (ev.sql_name || '') + '」。可据此改写（如调整时间窗口/口径）后执行。⚠️ 改写结果由 AI 生成、准确率无法保证，请人工复核。';
  card.appendChild(q);

  const row = document.createElement('div');
  row.className = 'confirm-actions';

  const yes = document.createElement('button');
  yes.className = 'btn btn-sm btn-primary';
  yes.textContent = '✅ 改写并执行';
  yes.addEventListener('click', () => executeRewriteConfirm(ev.sql_name || ''));
  row.appendChild(yes);

  const fresh = document.createElement('button');
  fresh.className = 'btn btn-sm';
  fresh.textContent = '⚡ AI 现写新SQL';
  fresh.addEventListener('click', () => executeRewriteConfirm(''));
  row.appendChild(fresh);

  const cancel = document.createElement('button');
  cancel.className = 'btn btn-sm';
  cancel.textContent = '✋ 取消';
  cancel.addEventListener('click', () => cancelRewriteConfirm());
  row.appendChild(cancel);

  card.appendChild(row);
  body.appendChild(card);
  setStatus(msg, '待确认是否改写就近SQL');
  armConfirmCountdown(
    msg,
    () => executeRewriteConfirm(ev.sql_name || ''),
    () => pendingRewriteConfirm && pendingRewriteConfirm.msg === msg,
    '改写并执行'
  );
}

async function executeRewriteConfirm(choice) {
  const pc = pendingRewriteConfirm;
  if (!pc) return;
  pendingRewriteConfirm = null;

  const msg = pc.msg;
  const card = msg.querySelector('.rewrite-confirm-card');
  if (card) card.remove();
  setStatus(msg, '处理中…');
  msg._t0 = performance.now(); // 二次确认后重新计时

  state.table = null;
  state.chartSpec = null;
  currentSql = null;
  currentAnswer = null;
  currentMeta = null;
  currentSubs = null;
  currentUsage = null;
  currentSuggestion = null;
  pendingConfirm = null;
  pendingGameConfirm = null;
  pendingForecastConfirm = null;
  pendingCandidates = null;
  pendingAiReportConfirm = null;

  const req = {
    ...(state.modelExplicit ? { model: state.model } : {}),
    message: pc.question || pc.text,
    mode: 'auto',
    preset_skill: null,
    chart_type: 'auto',
    docs: [],
    context_report: null,
    history: currentHistory,
    confirm: null,
    game_confirm: null,
    target_game: pc.game || null,
    forecast_confirm: null,
    candidate: null,
    ai_report_confirm: null,
    rewrite_confirm: choice,  // ""=不改写、AI现写；"<SQL名>"=以该SQL为底稿改写
  };
  maybeThreadSessionGames(req);

  await runStream(req, msg);
}

function cancelRewriteConfirm() {
  const pc = pendingRewriteConfirm;
  if (!pc) return;
  pendingRewriteConfirm = null;
  stopConfirmTimer();
  const card = pc.msg.querySelector('.rewrite-confirm-card');
  if (card) card.remove();
  setStatus(pc.msg, '已取消');
}

function renderGameConfirmCard(msg, ev) {
  const body = msg.querySelector('.body');
  const card = document.createElement('div');
  card.className = 'confirm-card game-confirm-card';

  const q = document.createElement('div');
  q.className = 'confirm-q';
  q.textContent = ev.reason || '识别到你要分析的项目与当前选中不一致，请确认要分析哪些项目：';
  card.appendChild(q);

  const list = document.createElement('div');
  list.className = 'confirm-games';
  (ev.games || []).forEach((g) => {
    const chip = document.createElement('span');
    chip.className = 'confirm-game-chip';
    chip.textContent = g.label || g.name || g.key;
    list.appendChild(chip);
  });
  card.appendChild(list);

  const row = document.createElement('div');
  row.className = 'confirm-actions';

  const yes = document.createElement('button');
  yes.className = 'btn btn-sm btn-primary';
  yes.textContent = '✅ 按上述项目分析';
  yes.addEventListener('click', () => executeGameConfirm('ok'));
  row.appendChild(yes);

  const cur = document.createElement('button');
  cur.className = 'btn btn-sm';
  const curName = (ev.current && ev.current.name) || '当前选中游戏';
  cur.textContent = '✍️ 按「' + curName + '」分析';
  cur.addEventListener('click', () => executeGameConfirm(''));
  row.appendChild(cur);

  card.appendChild(row);
  body.appendChild(card);
  armConfirmCountdown(
    msg,
    () => executeGameConfirm('ok'),
    () => pendingGameConfirm && pendingGameConfirm.msg === msg,
    '按上述项目分析'
  );
}

async function executeGameConfirm(choice) {
  const pc = pendingGameConfirm;
  if (!pc) return;
  pendingGameConfirm = null;

  const msg = pc.msg;
  const card = msg.querySelector('.game-confirm-card');
  if (card) card.remove();
  setStatus(msg, '处理中…');
  msg._t0 = performance.now(); // 二次确认后重新计时

  state.table = null;
  state.chartSpec = null;
  currentSql = null;
  currentAnswer = null;
  currentMeta = null;
  currentSubs = null;
  currentUsage = null;
  currentSuggestion = null;

  const req = {
    ...(state.modelExplicit ? { model: state.model } : {}),
    message: pc.question || pc.text,
    mode: 'auto',
    preset_skill: null,
    chart_type: 'auto',
    docs: [],
    context_report: null,
    history: currentHistory,
    confirm: null,
    game_confirm: choice,  // "ok" = 按解析项目；"" = 按当前选中游戏
    game_confirm_source: pc.source || null,
    target_game: pc.target_game || null,
  };

  // 执行阶段同样锁定输入，避免并发发送重置本轮上下文
  await runStream(req, msg);
}

function renderForecastConfirmCard(msg, ev) {
  showBadge(msg, '🔮 预测确认：' + ev.method, false);
  addProcessStep(msg, '🔮 命中预测能力「' + ev.method + '」，需确认预测时间段');

  const body = msg.querySelector('.body');
  const card = document.createElement('div');
  card.className = 'confirm-card forecast-confirm-card';

  const q = document.createElement('div');
  q.className = 'confirm-q';
  card.appendChild(q);

  const row = document.createElement('div');
  row.className = 'confirm-actions';

  let yearSel = null;
  if (ev.year_ambiguous) {
    const what = ev.month ? (ev.month + '月') : (ev.label || '该时间段');
    q.textContent = '你要预测「' + what + '」的流水，但未写明年份，请先确认要预测的年份：';
    yearSel = document.createElement('select');
    yearSel.className = 'control confirm-select';
    (ev.years || []).forEach((y) => {
      const o = document.createElement('option');
      o.value = String(y); o.textContent = y + '年';
      if (y === ev.year) o.selected = true;
      yearSel.appendChild(o);
    });
    row.appendChild(yearSel);
  } else {
    q.textContent = '你要预测的是「' + (ev.label || '该时间段') + '」（已发生的时间段），将回填预测这段已发生的数据，是否继续？';
  }

  const yes = document.createElement('button');
  yes.className = 'btn btn-sm btn-primary';
  yes.textContent = '✅ 确认并预测';
  yes.addEventListener('click', () => executeForecastConfirm(yearSel ? yearSel.value : null));
  row.appendChild(yes);

  const cancel = document.createElement('button');
  cancel.className = 'btn btn-sm';
  cancel.textContent = '✋ 取消';
  cancel.addEventListener('click', () => cancelForecastConfirm());
  row.appendChild(cancel);

  card.appendChild(row);
  body.appendChild(card);
  setStatus(msg, '待确认预测时间段');
  armConfirmCountdown(
    msg,
    () => executeForecastConfirm(yearSel ? yearSel.value : null),
    () => pendingForecastConfirm && pendingForecastConfirm.msg === msg,
    '确认并预测'
  );
}

async function executeForecastConfirm(selectedYear) {
  const pc = pendingForecastConfirm;
  if (!pc) return;
  pendingForecastConfirm = null;

  const msg = pc.msg;
  const card = msg.querySelector('.forecast-confirm-card');
  if (card) card.remove();
  setStatus(msg, '处理中…');
  msg._t0 = performance.now(); // 二次确认后重新计时

  state.table = null;
  state.chartSpec = null;
  currentSql = null;
  currentAnswer = null;
  currentMeta = null;
  currentSubs = null;
  currentUsage = null;
  currentSuggestion = null;

  let start = pc.start, end = pc.end;
  if (selectedYear && pc.year && Number(selectedYear) !== Number(pc.year)) {
    // 用户改了年份 → 起止日期整体平移年份差（保留原月/日，覆盖单月与跨月时间段）
    const delta = Number(selectedYear) - Number(pc.year);
    const p = (n) => String(n).padStart(2, '0');
    const shift = (s) => {
      const parts = s.split('-');
      return String(Number(parts[0]) + delta) + '-' + p(Number(parts[1])) + '-' + p(Number(parts[2]));
    };
    start = shift(start);
    end = shift(end);
  }

  const req = {
    ...(state.modelExplicit ? { model: state.model } : {}),
    message: pc.question || pc.text,
    mode: 'auto',
    preset_skill: null,
    chart_type: 'auto',
    docs: [],
    context_report: null,
    history: currentHistory,
    confirm: null,
    game_confirm: null,
    target_game: null,
    forecast_confirm: JSON.stringify({ method: pc.method, start: start, end: end, target_game: pc.target_game }),
  };
  maybeThreadSessionGames(req);  // 顶层补 target_games（游戏在嵌套 forecast_confirm.target_game 里，顶层原本恒 null）

  // 执行阶段同样锁定输入，避免并发发送重置本轮上下文
  await runStream(req, msg);
}

function cancelForecastConfirm() {
  const pc = pendingForecastConfirm;
  if (!pc) return;
  pendingForecastConfirm = null;
  stopConfirmTimer();
  const card = pc.msg.querySelector('.forecast-confirm-card');
  if (card) card.remove();
  setStatus(pc.msg, '已取消');
}

function renderUsageBadge(msg, usage) {
  if (!usage) return;
  const meta = msg.querySelector('.msg-meta');
  if (meta) meta.hidden = false;
  const el = msg.querySelector('.usage');
  el.textContent = '🔢 ' + usage.total_tokens + ' tokens · 约 ¥' + (usage.cost || 0).toFixed(4);
}

function renderTimeBadge(msg, seconds) {
  if (seconds == null) return;
  const meta = msg.querySelector('.msg-meta');
  if (meta) meta.hidden = false;
  const el = msg.querySelector('.resp-time');
  el.textContent = '⏱️ ' + seconds + 's';
}

function renderUsageStats() {
  const el = $('#usage-stats');
  if (!el) return;
  const parts = [];
  if (sessionUsage.tokens) {
    parts.push('本次会话 · ' + sessionUsage.tokens + ' tokens · 约 ¥' + sessionUsage.cost.toFixed(4));
  }
  el.textContent = parts.join('  ·  ');
  el.hidden = !parts.length;
}

function renderSessionUsage() { renderUsageStats(); }

// ---- 深度下钻：普通答案完成后提供「🔍 深度分析」一键转 agentic 流（审计 P1-2）----

function renderDeepButton(msg) {
  const body = msg.querySelector('.body');
  if (!body || body.querySelector('.deep-trigger')) return;
  if (!(msg._question || lastQuestion || state.skill)) return;
  const btn = document.createElement('button');
  btn.className = 'btn btn-sm deep-trigger';
  btn.textContent = '🔍 深度分析';
  btn.title = '把这个问题交给深度分析 Agent：多步检索知识库/已存SQL/专项并取数验证，结果作为新消息返回';
  btn.addEventListener('click', () => requestDeepAnalysis(msg));
  body.appendChild(btn);
}

async function requestDeepAnalysis(msg) {
  if (sending) return;
  const btn = msg.querySelector('.deep-trigger');
  if (!btn) return;
  // 对抗审查三轮 [7]：深度入口统一收口——摘掉仍在倒计时的旧游戏多选卡，
  // 防 60s 倒计时在深度流进行中并发触发 executeGameSelect
  clearPendingGameSelect('已取消');
  // 对抗审查三轮 [6]：普通会话已绑定游戏时带到深度会话，深度绑定上下文不丢、
  // 多权限用户不因 deepSessionGames 为空再弹多选卡
  if (currentGameMode() === 'none' && sessionGames.length && !deepSessionGames.length) {
    deepSessionGames = sessionGames.slice();
    storeSessionGames();
  }
  const question = (msg._question || lastQuestion || '') ||
    (state.skill ? ('用深度分析跑一遍专项「' + state.skill + '」') : '');
  if (!question) return;
  btn.disabled = true;
  btn.textContent = '⏳ 深度分析启动中…';
  const dmsg = appendAssistant();
  dmsg._deep = true;
  dmsg._question = question;
  state.table = null;
  state.chartSpec = null;
  currentSql = null;
  currentAnswer = null;
  currentMeta = null;
  currentSubs = null;
  currentUsage = null;
  currentSuggestion = null;
  lastQuestion = question;
  // 复用深度分析 agentic 端点；历史含当前普通答案，作为延续而非重跑。buildDeepHistory(question, msg._ti)
  // 按锚点索引精确剔除本轮提问（同一问题问过多轮时也不会删错别的轮次），并保留上一轮的普通答案
  const req = { message: question, history: buildDeepHistory(question, msg._ti) };
  if (currentGameMode() === 'none' && deepSessionGames.length) req.session_games = deepSessionGames;
  await runStream(req, dmsg, '/api/agent/chat/stream');
  btn.disabled = false;
  btn.textContent = '🔍 深度分析';
}

// ---- 智能路由：普通模式识别为探索性/开放性问题 → 同一条消息无缝切换深度分析 ----
async function startAutoDeep(msg) {
  const rd = msg._routeDeep;
  msg._routeDeep = null;
  // 对抗审查三轮 [6]：智能路由无缝切深度时，把普通会话已绑定游戏带到深度会话，
  // 否则深度绑定上下文丢失、多权限用户再弹多选卡
  if (currentGameMode() === 'none' && sessionGames.length && !deepSessionGames.length) {
    deepSessionGames = sessionGames.slice();
    storeSessionGames();
  }
  // 路由时后端可能对追问/指代做了精化（refined_question）：深度请求喂精化文本，避免 Agent 拿到
  // 「为什么下降了？」这类缺指代的原文；但历史锚点剔除必须用 transcript 里的原始提问，
  // 精化文本与原文不一致会导致剔除永不命中、提问被喂两遍（对抗审查修复）
  const rawQuestion = rd.question || lastQuestion || '';
  const question = rd.refined || rawQuestion;
  if (!question) return;
  msg._deep = true;
  msg._question = rawQuestion;  // 消息归属的提问仍是用户原文（与 transcript 用户条目一致）
  msg._t0 = performance.now();  // 深度分析阶段重新计时
  state.table = null;
  state.chartSpec = null;
  currentSql = null;
  currentAnswer = null;
  currentMeta = null;
  currentSubs = null;
  currentUsage = null;
  currentSuggestion = null;
  lastQuestion = rawQuestion;
  // 普通流未发 done 就提前返回，msg 尚未入库（_ti 未挂）：buildDeepHistory 回落尾部同文剔除，
  // 恰好删掉本轮刚 append 的用户提问（按原文匹配），历史=此前对话
  const req = { message: question, history: buildDeepHistory(rawQuestion || question, msg._ti) };
  if (currentGameMode() === 'none' && deepSessionGames.length) req.session_games = deepSessionGames;
  await runStream(req, msg, '/api/agent/chat/stream');
}

// ---- 提炼建议：手动触发（点「💡 提炼建议」才生成，不阻塞本轮结果）----

function renderSuggestButton(msg) {
  const body = msg.querySelector('.body');
  if (!body || body.querySelector('.suggest-trigger') || body.querySelector('.suggest-card')) return;
  const btn = document.createElement('button');
  btn.className = 'btn btn-sm suggest-trigger';
  btn.textContent = '🧠 提炼到个人知识库';
  btn.title = '把本轮对话提炼成一条个人知识库文档（习惯记忆，仅自己可见）';
  btn.addEventListener('click', () => requestSuggestion(msg));
  body.appendChild(btn);
}

async function requestSuggestion(msg) {
  const btn = msg.querySelector('.suggest-trigger');
  if (!btn) return;
  const payload = {
    ...(state.modelExplicit ? { model: state.model } : {}),
    skill: null,  // 只提炼知识库，不优化既有专项
    question: msg._question || lastQuestion || '',
    sql: msg._sql || '',
    answer: msg._answer || '',
    kinds: ['doc'],  // 只提炼知识库（个人记忆），不生成 SQL/专项/模型
  };
  // 评审 A1：「不选游戏」模式回传会话游戏——后端哨兵恢复链靠它定位范围（否则 400/全量泄漏）。
  // 对抗审查二轮：深度消息的绑定游戏存 deepSessionGames（与普通会话隔离），
  // 深度气泡回传 sessionGames 会拿到空数组/旧值，哨兵恢复链误走全允许集搜索
  const boundGames = msg._deep ? deepSessionGames : sessionGames;
  if (currentGameMode() === 'none' && boundGames.length) payload.games = boundGames.slice();
  btn.disabled = true;
  btn.textContent = '⏳ 提炼中…';
  try {
    const res = await fetch('/api/chat/suggest', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    if (!res.ok) { const e = await res.json().catch(() => ({})); throw new Error(e.detail || res.status); }
    const suggestion = await res.json();
    btn.remove();
    renderSuggestionCard(msg, suggestion);
  } catch (e) {
    btn.disabled = false;
    btn.textContent = '🧠 提炼到个人知识库（重试）';
    alert('提炼失败：' + e.message);
  }
}

function suggestionNames(kind) {
  if (kind === 'sql') return sqlNames;
  if (kind === 'doc') return docNames;
  if (kind === 'model') return modelNames;
  return skillNames;
}

// ---- 深度验证：把生成器产出的草稿（提炼建议/订阅报告/知识库汇总）交给深度分析 Agent 审阅（审计 P1-2）----

async function requestDraftValidation(msg, draftText, kindLabel) {
  if (sending) return;
  if (!draftText || !draftText.trim()) { alert('草稿为空，无法验证'); return; }
  const dmsg = appendAssistant();
  dmsg._deep = true;
  dmsg._question = '验证' + kindLabel + '草稿';
  // 与 requestDeepAnalysis 同口径：清掉上一轮结果态，避免旧表/旧图串到新流
  state.table = null;
  state.chartSpec = null;
  currentSql = null;
  currentAnswer = null;
  currentMeta = null;
  currentSubs = null;
  currentUsage = null;
  currentSuggestion = null;
  lastQuestion = dmsg._question;
  const prompt = '请审阅下面这份' + kindLabel + '草稿：检查数据口径是否有误、逻辑是否自洽、有没有明显遗漏或冗余，'
    + '并逐条给出修改建议（不改写全文）。草稿内容：\n\n' + draftText;
  // message 是新写的验证提示词（与历史无同文重复），历史全量携带、不做剔除
  const req = { message: prompt, history: buildDeepHistory() };
  await runStream(req, dmsg, '/api/agent/chat/stream');
}

function renderSuggestionCard(msg, ev) {
  const body = msg.querySelector('.body');
  const old = body.querySelector('.suggest-card');
  if (old) old.remove();

  // 只提炼知识库（个人记忆）；无 doc 草稿则不渲染
  const doc = ev.doc;
  if (!doc) return;

  const card = document.createElement('div');
  card.className = 'suggest-card';

  const title = document.createElement('div');
  title.className = 'suggest-title';
  title.textContent = '🧠 提炼到个人知识库';
  card.appendChild(title);

  const hint = document.createElement('div');
  hint.className = 'suggest-hint';
  hint.textContent = '点「保存」写入个人知识库（仅自己可见）。';
  card.appendChild(hint);

  const row = document.createElement('div');
  row.className = 'suggest-row';

  const head = document.createElement('div');
  head.className = 'suggest-head';
  const tag = document.createElement('span');
  tag.className = 'suggest-label';
  tag.textContent = '📚 知识库';
  const nameInput = document.createElement('input');
  nameInput.className = 'control suggest-name';
  nameInput.value = doc.name || '';
  const saveBtn = document.createElement('button');
  saveBtn.className = 'btn btn-sm btn-primary';
  saveBtn.textContent = '💾 保存';
  head.appendChild(tag);
  head.appendChild(nameInput);
  head.appendChild(saveBtn);
  row.appendChild(head);

  const actions = document.createElement('div');
  actions.className = 'suggest-actions';
  const previewBtn = document.createElement('button');
  previewBtn.className = 'btn btn-sm';
  previewBtn.textContent = '预览';
  actions.appendChild(previewBtn);
  // 审计 P1-2：草稿交深度分析 Agent 审阅（口径/逻辑/遗漏），结果作为新消息返回
  const verifyBtn = document.createElement('button');
  verifyBtn.className = 'btn btn-sm';
  verifyBtn.textContent = '🔍 深度验证';
  verifyBtn.title = '把这份草稿交给深度分析 Agent 审阅：检查口径、逻辑与遗漏，给出修改建议';
  actions.appendChild(verifyBtn);
  row.appendChild(actions);

  const pre = document.createElement('pre');
  pre.className = 'suggest-preview';
  pre.hidden = true;
  pre.textContent = doc.draft || '';
  row.appendChild(pre);
  card.appendChild(row);
  body.appendChild(card);

  let draft = doc.draft || '';
  previewBtn.addEventListener('click', () => {
    pre.hidden = !pre.hidden;
    if (!pre.hidden) pre.textContent = draft;
  });
  verifyBtn.addEventListener('click', () => requestDraftValidation(msg, draft, '知识库'));

  saveBtn.addEventListener('click', async () => {
    const name = (nameInput.value || '').trim();
    if (!name) { alert('请先填写名称'); return; }
    saveBtn.disabled = true; saveBtn.textContent = '保存中…';
    try {
      await saveSuggestion('doc', name, draft, doc);
      saveBtn.disabled = false; saveBtn.textContent = '✅ 已保存';
    } catch (e) {
      saveBtn.disabled = false; saveBtn.textContent = '❌ 失败';
      setTimeout(() => { saveBtn.textContent = '💾 保存'; }, 2000);
      alert('保存失败：' + e.message);
    }
  });
}

function buildSuggestionRow(kind, icon, label, slot, turn) {
  const row = document.createElement('div');
  row.className = 'suggest-row';

  const head = document.createElement('div');
  head.className = 'suggest-head';

  const tag = document.createElement('span');
  tag.className = 'suggest-label';
  tag.textContent = icon + ' ' + label;

  const nameInput = document.createElement('input');
  nameInput.className = 'control suggest-name';
  nameInput.value = slot.name || '';

  const saveBtn = document.createElement('button');
  saveBtn.className = 'btn btn-sm btn-primary';
  const saveBaseText = slot.action === 'update' ? '💾 保存优化' : '💾 保存';
  saveBtn.textContent = saveBaseText;

  head.appendChild(tag);
  head.appendChild(nameInput);
  head.appendChild(saveBtn);
  row.appendChild(head);

  const actions = document.createElement('div');
  actions.className = 'suggest-actions';
  const mergeSel = document.createElement('select');
  mergeSel.className = 'control suggest-select';
  const ph = document.createElement('option');
  ph.value = ''; ph.textContent = '↩ 合并到现有…';
  mergeSel.appendChild(ph);
  suggestionNames(kind).forEach((n) => {
    const o = document.createElement('option');
    o.value = n; o.textContent = n;
    mergeSel.appendChild(o);
  });
  const previewBtn = document.createElement('button');
  previewBtn.className = 'btn btn-sm';
  previewBtn.textContent = '预览';
  actions.appendChild(mergeSel);
  actions.appendChild(previewBtn);
  row.appendChild(actions);

  const pre = document.createElement('pre');
  pre.className = 'suggest-preview';
  pre.hidden = true;
  pre.textContent = slot.draft || '';
  row.appendChild(pre);

  let draft = slot.draft || '';

  previewBtn.addEventListener('click', () => {
    pre.hidden = !pre.hidden;
    if (!pre.hidden) pre.textContent = draft;
  });

  saveBtn.addEventListener('click', async () => {
    const name = (nameInput.value || '').trim();
    if (!name) { alert('请先填写名称'); return; }
    saveBtn.disabled = true; saveBtn.textContent = '保存中…';
    try {
      await saveSuggestion(kind, name, draft, slot);
      saveBtn.disabled = false; saveBtn.textContent = '✅ 已保存';
    } catch (e) {
      saveBtn.disabled = false; saveBtn.textContent = '❌ 失败';
      setTimeout(() => { saveBtn.textContent = saveBaseText; }, 2000);
      alert('保存失败：' + e.message);
    }
  });

  mergeSel.addEventListener('change', async () => {
    const target = mergeSel.value;
    if (!target) return;
    mergeSel.disabled = true;
    try {
      const backendKind = kind === 'doc' ? 'docs' : (kind === 'skill' ? 'skills' : (kind === 'model' ? 'models' : 'sql'));
      const mergePayload = {
        ...(state.modelExplicit ? { model: state.model } : {}), kind: backendKind, target: target,
        question: turn.question, sql: turn.sql, answer: turn.answer,
      };
      // 评审 A1：「不选游戏」模式回传会话游戏——后端哨兵恢复链（回传 → 目标资产所属）靠它定位。
      // 对抗审查二轮：深度轮的绑定游戏在 deepSessionGames（转录条目 meta.source='deep' 标识）
      const mergeBoundGames = (turn && turn.meta && turn.meta.source === 'deep') ? deepSessionGames : sessionGames;
      if (currentGameMode() === 'none' && mergeBoundGames.length) mergePayload.games = mergeBoundGames.slice();
      const res = await fetch('/api/chat/suggest-merge', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(mergePayload),
      });
      if (!res.ok) { const e = await res.json().catch(() => ({})); throw new Error(e.detail || res.status); }
      const data = await res.json();
      draft = data.draft || draft;
      if (data.name) nameInput.value = data.name;
      if (data.sqls) slot.sqls = data.sqls;
      if (data.docs) slot.docs = data.docs;
      if (data.transformed_sqls) slot.transformed_sqls = data.transformed_sqls;
      if (data.sources) slot.sources = data.sources;
      pre.textContent = draft;
      pre.hidden = false;
    } catch (e) {
      alert('合并生成失败：' + e.message);
    } finally {
      mergeSel.disabled = false;
      mergeSel.value = '';
    }
  });

  return row;
}

async function saveSuggestion(kind, name, draft, slot) {
  let res;
  if (kind === 'sql') {
    res = await fetch('/api/admin/sqls/' + encodeURIComponent(name), {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ sql: draft, meta: {}, level: '通用' }),
    });
  } else if (kind === 'doc') {
    res = await fetch('/api/admin/knowledge/docs/' + encodeURIComponent(name), {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ content: draft, level: '个人' }),
    });
  } else if (kind === 'model') {
    // 更新/保存模型：保留原取数 SQL/粒度/窗口（新建时用生成流程下发的 manifest）
    const target = slot.target || name;
    let meta = slot.manifest || {};
    if (!meta.sql) {
      try {
        const r = await fetch('/api/admin/models/' + encodeURIComponent(target));
        if (r.ok) { const ex = await r.json(); meta = ex.meta || meta; }
      } catch (e) { /* 忽略 */ }
    }
    res = await fetch('/api/admin/models', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(Object.assign({}, meta, {
        name: name, code: draft, desc: meta.desc || meta.name || name,
        sources: slot.sources || meta.sources || [],
        transformed_sqls: slot.transformed_sqls || {},
      })),
    });
  } else { // skill
    let sqls = slot.sqls || [];
    let docs = slot.docs || [];
    if (slot.action === 'update') {
      // 优化既有专项：保留原有关联，再并入新建议关联
      try {
        const r = await fetch('/api/admin/skills/' + encodeURIComponent(name));
        const ex = await r.json();
        sqls = [...new Set([...(ex.sqls || []), ...sqls])];
        docs = [...new Set([...(ex.docs || []), ...docs])];
      } catch (e) { /* 忽略，用建议值 */ }
    }
    res = await fetch('/api/admin/skills/' + encodeURIComponent(name), {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ content: draft, sqls: sqls, docs: docs, level: '通用' }),
    });
  }
  if (!res.ok) {
    const e = await res.json().catch(() => ({}));
    throw new Error(e.detail || res.status);
  }
}

// ---- 生成草稿卡片（能力 1：对话里 AI 自动生成 SQL/模型/专项）----

function buildAssocText(ev) {
  const parts = [];
  const a = ev.associations || {};
  if (a.docs && a.docs.length) parts.push('📚 关联 ' + a.docs.length + ' 文档');
  if (a.sqls && a.sqls.length) parts.push('🗄️ 关联 ' + a.sqls.length + ' SQL');
  if (a.forecast) parts.push('🔮 绑定预测');
  const ts = ev.transforms && ev.transforms.sqls;
  if (ts) {
    const n = Object.keys(ts).filter((k) => ts[k]).length;
    if (n) parts.push('✂️ 专属修改 SQL ×' + n);
  }
  return parts.join(' · ');
}

function renderGenerateCard(msg, ev) {
  const body = msg.querySelector('.body');
  const card = document.createElement('div');
  card.className = 'suggest-card generate-card';

  const kindLabel = { sql: '🗄️ SQL', model: '🔮 模型', skill: '🎯 专项' }[ev.kind] || '工件';
  const title = document.createElement('div');
  title.className = 'suggest-title';
  title.textContent = '🛠️ 生成草稿 · ' + kindLabel;
  card.appendChild(title);

  const hint = document.createElement('div');
  hint.className = 'suggest-hint';
  hint.textContent = '点「保存」才写入；可直接改名称。';
  card.appendChild(hint);

  if (ev.problems && ev.problems.length) {
    const warn = document.createElement('div');
    warn.className = 'suggest-hint';
    warn.textContent = '⚠️ 预检提示：' + ev.problems.join('；');
    card.appendChild(warn);
  }

  const row = document.createElement('div');
  row.className = 'suggest-row';

  const head = document.createElement('div');
  head.className = 'suggest-head';
  const tag = document.createElement('span');
  tag.className = 'suggest-label';
  tag.textContent = '名称';
  const nameInput = document.createElement('input');
  nameInput.className = 'control suggest-name';
  nameInput.value = ev.name || '';
  const saveBtn = document.createElement('button');
  saveBtn.className = 'btn btn-sm btn-primary';
  saveBtn.textContent = '💾 保存';
  head.appendChild(tag);
  head.appendChild(nameInput);
  head.appendChild(saveBtn);
  row.appendChild(head);

  const actions = document.createElement('div');
  actions.className = 'suggest-actions';
  const assocText = buildAssocText(ev);
  if (assocText) {
    const assocEl = document.createElement('span');
    assocEl.className = 'suggest-assoc';
    assocEl.textContent = assocText;
    actions.appendChild(assocEl);
  }
  const regenBtn = document.createElement('button');
  regenBtn.className = 'btn btn-sm';
  regenBtn.textContent = '🔄 重新生成';
  regenBtn.addEventListener('click', () => {
    card.remove();
    $('#input').value = lastQuestion || '';
    sendMessage();
  });
  actions.appendChild(regenBtn);
  const previewBtn = document.createElement('button');
  previewBtn.className = 'btn btn-sm';
  previewBtn.textContent = '预览';
  actions.appendChild(previewBtn);
  row.appendChild(actions);

  const pre = document.createElement('pre');
  pre.className = 'suggest-preview';
  pre.hidden = true;
  let draft = ev.draft || '';
  pre.textContent = draft;
  row.appendChild(pre);

  card.appendChild(row);

  previewBtn.addEventListener('click', () => {
    pre.hidden = !pre.hidden;
    if (!pre.hidden) pre.textContent = draft;
  });

  saveBtn.addEventListener('click', async () => {
    const name = (nameInput.value || '').trim();
    if (!name) { alert('请先填写名称'); return; }
    saveBtn.disabled = true; saveBtn.textContent = '保存中…';
    try {
      await saveGenerated(ev, name, draft);
      saveBtn.disabled = false; saveBtn.textContent = '✅ 已保存';
    } catch (e) {
      saveBtn.disabled = false; saveBtn.textContent = '❌ 失败';
      setTimeout(() => { saveBtn.textContent = '💾 保存'; }, 2000);
      alert('保存失败：' + e.message);
    }
  });

  body.appendChild(card);
}

async function saveGenerated(ev, name, draft) {
  let res;
  if (ev.kind === 'sql') {
    res = await fetch('/api/admin/sqls/' + encodeURIComponent(name), {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ sql: draft, meta: {}, level: '个人', sources: ev.sources || [] }),
    });
  } else if (ev.kind === 'model') {
    const m = ev.manifest || {};
    const body = Object.assign({}, m, {
      name: name, code: draft, desc: name, level: '通用',
      sources: ev.sources || [],
      transformed_sqls: (ev.transforms && ev.transforms.sqls) || {},
    });
    res = await fetch('/api/admin/models', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
    });
  } else { // skill
    const a = ev.associations || {};
    const t = ev.transforms || {};
    const frozen = {
      sqls: t.sqls || {}, knowledge: t.knowledge || {}, models: t.models || {},
      provenance: ev.provenance || { sql: {}, models: {}, knowledge: {} },
    };
    res = await fetch('/api/admin/skills/' + encodeURIComponent(name), {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        content: draft, sqls: a.sqls || [], docs: a.docs || [],
        level: '个人', forecast: a.forecast || null, frozen: frozen,
      }),
    });
  }
  if (!res.ok) {
    const e = await res.json().catch(() => ({}));
    throw new Error(e.detail || res.status);
  }
  // 生成保存后刷新名称缓存（供后续提炼卡下拉）
  if (ev.kind === 'sql') loadSqlNames();
  else if (ev.kind === 'model') loadModelNames();
  else loadSkills();
}

// ---- 保存 / 新对话 ----

function buildUsagePayload() {
  return {
    prompt_tokens: sessionUsage.prompt || 0,
    completion_tokens: sessionUsage.completion || 0,
    total_tokens: sessionUsage.tokens || 0,
    cost: sessionUsage.cost || 0,
  };
}

async function autoSave() {
  if (!transcript.some((m) => m.role === 'user')) return;
  const first = transcript.find((m) => m.role === 'user');
  const payload = { title: (first && first.text || '对话').slice(0, 40), messages: transcript.filter((m) => !m._confirmOnly), usage: buildUsagePayload() };
  try {
    let saved = false;
    if (cacheSid) {
      const res = await fetch('/api/chat-history/' + encodeURIComponent(cacheSid), {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
      if (res.ok) saved = true;
    }
    if (!saved) {
      const res = await fetch('/api/chat-history', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
      const data = await res.json();
      if (data && data.id) cacheSid = data.id;
      if (res.ok) saved = true;
    }
    if (saved) loadSidebarHistory();
  } catch (e) { /* 自动缓存失败静默忽略 */ }
}

function newConversation() {
  if (transcript.length && !confirm('清空当前对话？（之前的对话已自动缓存，可在「聊天记录」查看）')) return;
  transcript = [];
  currentSql = null;
  currentAnswer = null;
  currentMeta = null;
  lastQuestion = null;
  cacheSid = null;
  lastReport = null;
  lastReportSkill = null;
  currentContextReport = null;
  currentSubs = null;
  pendingConfirm = null;
  pendingGameConfirm = null;
  pendingForecastConfirm = null;
  pendingCandidates = null;
  pendingAiReportConfirm = null;
  pendingRewriteConfirm = null;
  pendingGenerateConfirm = null;
  pendingGameSelect = null;
  stopConfirmTimer();
  currentUsage = null;
  currentSuggestion = null;
  currentHistory = [];
  sessionUsage = { tokens: 0, cost: 0, prompt: 0, completion: 0 };
  // 「新对话」清除会话级游戏绑定（含 sessionStorage，防换对话后沿用旧选择）
  sessionGames = [];
  deepSessionGames = [];
  storeSessionGames();
  state.table = null;
  state.chartSpec = null;
  renderSessionUsage();
  const bar = $('#session-bar');
  if (bar) { bar.hidden = true; bar.innerHTML = ''; }
  const url = new URL(location.href);
  if (url.searchParams.has('session')) {
    url.searchParams.delete('session');
    history.replaceState(null, '', url);
  }
  markActiveSession(null);
  $('#messages').innerHTML =
    '<div class="welcome"><h2>👋 有什么想查的？</h2>' +
    '<p>用自然语言提问，我会生成 SQL 查询数据库，并用表格和图形展示结果。</p></div>';
  loadSuggestions();  // 新对话也刷新起始建议卡（后台 starter 变更即时生效）
}

// 审计 P2-2：订阅保存前确认「聊天里 AI 现写的 SQL」清单；返回 Promise<boolean>
function confirmChatRawSqls(list) {
  return new Promise(function (resolve) {
    const ov = document.createElement('div');
    ov.className = 'modal-overlay';
    const box = document.createElement('div');
    box.className = 'modal modal-wide';

    const head = document.createElement('div');
    head.className = 'modal-head';
    const title = document.createElement('div');
    title.className = 'modal-title';
    title.textContent = '📄 确认保存 AI 现写的 SQL（' + list.length + ' 条）';
    head.appendChild(title);
    box.appendChild(head);

    const tip = document.createElement('p');
    tip.className = 'hint';
    tip.style.cssText = 'margin:8px 0;font-size:12px;';
    tip.textContent = '订阅报告会将以下 SQL 写入个人 SQL 库（仅自己可见），请确认内容后继续。';
    box.appendChild(tip);

    const body = document.createElement('div');
    body.style.cssText = 'max-height:320px;overflow:auto;border:1px solid var(--border);border-radius:8px;';
    list.forEach(function (item) {
      const itemBox = document.createElement('div');
      itemBox.style.cssText = 'padding:8px 10px;border-bottom:1px solid var(--border);';
      const nm = document.createElement('div');
      nm.style.cssText = 'font-weight:600;font-size:13px;color:var(--text);';
      nm.textContent = item.name;
      const sq = document.createElement('pre');
      sq.style.cssText = 'margin:4px 0 0;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px;white-space:pre-wrap;word-break:break-all;color:var(--muted);';
      sq.textContent = item.sql + (item.truncated ? ' …（已截断）' : '');
      itemBox.appendChild(nm);
      itemBox.appendChild(sq);
      body.appendChild(itemBox);
    });
    box.appendChild(body);

    const btnRow = document.createElement('div');
    btnRow.style.cssText = 'display:flex;justify-content:flex-end;gap:8px;margin-top:12px;';
    const okBtn = document.createElement('button');
    okBtn.className = 'btn btn-primary';
    okBtn.textContent = '✅ 确认并订阅';
    const cancelBtn = document.createElement('button');
    cancelBtn.className = 'btn';
    cancelBtn.textContent = '取消';
    btnRow.appendChild(cancelBtn);
    btnRow.appendChild(okBtn);
    box.appendChild(btnRow);

    ov.appendChild(box);
    document.body.appendChild(ov);

    let settled = false;
    const esc = (e) => { if (e.key === 'Escape') close(false); };
    function close(ok) {
      if (settled) return;
      settled = true;
      document.removeEventListener('keydown', esc);
      ov.remove();
      resolve(ok);
    }
    document.addEventListener('keydown', esc);
    okBtn.addEventListener('click', () => close(true));
    cancelBtn.addEventListener('click', () => close(false));
    ov.addEventListener('click', (e) => { if (e.target === ov) close(false); });
  });
}

async function subscribeReport(msg) {
  const meta = msg._meta;
  const sql = msg._sql;
  const name = (msg._question || '订阅报告').slice(0, 40);
  const btn = msg.querySelector('.subscribe-btn');
  btn.textContent = '⏳ 订阅中…';
  btn.disabled = true;

  const payload = { name: name, source: 'chat', skill: null, docs: [], sqls: [], raw_sqls: [] };

  if (meta && meta.source === 'skill' && meta.skill) {
    payload.skill = meta.skill;
    try {
      const res = await fetch('/api/admin/skills/' + encodeURIComponent(meta.skill));
      const data = await res.json();
      payload.sqls = data.sqls || [];
      payload.docs = data.docs || [];
    } catch (e) { /* 忽略，回退到空 */ }
  } else if (sql) {
    const ts = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14);
    payload.raw_sqls = [{ name: 'chat_' + ts, sql: sql }];
  }

  try {
    // 审计 P2-2：先预览 AI 现写 SQL 清单；非空则弹确认框，用户确认后才真正创建订阅落盘
    const previewRes = await fetch('/api/reports/subscriptions/preview', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    if (!previewRes.ok) {
      const perr = await previewRes.json().catch(() => ({}));
      throw new Error(perr.detail || ('HTTP ' + previewRes.status));
    }
    const previewData = await previewRes.json();
    const rawList = previewData.raw_sqls || [];
    if (rawList.length && !(await confirmChatRawSqls(rawList))) {
      btn.textContent = '📡 订阅报告';
      btn.disabled = false;
      return;
    }
    const res = await fetch('/api/reports/subscriptions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    if (!res.ok) {
      const err = await res.json().catch(() => ({}));
      throw new Error(err.detail || res.status);
    }
    btn.textContent = '✅ 已订阅';
  } catch (e) {
    btn.textContent = '📡 订阅报告';
    btn.disabled = false;
    alert('订阅失败：' + e.message);
  }
}

// ---- 订阅报告调出（命中专项且有订阅时）----

function pad2(n) { return String(n).padStart(2, '0'); }
function fmtDate(d) { return d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate()); }

function rangeFromDays(n) {
  const end = new Date();
  const start = new Date(); start.setDate(start.getDate() - n);
  return { start: fmtDate(start), end: fmtDate(end), label: `最近${n}天（${fmtDate(start)} ~ ${fmtDate(end)}）` };
}
function monthRange(offset) {
  const now = new Date();
  const start = new Date(now.getFullYear(), now.getMonth() + offset, 1);
  const end = new Date(now.getFullYear(), now.getMonth() + offset + 1, 0);
  return { start: fmtDate(start), end: fmtDate(end), label: `${fmtDate(start)} ~ ${fmtDate(end)}` };
}
function weekRange(offset) {
  const now = new Date();
  const day = now.getDay() || 7;
  const start = new Date(now); start.setDate(now.getDate() - (day - 1) + offset * 7);
  const end = new Date(start); end.setDate(start.getDate() + 6);
  return { start: fmtDate(start), end: fmtDate(end), label: `${fmtDate(start)} ~ ${fmtDate(end)}` };
}

function extractDateRange(text) {
  if (!text) return null;
  let m = text.match(/(?:最近|近|过去)\s*(\d+)\s*天/);
  if (m) return rangeFromDays(parseInt(m[1], 10));
  m = text.match(/(?:最近|近|过去)\s*(\d+)\s*周/);
  if (m) return rangeFromDays(parseInt(m[1], 10) * 7);
  m = text.match(/(?:最近|近|过去)\s*(\d+)\s*个?月/);
  if (m) return rangeFromDays(parseInt(m[1], 10) * 30);
  if (/本月/.test(text)) return monthRange(0);
  if (/上月/.test(text)) return monthRange(-1);
  if (/本周/.test(text)) return weekRange(0);
  if (/上周/.test(text)) return weekRange(-1);
  m = text.match(/(\d{4})[-/](\d{1,2})[-/](\d{1,2})\s*(?:到|至|~|-)\s*(\d{4})[-/](\d{1,2})[-/](\d{1,2})/);
  if (m) {
    const start = `${m[1]}-${pad2(m[2])}-${pad2(m[3])}`;
    const end = `${m[4]}-${pad2(m[5])}-${pad2(m[6])}`;
    return { start, end, label: `${start} ~ ${end}` };
  }
  return null;
}

function conversationText() {
  const parts = transcript.filter((m) => m.role === 'user').map((m) => m.text);
  if (lastQuestion) parts.push(lastQuestion);
  return parts.join('；');
}

function renderSubActions(msg) {
  const box = msg.querySelector('.report-actions');
  if (!currentSubs || !currentSubs.length) return;
  box.hidden = false;
  box.innerHTML = '';

  const label = document.createElement('div');
  label.className = 'field-label';
  label.textContent = '📅 该专项已有订阅报告，可换日期调出：';
  box.appendChild(label);

  let selectedSub = currentSubs[0];
  const range = extractDateRange(conversationText());

  const dateRow = document.createElement('div');
  dateRow.className = 'sub-date';
  const startInput = document.createElement('input');
  startInput.type = 'date'; startInput.className = 'control sub-start';
  const endInput = document.createElement('input');
  endInput.type = 'date'; endInput.className = 'control sub-end';
  const dateText = document.createElement('span');
  dateText.className = 'sub-date-text';

  function syncDate() {
    const editing = dateRow.classList.contains('editing');
    if (range && !editing) {
      dateText.textContent = range.label;
      dateText.hidden = false;
      startInput.hidden = true; endInput.hidden = true;
      startInput.value = range.start; endInput.value = range.end;
    } else {
      dateText.hidden = true;
      startInput.hidden = false; endInput.hidden = false;
      if (!startInput.value) startInput.value = range ? range.start : '';
      if (!endInput.value) endInput.value = range ? range.end : '';
    }
  }

  const changeBtn = document.createElement('button');
  changeBtn.className = 'btn btn-sm';
  changeBtn.textContent = range ? '✏️ 修改日期' : '📅 选择日期';
  changeBtn.addEventListener('click', () => { dateRow.classList.toggle('editing'); syncDate(); });

  const runBtn = document.createElement('button');
  runBtn.className = 'btn btn-sm btn-primary sub-run-btn';
  runBtn.textContent = '🚀 调出订阅报告';
  runBtn.addEventListener('click', () => {
    const start = startInput.value || (range ? range.start : '');
    const end = endInput.value || (range ? range.end : '');
    if (!start || !end) { dateRow.classList.add('editing'); syncDate(); alert('请选择起止日期'); return; }
    runSubReport(box, selectedSub, start, end, runBtn);
  });

  dateRow.appendChild(dateText);
  dateRow.appendChild(startInput);
  dateRow.appendChild(endInput);
  dateRow.appendChild(changeBtn);
  dateRow.appendChild(runBtn);

  if (currentSubs.length > 1) {
    const sel = document.createElement('select');
    sel.className = 'control sub-select';
    currentSubs.forEach((s) => {
      const o = document.createElement('option');
      o.value = s.id; o.textContent = s.name;
      sel.appendChild(o);
    });
    sel.addEventListener('change', () => {
      selectedSub = currentSubs.find((s) => s.id === sel.value) || currentSubs[0];
    });
    box.appendChild(sel);
  }

  box.appendChild(dateRow);
  syncDate();
}

async function runSubReport(container, sub, start, end, btn) {
  if (btn) { btn.disabled = true; btn.textContent = '⏳ 生成中…'; }
  const body = {
    sqls: sub.sqls || [],
    mods: {},
    skill: sub.skill || null,
    docs: sub.docs || [],
    extra_prompt: sub.extra_prompt || '',
    start_date: start,
    end_date: end,
    subscription_id: sub.id,
    source: 'subscription',
  };

  const out = document.createElement('div');
  out.className = 'sub-report';
  const log = document.createElement('div');
  log.className = 'status-log';
  log.style.maxHeight = '200px';
  const finalBox = document.createElement('div');
  finalBox.className = 'markdown-body';
  finalBox.hidden = true;
  out.appendChild(log);
  out.appendChild(finalBox);
  container.appendChild(out);

  try {
    await streamChat(body, (ev) => {
      if (ev.type === 'stage') {
        log.textContent += ev.message + '\n';
        log.scrollTop = log.scrollHeight;
      } else if (ev.type === 'markdown') {
        if (ev.stage === 'final') {
          finalBox.hidden = false;
          renderMarkdownInto(finalBox, ev.markdown || '');
        }
      } else if (ev.type === 'report') {
        finalBox.hidden = false;
        renderMarkdownInto(finalBox, ev.report_md || '');
      } else if (ev.type === 'error') {
        log.textContent += '❌ ' + ev.message + '\n';
        log.scrollTop = log.scrollHeight;
      }
    }, '/api/reports/run');
  } catch (e) {
    log.textContent += '请求失败：' + e.message + '\n';
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = '✅ 已调出'; }
  }
}

// ---- 切页签时自动缓存当前对话 ----

function persistNow() {
  if (!transcript.some((m) => m.role === 'user')) return;
  const first = transcript.find((m) => m.role === 'user');
  const payload = { title: (first && first.text || '对话').slice(0, 40), messages: transcript.filter((m) => !m._confirmOnly), usage: buildUsagePayload() };
  const url = cacheSid ? '/api/chat-history/' + encodeURIComponent(cacheSid) : '/api/chat-history';
  const method = cacheSid ? 'PUT' : 'POST';
  try {
    fetch(url, { method: method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload), keepalive: true });
  } catch (e) { /* 忽略 */ }
}

// ---- 事件与初始化 ----

function updateInputHint() {
  const input = $('#input');
  if (state.skill) {
    input.placeholder = '可选：补充说明，如「只看美国」；留空直接按专项生成分析';
  } else {
    input.placeholder = '输入问题，例如：最近7天各国家流水趋势';
  }
}

// 起始建议卡（starter）：优先取后端 /api/agent/starters（后台可配置），
// 接口不可用 / 失败 / 返回为空时回落这套默认问题。
const FALLBACK_SUGGESTIONS = ['最近7天各国家流水趋势', '各商品流水构成', '各国 ARPU 对比', '最近30天流水达成'];

function renderSuggestions(list) {
  const box = $('#suggestions');
  if (!box) return;
  box.innerHTML = '';
  list.forEach((t) => {
    // 兼容两种条目：后端 /api/agent/starters 返回对象 {id, text, game_keys}，回落路径是纯字符串；
    // 对象直接赋值会被字符串化成 "[object Object]"（对抗审查修复）
    const text = (t && typeof t === 'object') ? (t.text || '') : t;
    if (!text) return;
    const chip = document.createElement('button');
    chip.className = 'chip';
    chip.textContent = text;
    chip.addEventListener('click', () => { $('#input').value = text; sendMessage(); });
    box.appendChild(chip);
  });
}

async function loadSuggestions() {
  try {
    // 零权限用户不给起始建议卡（无游戏可查，引导先联系管理员）
    if (zeroPerm) { renderSuggestions([]); return; }
    // 与 streamChat 相同的认证方式（auth.js 包装的 window.fetch 自动附令牌）
    const resp = await fetch('/api/agent/starters', { headers: { 'Content-Type': 'application/json' } });
    if (resp.ok) {
      const data = await resp.json().catch(() => null);
      if (data && Array.isArray(data.starters) && data.starters.length) {
        renderSuggestions(data.starters);
        return;
      }
    }
  } catch (e) { /* 接口失败静默回落默认建议 */ }
  renderSuggestions(FALLBACK_SUGGESTIONS);
}

function bindEvents() {
  $('#model-select').addEventListener('change', (e) => {
    // 用户显式改选才回传 model；否则不传，由后端按「主对话」槽位解析（模型管理可统一调整，2026-10-26）
    state.model = e.target.value;
    state.modelExplicit = true;
  });
  $('#skill-select').addEventListener('change', (e) => { state.skill = e.target.value || null; updateInputHint(); });
  $('#send').addEventListener('click', sendMessage);
  $('#stop').addEventListener('click', stopGeneration);
  $('#new-chat').addEventListener('click', newConversation);
  $('#input').addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(); }
  });
  window.addEventListener('pagehide', persistNow);
  updateInputHint();
}

async function init() {
  await ensureLibs();
  try { await Promise.all([loadModels(), loadSkills(), loadSqlNames(), loadModelNames()]); }
  catch (e) { console.warn('初始化部分失败', e); }
  bindEvents();
  await initGamePanel();  // 零权限判定先行：横幅/禁发送/起始建议都依赖它
  loadSuggestions();
  await restoreSessionFromUrl();
  loadSidebarHistory();
}

document.addEventListener('DOMContentLoaded', init);
