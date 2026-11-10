import React, { useCallback, useEffect, useState } from 'react';
import { useStore } from '../stores/useStore';
import { useToast } from './Toast';
import { api } from '../services/api';
import { Boxes, Plus, Trash2, X, RefreshCw, Lock, AlertTriangle } from 'lucide-react';
import { overlayStyle, dialogStyle, saveCancelBtn, dangerBtn } from './wsCommon';
import { useDialog } from '../lib/useDialog';
import { useDeletedCount } from './RecycleBinDialog';

interface ModelRow {
  name: string;
  source: 'builtin' | 'external';
  problems: string[];
  meta: any;
}

/** 算法模型列表侧栏：/api/admin/models，扁平列表（内置只读 + 外部可编辑/删除），无层级分组。 */
export const ModelsListSidebar: React.FC<{ onClose?: () => void }> = ({ onClose }) => {
  const { selectedModel, setSelectedModel, setModelDraft, bumpModelFiles } = useStore();
  const modelFilesVersion = useStore((s) => s.modelFilesVersion);
  const myPermissions = useStore((s) => s.myPermissions);
  const canEdit = myPermissions === null || myPermissions.includes('analysis_edit');
  const canDelete = myPermissions === null || myPermissions.includes('analysis_delete');
  const { success, error: toastError } = useToast();
  const [models, setModels] = useState<ModelRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [deleteTarget, setDeleteTarget] = useState<string | null>(null);
  // 审计 P2-12：删除确认弹窗无障碍（Escape 关闭 + 聚焦管理）
  const deleteDialogRef = useDialog(!!deleteTarget, () => setDeleteTarget(null));
  // 审计建议 9：弹窗打开时拉回收站，提示该工件已有可恢复版本数（失败静默按 0）
  const deletedCount = useDeletedCount('model', deleteTarget);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const r = await api.listModels();
      setModels(r.models || []);
    } catch (e: any) {
      toastError(e.message || '加载模型失败');
    } finally {
      setLoading(false);
    }
  }, [toastError]);

  useEffect(() => { load(); }, [load, modelFilesVersion]);

  const handleSelect = async (m: ModelRow) => {
    try {
      const r = await api.readModel(m.name);
      const meta = r.meta || {};
      setModelDraft({
        name: r.name || m.name,
        desc: meta.desc || '',
        input: meta.input || 'sql',
        granularity: meta.granularity || 'day',
        sql: meta.sql || '',
        hist_days: meta.hist_days ?? null,
        hist_months: meta.hist_months ?? null,
        horizon_days: meta.horizon_days ?? null,
        horizon_months: meta.horizon_months ?? null,
        window: meta.window ?? null,
        code: r.code || '',
        sources: r.sources || [],
        transformed_sqls: (r.model_sql && meta.sql) ? { [meta.sql]: r.model_sql } : {},
        problems: r.problems || [],
        builtin: m.source === 'builtin',
      });
      setSelectedModel(m.name);
      if (m.source !== 'builtin') success(`已加载模型「${m.name}」`);
    } catch (e: any) {
      toastError(e.message || '加载失败');
    }
  };

  const handleNew = () => {
    setModelDraft(null);
    setSelectedModel(null);
  };

  const confirmDelete = async () => {
    const name = deleteTarget;
    if (!name) return;
    setDeleteTarget(null);
    try {
      await api.deleteModel(name);
      if (selectedModel === name) { setSelectedModel(null); setModelDraft(null); }
      success(`已删除模型「${name}」`);
      await load();
    } catch (e: any) {
      toastError(e.message || '删除失败');
    }
  };

  const renderRow = (m: ModelRow) => {
    const isSelected = m.name === selectedModel;
    const builtin = m.source === 'builtin';
    return (
      // 审计 P2-12：条目 div 补 role=button + 键盘（Enter/Space 加载）
      <div key={m.name}
        role="button"
        tabIndex={0}
        aria-current={isSelected ? 'true' : undefined}
        onClick={() => handleSelect(m)}
        onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); handleSelect(m); } }}
        style={{
          padding: '6px 8px', borderRadius: 4, marginBottom: 1, cursor: 'pointer',
          backgroundColor: isSelected ? 'var(--tint-blue-bg)' : 'transparent',
          borderLeft: isSelected ? '3px solid var(--accent-blue)' : '3px solid transparent',
        }}
        onMouseEnter={(e) => { if (!isSelected) (e.currentTarget as HTMLElement).style.backgroundColor = 'var(--surface-2)'; }}
        onMouseLeave={(e) => { if (!isSelected) (e.currentTarget as HTMLElement).style.backgroundColor = 'transparent'; }}
        title={builtin ? '内置能力（只读）' : '点击加载到编辑器'}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
          {builtin
            ? <Lock size={13} style={{ color: 'var(--text-inactive)', flexShrink: 0 }} />
            : <Boxes size={13} style={{ color: 'var(--accent-amber)', flexShrink: 0 }} />}
          <span style={{ fontSize: 12, color: 'var(--text-primary)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', flex: 1 }}>{m.name}</span>
          {(m.problems?.length > 0) && (
            <span title={`${m.problems.length} 项安全预检问题`} style={{ display: 'flex', flexShrink: 0 }}>
              <AlertTriangle size={11} style={{ color: '#f90' }} />
            </span>
          )}
          {!builtin && (
            <button
              onClick={(e) => { e.stopPropagation(); setDeleteTarget(m.name); }}
              disabled={!canDelete}
              aria-label={`删除「${m.name}」`}
              style={{ background: 'none', border: 'none', color: 'var(--text-inactive)', cursor: canDelete ? 'pointer' : 'not-allowed', padding: 0, display: 'flex', flexShrink: 0, opacity: canDelete ? 1 : 0.4 }}
              title={canDelete ? '删除' : '仅可查看（无删除权限）'}>
              <Trash2 size={11} />
            </button>
          )}
        </div>
        <div style={{ marginTop: 2, paddingLeft: 17 }}>
          <span style={{ fontSize: 10, color: 'var(--text-inactive)' }}>
            {builtin ? '内置能力' : (m.meta?.input === 'upload' ? '离线上传' : (m.meta?.sql ? `取数：${m.meta.sql}` : '自动取数'))}
          </span>
        </div>
      </div>
    );
  };

  return (
    <div style={{ width: '100%', height: '100%', minHeight: 0, borderRight: '1px solid var(--border-light)', display: 'flex', flexDirection: 'column', backgroundColor: 'var(--surface-1)' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '10px 12px', borderBottom: '1px solid var(--border-light)' }}>
        <h3 style={{ margin: 0, fontSize: 14, color: 'var(--text-primary)', display: 'flex', alignItems: 'center', gap: 6 }}><Boxes size={14} /> 算法模型</h3>
        <div style={{ display: 'flex', gap: 2 }}>
          <button onClick={load} style={iconBtn} title="刷新" aria-label="刷新"><RefreshCw size={14} /></button>
          <button onClick={handleNew} disabled={!canEdit} style={{ ...iconBtn, opacity: canEdit ? 1 : 0.4, cursor: canEdit ? 'pointer' : 'not-allowed' }} title={canEdit ? '新建模型' : '仅可查看（无新增/修改权限）'} aria-label="新建模型"><Plus size={14} /></button>
          {onClose && <button onClick={onClose} style={iconBtn} title="关闭" aria-label="关闭列表栏"><X size={14} /></button>}
        </div>
      </div>

      <div style={{ flex: 1, overflowY: 'auto', padding: 4 }}>
        {loading ? (
          <p style={{ textAlign: 'center', color: 'var(--text-inactive)', fontSize: 12, marginTop: 20 }}>加载中...</p>
        ) : models.length === 0 ? (
          <p style={{ textAlign: 'center', color: 'var(--text-inactive)', fontSize: 12, marginTop: 20 }}>暂无模型</p>
        ) : models.map(renderRow)}
      </div>

      {deleteTarget && (
        <div onClick={() => setDeleteTarget(null)} style={overlayStyle}>
          <div ref={deleteDialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={dialogStyle}>
            <p style={{ margin: 0, fontSize: 13, color: 'var(--text-primary)' }}>确认删除模型「{deleteTarget}」？</p>
            <p style={{ margin: '6px 0 0', fontSize: 11, color: 'var(--text-muted)' }}>删除后可从回收站恢复（版本库保留最近 30 天）。{deletedCount > 0 && <>回收站中该模型已有 <b>{deletedCount}</b> 份可恢复版本。</>}</p>
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

const iconBtn: React.CSSProperties = { background: 'none', border: 'none', color: 'var(--text-muted)', cursor: 'pointer', padding: 4, display: 'flex', alignItems: 'center', borderRadius: 4 };

export default ModelsListSidebar;
