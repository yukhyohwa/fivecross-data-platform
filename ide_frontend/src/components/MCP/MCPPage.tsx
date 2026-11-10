import React, { useCallback, useEffect, useState } from 'react';
import { api } from '../../services/api';
import { RemoteMCPPanel } from './RemoteMCPPanel';

/** 统一 FiveCross 工具目录：深度分析工具与本地 MCP 工具合并（可编辑描述/启停）。 */
type CatalogTool = {
  key: string;       // "{source}::{name}"
  name: string;
  description: string;
  source: string;    // chatbi | mcp | sqlide
  enabled: boolean;
  edited: boolean;
};

/** 单个本地工具行：只读展示 + admin 可展开编辑描述/启停。 */
const ToolRow: React.FC<{ tool: CatalogTool; color: string; admin: boolean; onSaved: () => void }> = ({ tool, color, admin, onSaved }) => {
  const [editing, setEditing] = useState(false);
  const [desc, setDesc] = useState(tool.description);
  const [enabled, setEnabled] = useState(tool.enabled);
  const [saving, setSaving] = useState(false);
  const [msg, setMsg] = useState('');

  const startEdit = () => { setDesc(tool.description); setEnabled(tool.enabled); setEditing(true); setMsg(''); };
  const cancel = () => { setEditing(false); setMsg(''); };
  const save = async () => {
    setSaving(true); setMsg('');
    try {
      await api.saveToolMeta(tool.key, desc.trim() ? desc.trim() : null, enabled);
      setMsg('✓ 已保存');
      setEditing(false);
      onSaved();
    } catch (e: any) {
      setMsg(`✗ ${e.message}`);
    }
    setSaving(false);
  };

  const dimmed = !tool.enabled;
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 6, padding: '6px 12px', backgroundColor: 'var(--surface-heavy)', borderRadius: 4, border: '1px solid var(--border-light)', opacity: dimmed ? 0.55 : 1 }}>
      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 8 }}>
        <span style={{ width: 6, height: 6, borderRadius: '50%', backgroundColor: dimmed ? 'var(--text-muted)' : color, marginTop: 5, flexShrink: 0 }} />
        <code style={{ fontSize: 12, color: dimmed ? 'var(--text-muted)' : color, minWidth: 180, fontFamily: 'monospace', flexShrink: 0 }}>{tool.name}</code>
        <span style={{ fontSize: 11, color: 'var(--text-muted)', lineHeight: 1.5, flex: 1 }}>
          {tool.description}
          {dimmed && <span style={{ marginLeft: 8, color: '#e74c3c', fontSize: 10, fontWeight: 600 }}>已停用</span>}
          {tool.edited && <span style={{ marginLeft: 8, color: 'var(--accent-amber)', fontSize: 10 }}>已编辑</span>}
        </span>
        {admin && !editing && (
          <button onClick={startEdit} style={{ fontSize: 11, padding: '2px 10px', borderRadius: 4, border: '1px solid var(--border-light)', backgroundColor: 'transparent', color: 'var(--text-secondary)', cursor: 'pointer', flexShrink: 0 }}>编辑</button>
        )}
      </div>
      {editing && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8, paddingLeft: 14 }}>
          <textarea
            value={desc}
            onChange={e => setDesc(e.target.value)}
            rows={2}
            placeholder="留空 = 回退代码默认描述"
            style={{ padding: '6px 8px', borderRadius: 4, border: '1px solid var(--border-light)', backgroundColor: 'var(--surface-2)', color: 'var(--text-primary)', fontSize: 12, resize: 'vertical', outline: 'none', fontFamily: 'inherit' }}
          />
          <label style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 12, color: 'var(--text-secondary)', cursor: 'pointer' }}>
            <input type="checkbox" checked={enabled} onChange={e => setEnabled(e.target.checked)} style={{ cursor: 'pointer' }} />
            启用（停用后 FiveCross 深度分析不再收到该工具）
          </label>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <button onClick={save} disabled={saving} style={{ padding: '3px 14px', borderRadius: 4, border: 'none', backgroundColor: 'var(--accent-blue)', color: '#fff', fontSize: 11, cursor: saving ? 'not-allowed' : 'pointer', opacity: saving ? 0.7 : 1 }}>{saving ? '保存中...' : '保存'}</button>
            <button onClick={cancel} style={{ padding: '3px 12px', borderRadius: 4, border: '1px solid var(--border-light)', backgroundColor: 'transparent', color: 'var(--text-secondary)', fontSize: 11, cursor: 'pointer' }}>取消</button>
            {msg && <span style={{ fontSize: 11, color: msg.startsWith('✓') ? '#4caf50' : '#e74c3c' }}>{msg}</span>}
          </div>
        </div>
      )}
    </div>
  );
};

