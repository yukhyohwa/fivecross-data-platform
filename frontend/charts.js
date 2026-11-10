'use strict';

/* ECharts 渲染 + 表格渲染。spec 结构：{chart_type, x, x_data, series[]} */

/* 统一专业主题：图表字体、坐标轴、网格线、图例，替代 ECharts 默认灰底样式。
   具体配色仍在 buildOption/palette 里按图表给，这里只兜底默认样式。 */
(function registerTheme() {
  if (typeof echarts === 'undefined' || !echarts.registerTheme) return;
  echarts.registerTheme('chatbi', {
    color: palette(7),
    textStyle: {
      fontFamily: '-apple-system, "Segoe UI", "Microsoft YaHei", "PingFang SC", sans-serif',
    },
    legend: { textStyle: { color: '#5b6478', fontSize: 12 } },
    categoryAxis: {
      axisLine: { lineStyle: { color: '#c8cedb' } },
      axisLabel: { color: '#7a8294' },
      axisTick: { show: false },
    },
    valueAxis: {
      axisLine: { show: false },
      axisLabel: { color: '#7a8294' },
      axisTick: { show: false },
      splitLine: { lineStyle: { color: '#eef1f6', type: 'dashed' } },
    },
  });
})();

/* 当前图表主题：可在「报告放大」头部切换，存 localStorage 跨会话记忆。
   默认 chatbi（上方的统一兜底样式），另可切官方 vintage/macarons/infographic/shine。 */
let ACTIVE_THEME = 'chatbi';
try { ACTIVE_THEME = localStorage.getItem('chatbi_theme') || 'chatbi'; } catch (e) { /* 隐私模式等场景忽略 */ }
const CHART_THEMES = ['chatbi', 'vintage', 'macarons', 'infographic', 'shine'];
const _chartEls = new Set();

function getChartTheme() { return ACTIVE_THEME; }
function listChartThemes() { return CHART_THEMES.slice(); }

/* 释放单个图表容器上的 ECharts 实例，并从全局登记表移除（容器可能已被移出 DOM）。 */
function disposeChart(el) {
  if (!el) return;
  if (el._chart) { try { el._chart.dispose(); } catch (e) { /* 忽略 */ } el._chart = null; }
  _chartEls.delete(el);
}

/* 释放 root（含自身）内所有已渲染图表，供清空/移除图表容器前调用，避免 ECharts 实例泄漏。 */
function disposeChartsIn(root) {
  if (!root) return;
  if (root._chart) disposeChart(root);
  if (root.querySelectorAll) root.querySelectorAll('[data-chart]').forEach(disposeChart);
}

/* 切换主题：重渲染所有仍挂在页面上的图（内嵌报告卡片与放大弹窗统一生效）。 */
function setChartTheme(name) {
  if (!CHART_THEMES.includes(name)) return;
  ACTIVE_THEME = name;
  try { localStorage.setItem('chatbi_theme', name); } catch (e) { /* 忽略 */ }
  _chartEls.forEach((el) => {
    if (!el.isConnected) { disposeChart(el); return; }
    disposeChart(el);
    try {
      el._chart = echarts.init(el, ACTIVE_THEME);
      el._chart.setOption(buildOption(el._spec, el._type), true);
    } catch (e) { el._chart = null; }
  });
}

/* 导出报告用：把 root 内所有图表快照成 PNG dataURL（不改原图，保持原报告可交互）。 */
function snapshotChartUrls(root) {
  const urls = [];
  (root.querySelectorAll('[data-chart]') || []).forEach((el) => {
    let url = '';
    try { url = el._chart ? el._chart.getDataURL({ type: 'png', pixelRatio: 2, backgroundColor: '#ffffff' }) : ''; } catch (e) { url = ''; }
    urls.push(url);
  });
  return urls;
}

