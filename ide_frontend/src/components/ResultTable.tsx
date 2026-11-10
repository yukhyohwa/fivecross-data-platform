import React, { useState, lazy, Suspense } from 'react';
import { useStore } from '../stores/useStore';
import { overlayStyle, dialogStyle, saveCancelBtn, dangerBtn } from './wsCommon';
import { useDialog } from '../lib/useDialog';
import { Loader2, AlertCircle, CheckCircle, Download, X, LayoutGrid, Trash2, Table2, BarChart3 } from 'lucide-react';

const ChartView = lazy(() => import('./ChartView').then((m) => ({ default: m.ChartView })));

/* ---- helpers ---- */

function exportCSV(columns: string[], rows: Record<string, unknown>[]) {
  const header = columns.map((c) => `"${c}"`).join(',');
  const data = rows.map((r) => columns.map((c) => {
    const v = r[c];
    if (v === null || v === undefined) return '';
    return `"${String(v).replace(/"/g, '""')}"`;
  }).join(',')).join('\n');
  const csv = `﻿${header}\n${data}`;
  const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `query_${new Date().toISOString().slice(0, 19).replace(/[T:]/g, '-')}.csv`;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}

/* ---- component ---- */

export const ResultTable: React.FC = () => {
  const {
    resultTabs,
    activeResultTabId,
    isExecuting,
    switchResultTab,
    closeResultTab,
    clearAgentResultTabs,
  } = useStore();

  const [chartModes, setChartModes] = useState<Record<number, boolean>>({});
  const [showAll, setShowAll] = useState(false);
  // 清空 AI 结果页确认弹窗开关（审计 P2-5：内联确认替代 window.confirm）
  const [confirmClearAgent, setConfirmClearAgent] = useState(false);
  // 审计 P2-12：弹窗无障碍（Escape 关闭 + 打开聚焦 + 关闭后焦点还原）
  const showAllDialogRef = useDialog(showAll, () => setShowAll(false));
  const confirmClearDialogRef = useDialog(confirmClearAgent, () => setConfirmClearAgent(false));

  const agentTabs = resultTabs.filter((t) => t.label.startsWith('🤖'));
  const handleClearAgent = () => {
    setConfirmClearAgent(true); // 审计 P2-5：内联确认弹窗替代 window.confirm
  };
  const confirmClearAgentTabs = () => {
    setConfirmClearAgent(false);
    clearAgentResultTabs();
  };

  if (isExecuting) {
    return (
      <div style={centerStyle}>
        <Loader2 size={24} style={{ animation: 'spin 1s linear infinite' }} />
        <span style={{ marginLeft: 8, color: 'var(--text-muted)' }}>执行中...</span>
      </div>
    );
  }

  if (resultTabs.length === 0) {
    return (
      <div style={centerStyle}>
        <span style={{ color: 'var(--text-muted)' }}>执行 SQL 查看结果</span>
      </div>
    );
  }

  const activeTab = resultTabs.find((t) => t.id === activeResultTabId) || resultTabs[0];

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      {/* Tab bar */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          borderBottom: '1px solid var(--border-light)',
          backgroundColor: 'var(--surface-1)',
          flexShrink: 0,
        }}
      >
        {/* 审计 P2-12：role=tablist/tab + Enter/Space 切换 */}
        <div role="tablist" aria-label="结果标签页" style={{ display: 'flex', alignItems: 'center', overflowX: 'auto', flex: 1 }}>
          {resultTabs.map((tab) => {
            const isActive = tab.id === activeTab.id;
            return (
              <div
                key={tab.id}
                role="tab"
                aria-selected={isActive}
                tabIndex={0}
                onClick={() => switchResultTab(tab.id)}
                onKeyDown={(e) => {
                  if (e.target !== e.currentTarget) return; // 删除钮聚焦时不触发切换（审计 P2-12）
                  if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); switchResultTab(tab.id); }
                }}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: 6,
                  padding: '6px 12px',
                  cursor: 'pointer',
                  fontSize: 12,
                  color: isActive ? 'var(--text-primary)' : 'var(--text-muted)',
                  borderRight: '1px solid var(--surface-heavy)',
                  backgroundColor: isActive ? 'var(--surface-2)' : 'transparent',
                  borderBottom: isActive ? '2px solid var(--accent-blue)' : '2px solid transparent',
                  whiteSpace: 'nowrap',
                  userSelect: 'none',
                }}
              >
                <span>{tab.label}</span>
                <button
                  onClick={(e) => { e.stopPropagation(); closeResultTab(tab.id); }}
                  title="删除该结果页"
                  aria-label={`删除结果页 ${tab.label}`}
                  style={{ background: 'none', border: 'none', color: 'var(--text-muted)', cursor: 'pointer', padding: 0, display: 'flex', fontSize: 12 }}
                >
                  <X size={12} />
                </button>
              </div>
            );
          })}
        </div>
        {agentTabs.length > 0 && (
          /* 审计 P2-12：按钮组窄屏可换行（宽屏不溢出则不生效） */
          <div style={{ display: 'flex', gap: 4, padding: '0 8px', flexShrink: 0, flexWrap: 'wrap' }}>
            <button
              onClick={() => setShowAll(true)}
              title="查看所有 AI 结果页"
              style={{ display: 'flex', alignItems: 'center', gap: 4, padding: '4px 8px', borderRadius: 4, border: '1px solid var(--border-light)', backgroundColor: 'transparent', color: 'var(--text-secondary)', cursor: 'pointer', fontSize: 11 }}
            >
              <LayoutGrid size={12} /> 所有
            </button>
            <button
              onClick={handleClearAgent}
              title="清空全部 AI 结果页"
              style={{ display: 'flex', alignItems: 'center', gap: 4, padding: '4px 8px', borderRadius: 4, border: '1px solid #e74c3c', backgroundColor: 'transparent', color: '#e74c3c', cursor: 'pointer', fontSize: 11 }}
            >
              <Trash2 size={12} /> 清空
            </button>
          </div>
        )}
      </div>

      {/* Content */}
      <div style={{
        flex: 1,
        overflow: 'hidden',
        padding: 8,
        display: 'flex',
        flexDirection: 'column',
        minHeight: 0,
      }}>
        {activeTab.error ? (
          <div style={{ ...centerStyle, color: '#e74c3c', height: '100%' }}>
            <AlertCircle size={18} />
            <span style={{ marginLeft: 8 }}>{activeTab.error}</span>
          </div>
        ) : !activeTab.results || activeTab.results.length === 0 ? (
          <div style={{ ...centerStyle, height: '100%' }}>
            <span style={{ color: 'var(--text-muted)' }}>执行 SQL 查看结果</span>
          </div>
        ) : (
          activeTab.results.map((result, idx) => (
            <div key={idx} style={{ flex: 1, display: 'flex', flexDirection: 'column', minHeight: 0, marginBottom: chartModes[idx] ? 0 : 4 }}>
              {result.type === 'select' ? (
                <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minHeight: 0 }}>
                  <div
                    style={{
                      fontSize: 12,
                      color: 'var(--text-muted)',
                      marginBottom: 4,
                      display: 'flex',
                      justifyContent: 'space-between',
                      alignItems: 'center',
                      flexShrink: 0,
                    }}
                  >
                    <span>
                      查询结果 ({result.row_count} 行
                      {result.execution_time != null ? `, ${(result.execution_time * 1000).toFixed(0)}ms` : ''})
                    </span>
                    {/* 审计 P2-12：操作按钮行窄屏可换行（宽屏不溢出则不生效） */}
                    <div style={{ display: 'flex', gap: 6, alignItems: 'center', flexWrap: 'wrap' }}>
                      <button
                        onClick={() => setChartModes((p) => ({ ...p, [idx]: !p[idx] }))}
                        style={{
                          display: 'flex', alignItems: 'center', gap: 4,
                          padding: '3px 10px', borderRadius: 4, border: `1px solid ${chartModes[idx] ? '#4caf50' : 'var(--text-inactive)'}`,
                          backgroundColor: chartModes[idx] ? 'var(--tint-green-bg)' : 'transparent',
                          color: chartModes[idx] ? '#4caf50' : 'var(--text-secondary)', cursor: 'pointer', fontSize: 11,
                        }}
                      >
                        {chartModes[idx] ? <><Table2 size={12} /> 表格</> : <><BarChart3 size={12} /> 图表</>}
                      </button>
                      {!chartModes[idx] && (
                        <button
                          onClick={() => exportCSV(result.columns || [], result.rows || [])}
                          style={{
                            display: 'flex', alignItems: 'center', gap: 4,
                            padding: '3px 10px', borderRadius: 4, border: '1px solid var(--text-inactive)',
                            backgroundColor: 'transparent', color: 'var(--text-secondary)', cursor: 'pointer', fontSize: 11,
                          }}
                          title="导出 CSV"
                        >
                          <Download size={12} /> CSV
                        </button>
                      )}
                    </div>
                  </div>
                  {chartModes[idx] ? (
                    <div style={{ border: '1px solid var(--border-light)', borderRadius: 6, overflow: 'hidden', flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column' }}>
                      <Suspense fallback={<div style={centerStyle}>加载图表组件...</div>}>
                        <ChartView columns={result.columns || []} rows={result.rows || []} />
                      </Suspense>
                    </div>
                  ) : (
                  <div style={{ flex: 1, overflowX: 'auto', overflowY: 'auto', border: '1px solid var(--border-light)', borderRadius: 6, minHeight: 0 }}>
                    <table style={{ borderCollapse: 'collapse', fontSize: 13, tableLayout: 'auto' }}>
                      <thead>
                        <tr style={{ backgroundColor: 'var(--surface-heavy)' }}>
                          <th style={thStyle}>#</th>
                          {(result.columns || []).map((col, ci) => (
                            <th key={ci} style={thStyle}>{col}</th>
                          ))}
                        </tr>
                      </thead>
                      <tbody>
                        {(result.rows || []).map((row, ri) => (
                          <tr key={ri} style={{ borderBottom: '1px solid var(--surface-heavy)', backgroundColor: ri % 2 === 0 ? 'transparent' : 'var(--surface-1)' }}>
                            <td style={{ ...tdStyle, color: 'var(--text-muted)', textAlign: 'center', width: 40 }}>{ri + 1}</td>
                            {(result.columns || []).map((col, ci) => (
                              <td key={ci} style={tdStyle}>
                                {row[col] === null
                                  ? <span style={{ color: 'var(--text-inactive)', fontStyle: 'italic' }}>NULL</span>
                                  : String(row[col])}
                              </td>
                            ))}
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                  )}
                </div>
              ) : (
                <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '8px 12px', backgroundColor: 'var(--tint-green-bg)', borderRadius: 6, color: '#5a5', fontSize: 13 }}>
                  <CheckCircle size={16} />
                  <span>影响行数: {result.affected_rows ?? 0}</span>
                  {result.last_insert_id != null && <span>, 自增ID: {result.last_insert_id}</span>}
                  {result.execution_time != null && <span style={{ color: 'var(--text-muted)' }}>({(result.execution_time * 1000).toFixed(0)}ms)</span>}
                </div>
              )}
            </div>
          ))
        )}
      </div>

      {/* 所有 AI 结果页弹窗 */}
      {showAll && (
        <div
          style={{ position: 'fixed', inset: 0, zIndex: 'var(--z-modal)', display: 'flex', alignItems: 'center', justifyContent: 'center', backgroundColor: 'rgba(0,0,0,0.55)' }}
          onClick={() => setShowAll(false)}
        >
          {/* 审计 P2-12：宽度 min(720px,94vw) 适配窄屏（内部列表已有滚动容器）；useDialog 提供 Escape/焦点 */}
          <div
            ref={showAllDialogRef}
            tabIndex={-1}
            role="dialog"
            aria-modal="true"
            style={{ width: 'min(720px,94vw)', maxHeight: '70vh', display: 'flex', flexDirection: 'column', background: 'var(--surface-2)', borderRadius: 8, padding: 16, color: 'var(--text-primary)' }}
            onClick={e => e.stopPropagation()}
          >
            <div style={{ display: 'flex', alignItems: 'center', marginBottom: 10 }}>
              <span style={{ fontSize: 13, fontWeight: 600 }}>所有 AI 结果页 ({agentTabs.length})</span>
              <button
                onClick={handleClearAgent}
                style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 4, padding: '4px 10px', borderRadius: 4, border: '1px solid #e74c3c', backgroundColor: 'transparent', color: '#e74c3c', cursor: 'pointer', fontSize: 11 }}
              >
                <Trash2 size={12} /> 清空
              </button>
            </div>
            <div style={{ overflowY: 'auto', display: 'flex', flexDirection: 'column', gap: 4 }}>
              {agentTabs.map((t) => (
                /* 审计 P2-12：列表条目 div → role=button 键盘可达 */
                <div
                  key={t.id}
                  role="button"
                  tabIndex={0}
                  onClick={() => { switchResultTab(t.id); setShowAll(false); }}
                  onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); switchResultTab(t.id); setShowAll(false); } }}
                  style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 10px', borderRadius: 4, border: '1px solid var(--border-light)', cursor: 'pointer', background: t.id === activeResultTabId ? 'var(--surface-heavy)' : 'transparent' }}
                >
                  <span style={{ fontSize: 12, flexShrink: 0 }}>{t.label}</span>
                  <code style={{ fontSize: 11, color: 'var(--text-muted)', flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{t.sql || '（无 SQL）'}</code>
                  <span style={{ fontSize: 11, color: 'var(--text-secondary)', flexShrink: 0 }}>{t.results?.[0]?.row_count ?? 0} 行</span>
                </div>
              ))}
              {agentTabs.length === 0 && <div style={{ color: 'var(--text-muted)', fontSize: 12, textAlign: 'center', padding: 16 }}>无 AI 结果页</div>}
            </div>
          </div>
        </div>
      )}

      {/* 清空 AI 结果页确认弹窗（审计 P2-5：自研内联确认，替代 window.confirm；审计 P2-12：role=dialog + useDialog） */}
      {confirmClearAgent && (
        <div onClick={() => setConfirmClearAgent(false)} style={overlayStyle}>
          <div ref={confirmClearDialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={dialogStyle}>
            <p style={{ margin: 0, fontSize: 13, color: 'var(--text-primary)' }}>确认清空全部 AI 结果页？</p>
            <p style={{ margin: '6px 0 0', fontSize: 11, color: 'var(--text-muted)' }}>此操作不可撤销。</p>
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end', marginTop: 14 }}>
              <button onClick={() => setConfirmClearAgent(false)} style={saveCancelBtn}>取消</button>
              <button onClick={confirmClearAgentTabs} style={dangerBtn}>清空</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};

const thStyle: React.CSSProperties = {
  padding: '6px 10px', textAlign: 'left', fontWeight: 600, borderBottom: '2px solid var(--text-muted)',
  whiteSpace: 'nowrap', position: 'sticky', top: 0, backgroundColor: 'var(--surface-heavy)',
  minWidth: 80,
};
const tdStyle: React.CSSProperties = {
  padding: '4px 10px', borderBottom: '1px solid var(--surface-heavy)',
  maxWidth: 320, minWidth: 60,
  overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', cursor: 'default',
};
const centerStyle: React.CSSProperties = {
  display: 'flex', alignItems: 'center', justifyContent: 'center', color: 'var(--text-muted)', fontSize: 14,
};
