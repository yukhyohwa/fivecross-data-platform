import React, { useState, useEffect } from 'react';
import { api } from '../../services/api';
import { useToast } from '../Toast';
import { RefreshCw, Save } from 'lucide-react';

/** 术语与口径（AI配置，记忆重组 2026-10-23）：系统级全局配置页。
 *  从 MemoryPage 迁出——术语表/口径层/候选确认面向全体用户生效，与个人记忆无关。
 *  写操作由后端 system 权限闸门硬拦；前端仅对非管理员隐藏编辑入口（只读展示）。 */

interface Candidate {
  term: string;
  column: string;
  source: string;
}

type Tab = 'candidates' | 'glossary' | 'metrics';

const tabBtnStyle: React.CSSProperties = {
  padding: '4px 12px', borderRadius: '4px 4px 0 0', border: 'none', cursor: 'pointer', fontSize: 12,
};

const editorTextareaStyle: React.CSSProperties = {
  width: '100%', minHeight: 360, padding: '10px 12px', borderRadius: 6,
  border: '1px solid var(--border-light)', backgroundColor: 'var(--surface-1)',
  color: 'var(--text-primary)', fontSize: 12.5, fontFamily: 'monospace',
  lineHeight: 1.6, resize: 'vertical', outline: 'none', boxSizing: 'border-box',
};

