import React, { useCallback, useEffect, useState } from 'react';
import { useStore } from '../stores/useStore';
import { useToast } from './Toast';
import { api } from '../services/api';
import { Target, Plus, Trash2, X, RefreshCw, ChevronDown, ChevronRight } from 'lucide-react';
import { overlayStyle, dialogStyle, saveCancelBtn, dangerBtn, ConfidentialityBadge } from './wsCommon';
import { useDialog } from '../lib/useDialog';
import { useDeletedCount } from './RecycleBinDialog';

interface SkillRow {
  name: string;
  level: string;
  sqls: string[];
  docs: string[];
  online?: boolean;
  confidentiality?: string | null;
}

const LEVELS = ['通用', '项目', '个人'] as const;

const levelColor = (level: string) => {
  if (level === '通用') return '#8ab4f8';
  if (level === '项目') return '#f90';
  if (level === '个人') return '#5a8';
  return 'var(--text-muted)';
};

const NEW_TEMPLATE = '# 新专项\n\n描述这个专项的分析角度、关键指标口径、计算逻辑与注意事项。\n';

/** 专项列表侧栏：/api/admin/skills，按 通用/项目/个人 分组折叠（镜像 SQL数据 侧栏）。 */
export const SkillListSidebar: React.FC<{ onClose?: () => void }> = ({ onClose }) => {
  const { selectedSkill, openSkillWindow, newSkillWindow } = useStore();
  const skillFilesVersion = useStore((s) => s.skillFilesVersion);
  const myPermissions = useStore((s) => s.myPermissions);
  const scopeLevel = useStore((s) => s.scopeLevel);
  const canEdit = myPermissions === null || myPermissions.includes('analysis_edit');
  const canDelete = myPermissions === null || myPermissions.includes('analysis_delete');
  const { success, error: toastError } = useToast();
  const [files, setFiles] = useState<SkillRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>({});
  const [deleteTarget, setDeleteTarget] = useState<string | null>(null);
  // 删除确认弹窗无障碍：Escape 关闭 + 打开聚焦 + 关闭还原焦点（审计 P2-12）
  const deleteDialogRef = useDialog(deleteTarget !== null, () => setDeleteTarget(null));
  // 审计建议 9：弹窗打开时拉回收站，提示该工件已有可恢复版本数（失败静默按 0）
  const deletedCount = useDeletedCount('skill', deleteTarget);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const r = await api.listSkills();
      setFiles(r.skills || []);
    } catch (e: any) {
      toastError(e.message || '加载专项失败');
    } finally {
      setLoading(false);
    }
  }, [toastError]);

  // 保存/删除/三按钮动作后通过 bumpSkillFiles 刷新列表
  useEffect(() => { load(); }, [load, skillFilesVersion]);

  const handleSelect = async (name: string) => {
    try {
      const r = await api.readSkill(name);
      openSkillWindow(name, {
        name: r.name || name,
        content: r.content || '',
        level: r.level || '通用',
        sqls: r.sqls || [],
        docs: r.docs || [],
        forecast: r.forecast || null,
      }, r);
      success(`已加载专项「${name}」`);
    } catch (e: any) {
      toastError(e.message || '加载失败');
    }
  };

  const handleNew = () => {
    newSkillWindow({ name: '', level: scopeLevel ?? '通用', content: NEW_TEMPLATE, sqls: [], docs: [], forecast: null });
  };

  const toggleCollapse = (lv: string) => setCollapsed((prev) => ({ ...prev, [lv]: !prev[lv] }));

  const confirmDelete = async () => {
    const name = deleteTarget;
    if (!name) return;
    setDeleteTarget(null);
    try {
      await api.deleteSkill(name);
      const st = useStore.getState();
      const win = st.skillWindows.find((w) => w.savedName === name);
      if (win) st.closeSkillWindow(win.id);
      success(`已删除专项「${name}」`);
      await load();
    } catch (e: any) {
      toastError(e.message || '删除失败');
    }
  };

  // 上线/下线：下线后聊天/自由对话/Agent 不可见（不可点名/不可选/不可引用），专项管理仍可见可编辑
  const [toggling, setToggling] = useState<string | null>(null);
  const toggleOnline = async (f: SkillRow) => {
    const target = !(f.online ?? true);
    setToggling(f.name);
    try {
      await api.setSkillOnline(f.name, target);
      // 同步已打开的编辑窗口状态，避免工具栏标识与侧栏不一致
      const st = useStore.getState();
      st.skillWindows.forEach((w) => {
        if (w.savedName === f.name && w.info) st.syncSkillWindowInfo({ ...w.info, online: target }, w.id);
      });
      success(target ? `已上线「${f.name}」（聊天中可选、可引用）` : `已下线「${f.name}」（聊天中不可见，仅专项管理可编辑）`);
      await load();
    } catch (e: any) {
      toastError(e.message || '上线/下线失败');
    } finally {
      setToggling(null);
    }
  };

  const renderRow = (f: SkillRow) => {
    const isSelected = f.name === selectedSkill?.name;
    const online = f.online !== false;   // 缺省按上线（向后兼容历史专项）
    const busyToggle = toggling === f.name;
    return (
      /* 审计 P2-12：条目 div 键盘可达（role=button + Enter/Space），选中态 aria-current */
      <div key={f.name}
        role="button"
        tabIndex={0}
        aria-current={isSelected ? 'true' : undefined}
        onClick={() => handleSelect(f.name)}
        onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); handleSelect(f.name); } }}
        style={{
          padding: '6px 8px', borderRadius: 4, marginBottom: 1, cursor: 'pointer',
          backgroundColor: isSelected ? 'var(--tint-blue-bg)' : 'transparent',
          borderLeft: isSelected ? '3px solid var(--accent-blue)' : '3px solid transparent',
        }}
        onMouseEnter={(e) => { if (!isSelected) (e.currentTarget as HTMLElement).style.backgroundColor = 'var(--surface-2)'; }}
        onMouseLeave={(e) => { if (!isSelected) (e.currentTarget as HTMLElement).style.backgroundColor = 'transparent'; }}
        title="点击加载到编辑器">
        <div style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
          <Target size={13} style={{ color: 'var(--accent-amber)', flexShrink: 0 }} />
          <span style={{ fontSize: 12, color: 'var(--text-primary)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', flex: 1 }}>{f.name}</span>
          <ConfidentialityBadge value={f.confidentiality} />
          {/* 上线/下线状态标识（点击切换）：上线=绿点，下线=灰点 */}
          <button
            onClick={(e) => { e.stopPropagation(); toggleOnline(f); }}
            disabled={!canEdit || busyToggle}
            aria-label={online ? `下线 ${f.name}` : `上线 ${f.name}`}
            style={{
              display: 'inline-flex', alignItems: 'center', gap: 3, flexShrink: 0,
              fontSize: 10, fontWeight: 600, lineHeight: '16px', padding: '0 5px', borderRadius: 8,
              color: online ? 'var(--success-text)' : 'var(--text-muted)',
              background: online ? 'var(--tint-green-bg)' : 'var(--surface-2)',
              border: '1px solid ' + (online ? 'var(--tint-green-border)' : 'var(--border-light)'),
              cursor: canEdit && !busyToggle ? 'pointer' : 'not-allowed', opacity: canEdit ? 1 : 0.55,
            }}
            title={canEdit ? (online ? '已上线，点击下线（聊天中不再可选/可引用）' : '已下线，点击上线（开放给聊天选择/引用）') : '仅可查看（无新增/修改权限）'}>
            <span style={{ width: 6, height: 6, borderRadius: '50%', background: online ? 'var(--success-text)' : 'var(--text-inactive)', flexShrink: 0 }} />
            {busyToggle ? '…' : online ? '已上线' : '已下线'}
          </button>
          <button
            onClick={(e) => { e.stopPropagation(); setDeleteTarget(f.name); }}
            disabled={!canDelete}
            aria-label={`删除 ${f.name}`}
            style={{ background: 'none', border: 'none', color: 'var(--text-inactive)', cursor: canDelete ? 'pointer' : 'not-allowed', padding: 0, display: 'flex', flexShrink: 0, opacity: canDelete ? 1 : 0.4 }}
            title={canDelete ? '删除' : '仅可查看（无删除权限）'}>
            <Trash2 size={11} />
          </button>
        </div>
        <div style={{ marginTop: 2, paddingLeft: 17 }}>
          <span style={{ fontSize: 10, color: 'var(--text-inactive)' }}>
            {f.sqls?.length ? `${f.sqls.length} SQL` : '无 SQL'} · {f.docs?.length ? `${f.docs.length} 文档` : '无文档'}
          </span>
        </div>
      </div>
    );
  };

  return (
    <div style={{ width: '100%', height: '100%', minHeight: 0, borderRight: '1px solid var(--border-light)', display: 'flex', flexDirection: 'column', backgroundColor: 'var(--surface-1)' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '10px 12px', borderBottom: '1px solid var(--border-light)' }}>
        <h3 style={{ margin: 0, fontSize: 14, color: 'var(--text-primary)', display: 'flex', alignItems: 'center', gap: 6 }}><Target size={14} /> 专项列表</h3>
        <div style={{ display: 'flex', gap: 2 }}>
          {/* 审计 P2-12：图标按钮补 aria-label（原仅 title） */}
          <button onClick={load} style={iconBtn} title="刷新" aria-label="刷新"><RefreshCw size={14} /></button>
          <button onClick={handleNew} disabled={!canEdit} style={{ ...iconBtn, opacity: canEdit ? 1 : 0.4, cursor: canEdit ? 'pointer' : 'not-allowed' }} title={canEdit ? '新建专项' : '仅可查看（无新增/修改权限）'} aria-label="新建专项"><Plus size={14} /></button>
          {onClose && <button onClick={onClose} style={iconBtn} title="关闭" aria-label="关闭"><X size={14} /></button>}
        </div>
      </div>

      <div style={{ flex: 1, overflowY: 'auto', padding: 4 }}>
        {loading ? (
          <p style={{ textAlign: 'center', color: 'var(--text-inactive)', fontSize: 12, marginTop: 20 }}>加载中...</p>
        ) : (
          (scopeLevel ? [scopeLevel] : [...LEVELS]).map((lv) => {
            const items = files.filter((f) => (f.level || '通用') === lv);
            const isCollapsed = collapsed[lv];
            return (
              <div key={lv} style={{ marginBottom: 2 }}>
                {/* 审计 P2-12：分组折叠头键盘可达 + aria-expanded */}
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
                    <p style={{ fontSize: 11, color: 'var(--text-inactive)', padding: '2px 0 6px 22px', margin: 0 }}>（暂无专项）</p>
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
            <p style={{ margin: 0, fontSize: 13, color: 'var(--text-primary)' }}>确认删除专项「{deleteTarget}」？</p>
            <p style={{ margin: '6px 0 0', fontSize: 11, color: 'var(--text-muted)' }}>删除后可从回收站恢复（版本库保留最近 30 天）。{deletedCount > 0 && <>回收站中该专项已有 <b>{deletedCount}</b> 份可恢复版本。</>}</p>
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
