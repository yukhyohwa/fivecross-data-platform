import React, { useState } from 'react';
import { api } from '../services/api';
import { useDialog } from '../lib/useDialog';
import { X } from 'lucide-react';

export const ChangePasswordDialog: React.FC<{ onClose: () => void }> = ({ onClose }) => {
  const [oldPwd, setOldPwd] = useState('');
  const [newPwd, setNewPwd] = useState('');
  const [msg, setMsg] = useState('');
  const [err, setErr] = useState('');
  const [saving, setSaving] = useState(false);

  // 审计 P2-12：弹窗接入 useDialog（Escape 关闭 + 打开聚焦 + 关闭还原焦点）；本组件仅在打开时挂载
  const dialogRef = useDialog(true, onClose);

  const handleSubmit = async () => {
    if (!oldPwd || !newPwd) { setErr('请填写完整'); return; }
    if (newPwd.length < 6) { setErr('新密码至少 6 个字符'); return; }
    setErr(''); setMsg('');
    setSaving(true);
    try {
      await api.changePassword(oldPwd, newPwd);
      setMsg('密码已修改');
      setOldPwd(''); setNewPwd('');
      setTimeout(onClose, 1200);
    } catch (e: any) { setErr(e.message); }
    setSaving(false);
  };

  return (
    // 审计 P2-12：遮罩点击关闭；卡片 role/aria-modal/tabIndex 弹窗语义；宽度 min() 化 + 80vh 滚动
    <div onClick={onClose} style={{ position: 'fixed', inset: 0, backgroundColor: 'rgba(0,0,0,0.5)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 'var(--z-modal)' }}>
      <div ref={dialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={{ backgroundColor: 'var(--surface-3)', borderRadius: 12, padding: 24, width: 'min(380px,94vw)', maxHeight: '80vh', overflowY: 'auto', border: '1px solid var(--border-light)', color: 'var(--text-primary)' }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 16 }}>
          <h3 style={{ margin: 0, fontSize: 16 }}>修改密码</h3>
          <button onClick={onClose} aria-label="关闭" style={{ background: 'none', border: 'none', color: 'var(--text-muted)', cursor: 'pointer', padding: 4 }}><X size={18} /></button>
        </div>
        <input type="password" placeholder="原密码" aria-label="原密码" value={oldPwd} onChange={(e) => setOldPwd(e.target.value)} style={inpS} />
        <input type="password" placeholder="新密码（至少6位）" aria-label="新密码（至少6位）" value={newPwd} onChange={(e) => setNewPwd(e.target.value)} style={inpS} />
        {err && <div style={{ marginTop: 8, padding: '6px 10px', borderRadius: 6, backgroundColor: 'var(--tint-red-bg)', color: '#e74c3c', fontSize: 13 }}>{err}</div>}
        {msg && <div style={{ marginTop: 8, padding: '6px 10px', borderRadius: 6, backgroundColor: 'var(--tint-green-bg)', color: '#5a5', fontSize: 13 }}>{msg}</div>}
        <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end', marginTop: 16 }}>
          <button onClick={onClose} disabled={saving} style={{ padding: '6px 16px', borderRadius: 6, border: '1px solid var(--text-muted)', backgroundColor: 'transparent', color: 'var(--text-muted)', cursor: 'pointer', fontSize: 13 }}>取消</button>
          <button onClick={handleSubmit} disabled={saving} style={{ padding: '6px 16px', borderRadius: 6, border: 'none', backgroundColor: 'var(--accent-blue)', color: '#fff', cursor: 'pointer', fontSize: 13, opacity: saving ? 0.6 : 1 }}>{saving ? '修改中...' : '确认修改'}</button>
        </div>
      </div>
    </div>
  );
};

const inpS: React.CSSProperties = { width: '100%', padding: '8px 12px', borderRadius: 6, border: '1px solid var(--text-muted)', backgroundColor: 'var(--surface-1)', color: 'var(--text-on-accent)', fontSize: 13, outline: 'none', boxSizing: 'border-box', marginBottom: 8 };