export const GlossaryPage: React.FC = () => {
  const { success, error: toastError } = useToast();
  const [tab, setTab] = useState<Tab>('candidates');

  // 管理员判定（对齐 MCP 管理页口径）：后端写接口另有 system 权限闸门双保险
  const [isAdmin, setIsAdmin] = useState(false);

  // ── 术语候选（AI 自动总结 → 人工确认并入术语表）──
  const [candidates, setCandidates] = useState<Candidate[]>([]);
  const [candLoading, setCandLoading] = useState(false);
  const [candSelected, setCandSelected] = useState<Set<number>>(new Set());
  const [candTerms, setCandTerms] = useState<Record<number, string>>({});
  const [confirming, setConfirming] = useState(false);

  // ── 术语表（glossary.md）──
  const [glossaryContent, setGlossaryContent] = useState('');
  const [glossaryLoading, setGlossaryLoading] = useState(false);
  const [glossarySaving, setGlossarySaving] = useState(false);

  // ── 口径（指标层 metrics.json）──
  const [metricsContent, setMetricsContent] = useState('');
  const [metricsError, setMetricsError] = useState<string | null>(null);
  const [metricsLoading, setMetricsLoading] = useState(false);
  const [metricsSaving, setMetricsSaving] = useState(false);

  // 请求序号守卫（沿用 MemoryPage 迁出时的对抗验证结论）：快速切 tab 产生并发在途请求时，
  // 旧快照晚到不得覆盖新数据
  const candSeqRef = React.useRef(0);
  const glossarySeqRef = React.useRef(0);
  const metricsSeqRef = React.useRef(0);

  useEffect(() => {
    // 与后端 has_perm(user, 'system') 同口径（/me 返回生效权限点）：role 字段是遗留标识，
    // 权限点才是 RBAC 闸门依据（对抗审查 2026-10-23 二轮）
    api.getMe().then(u => setIsAdmin((u?.permissions || []).includes('system')))
      .catch(() => setIsAdmin(false));
  }, []);

  const loadCandidates = async () => {
    const seq = ++candSeqRef.current;
    setCandLoading(true);
    try {
      const r = await api.getGlossaryConfig();
      if (seq !== candSeqRef.current) return;
      const list = r.candidates || [];
      setCandidates(list);
      setCandTerms(Object.fromEntries(list.map((c: Candidate, i: number) => [i, c.term || ''])));
      // 勾选索引裁剪到新列表长度：候选被他处确认后列表变短，残留索引会把勾选错位到别的列
      setCandSelected(prev => {
        const next = new Set([...prev].filter(i => i < list.length));
        return next.size === prev.size ? prev : next;
      });
    } catch { if (seq === candSeqRef.current) toastError('加载候选失败'); }
    finally { if (seq === candSeqRef.current) setCandLoading(false); }
  };

  const loadGlossary = async () => {
    const seq = ++glossarySeqRef.current;
    setGlossaryLoading(true);
    try {
      const r = await api.getGlossaryConfig();
      if (seq !== glossarySeqRef.current) return;
      setGlossaryContent(r.content || '');
    } catch { if (seq === glossarySeqRef.current) toastError('加载术语表失败'); }
    finally { if (seq === glossarySeqRef.current) setGlossaryLoading(false); }
  };

  const loadMetrics = async () => {
    const seq = ++metricsSeqRef.current;
    setMetricsLoading(true);
    try {
      const r = await api.getMetricsConfig();
      if (seq !== metricsSeqRef.current) return;
      setMetricsContent(r.content || '');
      setMetricsError(r.error || null);
    } catch { if (seq === metricsSeqRef.current) toastError('加载口径失败'); }
    finally { if (seq === metricsSeqRef.current) setMetricsLoading(false); }
  };

  // 切到对应页时才拉取（保证打开时是最新）
  useEffect(() => {
    if (tab === 'candidates') loadCandidates();
    else if (tab === 'glossary') loadGlossary();
    else if (tab === 'metrics') loadMetrics();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tab]);

  // ── 候选确认 ──
  const toggleCand = (i: number) => {
    setCandSelected(prev => {
      const next = new Set(prev);
      if (next.has(i)) next.delete(i); else next.add(i);
      return next;
    });
  };
  const toggleAllCand = () => {
    if (candidates.length && candSelected.size === candidates.length) setCandSelected(new Set());
    else setCandSelected(new Set(candidates.map((_, i) => i)));
  };
  const setCandTerm = (i: number, v: string) => setCandTerms(prev => ({ ...prev, [i]: v }));

  const confirmSelected = async () => {
    const entries = [...candSelected]
      .map(i => ({ term: (candTerms[i] || '').trim(), column: candidates[i]?.column || '' }))
      .filter(e => e.term && e.column);
    if (!entries.length) { toastError('请先勾选候选，并为勾选项填写「术语」'); return; }
    setConfirming(true);
    try {
      const res = await api.confirmGlossaryEntries(entries);
      success(`已并入术语表 ${res.added} 条${res.removed ? `，移除候选 ${res.removed} 条` : ''}`);
      setCandSelected(new Set());
      loadCandidates();
    } catch (e: any) { toastError('确认失败: ' + (e?.message || '')); }
    finally { setConfirming(false); }
  };

  // ── 术语表 / 口径保存 ──
  const saveGlossary = async () => {
    if (glossaryLoading) return;  // 对抗审查 2026-10-23 二轮：加载中 content 还是初始空串，直存会清空术语表
    setGlossarySaving(true);
    try {
      await api.saveGlossaryConfig(glossaryContent);
      success('术语表已保存');
      loadCandidates(); // 候选去重依赖术语表，同步刷新
    } catch (e: any) { toastError('保存失败: ' + (e?.message || '')); }
    finally { setGlossarySaving(false); }
  };

  const saveMetrics = async () => {
    if (metricsLoading) return;  // 同上：加载中直存会把口径文件清成空串
    setMetricsSaving(true);
    try {
      await api.saveMetricsConfig(metricsContent);
      success('口径已保存');
      setMetricsError(null);
    } catch (e: any) { toastError('保存失败: ' + (e?.message || '')); }
    finally { setMetricsSaving(false); }
  };

  return (
    <div style={{ height: '100%', display: 'flex', flexDirection: 'column', padding: 16, gap: 12, overflow: 'hidden', backgroundColor: 'var(--surface-3)', color: 'var(--text-primary)' }}>
      {/* Tabs */}
      <div style={{ display: 'flex', gap: 2, borderBottom: '1px solid var(--border-light)', paddingBottom: 4, flexShrink: 0 }}>
        {[
          { key: 'candidates', label: `候选确认${candidates.length ? ` (${candidates.length})` : ''}` },
          { key: 'glossary', label: '术语' },
          { key: 'metrics', label: '口径' },
        ].map(t => (
          <button key={t.key} onClick={() => setTab(t.key as Tab)}
            role="tab" aria-selected={tab === t.key}
            style={{
              ...tabBtnStyle,
              backgroundColor: tab === t.key ? 'var(--surface-hover)' : 'transparent',
              color: tab === t.key ? '#fff' : 'var(--text-muted)',
            }}>{t.label}</button>
        ))}
      </div>

      <div style={{ flex: 1, minHeight: 0, overflowY: 'auto' }}>
        {!isAdmin && (
          <div style={{ fontSize: 12, color: 'var(--text-muted)', padding: '6px 2px', lineHeight: 1.6 }}>
            术语与口径是系统级配置（全体用户通用）：当前为只读视图，仅管理员可编辑/确认。
          </div>
        )}

        {/* ── 候选确认 ── */}
        {tab === 'candidates' && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 8 }}>
              <div style={{ fontSize: 12, color: 'var(--text-muted)', lineHeight: 1.6 }}>
                候选由 AI 自动总结：在「用户应用 → 聊天窗口」用自然语言问数据后，AI 会把 SQL 里出现、术语表尚未收录的字段（按表结构中文描述）整理成候选。勾选并补全「术语」后，点击「确认并入术语表」即可保存。
              </div>
              {isAdmin && (
                <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                  <button onClick={loadCandidates} disabled={candLoading}
                    style={{ fontSize: 12, padding: '5px 10px', borderRadius: 5, border: '1px solid var(--text-muted)', backgroundColor: 'transparent', color: 'var(--text-muted)', cursor: 'pointer' }}>
                    <RefreshCw size={12} style={{ marginRight: 4, verticalAlign: 'middle' }} />
                    刷新
                  </button>
                  <button onClick={confirmSelected} disabled={confirming || candSelected.size === 0}
                    style={{ fontSize: 12, padding: '5px 14px', borderRadius: 5, border: 'none', backgroundColor: 'var(--accent-blue)', color: '#fff', cursor: confirming || candSelected.size === 0 ? 'not-allowed' : 'pointer', opacity: confirming || candSelected.size === 0 ? 0.6 : 1 }}>
                    确认并入术语表{candSelected.size ? ` (${candSelected.size})` : ''}
                  </button>
                </div>
              )}
            </div>

            {candLoading && <div style={{ textAlign: 'center', color: 'var(--text-muted)', fontSize: 12 }}>加载中...</div>}

            {!candLoading && candidates.length === 0 && (
              <div style={{ textAlign: 'center', color: 'var(--text-inactive)', fontSize: 12, marginTop: 30, lineHeight: 1.8 }}>
                暂无待确认候选。<br />去聊天窗口用自然语言问几个取数问题，AI 生成 SQL 后会自动产出候选。
              </div>
            )}

            {candidates.length > 0 && (
              <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
                <thead>
                  <tr style={{ backgroundColor: 'var(--surface-heavy)', textAlign: 'left' }}>
                    <th style={{ padding: '6px 8px', width: 28 }}>
                      {isAdmin && <input type="checkbox" checked={candSelected.size === candidates.length && candidates.length > 0} onChange={toggleAllCand} />}
                    </th>
                    <th style={{ padding: '6px 8px', width: 220 }}>术语（可改）</th>
                    <th style={{ padding: '6px 8px' }}>列名</th>
                    <th style={{ padding: '6px 8px', width: 140 }}>来源</th>
                  </tr>
                </thead>
                <tbody>
                  {candidates.map((c, i) => (
                    <tr key={`${c.column}-${i}`} style={{ borderBottom: '1px solid var(--border-light)' }}>
                      <td style={{ padding: '6px 8px' }}>
                        {isAdmin && <input type="checkbox" checked={candSelected.has(i)} onChange={() => toggleCand(i)} />}
                      </td>
                      <td style={{ padding: '6px 8px' }}>
                        <input value={candTerms[i] ?? ''} onChange={e => setCandTerm(i, e.target.value)} placeholder="填写术语，如：国家代码" readOnly={!isAdmin}
                          style={{ width: '100%', padding: '4px 8px', borderRadius: 4, border: '1px solid var(--border-light)', backgroundColor: isAdmin ? 'var(--surface-1)' : 'var(--surface-heavy)', color: 'var(--text-primary)', fontSize: 12, outline: 'none' }} />
                      </td>
                      <td style={{ padding: '6px 8px' }}>
                        <code style={{ fontFamily: 'monospace', fontSize: 12, color: 'var(--accent-blue)' }}>{c.column}</code>
                      </td>
                      <td style={{ padding: '6px 8px', color: 'var(--text-muted)' }}>{c.source || '—'}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>
        )}

        {/* ── 术语 ── */}
        {tab === 'glossary' && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 8 }}>
              <div style={{ fontSize: 12, color: 'var(--text-muted)', lineHeight: 1.6 }}>
                术语表 glossary.md：每行「术语 → 列名」，用于 SQL 生成时的 schema linking（口语 → 列名映射）。保存会自动备份历史版本。
              </div>
              {isAdmin && (
                <button onClick={saveGlossary} disabled={glossarySaving || glossaryLoading}
                  style={{ fontSize: 12, padding: '5px 14px', borderRadius: 5, border: 'none', backgroundColor: 'var(--accent-blue)', color: '#fff', cursor: (glossarySaving || glossaryLoading) ? 'not-allowed' : 'pointer', opacity: (glossarySaving || glossaryLoading) ? 0.6 : 1 }}>
                  <Save size={12} style={{ marginRight: 4, verticalAlign: 'middle' }} />
                  {glossarySaving ? '保存中...' : '保存术语表'}
                </button>
              )}
            </div>
            {glossaryLoading
              ? <div style={{ textAlign: 'center', color: 'var(--text-muted)', fontSize: 12 }}>加载中...</div>
              : <textarea value={glossaryContent} onChange={e => setGlossaryContent(e.target.value)} style={editorTextareaStyle} spellCheck={false} readOnly={!isAdmin} />}
          </div>
        )}

        {/* ── 口径 ── */}
        {tab === 'metrics' && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 8 }}>
              <div style={{ fontSize: 12, color: 'var(--text-muted)', lineHeight: 1.6 }}>
                口径层 metrics.json（JSON 数组）：指标定义、口径与别名。保存前自动校验 JSON 合法性。
                {metricsError && <span style={{ display: 'block', color: '#e74c3c', marginTop: 4 }}>⚠️ 当前文件不是合法 JSON：{metricsError}</span>}
              </div>
              {isAdmin && (
                <button onClick={saveMetrics} disabled={metricsSaving || metricsLoading}
                  style={{ fontSize: 12, padding: '5px 14px', borderRadius: 5, border: 'none', backgroundColor: 'var(--accent-blue)', color: '#fff', cursor: (metricsSaving || metricsLoading) ? 'not-allowed' : 'pointer', opacity: (metricsSaving || metricsLoading) ? 0.6 : 1 }}>
                  <Save size={12} style={{ marginRight: 4, verticalAlign: 'middle' }} />
                  {metricsSaving ? '保存中...' : '保存口径'}
                </button>
              )}
            </div>
            {metricsLoading
              ? <div style={{ textAlign: 'center', color: 'var(--text-muted)', fontSize: 12 }}>加载中...</div>
              : <textarea value={metricsContent} onChange={e => setMetricsContent(e.target.value)} style={editorTextareaStyle} spellCheck={false} readOnly={!isAdmin} />}
          </div>
        )}
      </div>
    </div>
  );
};
