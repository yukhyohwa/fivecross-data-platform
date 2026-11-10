import React, { useCallback, useEffect, useState } from 'react';
import { useStore } from '../stores/useStore';
import { useToast } from './Toast';
import { api } from '../services/api';
import { FileCode, Plus, Trash2, X, Search, RefreshCw, ChevronDown, ChevronRight, Wand2 } from 'lucide-react';
import { overlayStyle, dialogStyle, saveCancelBtn, dangerBtn, ConfidentialityBadge } from './wsCommon';
import { useDialog } from '../lib/useDialog';
import { useDeletedCount } from './RecycleBinDialog';

interface SqlFileRow {
  name: string;
  level: string;
  meta?: Record<string, any>;
  confidentiality?: string | null;
  indicators?: any[];
}

const LEVELS = ['通用', '项目', '个人'] as const;

const stripExt = (name: string) => name.replace(/\.sql$/i, '');

const levelColor = (level: string) => {
  if (level === '通用') return '#8ab4f8';
  if (level === '项目') return '#f90';
  if (level === '个人') return '#5a8';
  return 'var(--text-muted)';
};

/** SQL 数据侧栏：游戏库取数口径的 sql/*.sql（走 /api/admin/sqls），按 通用/项目/个人 分组折叠。 */
export const SqlFilesSidebar: React.FC<{ onClose?: () => void }> = ({ onClose }) => {
  const { setSql, addEditorTab, selectedSqlFile, setSelectedSqlFile, setActiveEditorTabLabel } = useStore();
  const sqlFilesVersion = useStore((s) => s.sqlFilesVersion);
  const myPermissions = useStore((s) => s.myPermissions);
  const scopeLevel = useStore((s) => s.scopeLevel);
  const canEdit = myPermissions === null || myPermissions.includes('analysis_edit');
  const canDelete = myPermissions === null || myPermissions.includes('analysis_delete');
  const { success, error: toastError } = useToast();
  const [files, setFiles] = useState<SqlFileRow[]>([]);
  const [search, setSearch] = useState('');
  const [loading, setLoading] = useState(false);
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>({});
  const [deleteTarget, setDeleteTarget] = useState<string | null>(null);
  const [generating, setGenerating] = useState<string | null>(null);
  // 审计 P2-12：删除确认弹窗无障碍（Escape 关闭 + 打开聚焦 + 焦点还原）
  const deleteDialogRef = useDialog(deleteTarget !== null, () => setDeleteTarget(null));
  // 审计建议 9：弹窗打开时拉回收站，提示该工件已有可恢复版本数（失败静默按 0）
  const deletedCount = useDeletedCount('sql', deleteTarget);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const r = await api.listSqls();
      setFiles(r.sqls || []);
    } catch (e: any) {
      toastError(e.message || '加载 SQL 文件失败');
    } finally {
      setLoading(false);
    }
  }, [toastError]);

  // 保存/删除/生成指标（可能在编辑器竖条触发）后通过 bumpSqlFiles 刷新列表
  useEffect(() => { load(); }, [load, sqlFilesVersion]);

  const handleSelect = async (name: string) => {
    try {
      const r = await api.readSql(name);
      setSql(r.sql || '');
      setActiveEditorTabLabel(stripExt(name)); // 活动标签页名改成文档名（全新标签才默认「查询 N」）
      setSelectedSqlFile({ name, level: r.level || '通用' });
      success(`已加载「${stripExt(name)}」到编辑器`);
    } catch (e: any) {
      toastError(e.message || '加载失败');
    }
  };

  const handleNew = () => {
    addEditorTab();
    setSelectedSqlFile(null);
  };

  const toggleCollapse = (lv: string) => setCollapsed((prev) => ({ ...prev, [lv]: !prev[lv] }));

  // 一键生成/更新指标：调 /api/indicators/generate-from-sql（一拆多），成功后刷新关联徽标
  const handleGenerate = async (name: string) => {
    if (generating) return;
    setGenerating(name);
    try {
      const data = await api.generateFromSql(name);
      await load();
      if (data.error) {
        toastError(data.error);
      } else if (data.indicators && data.indicators.length) {
        success(`已拆分「${stripExt(name)}」为 ${data.indicators.length} 个指标（新建 ${data.created || 0} / 更新 ${data.updated || 0}），请到 AI配置 → 指标管理 确认转正`);
      } else {
        success('未拆分出指标');
      }
    } catch (e: any) {
      toastError(e.message || '生成指标失败');
      await load();
    } finally {
      setGenerating(null);
    }
  };

  const confirmDelete = async () => {
    const name = deleteTarget;
    if (!name) return;
    setDeleteTarget(null);
    try {
      await api.deleteSql(name);
      const cur = useStore.getState().selectedSqlFile;
      if (cur && cur.name === name) useStore.getState().setSelectedSqlFile(null);
      success(`已删除「${stripExt(name)}」`);
      await load();
    } catch (e: any) {
      toastError(e.message || '删除失败');
    }
  };

  const lower = search.toLowerCase();
  const filtered = lower ? files.filter((f) => f.name.toLowerCase().includes(lower)) : files;
  // 个人定制上下文只显示指定层级（个人），否则按 通用/项目/个人 全部分组
  const levels = (scopeLevel ? [scopeLevel] : [...LEVELS]) as string[];

  const renderRow = (f: SqlFileRow) => {
    const isSelected = f.name === selectedSqlFile?.name;
    const indicatorCount = f.indicators?.length || 0;
    const busy = generating === f.name;
    return (
      /* 审计 P2-12：列表条目 div → role=button 键盘可达（子按钮聚焦时不触发条目） */
      <div key={f.name}
        onClick={() => handleSelect(f.name)}
        role="button"
        tabIndex={0}
        onKeyDown={(e) => {
          if (e.target !== e.currentTarget) return; // 拆分/删除钮聚焦时不触发选中
          if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); handleSelect(f.name); }
        }}
        style={{
          padding: '6px 8px', borderRadius: 4, marginBottom: 1, cursor: 'pointer',
          backgroundColor: isSelected ? 'var(--tint-blue-bg)' : 'transparent',
          borderLeft: isSelected ? '3px solid var(--accent-blue)' : '3px solid transparent',
        }}
        onMouseEnter={(e) => { if (!isSelected) (e.currentTarget as HTMLElement).style.backgroundColor = 'var(--surface-2)'; }}
        onMouseLeave={(e) => { if (!isSelected) (e.currentTarget as HTMLElement).style.backgroundColor = 'transparent'; }}
        title="点击加载到编辑器">
        <div style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
          <FileCode size={13} style={{ color: 'var(--accent-amber)', flexShrink: 0 }} />
          <span style={{ fontSize: 12, color: 'var(--text-primary)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', flex: 1 }}>{stripExt(f.name)}</span>
          <ConfidentialityBadge value={f.confidentiality} />
          <button
            onClick={(e) => { e.stopPropagation(); handleGenerate(f.name); }}
            disabled={busy}
            title={indicatorCount ? '重新 AI 拆分为多个单指标（同步/重建关联指标）' : 'AI 解析该 SQL 拆分为多个单指标草稿（去 AI配置→指标管理 确认）'}
            style={{ display: 'flex', alignItems: 'center', gap: 2, background: 'none', border: '1px solid var(--accent-amber)', color: 'var(--accent-amber-text)', cursor: busy ? 'default' : 'pointer', padding: '1px 5px', borderRadius: 3, fontSize: 10, flexShrink: 0, opacity: busy ? 0.6 : 1 }}>
            <Wand2 size={9} />{busy ? '⏳' : (indicatorCount ? '重拆' : '拆分')}
          </button>
          <button
            onClick={(e) => { e.stopPropagation(); setDeleteTarget(f.name); }}
            disabled={!canDelete}
            aria-label={canDelete ? `删除 ${stripExt(f.name)}` : '仅可查看（无删除权限）'}
            style={{ background: 'none', border: 'none', color: 'var(--text-inactive)', cursor: canDelete ? 'pointer' : 'not-allowed', padding: 0, display: 'flex', flexShrink: 0, opacity: canDelete ? 1 : 0.4 }}
            title={canDelete ? '删除' : '仅可查看（无删除权限）'}>
            <Trash2 size={11} />
          </button>
        </div>
        {indicatorCount > 0 && (
          <div style={{ marginTop: 2, paddingLeft: 17 }}>
            <span style={{ fontSize: 10, color: 'var(--text-inactive)' }}>{indicatorCount} 指标</span>
          </div>
        )}
      </div>
    );
  };

  return (
    <div style={{ width: '100%', height: '100%', minHeight: 0, borderRight: '1px solid var(--border-light)', display: 'flex', flexDirection: 'column', backgroundColor: 'var(--surface-1)' }}>
      {/* 审计 P2-12：头部窄屏可换行（宽屏不溢出则不生效）；图标钮补 aria-label */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '10px 12px', borderBottom: '1px solid var(--border-light)', flexWrap: 'wrap', gap: 4 }}>
        <h3 style={{ margin: 0, fontSize: 14, color: 'var(--text-primary)', display: 'flex', alignItems: 'center', gap: 6 }}><FileCode size={14} /> SQL数据</h3>
        <div style={{ display: 'flex', gap: 2 }}>
          <button onClick={load} style={iconBtn} title="刷新" aria-label="刷新"><RefreshCw size={14} /></button>
          <button onClick={handleNew} disabled={!canEdit} style={{ ...iconBtn, opacity: canEdit ? 1 : 0.4, cursor: canEdit ? 'pointer' : 'not-allowed' }} title={canEdit ? '新建（打开空编辑器页）' : '仅可查看（无新增/修改权限）'} aria-label={canEdit ? '新建（打开空编辑器页）' : '仅可查看（无新增/修改权限）'}><Plus size={14} /></button>
          {onClose && <button onClick={onClose} style={iconBtn} title="关闭" aria-label="关闭"><X size={14} /></button>}
        </div>
      </div>

      <div style={{ padding: '6px 8px', borderBottom: '1px solid var(--surface-heavy)' }}>
        <div style={{ position: 'relative' }}>
          <Search size={11} style={{ position: 'absolute', left: 8, top: '50%', transform: 'translateY(-50%)', color: 'var(--text-inactive)', pointerEvents: 'none' }} />
          <input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="搜索 SQL 文件..." aria-label="搜索 SQL 文件" style={{ ...searchInput, paddingLeft: 24 }} />
        </div>
      </div>

      <div style={{ flex: 1, overflowY: 'auto', padding: 4 }}>
        {loading ? (
          <p style={{ textAlign: 'center', color: 'var(--text-inactive)', fontSize: 12, marginTop: 20 }}>加载中...</p>
        ) : search && filtered.length === 0 ? (
          <p style={{ textAlign: 'center', color: 'var(--text-inactive)', fontSize: 12, marginTop: 20 }}>无匹配</p>
        ) : (
          levels.map((lv) => {
            const items = filtered.filter((f) => (f.level || '通用') === lv);
            if (search && items.length === 0) return null; // 搜索时隐藏空组
            const isCollapsed = collapsed[lv];
            return (
              <div key={lv} style={{ marginBottom: 2 }}>
                {/* 审计 P2-12：分组折叠行 → role=button 键盘可达 */}
                <div onClick={() => toggleCollapse(lv)} role="button" tabIndex={0} aria-expanded={!isCollapsed}
                  onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggleCollapse(lv); } }}
                  style={{ display: 'flex', alignItems: 'center', gap: 5, padding: '4px 6px', cursor: 'pointer', userSelect: 'none', borderRadius: 4 }}>
                  {isCollapsed ? <ChevronRight size={12} style={{ color: 'var(--text-muted)', flexShrink: 0 }} /> : <ChevronDown size={12} style={{ color: 'var(--text-muted)', flexShrink: 0 }} />}
                  <span style={{ width: 8, height: 8, borderRadius: '50%', backgroundColor: levelColor(lv), flexShrink: 0 }} />
                  <span style={{ fontSize: 12, fontWeight: 600, color: 'var(--text-primary)' }}>{lv}</span>
                  <span style={{ fontSize: 10, color: 'var(--text-inactive)' }}>{items.length}</span>
                </div>
                {!isCollapsed && (
                  items.length === 0 ? (
                    <p style={{ fontSize: 11, color: 'var(--text-inactive)', padding: '2px 0 6px 22px', margin: 0 }}>（暂无 SQL）</p>
                  ) : items.map(renderRow)
                )}
              </div>
            );
          })
        )}
      </div>

      {deleteTarget && (
        <div onClick={() => setDeleteTarget(null)} style={overlayStyle}>
          {/* 审计 P2-12：role=dialog + useDialog（Escape 关闭/焦点管理） */}
          <div ref={deleteDialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={dialogStyle}>
            <p style={{ margin: 0, fontSize: 13, color: 'var(--text-primary)' }}>确认删除 SQL 文件「{stripExt(deleteTarget)}」？</p>
            <p style={{ margin: '6px 0 0', fontSize: 11, color: 'var(--text-muted)' }}>删除后可从回收站恢复（版本库保留最近 30 天）。{deletedCount > 0 && <>回收站中该文件已有 <b>{deletedCount}</b> 份可恢复版本。</>}</p>
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
const searchInput: React.CSSProperties = { width: '100%', padding: '4px 8px', borderRadius: 4, border: '1px solid var(--text-muted)', backgroundColor: 'var(--surface-1)', color: 'var(--text-on-accent)', fontSize: 12, outline: 'none', boxSizing: 'border-box' };
