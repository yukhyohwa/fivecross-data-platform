import React, { useState, useEffect } from 'react';
import { api } from '../services/api';
import { useDialog } from '../lib/useDialog';
import { X } from 'lucide-react';

interface User { id: string; username: string; }

interface ShareDialogProps {
  open: boolean;
  onClose: () => void;
  onShare: (targetUserIds: string[], mode: 'collaborative'|'copy', permission: 'read'|'write') => Promise<void>;
  count: number;
  showModeSelect?: boolean; // false for memory (copy-only)
  /** 固定分享方式：隐藏方式选择但保留权限选择（远程 MCP 只能 collaborative）。 */
  forceMode?: 'collaborative' | 'copy';
}

export const ShareDialog: React.FC<ShareDialogProps> = ({ open, onClose, onShare, count, showModeSelect = true, forceMode }) => {
  const [users, setUsers] = useState<User[]>([]);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [mode, setMode] = useState<'collaborative'|'copy'>('copy');
  const [permission, setPermission] = useState<'read'|'write'>('read');
  const [loading, setLoading] = useState(false);
  const effectiveMode = forceMode ?? mode;

  // 审计 P2-12：弹窗接入 useDialog（Escape 关闭 + 打开聚焦 + 关闭还原焦点）
  const dialogRef = useDialog(open, onClose);

  useEffect(() => {
    if (open) {
      setSelected(new Set());
      api.listUsersBasic().then(setUsers).catch(() => {});
    }
  }, [open]);

  if (!open) return null;

  const toggle = (id: string) => {
    setSelected(prev => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  };

  const handleConfirm = async () => {
    if (selected.size === 0) return;
    setLoading(true);
    try {
      await onShare([...selected], effectiveMode, permission);
      onClose();
    } finally {
      setLoading(false);
    }
  };

  return (
    // 审计 P2-12：遮罩点击关闭；卡片 role/aria-modal/tabIndex 弹窗语义；宽度 min() 化（用户列表内部已滚动，只改宽）
    <div onClick={onClose} style={{ position: 'fixed', inset: 0, zIndex: 'var(--z-modal)', backgroundColor: 'rgba(0,0,0,0.5)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <div ref={dialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={{ backgroundColor: 'var(--surface-2)', border: '1px solid var(--border-light)', borderRadius: 10, padding: 20, width: 'min(360px,94vw)', maxHeight: '80vh', display: 'flex', flexDirection: 'column', gap: 14 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <h3 style={{ margin: 0, fontSize: 14, color: 'var(--text-heading)' }}>分享 {count} 项</h3>
          <button onClick={onClose} aria-label="关闭" style={{ background: 'none', border: 'none', cursor: 'pointer', color: 'var(--text-muted)', padding: 2 }}><X size={14} /></button>
        </div>

        {showModeSelect && !forceMode && (
          <div style={{ fontSize: 12 }}>
            <div style={{ marginBottom: 6, color: 'var(--text-muted)' }}>分享方式</div>
            <div style={{ display: 'flex', gap: 12 }}>
              {(['collaborative', 'copy'] as const).map(m => (
                <label key={m} style={{ display: 'flex', alignItems: 'center', gap: 5, cursor: 'pointer', color: 'var(--text-primary)' }}>
                  <input type="radio" checked={mode === m} onChange={() => setMode(m)} />
                  {m === 'collaborative' ? '共同创作' : '复制分享'}
                </label>
              ))}
            </div>
          </div>
        )}

        {showModeSelect && effectiveMode === 'collaborative' && (
          <div style={{ fontSize: 12 }}>
            <div style={{ marginBottom: 6, color: 'var(--text-muted)' }}>权限</div>
            <div style={{ display: 'flex', gap: 12 }}>
              {(['read', 'write'] as const).map(p => (
                <label key={p} style={{ display: 'flex', alignItems: 'center', gap: 5, cursor: 'pointer', color: 'var(--text-primary)' }}>
                  <input type="radio" checked={permission === p} onChange={() => setPermission(p)} />
                  {p === 'read' ? '只读' : '可编辑'}
                </label>
              ))}
            </div>
          </div>
        )}

        <div style={{ fontSize: 12 }}>
          <div style={{ marginBottom: 6, color: 'var(--text-muted)' }}>选择用户</div>
          <div style={{ overflowY: 'auto', maxHeight: 200, border: '1px solid var(--border-light)', borderRadius: 6, padding: 8, display: 'flex', flexDirection: 'column', gap: 4 }}>
            {users.length === 0 && <span style={{ color: 'var(--text-inactive)', fontSize: 11 }}>无其他用户</span>}
            {users.map(u => (
              <label key={u.id} style={{ display: 'flex', alignItems: 'center', gap: 8, cursor: 'pointer', padding: '3px 4px', borderRadius: 4, backgroundColor: selected.has(u.id) ? 'var(--tint-blue-bg)' : 'transparent' }}>
                <input type="checkbox" checked={selected.has(u.id)} onChange={() => toggle(u.id)} />
                <span style={{ fontSize: 12, color: 'var(--text-primary)' }}>{u.username}</span>
              </label>
            ))}
          </div>
        </div>

        <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8 }}>
          <button onClick={onClose} style={{ padding: '5px 14px', borderRadius: 5, border: '1px solid var(--border-light)', backgroundColor: 'transparent', color: 'var(--text-muted)', cursor: 'pointer', fontSize: 12 }}>取消</button>
          <button onClick={handleConfirm} disabled={loading || selected.size === 0}
            style={{ padding: '5px 14px', borderRadius: 5, border: 'none', backgroundColor: 'var(--accent-blue)', color: '#fff', cursor: 'pointer', fontSize: 12, opacity: selected.size === 0 ? 0.4 : 1 }}>
            {loading ? '分享中...' : '确认分享'}
          </button>
        </div>
      </div>
    </div>
  );
};
