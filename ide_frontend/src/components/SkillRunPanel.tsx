import React, { useEffect, useMemo, useState } from 'react';
import ReactECharts from 'echarts-for-react';
import { marked } from 'marked';
import { useStore } from '../stores/useStore';
import { abortSkillGaps, abortSkillStream, requestSkillGaps } from '../services/skillRun';
import { sanitizeHtml } from '../lib/sanitizeHtml';
import { useDialog } from '../lib/useDialog';
import { CircleAlert, CircleCheck, Loader2, Maximize2, Play, Square, Trash2, X } from 'lucide-react';

/** 表格展示行数上限（面板内看前 N 行，CSV 导出全量） */
const MAX_TABLE_ROWS = 200;

const badge: React.CSSProperties = {
  display: 'inline-flex', alignItems: 'center', gap: 4, fontSize: 11, fontWeight: 600,
};
const btn: React.CSSProperties = {
  display: 'inline-flex', alignItems: 'center', gap: 4, padding: '2px 8px', fontSize: 11,
  borderRadius: 4, border: '1px solid var(--text-muted)', background: 'var(--surface-1)',
  color: 'var(--text-secondary)', cursor: 'pointer', whiteSpace: 'nowrap',
};
const miniBtn: React.CSSProperties = {
  padding: '1px 7px', fontSize: 10, borderRadius: 3, border: '1px solid var(--text-muted)',
  background: 'transparent', color: 'var(--text-muted)', cursor: 'pointer', whiteSpace: 'nowrap',
};
const empty: React.CSSProperties = {
  display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center',
  height: '100%', gap: 8, color: 'var(--text-inactive)', fontSize: 12,
};

function fmt(v: unknown): string {
  if (v === null || v === undefined) return 'NULL';
  return String(v);
}

/** CSV 导出（带 BOM，Excel 直接打开不乱码；同 ResultTable 口径）。
 *  rows 是「行数组的数组」[[v,v,...], ...]（后端 df_to_table 用 orient="split"），按列下标取值，不是对象。 */
function exportCsv(columns: string[], rows: unknown[][]): void {
  const esc = (s: string) => /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
  const lines = [columns.map(esc).join(',')];
  for (const r of rows) lines.push(columns.map((_, i) => esc(fmt(r[i]))).join(','));
  const blob = new Blob(['﻿' + lines.join('\n')], { type: 'text/csv;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = 'skill_run.csv';
  a.click();
  URL.revokeObjectURL(url);
}

type RunTable = { name: string | null; table: { columns: string[]; rows: unknown[][] }; sql: string | null };

/** 图表 + 配对表格块：按 spec.name 配对（同聊天窗口 renderViz 口径），无图表时表格单独成块 */
const RunBlock: React.FC<{ chart: any; table: RunTable | null }> = ({ chart, table }) => {
  const [showSql, setShowSql] = useState(false);
  const [showTable, setShowTable] = useState(true);
  const columns = table?.table.columns || [];
  const rows = table?.table.rows || [];
  const shown = rows.slice(0, MAX_TABLE_ROWS);
  return (
    <div style={{ border: '1px solid var(--border-light)', borderRadius: 6, marginBottom: 10, overflow: 'hidden', backgroundColor: 'var(--surface-0)' }}>
      {chart && (
        <div style={{ borderBottom: '1px solid var(--border-light)' }}>
          <ReactECharts option={chart} style={{ height: 300, width: '100%' }} opts={{ renderer: 'canvas' }} notMerge={true} />
        </div>
      )}
      {table && (
        <div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '4px 8px', borderBottom: '1px solid var(--border-light)', flexWrap: 'wrap' }}>
            {table.name && <span style={{ fontSize: 11, color: 'var(--text-secondary)', fontWeight: 600 }}>📊 {table.name}</span>}
            <button onClick={() => setShowTable((v) => !v)} style={miniBtn} title={showTable ? '隐藏数据' : '显示数据'}>
              {showTable ? '隐藏数据' : '显示数据'}（{rows.length} 行）
            </button>
            {table.sql && (
              <button onClick={() => setShowSql((v) => !v)} style={miniBtn}>{showSql ? '隐藏 SQL' : 'SQL'}</button>
            )}
            <button onClick={() => exportCsv(columns, rows)} style={miniBtn} title="导出全量数据为 CSV">⬇ CSV</button>
            <div style={{ flex: 1 }} />
          </div>
          {showSql && table.sql && (
            <pre style={{ margin: 0, padding: '8px 10px', fontSize: 11, lineHeight: 1.5, background: 'var(--surface-1)', borderBottom: '1px solid var(--border-light)', overflowX: 'auto', color: 'var(--text-secondary)', whiteSpace: 'pre-wrap' }}>{table.sql}</pre>
          )}
          {showTable && (
            <div style={{ overflow: 'auto', maxHeight: 300 }}>
              <table style={{ borderCollapse: 'collapse', fontSize: 11, whiteSpace: 'nowrap', width: '100%' }}>
                <thead>
                  <tr>{columns.map((c) => (
                    <th key={c} style={{ position: 'sticky', top: 0, background: 'var(--surface-2)', color: 'var(--accent-amber-text)', fontWeight: 600, textAlign: 'left', padding: '4px 8px', border: '1px solid var(--border-light)' }}>{c}</th>
                  ))}</tr>
                </thead>
                <tbody>
                  {shown.map((r, ri) => (
                    <tr key={ri} style={ri % 2 ? { background: 'var(--surface-1)' } : undefined}>
                      {columns.map((c, i) => (
                        <td key={c} style={{ padding: '3px 8px', border: '1px solid var(--border-light)', color: 'var(--text-primary)' }}>{fmt(r[i])}</td>
                      ))}
                    </tr>
                  ))}
                </tbody>
              </table>
              {rows.length > MAX_TABLE_ROWS && (
                <div style={{ padding: '4px 8px', fontSize: 11, color: 'var(--text-muted)', borderTop: '1px solid var(--border-light)' }}>
                  仅显示前 {MAX_TABLE_ROWS} 行，共 {rows.length} 行（⬇ CSV 导出全量）
                </div>
              )}
            </div>
          )}
        </div>
      )}
    </div>
  );
};

