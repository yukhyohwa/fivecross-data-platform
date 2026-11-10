import React, { useEffect, useState } from 'react';
import { api } from '../../services/api';
import { useStore } from '../../stores/useStore';
import { useToast } from '../Toast';
import { ShareDialog } from '../ShareDialog';
import { downloadJson, pickJsonFile, exportFilename } from '../../lib/importExport';
import { overlayStyle, dialogStyle, saveCancelBtn, dangerBtn } from '../wsCommon';
import { useDialog } from '../../lib/useDialog';
import { Loader2, Sparkles, Download, Upload, Save, Radar } from 'lucide-react';

/* ───── 创建/编辑表单 ───── */
export const IndicatorForm: React.FC<{ indicator?: any; initialSql?: string; noOverlay?: boolean; onClose: () => void; onSaved: () => void }> = ({ indicator, initialSql, noOverlay, onClose, onSaved }) => {
  const { success: toastSuccess, error: toastError } = useToast();
  const [form, setForm] = useState({
    metric_name: indicator?.metric_name || '',
    metric_alias: indicator?.metric_alias || '',
    domain: indicator?.domain || '',
    category: indicator?.category || '',
    tags: (indicator?.tags || []).join(', '),
    canonical_sql: indicator?.canonical_sql || initialSql || '',
    definition: indicator?.definition || '',
    aggregation_type: indicator?.aggregation_type || '',
    granularity: indicator?.granularity || '',
    status: indicator?.status || 'draft',
  });
  const [saving, setSaving] = useState(false);
  const [analyzing, setAnalyzing] = useState(false);

  // 审计 P2-12：覆盖层模式接入 useDialog（Escape 关闭 + 打开聚焦）；noOverlay 内嵌模式不受影响
  const dialogRef = useDialog(!noOverlay, onClose);

  const save = async () => {
    setSaving(true);
    try {
      const data = { ...form, tags: form.tags.split(',').map((s: string) => s.trim()).filter(Boolean) };
      if (indicator) {
        await api.updateIndicator(indicator.id, data);
      } else {
        await api.createIndicator(data);
      }
      onSaved();
      onClose();
    } catch (e: any) { alert('保存失败: ' + e.message); }
    setSaving(false);
  };

  const handleAiParse = async () => {
    if (!form.canonical_sql.trim()) {
      toastError('请先输入 SQL');
      return;
    }
    setAnalyzing(true);
    try {
      const result = await api.parseSqlIndicator(form.canonical_sql, form.metric_name);
      setForm((prev) => ({
        ...prev,
        domain: result.domain || prev.domain,
        category: result.category || prev.category,
        definition: result.definition || prev.definition,
        tags: Array.isArray(result.tags) ? result.tags.join(', ') : prev.tags,
        aggregation_type: result.aggregation_type || prev.aggregation_type,
        granularity: result.granularity || prev.granularity,
      }));
      toastSuccess('AI 解析完成，字段已填充');
    } catch (e: any) {
      toastError(e.message || 'AI 解析失败');
    }
    setAnalyzing(false);
  };

  const formContent = (
    <div
      ref={dialogRef}
      {...(noOverlay ? {} : { tabIndex: -1, role: 'dialog' as const, 'aria-modal': true as const, onClick: (e: React.MouseEvent) => e.stopPropagation() })}
      style={noOverlay
        ? { width: '100%', maxHeight: '88vh', overflowY: 'auto', overflowX: 'hidden' }
        // 审计 P2-12：固定宽度 min() 化；内部已有滚动（maxHeight+overflowY），只改宽度
        : { width: 'min(560px,94vw)', maxWidth: '95vw', maxHeight: '88vh', overflowY: 'auto', overflowX: 'hidden', padding: 16, borderRadius: 8, border: '1px solid var(--text-muted)', background: 'var(--surface-3)' }
      }
    >
      {!noOverlay && <h3 style={{ margin: '0 0 10px', fontSize: 14, color: 'var(--text-heading)' }}>{indicator ? '编辑指标' : '新建指标'}</h3>}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          <div style={{ display: 'flex', gap: 6 }}>
            <input placeholder="指标名称 *" value={form.metric_name} onChange={e => setForm({ ...form, metric_name: e.target.value })}
              style={{ flex: 1, minWidth: 0, padding: '5px 8px', borderRadius: 4, border: '1px solid var(--text-muted)', background: 'var(--surface-heavy)', color: 'var(--text-primary)', fontSize: 12 }} />
            <input placeholder="英文别名" value={form.metric_alias} onChange={e => setForm({ ...form, metric_alias: e.target.value })}
              style={{ flex: 1, minWidth: 0, padding: '5px 8px', borderRadius: 4, border: '1px solid var(--text-muted)', background: 'var(--surface-heavy)', color: 'var(--text-primary)', fontSize: 12 }} />
          </div>
          <div style={{ display: 'flex', gap: 6 }}>
            <select value={form.domain} onChange={e => setForm({ ...form, domain: e.target.value })}
              style={{ flex: 1, minWidth: 0, padding: '5px 6px', borderRadius: 4, border: '1px solid var(--text-muted)', background: 'var(--surface-heavy)', color: 'var(--text-primary)', fontSize: 12 }}>
              <option value="">选择业务域</option>
              {['用户增长', '付费转化', '留存', '商业化', '运营活动', '通用'].map(d => <option key={d} value={d}>{d}</option>)}
            </select>
            <select value={form.category} onChange={e => setForm({ ...form, category: e.target.value })}
              style={{ flex: 1, minWidth: 0, padding: '5px 6px', borderRadius: 4, border: '1px solid var(--text-muted)', background: 'var(--surface-heavy)', color: 'var(--text-primary)', fontSize: 12 }}>
              <option value="">选择类别</option>
              {['核心指标', '过程指标', '结果指标'].map(c => <option key={c} value={c}>{c}</option>)}
            </select>
            <select value={form.aggregation_type} onChange={e => setForm({ ...form, aggregation_type: e.target.value })}
              style={{ flex: 1, minWidth: 0, padding: '5px 6px', borderRadius: 4, border: '1px solid var(--text-muted)', background: 'var(--surface-heavy)', color: 'var(--text-primary)', fontSize: 12 }}>
              <option value="">聚合类型</option>
              {['COUNT_DISTINCT', 'SUM', 'AVG', 'RATIO', 'PERCENTILE', 'WINDOW'].map(t => <option key={t} value={t}>{t}</option>)}
            </select>
          </div>
          <input placeholder="标签（逗号分隔，如: 留存, 核心, 日级）" value={form.tags} onChange={e => setForm({ ...form, tags: e.target.value })}
            style={{ padding: '5px 8px', borderRadius: 4, border: '1px solid var(--text-muted)', background: 'var(--surface-heavy)', color: 'var(--text-primary)', fontSize: 12 }} />
          <textarea placeholder="业务定义 / 逻辑描述" value={form.definition} onChange={e => setForm({ ...form, definition: e.target.value })}
            style={{ minHeight: 40, padding: '5px 8px', borderRadius: 4, border: '1px solid var(--text-muted)', background: 'var(--surface-heavy)', color: 'var(--text-primary)', fontSize: 12, resize: 'vertical' }} />
          <div style={{ fontSize: 11, color: 'var(--text-muted)' }}>完整 SQL *</div>
          <textarea placeholder="SELECT ..." value={form.canonical_sql} onChange={e => setForm({ ...form, canonical_sql: e.target.value })}
            style={{ minHeight: 100, padding: '6px 8px', borderRadius: 4, border: '1px solid var(--text-muted)', background: 'var(--surface-2)', color: 'var(--accent-amber)', fontSize: 12, fontFamily: 'monospace', resize: 'vertical' }} />
          <div style={{ fontSize: 11, color: 'var(--text-muted)' }}>点击「🤖 AI 解析」由 AI 根据 SQL 注释和结构自动填充上方字段</div>
        </div>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginTop: 10 }}>
          <button onClick={handleAiParse} disabled={analyzing || !form.canonical_sql.trim()}
            style={{
              padding: '5px 12px', borderRadius: 4, border: '1px solid #9b59b6', background: '#2a1a3a',
              color: '#bb86fc', cursor: 'pointer', fontSize: 12, display: 'flex', alignItems: 'center', gap: 5,
              opacity: analyzing ? 0.6 : 1,
            }}>
            {analyzing ? <Loader2 size={13} style={{ animation: 'spin 1s linear infinite' }} /> : <Sparkles size={13} />}
            {analyzing ? '解析中...' : 'AI 解析'}
          </button>
          <div style={{ display: 'flex', gap: 6 }}>
            <button onClick={onClose}
              style={{ padding: '5px 14px', borderRadius: 4, border: '1px solid var(--text-muted)', background: 'transparent', color: 'var(--text-muted)', cursor: 'pointer', fontSize: 12 }}>取消</button>
            <button onClick={save} disabled={saving || !form.metric_name || !form.canonical_sql}
              style={{ padding: '5px 14px', borderRadius: 4, border: '1px solid var(--accent-blue)', background: 'var(--tint-blue-bg)', color: 'var(--accent-blue)', cursor: 'pointer', fontSize: 12, opacity: saving ? 0.6 : 1 }}>
              {saving ? '保存中...' : (<><Save size={13} style={{ marginRight: 4, verticalAlign: 'middle' }} />保存</>)}
            </button>
          </div>
        </div>
      </div>
  );

  if (noOverlay) return formContent;
  return (
    // 审计 P2-12：遮罩点击关闭
    <div onClick={onClose} style={{ position: 'fixed', top: 0, left: 0, right: 0, bottom: 0, backgroundColor: 'rgba(0,0,0,0.6)', zIndex: 'var(--z-modal)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      {formContent}
    </div>
  );
};

/* ───── 主页面 ───── */
export const IndicatorPage: React.FC = () => {
  const [indicators, setIndicators] = useState<any[]>([]);
  const [total, setTotal] = useState(0);
  const [search, setSearch] = useState('');
  const [domain, setDomain] = useState('');
  const [domains, setDomains] = useState<string[]>([]);
  const [selected, setSelected] = useState<any>(null);
  const [showForm, setShowForm] = useState(false);
  const [editing, setEditing] = useState<any>(null);
  const [loading, setLoading] = useState(false);
  const [deletingId, setDeletingId] = useState<number | null>(null);
  const [checkedIds, setCheckedIds] = useState<Set<number>>(new Set());
  const [shareOpen, setShareOpen] = useState(false);
  const { success: toastSuccess, error: toastError } = useToast();
  const requestOpenSqlFile = useStore((s) => s.requestOpenSqlFile);
  const [scanning, setScanning] = useState(false);
  const [scanResult, setScanResult] = useState<any>(null);
  const [scanOpen, setScanOpen] = useState(false);
  const [draftIdMap, setDraftIdMap] = useState<Map<string, number>>(new Map());
  const [confirmingId, setConfirmingId] = useState<number | null>(null);
  // 删除确认弹窗目标（审计 P2-5：内联确认替代原生 confirm）
  const [deleteTarget, setDeleteTarget] = useState<number | null>(null);

  // 审计 P2-12：扫描结果弹窗 / 删除确认弹窗接入 useDialog（Escape 关闭 + 打开聚焦 + 关闭还原焦点）
  const scanDialogRef = useDialog(scanOpen, () => setScanOpen(false));
  const deleteDialogRef = useDialog(deleteTarget !== null, () => setDeleteTarget(null));

  const load = async () => {
    setLoading(true);
    try {
      const res = await api.getIndicators({ search, domain, size: 100 });
      setIndicators(res.items);
      setTotal(res.total);
    } catch (e) { console.error(e); }
    setLoading(false);
  };

  useEffect(() => { load(); api.getIndicatorDomains().then(setDomains).catch(() => {}); }, []);
  useEffect(() => { load(); }, [search, domain]);

  const handleDelete = (id: number) => {
    setDeleteTarget(id); // 审计 P2-5：内联确认弹窗替代原生 confirm
  };

  /** 删除确认弹窗「删除」按钮的执行体（审计 P2-5） */
  const confirmDelete = async () => {
    if (deleteTarget === null) return;
    const id = deleteTarget;
    setDeleteTarget(null);
    setDeletingId(id);
    try { await api.deleteIndicator(id); await load(); }
    catch (e: any) { toastError(e.message || '删除失败'); }
    finally { setDeletingId(null); }
  };

  const handleExport = async () => {
    try {
      const data = await api.exportIndicators(checkedIds.size > 0 ? [...checkedIds] : undefined);
      downloadJson(data, exportFilename('indicators'));
      toastSuccess(`已导出 ${data.count} 个指标`);
    } catch (e: any) { toastError('导出失败: ' + e.message); }
  };

  const handleImport = async () => {
    const data = await pickJsonFile();
    if (!data || !data.items) {
      if (data) toastError('文件格式不正确，缺少 items 字段');
      return;
    }
    try {
      const result = await api.importIndicators(data.items);
      if (result.errors.length > 0) {
        toastError(`${result.errors.length} 个导入失败: ${result.errors.slice(0, 3).map((e: any) => e.name).join(', ')}`);
      }
      toastSuccess(`成功导入 ${result.created}/${result.total} 个指标`);
      load();
    } catch (e: any) { toastError('导入失败: ' + e.message); }
  };

  const handleScan = async () => {
    setScanning(true);
    try {
      const result = await api.scanSqlIndicators();
      setScanResult(result);
      // 解析新建草稿的 metric_id → id，供「确认转正」
      try {
        const drafts = await api.getIndicators({ status: 'draft', size: 500 });
        const m = new Map<string, number>();
        for (const it of drafts.items) if (it.metric_id) m.set(it.metric_id, it.id);
        setDraftIdMap(m);
      } catch { setDraftIdMap(new Map()); }
      setScanOpen(true);
    } catch (e: any) { toastError(e.message || '扫描失败'); }
    finally { setScanning(false); }
  };

  const handleConfirm = async (metricId: string) => {
    const id = draftIdMap.get(metricId);
    if (!id) { toastError('未找到该草稿指标'); return; }
    setConfirmingId(id);
    try {
      await api.confirmIndicator(id);
      toastSuccess('已转正');
      setScanResult((prev: any) => prev ? {
        ...prev,
        preview: (prev.preview || []).map((p: any) => p.metric_id === metricId ? { ...p, confirmed: true } : p),
      } : prev);
      load();
    } catch (e: any) { toastError(e.message || '确认失败'); }
    finally { setConfirmingId(null); }
  };

  return (
    <div style={{ flex: 1, display: 'flex', padding: 12, gap: 8, backgroundColor: 'var(--surface-3)', color: 'var(--text-primary)', overflow: 'hidden' }}>
      {/* Left: Table */}
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 4, minWidth: 0 }}>
        {/* Toolbar */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexShrink: 0 }}>
          <h3 style={{ margin: 0, fontSize: 14, color: 'var(--text-heading)' }}>指标管理 ({total})</h3>
          <input value={search} onChange={e => setSearch(e.target.value)} placeholder="搜索指标名..." style={{ flex: 1, maxWidth: 200, padding: '4px 8px', borderRadius: 4, border: '1px solid var(--text-muted)', background: 'var(--surface-heavy)', color: 'var(--text-primary)', fontSize: 12 }} />
          <select value={domain} onChange={e => setDomain(e.target.value)} style={{ padding: '4px 8px', borderRadius: 4, border: '1px solid var(--text-muted)', background: 'var(--surface-heavy)', color: 'var(--text-primary)', fontSize: 12 }}>
            <option value="">全部域</option>
            {domains.map(d => <option key={d} value={d}>{d}</option>)}
          </select>
          <button onClick={handleScan} disabled={scanning}
            style={{ padding: '4px 10px', borderRadius: 4, border: '1px solid #e8a838', background: 'var(--tint-amber-bg)', color: 'var(--accent-amber)', cursor: 'pointer', fontSize: 11 }}>
            {scanning ? '扫描中...' : (<><Radar size={12} style={{ marginRight: 4, verticalAlign: 'middle' }} />扫描 SQL 生成指标</>)}
          </button>
          <button onClick={handleImport}
            style={{ padding: '4px 10px', borderRadius: 4, border: '1px solid var(--text-muted)', background: 'transparent', color: 'var(--text-muted)', cursor: 'pointer', fontSize: 11 }}>
            <Upload size={12} style={{ marginRight: 4, verticalAlign: 'middle' }} />
            导入
          </button>
          {checkedIds.size > 0 && (
            <>
              <button onClick={handleExport}
                style={{ padding: '4px 10px', borderRadius: 4, border: '1px solid var(--text-muted)', background: 'transparent', color: 'var(--text-muted)', cursor: 'pointer', fontSize: 11 }}>
                <Download size={12} style={{ marginRight: 4, verticalAlign: 'middle' }} />
                导出 ({checkedIds.size})
              </button>
              <button onClick={() => setShareOpen(true)}
                style={{ padding: '4px 10px', borderRadius: 4, border: '1px solid var(--accent-blue)', background: 'transparent', color: 'var(--accent-blue)', cursor: 'pointer', fontSize: 11 }}>
                批量分享 ({checkedIds.size})
              </button>
            </>
          )}
          <button onClick={() => { setEditing(null); setShowForm(true); }}
            style={{ padding: '4px 10px', borderRadius: 4, border: '1px solid var(--accent-blue)', background: 'var(--tint-blue-bg)', color: 'var(--accent-blue)', cursor: 'pointer', fontSize: 11 }}>+ 新建</button>
        </div>

        {/* Table */}
        <div style={{ flex: 1, overflow: 'auto', border: '1px solid var(--border-light)', borderRadius: 4 }}>
          {loading ? (
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', height: '100%', gap: 8, color: 'var(--text-muted)', fontSize: 13 }}>
              <Loader2 size={18} style={{ animation: 'spin 1s linear infinite' }} /> 加载中...
            </div>
          ) : (
          <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
            <thead>
              <tr style={{ backgroundColor: 'var(--surface-heavy)', position: 'sticky', top: 0 }}>
                <th style={{ padding: '6px 8px', borderBottom: '1px solid var(--text-muted)', width: 28 }}>
                  <input type="checkbox"
                    checked={checkedIds.size === indicators.filter(i => i.share_role === 'owner').length && indicators.filter(i => i.share_role === 'owner').length > 0}
                    onChange={() => {
                      const ownerIds = indicators.filter(i => i.share_role === 'owner').map(i => i.id);
                      if (checkedIds.size === ownerIds.length) setCheckedIds(new Set());
                      else setCheckedIds(new Set(ownerIds));
                    }} />
                </th>
                {['指标名', '别名', '域', '类别', '粒度', '聚合', '状态', '版本', '更新'].map(h => (
                  <th key={h} style={{ padding: '6px 10px', textAlign: 'left', borderBottom: '1px solid var(--text-muted)', color: 'var(--text-muted)', fontWeight: 600, fontSize: 11 }}>{h}</th>
                ))}
                <th style={{ padding: '6px 10px', borderBottom: '1px solid var(--text-muted)' }}>操作</th>
              </tr>
            </thead>
            <tbody>
              {indicators.map(ind => (
                <tr key={ind.id} onClick={() => setSelected(ind)}
                  role="button" tabIndex={0}
                  onKeyDown={(e) => {
                    // 审计 P2-12：行可键盘选中；事件源为行内按钮/复选框时不触发
                    if (e.target !== e.currentTarget) return;
                    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); setSelected(ind); }
                  }}
                  style={{ cursor: 'pointer', backgroundColor: selected?.id === ind.id ? 'var(--tint-green-bg)' : undefined }}
                  onMouseEnter={e => e.currentTarget.style.backgroundColor = 'var(--surface-heavy)'}
                  onMouseLeave={e => { e.currentTarget.style.backgroundColor = selected?.id === ind.id ? 'var(--tint-green-bg)' : ''; }}>
                  <td style={{ padding: '5px 8px', borderBottom: '1px solid var(--surface-heavy)' }} onClick={e => e.stopPropagation()}>
                    {ind.share_role === 'owner' ? (
                      <input type="checkbox" checked={checkedIds.has(ind.id)}
                        onChange={() => setCheckedIds(prev => { const n = new Set(prev); n.has(ind.id) ? n.delete(ind.id) : n.add(ind.id); return n; })} />
                    ) : ind.share_role === 'level' ? (
                      // 层级共享（指标打通）：来源 SQL 为 通用/项目 的派生指标，全体/同族用户可见可共建
                      <span title={`来源 SQL「${ind.source_sql || ''}」为${ind.source_level || ''}级，${ind.my_permission === 'write' ? '可共建' : '只读'}`}
                        style={{ fontSize: 9, padding: '1px 4px', borderRadius: 3, backgroundColor: ind.source_level === '通用' ? 'var(--tint-blue-bg)' : '#2a1a3a', color: ind.source_level === '通用' ? 'var(--accent-blue)' : '#bb86fc', border: `1px solid ${ind.source_level === '通用' ? 'var(--tint-blue-border)' : '#7d3c98'}`, whiteSpace: 'nowrap' }}>
                        {ind.source_level === '通用' ? '通用·共享' : '项目·共享'}{ind.my_permission === 'write' ? '·共写' : ''}
                      </span>
                    ) : (
                      <span style={{ fontSize: 9, padding: '1px 4px', borderRadius: 3, backgroundColor: ind.my_permission === 'write' ? 'var(--tint-green-bg)' : 'var(--tint-blue-bg)', color: 'var(--text-muted)', border: '1px solid var(--border-light)' }}>
                        {ind.my_permission === 'write' ? '共写' : '共读'}
                      </span>
                    )}
                  </td>
                  <td style={{ padding: '5px 10px', borderBottom: '1px solid var(--surface-heavy)', fontWeight: 500 }}>{ind.metric_name}</td>
                  <td style={{ padding: '5px 10px', borderBottom: '1px solid var(--surface-heavy)', color: 'var(--text-muted)' }}>{ind.metric_alias}</td>
                  <td style={{ padding: '5px 10px', borderBottom: '1px solid var(--surface-heavy)' }}>{ind.domain}</td>
                  <td style={{ padding: '5px 10px', borderBottom: '1px solid var(--surface-heavy)', color: 'var(--text-muted)' }}>{ind.category}</td>
                  <td style={{ padding: '5px 10px', borderBottom: '1px solid var(--surface-heavy)' }}>{ind.granularity}</td>
                  <td style={{ padding: '5px 10px', borderBottom: '1px solid var(--surface-heavy)', color: 'var(--accent-amber)' }}>{ind.aggregation_type}</td>
                  <td style={{ padding: '5px 10px', borderBottom: '1px solid var(--surface-heavy)' }}>
                    <span style={{ color: ind.status === 'active' ? '#4caf50' : ind.status === 'draft' ? '#ff9800' : 'var(--text-muted)', fontSize: 11 }}>{ind.status}</span>
                  </td>
                  <td style={{ padding: '5px 10px', borderBottom: '1px solid var(--surface-heavy)' }}>v{ind.version}</td>
                  <td style={{ padding: '5px 10px', borderBottom: '1px solid var(--surface-heavy)', color: 'var(--text-muted)', fontSize: 11 }}>{(ind.updated_at || '').slice(0, 10)}</td>
                  <td style={{ padding: '5px 10px', borderBottom: '1px solid var(--surface-heavy)' }}>
                    {ind.my_permission === 'write' && (
                      <button onClick={e => { e.stopPropagation(); setEditing(ind); setShowForm(true); }}
                        style={{ padding: '2px 6px', borderRadius: 3, border: '1px solid var(--text-muted)', background: 'transparent', color: 'var(--text-muted)', cursor: 'pointer', fontSize: 10, marginRight: 4 }}>编辑</button>
                    )}
                    {/* 删除仅本人（owner）或层级共享共建者（后端再按 analysis_delete 闸门）；显式分享来的指标不可删 */}
                    {(ind.share_role === 'owner' || (ind.share_role === 'level' && ind.my_permission === 'write')) && (
                      <button onClick={e => { e.stopPropagation(); handleDelete(ind.id); }}
                        disabled={deletingId === ind.id}
                        style={{ padding: '2px 6px', borderRadius: 3, border: '1px solid #e74c3c', background: 'transparent', color: '#e74c3c', cursor: 'pointer', fontSize: 10, opacity: deletingId === ind.id ? 0.5 : 1 }}>
                        {deletingId === ind.id ? '删除中...' : '删除'}
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          )}
        </div>
      </div>

      {/* Right: Detail Panel */}
      {/* 审计 P2-12 核验：固定 340 详情卡片 → min(340px,45vw)，窄屏下表格区不被压到 0（宽屏仍 340 不变） */}
      {selected && (
        <div style={{ width: 'min(340px, 45vw)', flexShrink: 0, display: 'flex', flexDirection: 'column', gap: 4, overflow: 'auto', border: '1px solid var(--border-light)', borderRadius: 4, padding: 10, background: 'var(--surface-2)' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--text-heading)' }}>{selected.metric_name}</div>
            <button onClick={() => setSelected(null)} aria-label="关闭详情" style={{ padding: '2px 6px', borderRadius: 3, border: 'none', background: 'transparent', color: 'var(--text-muted)', cursor: 'pointer', fontSize: 16 }}>×</button>
          </div>
          {selected.metric_alias && <div style={{ fontSize: 11, color: 'var(--text-muted)' }}>别名: {selected.metric_alias}</div>}
          <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap', marginTop: 4 }}>
            {selected.domain && <span style={{ padding: '2px 6px', borderRadius: 3, background: 'var(--tint-blue-bg)', border: '1px solid var(--tint-blue-border)', fontSize: 10 }}>{selected.domain}</span>}
            {selected.category && <span style={{ padding: '2px 6px', borderRadius: 3, background: 'var(--tint-amber-bg)', border: '1px solid var(--tint-amber-bg)', fontSize: 10 }}>{selected.category}</span>}
            {selected.granularity && <span style={{ padding: '2px 6px', borderRadius: 3, background: 'var(--tint-green-bg)', border: '1px solid var(--tint-green-border)', fontSize: 10 }}>{selected.granularity}</span>}
            {(selected.tags || []).map((t: string, i: number) => <span key={i} style={{ padding: '2px 6px', borderRadius: 3, background: 'var(--surface-heavy)', border: '1px solid var(--text-muted)', fontSize: 10, color: 'var(--text-muted)' }}>#{t}</span>)}
          </div>
          {selected.definition && <div style={{ fontSize: 11, color: 'var(--text-secondary)', marginTop: 4, lineHeight: 1.5 }}>{selected.definition}</div>}
          {(() => {
            const src = (selected as any).source_sql
              || (String(selected.metric_id || '').startsWith('sql_') ? String(selected.metric_id).slice(4) + '.sql' : '');
            if (!src) return null;
            return (
              <div style={{ marginTop: 8, display: 'flex', alignItems: 'center', gap: 6 }}>
                <span style={{ fontSize: 11, fontWeight: 600, color: 'var(--text-muted)', flexShrink: 0 }}>来源 SQL 文件</span>
                <span style={{ fontSize: 11, color: 'var(--text-secondary)', flex: 1, minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                  {src}
                </span>
                {(selected as any).source_level && (
                  <span style={{ fontSize: 9, padding: '1px 5px', borderRadius: 3, backgroundColor: selected.source_level === '通用' ? 'var(--tint-blue-bg)' : '#2a1a3a', color: selected.source_level === '通用' ? 'var(--accent-blue)' : '#bb86fc', border: `1px solid ${selected.source_level === '通用' ? 'var(--tint-blue-border)' : '#7d3c98'}`, whiteSpace: 'nowrap', flexShrink: 0 }}>
                    {selected.source_level === '通用' ? '通用·共享' : '项目·共享'}
                  </span>
                )}
                <button onClick={() => requestOpenSqlFile(src)}
                  style={{ padding: '2px 8px', borderRadius: 3, border: '1px solid var(--accent-blue)', background: 'transparent', color: 'var(--accent-blue)', cursor: 'pointer', fontSize: 10, flexShrink: 0 }}>
                  在 SQL 数据中打开
                </button>
              </div>
            );
          })()}
          <div style={{ marginTop: 8 }}>
            <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--text-muted)', marginBottom: 4 }}>SQL</div>
            <pre style={{ margin: 0, padding: 8, borderRadius: 4, background: 'var(--surface-1)', fontSize: 11, color: 'var(--accent-amber)', overflow: 'auto', maxHeight: 150, fontFamily: 'monospace', lineHeight: 1.4 }}>{selected.canonical_sql}</pre>
          </div>
          {selected.supported_filters?.length > 0 && (
            <div style={{ marginTop: 4 }}>
              <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--text-muted)', marginBottom: 2 }}>支持筛选</div>
              <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>{(selected.supported_filters || []).map((f: any, i: number) => (
                <span key={i} style={{ padding: '2px 6px', borderRadius: 3, background: 'var(--surface-heavy)', border: '1px solid var(--text-muted)', fontSize: 10, color: 'var(--text-muted)' }}>{f.field}</span>
              ))}</div>
            </div>
          )}
          {selected.business_scenarios?.length > 0 && (
            <div style={{ marginTop: 4 }}>
              <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--text-muted)', marginBottom: 2 }}>适用场景</div>
              <div style={{ fontSize: 11, color: 'var(--text-secondary)' }}>{(selected.business_scenarios || []).join('、')}</div>
            </div>
          )}
          {selected.test_cases?.length > 0 && (
            <div style={{ marginTop: 4 }}>
              <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--text-muted)', marginBottom: 2 }}>测试用例</div>
              <pre style={{ margin: 0, padding: 6, borderRadius: 4, background: 'var(--surface-1)', fontSize: 10, color: 'var(--text-muted)', overflow: 'auto', maxHeight: 80 }}>
                {JSON.stringify(selected.test_cases, null, 1).slice(0, 300)}
              </pre>
            </div>
          )}
          <div style={{ fontSize: 10, color: 'var(--text-muted)', marginTop: 'auto' }}>
            创建: {(selected.created_at || '').slice(0, 10)} · v{selected.version}
          </div>
        </div>
      )}

      {/* Form Modal */}
      {showForm && <IndicatorForm indicator={editing} onClose={() => { setShowForm(false); setEditing(null); }} onSaved={load} />}

      {scanOpen && scanResult && (
        <div onClick={() => setScanOpen(false)} style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.6)', zIndex: 'var(--z-modal)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          {/* 审计 P2-12：role/aria-modal/tabIndex 弹窗语义，遮罩点击关闭；宽度 min() 化（内部已有滚动） */}
          <div ref={scanDialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={{ width: 'min(720px,94vw)', maxWidth: '94vw', maxHeight: '84vh', overflow: 'auto', background: 'var(--surface-3)', borderRadius: 10, padding: 18, border: '1px solid var(--border-light)', color: 'var(--text-primary)' }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
              <h3 style={{ margin: 0, fontSize: 15, color: 'var(--text-heading)' }}>扫描 SQL 生成指标</h3>
              <button onClick={() => setScanOpen(false)} aria-label="关闭" style={{ padding: '2px 8px', borderRadius: 4, border: 'none', background: 'transparent', color: 'var(--text-muted)', cursor: 'pointer', fontSize: 18 }}>×</button>
            </div>
            <div style={{ fontSize: 12, color: 'var(--text-secondary)', marginBottom: 10 }}>
              扫描 {scanResult.scanned} 条 SQL · 新建 {scanResult.created} · 已存在 {scanResult.skipped} · 失败 {scanResult.failed}
            </div>
            <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
              <thead>
                <tr style={{ backgroundColor: 'var(--surface-heavy)' }}>
                  {['SQL 文件', '指标名', '业务域', '状态', '操作'].map(h => (
                    <th key={h} style={{ padding: '6px 8px', textAlign: 'left', borderBottom: '1px solid var(--text-muted)', color: 'var(--text-muted)', fontSize: 11 }}>{h}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {(scanResult.preview || []).map((p: any, i: number) => {
                  const status = p.confirmed ? '已转正'
                    : p.owned_by_other ? '他人所有'
                    : p.updated ? (p.level_shared ? '已共建' : '已更新')
                    : p.created ? (p.level_shared ? '已建·共享' : '草稿')
                    : p.exists ? '已存在'
                    : '失败';
                  const statusColor = p.confirmed ? '#4caf50'
                    : p.owned_by_other ? '#e74c3c'
                    : p.updated ? '#4caf50'
                    : p.created ? '#ff9800'
                    : p.exists ? 'var(--text-muted)' : '#e74c3c';
                  return (
                    <tr key={i}>
                      <td style={{ padding: '5px 8px', borderBottom: '1px solid var(--surface-heavy)', color: 'var(--text-muted)' }}>{p.sql_name}</td>
                      <td style={{ padding: '5px 8px', borderBottom: '1px solid var(--surface-heavy)', fontWeight: 500 }}>{p.metric_name}</td>
                      <td style={{ padding: '5px 8px', borderBottom: '1px solid var(--surface-heavy)' }}>{p.domain || ''}</td>
                      <td style={{ padding: '5px 8px', borderBottom: '1px solid var(--surface-heavy)' }}><span style={{ color: statusColor, fontSize: 11 }}>{status}</span></td>
                      <td style={{ padding: '5px 8px', borderBottom: '1px solid var(--surface-heavy)' }}>
                        {(p.created || p.updated) && p.status === 'draft' && !p.confirmed && (
                          <button onClick={() => handleConfirm(p.metric_id)} disabled={confirmingId === draftIdMap.get(p.metric_id)}
                            style={{ padding: '2px 8px', borderRadius: 3, border: '1px solid var(--accent-blue)', background: 'transparent', color: 'var(--accent-blue)', cursor: 'pointer', fontSize: 10 }}>
                            确认转正
                          </button>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
            <div style={{ display: 'flex', justifyContent: 'flex-end', marginTop: 12 }}>
              <button onClick={() => { setScanOpen(false); load(); }} style={{ padding: '5px 14px', borderRadius: 4, border: '1px solid var(--text-muted)', background: 'transparent', color: 'var(--text-muted)', cursor: 'pointer', fontSize: 12 }}>关闭</button>
            </div>
          </div>
        </div>
      )}

      <ShareDialog
        open={shareOpen}
        onClose={() => setShareOpen(false)}
        count={checkedIds.size}
        showModeSelect={true}
        onShare={async (targetUserIds, mode, permission) => {
          const res = await api.shareIndicators([...checkedIds], targetUserIds, mode, permission);
          toastSuccess(`已分享 ${res.shared} 个指标`);
          setCheckedIds(new Set());
        }}
      />

      {/* 删除指标确认弹窗（审计 P2-5：自研内联确认，替代原生 confirm） */}
      {deleteTarget !== null && (
        <div onClick={() => setDeleteTarget(null)} style={overlayStyle}>
          {/* 审计 P2-12：role/aria-modal/tabIndex 弹窗语义 */}
          <div ref={deleteDialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={dialogStyle}>
            <p style={{ margin: 0, fontSize: 13, color: 'var(--text-primary)' }}>确认删除该指标？</p>
            <p style={{ margin: '6px 0 0', fontSize: 11, color: 'var(--text-muted)' }}>此操作不可撤销。</p>
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end', marginTop: 14 }}>
              <button onClick={() => setDeleteTarget(null)} style={saveCancelBtn}>取消</button>
              <button onClick={confirmDelete} style={dangerBtn}>删除</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};
