import React, { useCallback, useEffect, useState } from 'react';
import { useStore } from '../stores/useStore';
import { useToast } from './Toast';
import { api } from '../services/api';
import { BookOpen, Plus, Trash2, X, RefreshCw, ChevronDown, ChevronRight } from 'lucide-react';
import { overlayStyle, dialogStyle, saveCancelBtn, dangerBtn, ConfidentialityBadge } from './wsCommon';
import { useDialog } from '../lib/useDialog';
import { useDeletedCount } from './RecycleBinDialog';

const LEVELS = ['通用', '项目', '个人'] as const;

const levelColor = (level: string) => {
  if (level === '通用') return '#8ab4f8';
  if (level === '项目') return '#f90';
  if (level === '个人') return '#5a8';
  return 'var(--text-muted)';
};

const NEW_TEMPLATE = '# 新文档\n\n在这里写背景知识、业务口径说明等，供 AI 在生成分析结论时参考。\n';

/** 知识库文档列表侧栏：/api/knowledge，按 通用/项目/个人 分组折叠（镜像 专项列表 / SQL数据 侧栏）。 */
export const KnowledgeListSidebar: React.FC<{ onClose?: () => void }> = ({ onClose }) => {
  const { selectedKb, openKbWindow, newKbWindow } = useStore();
  const kbFilesVersion = useStore((s) => s.kbFilesVersion);
  const myPermissions = useStore((s) => s.myPermissions);
  const scopeLevel = useStore((s) => s.scopeLevel);
  const canEdit = myPermissions === null || myPermissions.includes('analysis_edit');
  const canDelete = myPermissions === null || myPermissions.includes('analysis_delete');
  const { success, error: toastError } = useToast();
  const [docs, setDocs] = useState<string[]>([]);
  const [docLevels, setDocLevels] = useState<Record<string, string>>({});
  const [docConfidentiality, setDocConfidentiality] = useState<Record<string, string | null>>({});
  const [loading, setLoading] = useState(false);
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>({});
  const [deleteTarget, setDeleteTarget] = useState<string | null>(null);
  // 审计 P2-12：删除确认弹窗无障碍（Escape 关闭 + 聚焦管理）
  const deleteDialogRef = useDialog(!!deleteTarget, () => setDeleteTarget(null));
  // 审计建议 9：弹窗打开时拉回收站，提示该工件已有可恢复版本数（失败静默按 0）
  const deletedCount = useDeletedCount('doc', deleteTarget);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const r = await api.listDocs();
      setDocs(r.docs || []);
      setDocLevels(r.doc_levels || {});
      setDocConfidentiality(r.doc_confidentiality || {});
    } catch (e: any) {
      toastError(e.message || '加载知识库失败');
    } finally {
      setLoading(false);
    }
  }, [toastError]);

  // 保存/删除后通过 bumpKbFiles 刷新列表
  useEffect(() => { load(); }, [load, kbFilesVersion]);

  const handleSelect = async (name: string) => {
    try {
      const r = await api.readDoc(name);
      openKbWindow(name, { name: r.name || name, content: r.content || '', level: r.level || '通用' });
      success(`已加载文档「${name}」`);
    } catch (e: any) {
      toastError(e.message || '加载失败');
    }
  };

  const handleNew = () => {
    newKbWindow({ name: '', level: scopeLevel ?? '通用', content: NEW_TEMPLATE });
  };

  const toggleCollapse = (lv: string) => setCollapsed((prev) => ({ ...prev, [lv]: !prev[lv] }));

  const confirmDelete = async () => {
    const name = deleteTarget;
    if (!name) return;
    setDeleteTarget(null);
    try {
      await api.deleteDoc(name);
      const st = useStore.getState();
      const win = st.kbWindows.find((w) => w.savedName === name);
      if (win) st.closeKbWindow(win.id);
      success(`已删除文档「${name}」`);
      await load();
    } catch (e: any) {
      toastError(e.message || '删除失败');
    }
  };

  const renderRow = (name: string) => {
    const isSelected = name === selectedKb?.name;
    return (
      // 审计 P2-12：条目 div 补 role=button + 键盘（Enter/Space 加载）
      <div key={name}
        role="button"
        tabIndex={0}
        aria-current={isSelected ? 'true' : undefined}
        onClick={() => handleSelect(name)}
        onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); handleSelect(name); } }}
        style={{
          padding: '6px 8px', borderRadius: 4, marginBottom: 1, cursor: 'pointer',
          backgroundColor: isSelected ? 'var(--tint-blue-bg)' : 'transparent',
          borderLeft: isSelected ? '3px solid var(--accent-blue)' : '3px solid transparent',
        }}
        onMouseEnter={(e) => { if (!isSelected) (e.currentTarget as HTMLElement).style.backgroundColor = 'var(--surface-2)'; }}
        onMouseLeave={(e) => { if (!isSelected) (e.currentTarget as HTMLElement).style.backgroundColor = 'transparent'; }}
        title="点击加载到编辑器">
        <div style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
          <BookOpen size={13} style={{ color: '#5a8', flexShrink: 0 }} />
          <span style={{ fontSize: 12, color: 'var(--text-primary)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', flex: 1 }}>{name}</span>
          <ConfidentialityBadge value={docConfidentiality[name]} />
          <button
            onClick={(e) => { e.stopPropagation(); setDeleteTarget(name); }}
            disabled={!canDelete}
            aria-label={`删除「${name}」`}
            style={{ background: 'none', border: 'none', color: 'var(--text-inactive)', cursor: canDelete ? 'pointer' : 'not-allowed', padding: 0, display: 'flex', flexShrink: 0, opacity: canDelete ? 1 : 0.4 }}
            title={canDelete ? '删除' : '仅可查看（无删除权限）'}>
            <Trash2 size={11} />
          </button>
        </div>
      </div>
    );
  };

  return (
    <div style={{ width: '100%', height: '100%', minHeight: 0, borderRight: '1px solid var(--border-light)', display: 'flex', flexDirection: 'column', backgroundColor: 'var(--surface-1)' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '10px 12px', borderBottom: '1px solid var(--border-light)' }}>
        <h3 style={{ margin: 0, fontSize: 14, color: 'var(--text-primary)', display: 'flex', alignItems: 'center', gap: 6 }}><BookOpen size={14} /> 知识库文档</h3>
        <div style={{ display: 'flex', gap: 2 }}>
          <button onClick={load} style={iconBtn} title="刷新" aria-label="刷新"><RefreshCw size={14} /></button>
          <button onClick={handleNew} disabled={!canEdit} style={{ ...iconBtn, opacity: canEdit ? 1 : 0.4, cursor: canEdit ? 'pointer' : 'not-allowed' }} title={canEdit ? '新建文档' : '仅可查看（无新增/修改权限）'} aria-label="新建文档"><Plus size={14} /></button>
          {onClose && <button onClick={onClose} style={iconBtn} title="关闭" aria-label="关闭列表栏"><X size={14} /></button>}
        </div>
      </div>

      <div style={{ flex: 1, overflowY: 'auto', padding: 4 }}>
        {loading ? (
          <p style={{ textAlign: 'center', color: 'var(--text-inactive)', fontSize: 12, marginTop: 20 }}>加载中...</p>
        ) : (
          (scopeLevel ? [scopeLevel] : [...LEVELS]).map((lv) => {
            const items = docs.filter((n) => (docLevels[n] || '通用') === lv);
            const isCollapsed = collapsed[lv];
            return (
              <div key={lv} style={{ marginBottom: 2 }}>
                {/* 审计 P2-12：分组折叠头补 role=button + 键盘 + aria-expanded */}
                <div onClick={() => toggleCollapse(lv)}
                  role="button"
                  tabIndex={0}
                  aria-expanded={!isCollapsed}
                  onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggleCollapse(lv); } }}
                  style={{ display: 'flex', alignItems: 'center', gap: 5, padding: '4px 6px', cursor: 'pointer', userSelect: 'none', borderRadius: 4 }}>
                  {isCollapsed ? <ChevronRight size={12} style={{ color: 'var(--text-muted)', flexShrink: 0 }} /> : <ChevronDown size={12} style={{ color: 'var(--text-muted)', flexShrink: 0 }} />}
                  <span style={{ width: 8, height: 8, borderRadius: '50%', backgroundColor: levelColor(lv), flexShrink: 0 }} />
                  <span style={{ fontSize: 12, fontWeight: 600, color: 'var(--text-primary)' }}>{lv}</span>
                  <span style={{ fontSize: 10, color: 'var(--text-inactive)' }}>{items.length}</span>
                </div>
                {!isCollapsed && (
                  items.length === 0 ? (
                    <p style={{ fontSize: 11, color: 'var(--text-inactive)', padding: '2px 0 6px 22px', margin: 0 }}>（暂无文档）</p>
                  ) : items.map(renderRow)
                )}
              </div>
            );
          })
        )}
      </div>

      {deleteTarget && (
        <div onClick={() => setDeleteTarget(null)} style={overlayStyle}>
          <div ref={deleteDialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={dialogStyle}>
            <p style={{ margin: 0, fontSize: 13, color: 'var(--text-primary)' }}>确认删除文档「{deleteTarget}」？</p>
            <p style={{ margin: '6px 0 0', fontSize: 11, color: 'var(--text-muted)' }}>删除后可从回收站恢复（版本库保留最近 30 天）。{deletedCount > 0 && <>回收站中该文档已有 <b>{deletedCount}</b> 份可恢复版本。</>}</p>
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
