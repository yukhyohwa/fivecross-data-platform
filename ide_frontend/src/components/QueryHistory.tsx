import React, { useState, useMemo, useCallback, useEffect } from 'react';
import { useStore } from '../stores/useStore';
import { useToast } from './Toast';
import { api } from '../services/api';
import { overlayStyle, dialogStyle, saveCancelBtn, dangerBtn } from './wsCommon';
import { useDialog } from '../lib/useDialog';
import { Clock, Trash2, X, Search, ChevronDown, ChevronRight } from 'lucide-react';

interface HistoryItem {
  id: number;
  session_id: string;
  game: string;
  sql: string;
  status: string;
  row_count: number;
  duration_ms: number;
  created_at: string;
}

const formatTime = (isoStr: string) => {
  try {
    const d = new Date(isoStr);
    return d.toLocaleString('zh-CN', { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' });
  } catch { return isoStr; }
};

const HistoryRow: React.FC<{ item: HistoryItem; onLoad: (sql: string) => void }> = ({ item, onLoad }) => {
  const [expanded, setExpanded] = useState(false);
  const isLong = item.sql.length > 60;
  const ok = item.status === 'ok';

  return (
    <div style={{ padding: '7px 10px', borderRadius: 6, marginBottom: 2, borderLeft: '3px solid transparent', cursor: 'default' }}
      onMouseEnter={(e) => { (e.currentTarget as HTMLElement).style.backgroundColor = 'var(--surface-2)'; (e.currentTarget as HTMLElement).style.borderLeftColor = 'var(--border-light)'; }}
      onMouseLeave={(e) => { (e.currentTarget as HTMLElement).style.backgroundColor = 'transparent'; (e.currentTarget as HTMLElement).style.borderLeftColor = 'transparent'; }}
    >
      <div style={{ fontSize: 11, marginBottom: 3, display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
        <span style={{ color: ok ? 'var(--accent-blue)' : '#e74c3c', flexShrink: 0, fontWeight: 600 }}>{ok ? '✓' : '✗'}</span>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6, flexShrink: 0 }}>
          {item.row_count != null && <span style={{ color: 'var(--text-inactive)' }}>{item.row_count} 行</span>}
          {item.duration_ms != null && <span style={{ color: 'var(--text-inactive)' }}>{item.duration_ms < 1000 ? `${item.duration_ms}ms` : `${(item.duration_ms / 1000).toFixed(1)}s`}</span>}
          <span style={{ color: 'var(--text-inactive)' }}>{formatTime(item.created_at)}</span>
        </div>
      </div>
      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 4 }}>
        {isLong && (
          <button onClick={() => setExpanded((p) => !p)} aria-label={expanded ? '收起 SQL' : '展开 SQL'} aria-expanded={expanded}
            style={{ background: 'none', border: 'none', color: 'var(--text-inactive)', cursor: 'pointer', padding: 0, flexShrink: 0, marginTop: 1 }}>
            {expanded ? <ChevronDown size={11} /> : <ChevronRight size={11} />}
          </button>
        )}
        {/* 审计 P2-12：可点击 SQL 条目 → role=button 键盘可达 */}
        <code
          onClick={() => onLoad(item.sql)}
          role="button"
          tabIndex={0}
          onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onLoad(item.sql); } }}
          title="点击加载到编辑器"
          style={{
            fontSize: 11, color: 'var(--text-muted)', display: 'block', cursor: 'pointer',
            whiteSpace: expanded ? 'pre-wrap' : 'nowrap',
            overflow: expanded ? 'visible' : 'hidden',
            textOverflow: expanded ? 'clip' : 'ellipsis',
            flex: 1, wordBreak: 'break-all',
          }}
        >
          {item.sql}
        </code>
      </div>
    </div>
  );
};

