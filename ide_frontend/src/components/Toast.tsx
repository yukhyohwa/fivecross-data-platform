import React, { createContext, useContext, useState, useCallback, useRef } from 'react';
import { CheckCircle, AlertCircle, Info, X } from 'lucide-react';

type ToastType = 'success' | 'error' | 'info';

interface ToastItem {
  id: number;
  type: ToastType;
  message: string;
}

interface ToastContextValue {
  toast: (message: string, type?: ToastType) => void;
  success: (message: string) => void;
  error: (message: string) => void;
  info: (message: string) => void;
}

const ToastContext = createContext<ToastContextValue | null>(null);

export const useToast = () => {
  const ctx = useContext(ToastContext);
  if (!ctx) throw new Error('useToast must be used within ToastProvider');
  return ctx;
};

export const ToastProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const [toasts, setToasts] = useState<ToastItem[]>([]);
  const counter = useRef(0);

  const remove = useCallback((id: number) => {
    setToasts((p) => p.filter((t) => t.id !== id));
  }, []);

  const toast = useCallback((message: string, type: ToastType = 'info') => {
    const id = ++counter.current;
    setToasts((p) => [...p, { id, type, message }]);
    setTimeout(() => remove(id), type === 'error' ? 5000 : 3000);
  }, [remove]);

  const success = useCallback((msg: string) => toast(msg, 'success'), [toast]);
  const error = useCallback((msg: string) => toast(msg, 'error'), [toast]);
  const info = useCallback((msg: string) => toast(msg, 'info'), [toast]);

  return (
    <ToastContext.Provider value={{ toast, success, error, info }}>
      {children}
      {/* 审计 P2-12：fixed 定位交给全局 .toast-stack（宽屏右下角，窄屏铺满底部） */}
      <div className="toast-stack">
        {toasts.map((t) => (
          <ToastItem key={t.id} item={t} onRemove={remove} />
        ))}
      </div>
    </ToastContext.Provider>
  );
};

const ICONS: Record<ToastType, React.ReactNode> = {
  success: <CheckCircle size={15} style={{ color: '#4caf50', flexShrink: 0 }} />,
  error: <AlertCircle size={15} style={{ color: '#e74c3c', flexShrink: 0 }} />,
  info: <Info size={15} style={{ color: 'var(--accent-blue)', flexShrink: 0 }} />,
};

const BG: Record<ToastType, string> = {
  success: 'var(--tint-green-bg)',
  error: 'var(--tint-red-bg)',
  info: 'var(--tint-blue-bg)',
};

const BORDER: Record<ToastType, string> = {
  success: 'var(--tint-green-border)',
  error: 'var(--tint-red-border)',
  info: 'var(--tint-blue-border)',
};

const ToastItem: React.FC<{ item: ToastItem; onRemove: (id: number) => void }> = ({ item, onRemove }) => {
  return (
    /* 审计 P2-12：role=status 让新通知按 polite 方式被读屏播报 */
    <div role="status" style={{
      display: 'flex', alignItems: 'center', gap: 8,
      padding: '10px 14px', borderRadius: 8,
      backgroundColor: BG[item.type], border: `1px solid ${BORDER[item.type]}`,
      boxShadow: '0 4px 12px rgba(0,0,0,0.4)',
      fontSize: 13, color: 'var(--text-primary)', maxWidth: 360,
      pointerEvents: 'auto',
      animation: 'toast-in 0.2s ease-out',
    }}>
      {ICONS[item.type]}
      <span style={{ flex: 1, lineHeight: 1.4 }}>{item.message}</span>
      {/* 审计 P2-12：纯图标按钮补 aria-label */}
      <button
        onClick={() => onRemove(item.id)}
        aria-label="关闭通知"
        style={{ background: 'none', border: 'none', color: 'var(--text-muted)', cursor: 'pointer', padding: 0, display: 'flex', flexShrink: 0 }}
      >
        <X size={13} />
      </button>
    </div>
  );
};