/* 导出报告用：把克隆体 clone 里对应位置的图表容器替换成 <img> 快照（静态、可打印/分享）。 */
function applyChartSnapshots(clone, urls) {
  const els = clone.querySelectorAll('[data-chart]') || [];
  els.forEach((el, i) => {
    el.innerHTML = '';
    if (urls && urls[i]) {
      const img = document.createElement('img');
      img.src = urls[i];
      img.alt = '图表';
      img.style.cssText = 'width:100%;height:auto;display:block;';
      el.appendChild(img);
    }
  });
  return els.length;
}

function renderChart(el, spec, type) {
  if (typeof echarts === 'undefined') {
    el.innerHTML = '<div class="hint">图表库未加载</div>';
    return;
  }
  if (!spec || !spec.series || !spec.series.length) {
    el.innerHTML = '<div class="hint">无可绘图数据</div>';
    return;
  }
  disposeChart(el);
  el._spec = spec;
  el._type = type;
  el.setAttribute('data-chart', '');   // 标记图表容器，供「导出报告」快照定位
  _chartEls.add(el);
  const chart = echarts.init(el, ACTIVE_THEME);
  chart.setOption(buildOption(spec, type), true);
  el._chart = chart;
}

function buildOption(spec, type) {
  const x = spec.x_data || [];
  if (type === 'pie') {
    const s = spec.series[0];
    const d = (s && Array.isArray(s.data)) ? s.data : [];
    const data = x.map((name, i) => ({ name: String(name), value: d[i] }));
    return {
      color: palette(data.length),
      tooltip: {
        trigger: 'item',
        formatter: '{b}: {c} ({d}%)',
        backgroundColor: '#ffffff',
        borderColor: '#e6e9f0',
        borderWidth: 1,
        padding: [8, 12],
        textStyle: { color: '#1f2430', fontSize: 12 },
        extraCssText: 'box-shadow:0 8px 24px rgba(15,23,42,.12);border-radius:8px;',
      },
      legend: { type: 'scroll', bottom: 0 },
      series: [{
        type: 'pie',
        radius: ['35%', '68%'],
        data,
        label: { formatter: '{b}: {d}%' },
      }],
    };
  }
  const isStack = type === 'stack_bar';
  const barType = (type === 'bar' || isStack) ? 'bar' : type;
  const rightSet = new Set((spec.y_axes && spec.y_axes.right) || []);
  const hasDual = rightSet.size > 0;
  const multi = spec.series.length > 1;
  const showBarLabels = type === 'bar' && !multi && x.length <= 12;
  // 堆叠段内标注「数值 + 占比」：周对比图（付费国家/商品构成、喵果消耗）的 2 根周期柱
  const stackPct = isStack && !!spec.stack_pct_label;
  const stackTotals = stackPct
    ? x.map((_, i) => spec.series.reduce((s, sr) => s + (Number(sr.data[i]) || 0), 0))
    : null;
  const axisBase = { type: 'value', splitLine: { lineStyle: { type: 'dashed', color: '#eef1f6' } }, axisLine: { show: false }, axisTick: { show: false }, axisLabel: { color: '#7a8294' } };
  return {
    color: palette(spec.series.length),
    tooltip: {
      trigger: 'axis',
      backgroundColor: '#ffffff',
      borderColor: '#e6e9f0',
      borderWidth: 1,
      padding: [8, 12],
      textStyle: { color: '#1f2430', fontSize: 12 },
      extraCssText: 'box-shadow:0 8px 24px rgba(15,23,42,.12);border-radius:8px;',
      valueFormatter: (v) => (v == null ? '-' : Number(v).toLocaleString()),
    },
    legend: multi ? { type: 'scroll', top: 0 } : undefined,
    grid: { left: 8, right: hasDual ? 8 : 16, top: multi ? 40 : 24, bottom: 8, containLabel: true },
    xAxis: {
      type: 'category',
      data: x,
      boundaryGap: type === 'bar' || isStack,
      axisLine: { lineStyle: { color: '#c3c9d6' } },
      axisTick: { show: false },
    },
    yAxis: hasDual
      ? [axisBase, { type: 'value', splitLine: { show: false }, axisLine: { show: false }, axisTick: { show: false } }]
      : axisBase,
    series: spec.series.map((s) => ({
      name: s.name,
      type: barType,
      stack: isStack ? 'total' : undefined,
      data: s.data,
      yAxisIndex: rightSet.has(s.name) ? 1 : 0,
      smooth: type === 'line',
      label: showBarLabels
        ? { show: true, position: 'top', formatter: (p) => (p.value == null ? '' : Number(p.value).toLocaleString()) }
        : (stackPct
          ? {
              show: true,
              position: 'inside',
              color: '#fff',
              fontSize: 10,
              formatter: (p) => {
                const total = stackTotals[p.dataIndex] || 0;
                const v = Number(p.value) || 0;
                const pct = total ? (v / total * 100) : 0;
                return Number(v).toLocaleString() + '\n' + pct.toFixed(1) + '%';
              },
            }
          : undefined),
    })),
  };
}

