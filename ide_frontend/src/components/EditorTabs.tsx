import React from 'react';
import { useStore } from '../stores/useStore';
import { Plus, X } from 'lucide-react';

export const EditorTabs: React.FC = () => {
  const {
    editorTabs,
    activeEditorTabId,
    addEditorTab,
    switchEditorTab,
    closeEditorTab,
    maxRows,
    setMaxRows,
  } = useStore();

  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        borderBottom: '1px solid var(--border-light)',
        backgroundColor: 'var(--surface-1)',
        flexShrink: 0,
      }}
    >
      {/* Scrollable tabs area（审计 P2-12：role=tablist/tab + Enter/Space 切换） */}
      <div role="tablist" aria-label="查询标签页" style={{
        display: 'flex',
        alignItems: 'center',
        flex: 1,
        minWidth: 0,
        overflowX: 'auto',
        overflowY: 'hidden',
      }}>
        {editorTabs.map((tab) => {
          const isActive = tab.id === activeEditorTabId;
          return (
            <div
              key={tab.id}
              role="tab"
              aria-selected={isActive}
              tabIndex={0}
              onClick={() => switchEditorTab(tab.id)}
              onKeyDown={(e) => {
                if (e.target !== e.currentTarget) return; // 关闭钮聚焦时不触发切换（审计 P2-12）
                if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); switchEditorTab(tab.id); }
              }}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 6,
                padding: '5px 10px',
                cursor: 'pointer',
                fontSize: 12,
                color: isActive ? 'var(--text-primary)' : 'var(--text-muted)',
                borderRight: '1px solid var(--surface-heavy)',
                backgroundColor: isActive ? 'var(--surface-2)' : 'transparent',
                borderBottom: isActive ? '2px solid var(--accent-blue)' : '2px solid transparent',
                whiteSpace: 'nowrap',
                userSelect: 'none',
                maxWidth: 160,
                flexShrink: 0,
              }}
            >
              <span style={{ overflow: 'hidden', textOverflow: 'ellipsis' }}>{tab.label}</span>
              {editorTabs.length > 1 && (
                <button onClick={(e) => { e.stopPropagation(); closeEditorTab(tab.id); }} style={btnStyle} aria-label={`关闭标签 ${tab.label}`}>
                  <X size={11} />
                </button>
              )}
            </div>
          );
        })}

        <button onClick={addEditorTab} style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', padding: '5px 10px', border: 'none', background: 'none', color: 'var(--text-muted)', cursor: 'pointer', fontSize: 14, flexShrink: 0 }} title="新建查询标签页" aria-label="新建查询标签页">
          <Plus size={14} />
        </button>
      </div>

      {/* Pinned max rows control — always visible on the right */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 4, padding: '0 8px', flexShrink: 0, borderLeft: '1px solid var(--border-light)' }}>
        <span style={{ fontSize: 11, color: 'var(--text-muted)', whiteSpace: 'nowrap' }}>行数</span>
        <input
          type="number"
          value={maxRows}
          onChange={(e) => setMaxRows(parseInt(e.target.value) || 0)}
          aria-label="最大返回行数"
          style={{
            width: 52,
            padding: '2px 4px',
            borderRadius: 3,
            border: '1px solid var(--text-muted)',
            backgroundColor: 'var(--surface-1)',
            color: 'var(--text-primary)',
            fontSize: 11,
            outline: 'none',
            textAlign: 'right',
          }}
          title="最大返回行数，0 为不限制；若 SQL 本身含 LIMIT 则优先"
        />
      </div>
    </div>
  );
};

const btnStyle: React.CSSProperties = {
  background: 'none', border: 'none', color: 'var(--text-muted)', cursor: 'pointer', padding: 0, display: 'flex', fontSize: 12,
};
