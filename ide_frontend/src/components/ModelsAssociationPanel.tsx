import React, { useState } from 'react';
import { FileCode, AlertTriangle, Package, ChevronDown, ChevronRight } from 'lucide-react';

/** 关联情况（只读）：绑定取数 SQL + SQL 快照 + 溯源/漂移。数据来自 readModel 结果。 */
export const ModelsAssociationPanel: React.FC<{ data: any }> = ({ data }) => {
  const [sqlOpen, setSqlOpen] = useState(false);

  if (!data || !data.name) {
    return (
      <div style={{ height: '100%', display: 'flex', alignItems: 'center', justifyContent: 'center', color: 'var(--text-inactive)', fontSize: 12, padding: 16, textAlign: 'center' }}>
        选择或保存模型后显示取数 SQL 与快照情况
      </div>
    );
  }

  const meta = data.meta || {};
  const input = meta.input || 'sql';
  const sql = meta.sql || '';
  const drift: string[] = data.drift || [];
  const sources: any[] = data.sources || [];
  const hasSnapshot = !!meta.sql_transformed && !!data.model_sql;

  return (
    <div style={{ height: '100%', overflowY: 'auto', padding: 12, backgroundColor: 'var(--surface-1)' }}>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, alignItems: 'center', marginBottom: 8 }}>
        <span style={{ fontSize: 12, fontWeight: 600, color: 'var(--text-primary)' }}>取数 SQL 与快照</span>
        <span style={{ fontSize: 11, color: 'var(--text-muted)' }}>
          {input === 'upload' ? '离线上传 · 无取数 SQL' : (sql ? `取数 SQL「${sql}」` : '未关联取数 SQL')}
        </span>
      </div>

      {input === 'upload' && (
        <p style={{ fontSize: 11, color: 'var(--text-muted)', margin: '0 0 8px' }}>离线上传模型不关联取数 SQL，也不生成 SQL 快照。</p>
      )}

      {drift.length > 0 && (
        <div style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '6px 8px', borderRadius: 4, backgroundColor: 'var(--tint-amber-bg)', border: '1px solid var(--tint-amber-border)', marginBottom: 8 }}>
          <AlertTriangle size={13} style={{ color: '#f90', flexShrink: 0 }} />
          <span style={{ fontSize: 11, color: '#f90' }}>{drift.length} 个来源已更新，快照仍用冻结内容，需点「刷新快照」</span>
        </div>
      )}

      <div style={{ display: 'flex', alignItems: 'center', gap: 5, marginBottom: 4 }}>
        <FileCode size={12} style={{ color: 'var(--accent-blue)' }} />
        <span style={{ fontSize: 11, fontWeight: 600, color: 'var(--text-secondary)' }}>SQL 快照</span>
      </div>
      <div style={{ paddingLeft: 17 }}>
        {input !== 'sql' ? (
          <span style={{ fontSize: 11, color: 'var(--text-inactive)' }}>（离线上传，无快照）</span>
        ) : hasSnapshot ? (
          <div>
            {/* 审计 P2-12：折叠钮为原生 button 已键盘可达，补 aria-expanded 表状态 */}
            <button onClick={() => setSqlOpen((v) => !v)}
              aria-expanded={sqlOpen}
              style={{ display: 'flex', alignItems: 'center', gap: 5, background: 'none', border: 'none', padding: 0, cursor: 'pointer' }}>
              {sqlOpen ? <ChevronDown size={11} style={{ color: 'var(--text-muted)' }} /> : <ChevronRight size={11} style={{ color: 'var(--text-muted)' }} />}
              <span style={{ fontSize: 11, color: 'var(--text-primary)' }}>已生成专属 SQL 快照（点开查看）</span>
            </button>
            {sqlOpen && (
              <pre style={{ margin: '6px 0 0', padding: 8, borderRadius: 4, backgroundColor: 'var(--surface-2)', border: '1px solid var(--border-light)', fontSize: 11, color: 'var(--text-secondary)', whiteSpace: 'pre-wrap', wordBreak: 'break-word', maxHeight: 240, overflowY: 'auto' }}>
                {data.model_sql}
              </pre>
            )}
          </div>
        ) : (
          <span style={{ fontSize: 11, color: 'var(--text-inactive)' }}>未生成快照（可直接复用原取数 SQL，或点「生成SQL快照」）</span>
        )}
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: 5, margin: '12px 0 4px' }}>
        <Package size={12} style={{ color: 'var(--accent-amber)' }} />
        <span style={{ fontSize: 11, fontWeight: 600, color: 'var(--text-secondary)' }}>溯源</span>
      </div>
      <div style={{ paddingLeft: 17, display: 'flex', flexDirection: 'column', gap: 2 }}>
        {sources.length === 0 ? (
          <span style={{ fontSize: 11, color: 'var(--text-inactive)' }}>（暂无溯源）</span>
        ) : sources.map((s, i) => {
          const stale = drift.includes(s.name);
          return (
            <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 5, fontSize: 11 }}>
              <span style={{ color: stale ? '#e74c3c' : 'var(--text-primary)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', flex: 1 }}>
                {s.kind === 'sql' ? 'SQL' : s.kind === 'doc' ? '文档' : s.kind}「{s.name}」
              </span>
              {stale && <span style={{ color: '#e74c3c', fontSize: 10, flexShrink: 0 }}>源已更新</span>}
            </div>
          );
        })}
      </div>
    </div>
  );
};

export default ModelsAssociationPanel;