function palette(n) {
  // 审计 P1-23 ④：唯一色源为 ide_frontend/src/lib/palette.ts（BRAND_PALETTE）；vanilla 无构建，
  // 此处 base 数组与其同源——改色必须两处同步改。
  const base = ['#4f7cff', '#e8546b', '#9a6bff', '#b8860b', '#2f9e5f', '#0d97a5', '#d95f2e'];
  const out = [];
  for (let i = 0; i < n; i++) out.push(base[i % base.length]);
  return out;
}

function renderTable(el, table, sql, name) {
  disposeChart(el);   // 该容器可能刚渲染过图表，先释放 ECharts 实例再覆写为表格
  el.removeAttribute('data-chart');   // 表格态不再是图表槽位，避免导出报告快照把它当图表清空
  el.innerHTML = '';
  if (!table || !table.columns || !table.columns.length) {
    el.innerHTML = '<div class="hint">无数据</div>';
    return;
  }
  const rows = Array.isArray(table.rows) ? table.rows : [];
  const total = table.total_rows != null ? table.total_rows : rows.length;

  // 行数较多时默认只展示前 10 行，其余折叠，可手动展开/收起
  const COLLAPSE_AT = 10;
  const extraCount = Math.max(0, rows.length - COLLAPSE_AT);
  let expanded = false;

  const cap = document.createElement('div');
  cap.className = 'table-cap';
  cap.textContent = extraCount > 0
    ? '共 ' + total + ' 行 · 默认展示前 10 行，剩余已折叠'
    : '共 ' + total + ' 行';
  const exportList = (table && Array.isArray(table.__export) && table.__export.length) ? table.__export : null;
  if (sql || exportList) {
    const exp = document.createElement('button');
    exp.className = 'btn btn-sm';
    exp.style.marginLeft = '8px';
    exp.textContent = '⬇️ 导出 CSV';
    exp.title = exportList
      ? '按多游戏各自的 SQL 逐库重查并拼接导出全量 CSV（可 Excel 打开）'
      : '按本次查询的 SQL 重跑并导出全量 CSV（可 Excel 打开）';
    exp.addEventListener('click', () => exportCsv(sql, name, exportList, (table && table.__db) || null));
    cap.appendChild(exp);
  }
  if (extraCount > 0) {
    const toggle = document.createElement('button');
    toggle.className = 'btn btn-sm';
    toggle.style.marginLeft = '8px';
    toggle.textContent = '展开剩余 ' + extraCount + ' 行';
    toggle.addEventListener('click', () => {
      expanded = !expanded;
      if (expanded && builtCount < rows.length) buildRows(builtCount);
      el.querySelectorAll('tbody tr.extra').forEach((tr) => { tr.hidden = !expanded; });
      toggle.textContent = expanded ? '收起' : ('展开剩余 ' + extraCount + ' 行');
    });
    cap.appendChild(toggle);
  }
  el.appendChild(cap);

  const wrap = document.createElement('div');
  wrap.className = 'table-scroll';
  const t = document.createElement('table');
  t.className = 'data-table';

  const thead = document.createElement('thead');
  const trh = document.createElement('tr');
  table.columns.forEach((c) => {
    const th = document.createElement('th');
    th.textContent = c;
    trh.appendChild(th);
  });
  thead.appendChild(trh);
  t.appendChild(thead);

  const tbody = document.createElement('tbody');
  // 判断各列是否数值列（用于右对齐 + 等宽数字）：非空值全为数字即视为数值列
  const numCols = table.columns.map((c, i) => {
    let has = false;
    for (const r of rows) {
      const v = r[i];
      if (v === null || v === undefined || v === '') continue;
      if (typeof v === 'number' && isFinite(v)) { has = true; continue; }
      return false;
    }
    return has;
  });

  // 惰性建行：先只渲染前 COLLAPSE_AT 行，展开时再补建剩余行，避免大结果集卡顿
  let builtCount = 0;
  function makeRow(row, idx) {
    const tr = document.createElement('tr');
    if (idx >= COLLAPSE_AT) { tr.classList.add('extra'); tr.hidden = true; }
    table.columns.forEach((c, i) => {
      const td = document.createElement('td');
      const v = row[i];
      td.textContent = (v === null || v === undefined || v === '') ? '—' : v;
      if (i > 0 && numCols[i]) td.classList.add('num');
      tr.appendChild(td);
    });
    return tr;
  }
  function buildRows(fromIdx) {
    for (let idx = fromIdx; idx < rows.length; idx++) {
      tbody.appendChild(makeRow(rows[idx], idx));
    }
    builtCount = rows.length;
  }
  for (let idx = 0; idx < Math.min(COLLAPSE_AT, rows.length); idx++) {
    tbody.appendChild(makeRow(rows[idx], idx));
  }
  builtCount = Math.min(COLLAPSE_AT, rows.length);

  t.appendChild(tbody);

  wrap.appendChild(t);
  el.appendChild(wrap);
}