/** 放大弹窗：近乎全屏地展示整体展现面板（报告正文 + 图表 + 表格 + 用量），
 * 供「执行结果」下半区空间不足时查看全貌。 */
const enlargeOverlay: React.CSSProperties = {
  position: 'fixed', inset: 0, backgroundColor: 'rgba(0,0,0,0.5)',
  display: 'flex', alignItems: 'center', justifyContent: 'center',
  zIndex: 'var(--z-top)', padding: 16,
};
const enlargeDialog: React.CSSProperties = {
  backgroundColor: 'var(--surface-2)', border: '1px solid var(--border-light)', borderRadius: 8,
  width: 'min(1200px, 96vw)', height: 'min(860px, 92vh)',
  display: 'flex', flexDirection: 'column', overflow: 'hidden',
  boxShadow: '0 8px 30px rgba(0,0,0,0.3)',
};

/** 执行结果正文（面板与放大弹窗共用）：方法引用 / 运行过程 / 错误 / 报告 markdown / 图表表格 / 用量。
 *  （缺口建议入口已上提到面板头部 strip，不进本组件——放大弹窗只做报告内容展示。） */
const RunBody: React.FC<{ run: any; blocks: { chart: any; table: RunTable | null }[] }> = ({ run, blocks }) => {
  const usage = run.usage;
  const tokens = usage
    ? ((usage.prompt_tokens ?? 0) + (usage.completion_tokens ?? 0)) || usage.total_tokens || 0
    : 0;
  return (
    <div style={{ padding: '10px 12px', fontSize: 12, lineHeight: 1.7 }}>
      {run.meta?.source === 'skill' && run.meta.skill && (
        <div style={{ color: 'var(--accent-amber-text)', fontSize: 11, fontWeight: 600, marginBottom: 6 }}>🎯 引用专项分析方法：{run.meta.skill}</div>
      )}

      {run.steps.length > 0 && (
        <details style={{ marginBottom: 8 }}>
          <summary style={{ cursor: 'pointer', color: 'var(--text-muted)', fontSize: 11 }}>运行过程（{run.steps.length} 步）</summary>
          <ol style={{ margin: '4px 0 0', paddingLeft: 18, color: 'var(--text-secondary)', fontSize: 11, maxHeight: 180, overflowY: 'auto' }}>
            {run.steps.map((s: any, i: number) => <li key={i}>{s}</li>)}
          </ol>
        </details>
      )}

      {run.error && (
        <div style={{ color: 'var(--danger)', fontSize: 12, fontWeight: 600, marginBottom: 8 }}>⚠️ {run.error}</div>
      )}

      {run.answer && (
        <div className="agent-reply" style={{ color: 'var(--text-primary)', marginBottom: 10 }} dangerouslySetInnerHTML={{ __html: sanitizeHtml(marked.parse(run.answer) as string) }} />
      )}

      {blocks.map((b, i) => <RunBlock key={i} chart={b.chart} table={b.table} />)}

      {usage && (tokens > 0 || usage.cost != null) && (
        <div style={{ color: 'var(--text-muted)', fontSize: 11, marginTop: 2 }}>
          用量：{tokens} tokens{usage.cost != null ? ` · 费用 ${usage.cost}` : ''}
        </div>
      )}
    </div>
  );
};

