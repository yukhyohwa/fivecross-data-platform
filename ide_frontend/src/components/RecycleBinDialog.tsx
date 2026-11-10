import React, { useCallback, useEffect, useState } from 'react';
import { useToast } from './Toast';
import { api } from '../services/api';
import { useStore } from '../stores/useStore';
import { RotateCcw, Trash2, X } from 'lucide-react';
import { overlayStyle, dialogStyle, saveCancelBtn, dangerBtn } from './wsCommon';
import { useDialog } from '../lib/useDialog';

interface DeletedItem {
  rel: string;
  versions: number;
  latest_mtime: number;
  latest_str: string;
}

/** 回收站（审计建议 8）：列出已删工件（源文件已删、_versions 版本镜像仍在，保留 30 天）。
 *  每条可「恢复最新版本」或「彻底删除」（两步确认防误点）。挂四个分析工作台工具条；
 *  对抗审查：前端同样按权限门控——无 analysis_edit 不请求列表，无 analysis_delete
 *  禁用恢复/彻底删除按钮（后端 403 是第二道闸）。 */
export const RecycleBinDialog: React.FC<{ open: boolean; onClose: () => void }> = ({ open, onClose }) => {
  const { success, error: toastError } = useToast();
  const myPermissions = useStore((s) => s.myPermissions);
  // null = 匿名回落/未加载，视为全量（与工作台 canEdit/canDelete 口径一致）
  const canList = myPermissions === null || myPermissions.includes('analysis_edit');
  const canDelete = myPermissions === null || myPermissions.includes('analysis_delete');
  const [items, setItems] = useState<DeletedItem[]>([]);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  // 两步确认：点「彻底删除」先变「确认彻底删除」，再点才执行；点别处/关闭即撤销
  const [confirmPurge, setConfirmPurge] = useState<string | null>(null);
  const dialogRef = useDialog(open, onClose);

  const load = useCallback(async () => {
    if (!canList) { setItems([]); return; }
    setLoading(true);
    try {
      const r = await api.listVersionsDeleted();
      setItems(r.items || []);
    } catch (e: any) {
      toastError(e.message || '加载回收站失败');
    } finally {
      setLoading(false);
    }
  }, [canList, toastError]);

  useEffect(() => {
    if (open) { setConfirmPurge(null); load(); }
  }, [open, load]);

  const handleRestore = async (item: DeletedItem) => {
    if (busy || !canDelete) return;
    setBusy(item.rel);
    try {
      await api.restoreDeleted(item.rel);
      success(`已恢复「${item.rel}」（最新版本）`);
      await load();
    } catch (e: any) {
      toastError(e.message || '恢复失败');
    } finally {
      setBusy(null);
    }
  };

  const handlePurge = async (item: DeletedItem) => {
    if (busy || !canDelete) return;
    if (confirmPurge !== item.rel) { setConfirmPurge(item.rel); return; }
    setConfirmPurge(null);
    setBusy(item.rel);
    try {
      await api.purgeDeleted(item.rel);
      success('已彻底删除（不可恢复）');
      await load();
    } catch (e: any) {
      toastError(e.message || '彻底删除失败');
    } finally {
      setBusy(null);
    }
  };

  if (!open) return null;
  return (
    <div onClick={onClose} style={overlayStyle}>
      <div ref={dialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={{ ...dialogStyle, width: 560, maxWidth: '94vw' }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <h3 style={{ margin: 0, fontSize: 14, color: 'var(--text-primary)', display: 'flex', alignItems: 'center', gap: 6 }}>
            <Trash2 size={14} /> 回收站
          </h3>
          <button onClick={onClose} style={closeBtn} title="关闭" aria-label="关闭"><X size={16} /></button>
        </div>
        <p style={{ margin: '6px 0 0', fontSize: 11, color: 'var(--text-muted)' }}>
          已删除的 专项 / 知识库文档 / SQL / 算法 版本镜像保留最近 30 天，可恢复最新版本；超期自动清理。
        </p>
        <div style={{ maxHeight: 360, overflowY: 'auto', marginTop: 10, border: '1px solid var(--border-light)', borderRadius: 6 }}>
          {!canList ? (
            <p style={{ textAlign: 'center', color: 'var(--text-inactive)', fontSize: 12, padding: 20, margin: 0 }}>
              仅可查看：无「回收站」访问权限（需 编辑 权限点）
            </p>
          ) : loading ? (
            <p style={{ textAlign: 'center', color: 'var(--text-inactive)', fontSize: 12, padding: 20, margin: 0 }}>加载中...</p>
          ) : items.length === 0 ? (
            <p style={{ textAlign: 'center', color: 'var(--text-inactive)', fontSize: 12, padding: 20, margin: 0 }}>回收站为空</p>
          ) : (
            items.map((it) => (
              <div key={it.rel} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 10px', borderBottom: '1px solid var(--surface-heavy)', flexWrap: 'wrap' }}>
                <span style={{ fontSize: 12, color: 'var(--text-primary)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', flex: '1 1 120px', fontFamily: 'monospace' }} title={it.rel}>{it.rel}</span>
                <span style={{ fontSize: 10, color: 'var(--text-inactive)', flexShrink: 0 }}>{it.versions} 版本 · {it.latest_str}</span>
                <button onClick={() => handleRestore(it)} disabled={!canDelete || busy === it.rel} title={!canDelete ? '仅可查看：无「删除」权限' : undefined}
                  style={{ ...rowBtn, border: '1px solid var(--success-text, #2ea043)', color: 'var(--success-text, #2ea043)', opacity: !canDelete || busy === it.rel ? 0.5 : 1 }}>
                  <RotateCcw size={10} /> 恢复
                </button>
                <button
                  onClick={() => handlePurge(it)}
                  disabled={!canDelete || busy === it.rel}
                  title={!canDelete ? '仅可查看：无「删除」权限' : undefined}
                  style={confirmPurge === it.rel ? { ...rowBtn, border: 'none', backgroundColor: '#e74c3c', color: '#fff', opacity: !canDelete || busy === it.rel ? 0.5 : 1 } : { ...rowBtn, border: '1px solid var(--error-text, #f85149)', color: 'var(--error-text, #f85149)', opacity: !canDelete || busy === it.rel ? 0.5 : 1 }}
                >
                  <Trash2 size={10} /> {confirmPurge === it.rel ? '确认彻底删除' : '彻底删除'}
                </button>
              </div>
            ))
          )}
        </div>
        <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end', marginTop: 12 }}>
          <button onClick={onClose} style={saveCancelBtn}>关闭</button>
        </div>
      </div>
    </div>
  );
};

const closeBtn: React.CSSProperties = { background: 'none', border: 'none', color: 'var(--text-muted)', cursor: 'pointer', padding: 2, display: 'flex' };
const rowBtn: React.CSSProperties = { display: 'flex', alignItems: 'center', gap: 3, background: 'none', cursor: 'pointer', padding: '2px 8px', borderRadius: 4, fontSize: 11, flexShrink: 0 };

// ── 删除确认弹窗共用：该工件当前在回收站已有的可恢复版本数 ──

/** 把回收站条目（rel 为相对 _versions 的源路径）匹配到某个工件名下，累计版本数。
 *  rel 形态：sql/<名>.sql(.json) / knowledge/docs/<名>.md(.json) / code/<名>.py(.py.json/.sql) /
 *  knowledge/skills/<名>.md(.json/.run.json) 或目录打包 knowledge/skills/<名>/…。 */
export const matchDeletedCount = (
  items: { rel: string; versions: number }[],
  kind: 'sql' | 'doc' | 'skill' | 'model',
  name: string,
): number => {
  const base = name.replace(/\.(sql|py)$/i, '');
  const patterns = kind === 'skill'
    ? [`knowledge/skills/${base}.`, `knowledge/skills/${base}/`]
    : kind === 'sql' ? [`sql/${base}.`]
    : kind === 'doc' ? [`knowledge/docs/${base}.`]
    : [`code/${base}.`];
  return items.reduce(
    (acc, it) => (patterns.some((p) => it.rel.startsWith(p)) ? acc + it.versions : acc),
    0,
  );
};

/** 弹窗打开（name 非空）时拉回收站列表，返回该工件已有的可恢复版本数；失败静默按 0。 */
export function useDeletedCount(kind: 'sql' | 'doc' | 'skill' | 'model', name: string | null): number {
  const [count, setCount] = useState(0);
  useEffect(() => {
    if (!name) { setCount(0); return; }
    let alive = true;
    api.listVersionsDeleted()
      .then((r) => { if (alive) setCount(matchDeletedCount(r.items || [], kind, name)); })
      .catch(() => {});
    return () => { alive = false; };
  }, [kind, name]);
  return count;
}