async function exportCsv(sql, name, sqls, db) {
  try {
    // sqls=[{sql, db, label}]：多游戏表导出——后端逐库重查拼「地区」列；
    // 单库路径传 sql（可选 db：哨兵「不选游戏」模式后端无 game，需显式指定库）
    const body = { sql: sql || '', name: name || 'export' };
    if (db) body.db = db;
    if (sqls && sqls.length) {
      body.sql = '';
      body.sqls = sqls;
    }
    const resp = await fetch('/api/chat/export-csv', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    if (!resp.ok) {
      const err = await resp.json().catch(() => ({}));
      alert('导出失败：' + (err.detail || resp.status));
      return;
    }
    const blob = await resp.blob();
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = (name || 'export') + '.csv';
    document.body.appendChild(a);
    a.click();
    a.remove();
    // 延迟释放，避免部分浏览器在点击与下载开始之间就回收了 blob 导致下载失败
    setTimeout(() => { URL.revokeObjectURL(a.href); }, 1000);
  } catch (e) {
    alert('导出失败：' + (e && e.message ? e.message : e));
  }
}

window.addEventListener('resize', () => {
  document.querySelectorAll('.chart').forEach((el) => {
    if (el._chart) el._chart.resize();
  });
});

/* 兜底：图表容器被移出 DOM（清空、翻页、关弹窗）时释放其 ECharts 实例，避免内存泄漏。 */
if (typeof MutationObserver !== 'undefined') {
  new MutationObserver((muts) => {
    muts.forEach((m) => {
      m.removedNodes.forEach((node) => {
        if (node.nodeType !== 1) return;
        if (node._chart) disposeChart(node);
        if (node.querySelectorAll) node.querySelectorAll('[data-chart]').forEach(disposeChart);
      });
    });
  }).observe(document.body, { childList: true, subtree: true });
}

/* 离开/刷新页面前释放全部 ECharts 实例。 */
window.addEventListener('pagehide', () => {
  _chartEls.forEach((el) => { disposeChart(el); });
});