/** 历史记录侧栏：按当前 AI 会话（sqlSessionId）拉取 SQL 执行历史。 */
export const QueryHistory: React.FC<{ onClose?: () => void }> = ({ onClose }) => {
  const { sqlSessionId, setSql, sql, addEditorTab } = useStore();
  const { info } = useToast();
  const [items, setItems] = useState<HistoryItem[]>([]);
  const [loading, setLoading] = useState(false);
  const [search, setSearch] = useState('');
  // 清空确认弹窗开关（审计 P2-5：内联确认替代 window.confirm）
  const [confirmClear, setConfirmClear] = useState(false);
  // 审计 P2-12：清空确认弹窗无障碍（Escape 关闭 + 打开聚焦 + 焦点还原）
  const confirmDialogRef = useDialog(confirmClear, () => setConfirmClear(false));

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const r = await api.listSqlHistory(sqlSessionId);
      setItems(r.items || []);
    } catch { setItems([]); } finally { setLoading(false); }
  }, [sqlSessionId]);

  useEffect(() => { load(); }, [load]);

  const lowerSearch = search.toLowerCase();
  const filtered = useMemo(() =>
    lowerSearch ? items.filter((item) => item.sql.toLowerCase().includes(lowerSearch)) : items,
    [items, lowerSearch]
  );

  const handleLoad = (historySql: string) => {
    if (sql.trim()) {
      addEditorTab();
      setSql(historySql);
      info('已在新标签页打开');
    } else {
      setSql(historySql);
    }
  };

  const handleClear = async () => {
    // 审计 P2-5：内联确认弹窗替代 window.confirm
    setConfirmClear(true);
  };

  const confirmClearHistory = async () => {
    setConfirmClear(false);
    await api.clearSqlHistory(sqlSessionId).catch(() => {});
    setItems([]);
  };

  return (
    <div style={{ width: '100%', height: '100%', minHeight: 0, borderRight: '1px solid var(--border-light)', display: 'flex', flexDirection: 'column', backgroundColor: 'var(--surface-1)' }}>
      {/* 审计 P2-12：头部窄屏可换行（宽屏不溢出则不生效） */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '10px 12px', borderBottom: '1px solid var(--border-light)', flexWrap: 'wrap', gap: 4 }}>
        <h3 style={{ margin: 0, fontSize: 14, color: 'var(--text-primary)', display: 'flex', alignItems: 'center', gap: 6 }}><Clock size={14} /> 历史记录</h3>
        <div style={{ display: 'flex', gap: 4 }}>
          <button onClick={handleClear} style={iconBtnStyle} title="清空当前会话历史" aria-label="清空当前会话历史"><Trash2 size={14} /></button>
          {onClose && <button onClick={onClose} style={iconBtnStyle} title="关闭" aria-label="关闭"><X size={14} /></button>}
        </div>
      </div>

      <div style={{ padding: '6px 8px', borderBottom: '1px solid var(--surface-heavy)' }}>
        <div style={{ position: 'relative' }}>
          <Search size={11} style={{ position: 'absolute', left: 8, top: '50%', transform: 'translateY(-50%)', color: 'var(--text-inactive)', pointerEvents: 'none' }} />
          <input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="搜索 SQL..." aria-label="搜索 SQL" style={{ ...searchInput, paddingLeft: 24 }} />
        </div>
      </div>

      <div style={{ flex: 1, overflowY: 'auto', padding: 4 }}>
        {loading ? (
          <p style={{ textAlign: 'center', color: 'var(--text-inactive)', fontSize: 12, marginTop: 20 }}>加载中...</p>
        ) : filtered.length === 0 ? (
          <p style={{ textAlign: 'center', color: 'var(--text-inactive)', fontSize: 12, marginTop: 20 }}>
            {search ? '无匹配' : sqlSessionId ? '当前会话暂无历史记录' : '暂无历史记录（执行 SQL 后按 AI 会话记录）'}
          </p>
        ) : (
          filtered.map((item) => (
            <HistoryRow key={item.id} item={item} onLoad={handleLoad} />
          ))
        )}
      </div>

      {/* 清空历史确认弹窗（审计 P2-5：自研内联确认，替代 window.confirm；审计 P2-12：role=dialog + useDialog） */}
      {confirmClear && (
        <div onClick={() => setConfirmClear(false)} style={overlayStyle}>
          <div ref={confirmDialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={dialogStyle}>
            <p style={{ margin: 0, fontSize: 13, color: 'var(--text-primary)' }}>确认清空当前会话的 SQL 执行历史？</p>
            <p style={{ margin: '6px 0 0', fontSize: 11, color: 'var(--text-muted)' }}>此操作不可撤销。</p>
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end', marginTop: 14 }}>
              <button onClick={() => setConfirmClear(false)} style={saveCancelBtn}>取消</button>
              <button onClick={confirmClearHistory} style={dangerBtn}>清空</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};

const iconBtnStyle: React.CSSProperties = { background: 'none', border: 'none', color: 'var(--text-muted)', cursor: 'pointer', padding: 4, display: 'flex', alignItems: 'center', borderRadius: 4 };
const searchInput: React.CSSProperties = { width: '100%', padding: '4px 8px', borderRadius: 4, border: '1px solid var(--text-muted)', backgroundColor: 'var(--surface-1)', color: 'var(--text-on-accent)', fontSize: 12, outline: 'none', boxSizing: 'border-box' };