export const MCPPage: React.FC = () => {
  const [status, setStatus] = useState<'online' | 'offline'>('offline');
  const [tab, setTab] = useState<'tools' | 'remote'>('tools');
  const [catalog, setCatalog] = useState<CatalogTool[]>([]);
  const [currentUser, setCurrentUser] = useState<{ role: string } | null>(null);
  const [remoteServers, setRemoteServers] = useState<{ id: number; name: string; tools: { name: string; description: string }[]; share_role: string }[]>([]);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    const API_BASE = import.meta.env.VITE_API_BASE || '';
    fetch(`${API_BASE}/api/mcp`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: '1', method: 'tools/list' }),
    }).then(r => r.json()).then(() => setStatus('online')).catch(() => setStatus('offline'));

    loadCatalog();
    loadRemoteServers();
  }, []);

  // 当前用户（判断 admin 编辑权限）
  useEffect(() => {
    api.getMe().then(u => setCurrentUser(u)).catch(() => setCurrentUser(null));
  }, []);

  const loadCatalog = async () => {
    setLoading(true);
    try {
      const data = await api.getToolCatalog();
      // bi_* 平台工具随「BI 平台配置」一起下线：不再展示、不计入目录
      setCatalog((data || []).filter(t => !(t.source === 'mcp' && t.name.startsWith('bi_'))));
    } catch { /* 离线时忽略 */ }
    setLoading(false);
  };

  // useCallback 且依赖为空：这个函数会作为 prop 传给 RemoteMCPPanel，
  // 若每次 render 都换新引用，会让下游的 useCallback/useEffect 反复重跑
  // （表现为 /api/remote-mcp 疯狂请求）。
  const loadRemoteServers = useCallback(async () => {
    try {
      const rows = await api.listRemoteMcpServers();
      setRemoteServers((rows as any[]) || []);
    } catch { /* 未登录/离线时忽略 */ }
  }, []);

  const chatbiTools = catalog.filter(t => t.source === 'chatbi');
  const localTools = catalog.filter(t => t.source === 'mcp');
  const sqlideTools = catalog.filter(t => t.source === 'sqlide');
  const isAdmin = currentUser?.role === 'admin';

  return (
    <div style={{ flex: 1, display: 'flex', flexDirection: 'column', padding: 12, gap: 8, backgroundColor: 'var(--surface-3)', color: 'var(--text-primary)', overflow: 'auto' }}>
      {/* Status bar */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '8px 12px', backgroundColor: 'var(--surface-heavy)', borderRadius: 6, border: '1px solid var(--border-light)' }}>
        <span style={{ width: 8, height: 8, borderRadius: '50%', backgroundColor: status === 'online' ? '#4caf50' : '#e74c3c' }} />
        <span style={{ fontSize: 12, fontWeight: 600 }}>MCP Server</span>
        <span style={{ fontSize: 11, color: status === 'online' ? '#4caf50' : '#e74c3c' }}>{status === 'online' ? '运行中' : '离线'}</span>
        <span style={{ fontSize: 11, color: 'var(--text-muted)', marginLeft: 'auto' }}>端点: /api/mcp | 协议: SSE + JSON-RPC | 已注册 {catalog.length} 个本地工具</span>
      </div>

      {/* Tabs */}
      <div style={{ display: 'flex', gap: 2, borderBottom: '1px solid var(--border-light)', paddingBottom: 4 }}>
        {[
          { key: 'tools', label: `已注册 Tools (${catalog.length})` },
          { key: 'remote', label: `远程 MCP${remoteServers.length ? ` (${remoteServers.length})` : ''}` },
        ].map(t => (
          <button key={t.key} onClick={() => setTab(t.key as any)}
            role="tab" aria-selected={tab === t.key}
            style={{ padding: '4px 12px', borderRadius: '4px 4px 0 0', border: 'none', cursor: 'pointer', fontSize: 12,
              backgroundColor: tab === t.key ? 'var(--surface-hover)' : 'transparent', color: tab === t.key ? '#fff' : 'var(--text-muted)' }}>{t.label}</button>
        ))}
      </div>

      {/* Tools Tab */}
      {tab === 'tools' && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
          {loading && <div style={{ textAlign: 'center', color: 'var(--text-muted)', fontSize: 12, padding: 20 }}>加载中...</div>}
          {!loading && catalog.length === 0 && <div style={{ textAlign: 'center', color: 'var(--text-muted)', fontSize: 12, padding: 20 }}>无已注册工具</div>}

          {/* FiveCross 深度分析工具 */}
          {chatbiTools.length > 0 && (
            <>
              <div style={{ fontSize: 11, color: 'var(--text-muted)', padding: '4px 0', borderBottom: '1px solid var(--border-light)', marginBottom: 2 }}>FiveCross 深度分析工具 ({chatbiTools.length})</div>
              {chatbiTools.map(tool => (
                <ToolRow key={tool.key} tool={tool} color="var(--accent-blue)" admin={isAdmin} onSaved={loadCatalog} />
              ))}
            </>
          )}

          {/* 本地工具 */}
          {localTools.length > 0 && (
            <>
              <div style={{ fontSize: 11, color: 'var(--text-muted)', padding: '4px 0', borderBottom: '1px solid var(--border-light)', marginTop: 8, marginBottom: 2 }}>本地工具 ({localTools.length})</div>
              {localTools.map(tool => (
                <ToolRow key={tool.key} tool={tool} color="var(--accent-amber)" admin={isAdmin} onSaved={loadCatalog} />
              ))}
            </>
          )}

          {/* 系统本地 MCP (sqlide) */}
          {sqlideTools.length > 0 && (
            <>
              <div style={{ fontSize: 11, color: 'var(--text-muted)', padding: '4px 0', borderBottom: '1px solid var(--border-light)', marginTop: 8, marginBottom: 2 }}>系统本地 MCP (sqlide) ({sqlideTools.length})</div>
              {sqlideTools.map(tool => (
                <ToolRow key={tool.key} tool={tool} color="var(--accent-blue)" admin={isAdmin} onSaved={loadCatalog} />
              ))}
            </>
          )}

          {/* 远程 MCP 工具（admin 配置 + 分享给成员的服务器） */}
          {remoteServers.filter(s => (s.tools || []).length > 0).map(s => (
            <div key={`remote-${s.id}`}>
              <div style={{ fontSize: 11, color: 'var(--text-muted)', padding: '4px 0', borderBottom: '1px solid var(--border-light)', marginTop: 8, marginBottom: 2 }}>
                远程 MCP · {s.name} ({s.tools.length}){s.share_role === 'shared' ? ' — 由管理员分享' : ''}
              </div>
              {s.tools.map(tool => (
                <div key={`${s.id}-${tool.name}`} style={{ display: 'flex', alignItems: 'flex-start', gap: 8, padding: '6px 12px', backgroundColor: 'var(--surface-heavy)', borderRadius: 4, border: '1px solid var(--border-light)' }}>
                  <span style={{ width: 6, height: 6, borderRadius: '50%', backgroundColor: '#4caf50', marginTop: 5, flexShrink: 0 }} />
                  <code style={{ fontSize: 12, color: '#ba68c8', minWidth: 180, fontFamily: 'monospace', flexShrink: 0 }}>mcp__{s.name}__{tool.name}</code>
                  <span style={{ fontSize: 11, color: 'var(--text-muted)', lineHeight: 1.5 }}>{tool.description}</span>
                </div>
              ))}
            </div>
          ))}
        </div>
      )}

      {/* Remote MCP Tab */}
      {tab === 'remote' && (
        <RemoteMCPPanel onChanged={loadRemoteServers} />
      )}
    </div>
  );
};