/** 专项执行结果面板（专项管理工作台下半区「执行结果」页签）：状态行/运行过程/报告 markdown/图表+表格/用量。
 *  空态 = 尚未执行：提示点左侧竖条「执行」。
 *  onOpenAgent：打开 AI源生 栏（缺口建议卡渲染在那边）——这里给一键打开入口。 */
export const SkillRunPanel: React.FC<{ onOpenAgent?: () => void }> = ({ onOpenAgent }) => {
  const run = useStore((s) => s.skillRun);
  const updateSkillRun = useStore((s) => s.updateSkillRun);
  const clearSkillRun = useStore((s) => s.clearSkillRun);
  const gapStatus = useStore((s) => s.skillGapStatus);

  // 「放大」查看整体展现面板（全屏弹窗）
  const [enlarged, setEnlarged] = useState(false);
  const enlargeRef = useDialog(enlarged, () => setEnlarged(false));

  // 缺口分析进行中的耗时（进度条旁展示，说明没卡住）
  const [gapElapsed, setGapElapsed] = useState(0);
  useEffect(() => {
    if (!gapStatus.running) { setGapElapsed(0); return; }
    const t0 = Date.now();
    setGapElapsed(0);
    const id = setInterval(() => setGapElapsed(Math.round((Date.now() - t0) / 1000)), 500);
    return () => clearInterval(id);
  }, [gapStatus.running]);

  // 手动触发「提炼修改建议」（报告缺口与补数建议，写入 store 后由 AI源生 消费渲染）
  const triggerGaps = () => {
    if (!run) return;
    requestSkillGaps(run.skill, run.answer, run.seq);
  };

  // 图表与表格按 name 配对（同聊天窗口 renderViz 口径）：有图表时每图一块（带配对表），无图表时表格单独成块
  const blocks = useMemo(() => {
    if (!run || !run.tables.length) return [];
    const charts = run.charts || [];
    if (charts.length) {
      return charts.map((spec, i) => {
        const hit = (spec?.name && run.tables.find((t) => t.name === spec.name)) || run.tables[i] || null;
        return { chart: spec, table: hit };
      });
    }
    return run.tables.map((t) => ({ chart: null, table: t }));
  }, [run]);

  if (!run) {
    return (
      <div style={empty}>
        <Play size={20} />
        <span>点击左侧竖条「▶ 执行」在本窗口运行当前专项，结果展示在这里</span>
      </div>
    );
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%', minHeight: 0, overflow: 'hidden' }}>
      {/* 头部：专项名 + 状态 + 停止/清空 */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 10px', borderBottom: '1px solid var(--border-light)', flexShrink: 0, flexWrap: 'wrap', backgroundColor: 'var(--surface-1)' }}>
        <span style={{ fontSize: 12, fontWeight: 600, color: 'var(--text-primary)', whiteSpace: 'nowrap' }}>🎯 {run.skill}</span>
        {run.running ? (
          <span style={{ ...badge, color: 'var(--accent-blue)' }}>
            <Loader2 size={11} style={{ animation: 'spin 1.2s linear infinite' }} /> {run.status || '执行中…'}
          </span>
        ) : run.error ? (
          <span style={{ ...badge, color: 'var(--danger)' }}><CircleAlert size={11} /> {run.status}</span>
        ) : (
          <span style={{ ...badge, color: '#27ae60' }}>
            <CircleCheck size={11} /> {run.status}
            {run.elapsed != null ? ` · ${Number(run.elapsed).toFixed(1)}s` : ''}
          </span>
        )}
        <div style={{ flex: 1 }} />
        {run.running && (
          <button onClick={() => { abortSkillStream(); updateSkillRun({ running: false, status: '已停止' }); }} style={btn} title="停止执行">
            <Square size={11} /> 停止
          </button>
        )}
        {(run.answer || blocks.length > 0) && (
          <button onClick={() => setEnlarged(true)} style={btn} title="放大查看整体展现面板">
            <Maximize2 size={11} /> 放大
          </button>
        )}
        <button onClick={() => { abortSkillStream(); abortSkillGaps(); clearSkillRun(); }} style={btn} title="清空执行结果">
          <Trash2 size={11} /> 清空
        </button>
      </div>

      {/* 报告缺口与补数建议（2026-10-29 起手动触发）：执行成功后点按钮提炼，进度条 + 中断 */}
      {!run.running && !run.error && run.answer && run.meta?.source === 'skill' && (
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 10px', borderBottom: '1px solid var(--border-light)', flexShrink: 0, flexWrap: 'wrap', backgroundColor: 'var(--tint-blue-bg)' }}>
          {run.gapSeq != null ? (
            <>
              <span style={{ fontSize: 11, color: 'var(--text-primary)', fontWeight: 600 }}>🔍 报告缺口与补数建议已生成</span>
              {onOpenAgent && (
                <button onClick={onOpenAgent} style={{ ...miniBtn, color: 'var(--accent-blue)', borderColor: 'var(--accent-blue)' }}>打开 AI源生 查看 →</button>
              )}
            </>
          ) : gapStatus.running ? (
            <>
              <Loader2 size={12} style={{ color: 'var(--accent-blue)', animation: 'spin 1s linear infinite', flexShrink: 0 }} />
              <span style={{ fontSize: 11, color: 'var(--text-primary)', whiteSpace: 'nowrap' }}>正在提炼修改建议…</span>
              <div style={{ position: 'relative', height: 4, background: 'var(--surface-1)', borderRadius: 2, overflow: 'hidden', flex: '1 1 60px', minWidth: 60 }}>
                <div style={{ position: 'absolute', top: 0, left: 0, height: '100%', width: '30%', background: 'var(--accent-blue)', borderRadius: 2, animation: 'progress-indeterminate 1.2s ease-in-out infinite' }} />
              </div>
              {gapElapsed > 0 && <span style={{ fontSize: 10, color: 'var(--text-muted)', fontVariantNumeric: 'tabular-nums', whiteSpace: 'nowrap' }}>{gapElapsed}s</span>}
              <button onClick={() => abortSkillGaps()} style={btn} title="中断提炼修改建议">
                <Square size={11} /> 中断
              </button>
            </>
          ) : (
            <>
              <span style={{ fontSize: 11, color: gapStatus.error ? 'var(--danger)' : 'var(--text-primary)', flex: '1 1 auto' }}>
                {gapStatus.error ? `⚠️ ${gapStatus.error}` : '🧠 提炼专项修改建议（缺口分析）'}
              </span>
              <button onClick={triggerGaps} style={btn} title="提炼报告缺口与补数建议到 AI源生">
                {gapStatus.error ? '↻ 重试' : '🧠 提炼修改建议'}
              </button>
            </>
          )}
        </div>
      )}

      <div style={{ flex: 1, minHeight: 0, overflowY: 'auto' }}>
        <RunBody run={run} blocks={blocks} />
      </div>

      {/* 放大：全屏查看整体展现面板 */}
      {enlarged && (
        <div ref={enlargeRef} tabIndex={-1} style={enlargeOverlay} onClick={(e) => { if (e.target === e.currentTarget) setEnlarged(false); }}>
          <div style={enlargeDialog} role="dialog" aria-modal="true" aria-label="整体展现面板">
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '10px 14px', borderBottom: '1px solid var(--border-light)', flexShrink: 0, backgroundColor: 'var(--surface-1)' }}>
              <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--text-primary)', whiteSpace: 'nowrap' }}>🎯 {run.skill}</span>
              {run.error ? (
                <span style={{ ...badge, color: 'var(--danger)' }}><CircleAlert size={11} /> {run.status}</span>
              ) : (
                <span style={{ ...badge, color: '#27ae60' }}><CircleCheck size={11} /> {run.status}</span>
              )}
              <div style={{ flex: 1 }} />
              <button onClick={() => setEnlarged(false)} style={btn} title="关闭">
                <X size={11} /> 关闭
              </button>
            </div>
            <div style={{ flex: 1, minHeight: 0, overflowY: 'auto' }}>
              <RunBody run={run} blocks={blocks} />
            </div>
          </div>
        </div>
      )}
    </div>
  );
};

export default SkillRunPanel;
