import React, { useCallback, useEffect, useRef, useState } from 'react';
import { api } from '../../services/api';
import { ShareDialog } from '../ShareDialog';
import { overlayStyle, dialogStyle, saveCancelBtn, dangerBtn } from '../wsCommon';
import { useDialog } from '../../lib/useDialog';

type Server = {
  id: number;
  name: string;
  url: string;
  transport: string;
  command: string;
  auth_type: string;
  auth_register_url: string;
  auth_authorize_url: string;
  auth_token_url: string;
  auth_scope: string;
  auth_resource: string;
  enabled: boolean;
  share_role: string;
  my_permission: string;
  shared_by_username?: string;
  has_credentials: boolean;
  has_refresh_token: boolean;
  credential_expires_at: number | null;
  tools: { name: string; description: string }[];
  tools_count: number;
  last_status: string;
  last_error: string;
  last_checked_at: string | null;
};

const EMPTY_FORM = {
  id: undefined as number | undefined,
  name: '',
  url: '',
  transport: 'http',
  command: '',
  args: '',
  auth_type: 'oauth2',
  auth_register_url: '',
  auth_authorize_url: '',
  auth_token_url: '',
  auth_scope: '',
  auth_resource: '',
};

/** Sensor Tower 预置（第一个配置项，仍走通用 POST） */
const SENSOR_TOWER: Partial<typeof EMPTY_FORM> = {
  name: 'sensortower',
  url: 'https://mcp.sensortower.com/mcp',
  transport: 'http',
  auth_type: 'oauth2',
  auth_register_url: 'https://mcp.sensortower.com/mcp/register',
  auth_authorize_url: 'https://mcp.sensortower.com/oauth/authorize',
  auth_token_url: 'https://mcp.sensortower.com/oauth/token',
  auth_scope: 'data_read',
  auth_resource: 'https://mcp.sensortower.com/mcp',
};

const label: React.CSSProperties = { fontSize: 11, color: 'var(--text-muted)' };
const input: React.CSSProperties = {
  padding: '5px 8px', borderRadius: 4, border: '1px solid var(--border-light)',
  backgroundColor: 'var(--surface-2)', color: 'var(--text-primary)', fontSize: 12, outline: 'none',
};
// 中性按钮：边框用 --border-light，但文字必须用可读的 --text-primary。
// （早期版本把两者都设成 --border-light，导致「测试/编辑/分享/停用」几乎隐形。）
const btn = (color?: string): React.CSSProperties => ({
  padding: '3px 10px', borderRadius: 4,
  border: `1px solid ${color || 'var(--border-light)'}`,
  backgroundColor: 'transparent',
  color: color || 'var(--text-primary)',
  cursor: 'pointer', fontSize: 11, whiteSpace: 'nowrap',
});

export const RemoteMCPPanel: React.FC<{ onChanged?: () => void }> = ({ onChanged }) => {
  const [servers, setServers] = useState<Server[]>([]);
  const [isAdmin, setIsAdmin] = useState(false);
  const [loading, setLoading] = useState(false);
  const [msg, setMsg] = useState('');
  const [showForm, setShowForm] = useState(false);
  const [form, setForm] = useState({ ...EMPTY_FORM });
  const [saving, setSaving] = useState(false);
  const [bearerFor, setBearerFor] = useState<number | null>(null);
  const [bearerToken, setBearerToken] = useState('');
  const [shareFor, setShareFor] = useState<number | null>(null);
  // 删除确认弹窗目标（审计 P2-5：内联确认替代原生 confirm）
  const [deleteTarget, setDeleteTarget] = useState<Server | null>(null);
  // OAuth 会话：环回可达时自动完成；不可达时靠粘贴地址栏 URL
  const [oauth, setOauth] = useState<{
    serverId: number; state: string; authorizeUrl: string; port: number;
    warning?: string; paste: string; status: string; error?: string;
    loopback: boolean;
  } | null>(null);
  const pollRef = useRef<number | null>(null);
  // 用 ref 持有回调：避免 onChanged 的引用变化影响 refresh 的 identity，
  // 进而让下面的 useEffect 反复触发（会打爆 /api/remote-mcp）。
  const onChangedRef = useRef(onChanged);
  useEffect(() => { onChangedRef.current = onChanged; }, [onChanged]);

  // 审计 P2-12：删除确认弹窗接入 useDialog（Escape 关闭 + 打开聚焦 + 关闭还原焦点）
  const deleteDialogRef = useDialog(deleteTarget !== null, () => setDeleteTarget(null));

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      const rows = await api.listRemoteMcpServers();
      setServers(rows || []);
      onChangedRef.current?.();
    } catch (e: any) {
      setMsg(`加载失败：${e?.message || e}`);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    refresh();
    api.getMe().then((u: { role?: string }) => setIsAdmin(u?.role === 'admin')).catch(() => {});
  }, [refresh]);

  // OAuth 结果轮询：环回 listener 收到回调后会回填
  useEffect(() => {
    if (!oauth || oauth.status !== 'pending') {
      if (pollRef.current) { window.clearInterval(pollRef.current); pollRef.current = null; }
      return;
    }
    pollRef.current = window.setInterval(async () => {
      try {
        const r = await api.remoteMcpOAuthStatus(oauth.state);
        if (r.status === 'ok') {
          setOauth(o => (o ? { ...o, status: 'ok' } : o));
          setMsg(`✓ 授权成功，已发现 ${r.tools_count ?? 0} 个工具`);
          refresh();
        } else if (r.status === 'error') {
          setOauth(o => (o ? { ...o, status: 'error', error: r.error } : o));
        } else if (r.status === 'expired') {
          setOauth(o => (o ? { ...o, status: 'expired', error: '授权会话已过期，请重新发起' } : o));
        }
      } catch { /* 轮询失败忽略，下一轮再试 */ }
    }, 2000);
    return () => { if (pollRef.current) { window.clearInterval(pollRef.current); pollRef.current = null; } };
  }, [oauth, refresh]);

  const startOAuth = async (s: Server) => {
    setMsg('');
    try {
      const r = await api.startRemoteMcpOAuth(s.id);
      setOauth({
        serverId: s.id, state: r.state, authorizeUrl: r.authorize_url, port: r.callback_port,
        warning: r.listener_warning, paste: '', status: 'pending',
        loopback: !!r.loopback_reachable,
      });
      window.open(r.authorize_url, '_blank', 'noopener');
    } catch (e: any) {
      setMsg(`发起授权失败：${e?.message || e}`);
    }
  };

  const submitPaste = async () => {
    if (!oauth || !oauth.paste.trim()) return;
    try {
      const r = await api.completeRemoteMcpOAuth(oauth.paste.trim());
      if (r.ok) {
        setMsg(`✓ 授权成功，已发现 ${r.tools_count ?? 0} 个工具`);
        setOauth(null);
        refresh();
      } else {
        setOauth(o => (o ? { ...o, status: 'error', error: r.error || '换取 token 失败' } : o));
      }
    } catch (e: any) {
      setOauth(o => (o ? { ...o, status: 'error', error: e?.message || String(e) } : o));
    }
  };

  const runTest = async (s: Server) => {
    setMsg('');
    try {
      const r = await api.testRemoteMcpServer(s.id);
      setMsg(r.ok ? `✓ ${s.name}：连通，${r.tools_count} 个工具` : `✗ ${s.name}：${r.error}`);
      refresh();
    } catch (e: any) {
      setMsg(`测试失败：${e?.message || e}`);
    }
  };

  const saveForm = async () => {
    setSaving(true);
    setMsg('');
    try {
      if (form.transport === 'stdio' && !form.command.trim()) throw new Error('stdio 传输必须填写 command');
      await api.saveRemoteMcpServer({
        ...form,
        args: form.args ? form.args.split(/\s+/).filter(Boolean) : [],
      });
      setShowForm(false);
      setForm({ ...EMPTY_FORM });
      setMsg('✓ 已保存');
      refresh();
    } catch (e: any) {
      setMsg(`保存失败：${e?.message || e}`);
    } finally {
      setSaving(false);
    }
  };

  const editServer = (s: Server) => {
    setForm({
      id: s.id, name: s.name, url: s.url, transport: s.transport, command: s.command,
      args: '', auth_type: s.auth_type, auth_register_url: s.auth_register_url,
      auth_authorize_url: s.auth_authorize_url, auth_token_url: s.auth_token_url,
      auth_scope: s.auth_scope, auth_resource: s.auth_resource,
    });
    setShowForm(true);
  };

  /** 删除确认弹窗「删除」按钮的执行体（审计 P2-5：内联确认替代原生 confirm） */
  const confirmDeleteServer = () => {
    if (!deleteTarget) return;
    const s = deleteTarget;
    setDeleteTarget(null);
    api.deleteRemoteMcpServer(s.id).then(() => { setMsg('已删除'); refresh(); });
  };

  const statusBadge = (s: Server) => {
    if (s.last_status === 'needs_auth') return { color: '#e74c3c', text: '已失效' };
    if (s.last_status === 'error') return { color: '#e74c3c', text: '异常' };
    if (!s.has_credentials && s.auth_type !== 'none') return { color: '#e67e22', text: '未配置' };
    if (s.last_status === 'ok') return { color: '#4caf50', text: '有效' };
    return { color: '#e67e22', text: '待测试' };
  };

  const field = (k: keyof typeof EMPTY_FORM, lbl: string, ph = '', type = 'text') => (
    <div key={k} style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
      <label style={label}>{lbl}</label>
      <input type={type} style={input} value={String(form[k] ?? '')} placeholder={ph}
        onChange={e => setForm(f => ({ ...f, [k]: e.target.value }))} />
    </div>
  );

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 10, maxWidth: 860 }}>
      <div style={{ fontSize: 12, color: 'var(--text-muted)', lineHeight: 1.6 }}>
        配置一次外部 MCP 服务器，Agent 每轮对话即可调用其工具（工具名形如{' '}
        <code style={{ background: 'var(--surface-1)', padding: '1px 4px', borderRadius: 2 }}>mcp__&lt;名称&gt;__&lt;工具&gt;</code>）。
        {isAdmin ? ' 授权后可在「分享」里发给成员。' : ' 下列服务器由管理员配置并分享。'}
      </div>

      {isAdmin && (
        <div style={{ display: 'flex', gap: 8 }}>
          <button onClick={() => { setForm({ ...EMPTY_FORM }); setShowForm(true); }}
            style={{ ...btn('var(--accent-blue)'), padding: '5px 14px', fontSize: 12 }}>新增服务器</button>
          <button onClick={() => { setForm({ ...EMPTY_FORM, ...SENSOR_TOWER } as any); setShowForm(true); }}
            style={{ ...btn('var(--accent-blue)'), padding: '5px 14px', fontSize: 12 }}>预填 Sensor Tower</button>
        </div>
      )}

      {msg && (
        <div style={{ fontSize: 12, color: msg.startsWith('✓') ? '#4caf50' : '#e74c3c' }}>{msg}</div>
      )}

      {loading && <div style={{ fontSize: 12, color: 'var(--text-muted)' }}>加载中...</div>}
      {!loading && servers.length === 0 && (
        <div style={{ fontSize: 12, color: 'var(--text-muted)', padding: 16, textAlign: 'center', border: '1px dashed var(--border-light)', borderRadius: 6 }}>
          {isAdmin ? '尚未配置任何远程 MCP 服务器' : '管理员还没有分享远程 MCP 服务器给你'}
        </div>
      )}

      {servers.map(s => {
        const badge = statusBadge(s);
        const isOwner = s.share_role === 'owner';
        return (
          <div key={s.id} style={{ display: 'flex', flexDirection: 'column', gap: 8, padding: '10px 12px', backgroundColor: 'var(--surface-heavy)', borderRadius: 6, border: '1px solid var(--border-light)' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
              <span style={{ width: 8, height: 8, borderRadius: '50%', backgroundColor: badge.color }} />
              <strong style={{ fontSize: 13 }}>{s.name}</strong>
              <span style={{ fontSize: 11, color: 'var(--text-muted)' }}>
                {s.transport === 'stdio' ? `stdio · ${s.command}` : s.url}
              </span>
              <span style={{ fontSize: 10, padding: '1px 6px', borderRadius: 3, border: `1px solid ${badge.color}`, color: badge.color }}>{badge.text}</span>
              {!isOwner && (
                <span style={{ fontSize: 10, color: 'var(--text-inactive)' }}>
                  由 {s.shared_by_username || '管理员'} 分享{s.my_permission === 'read' ? ' · 只读' : ''}
                </span>
              )}
              {isOwner && !s.enabled && <span style={{ fontSize: 10, color: '#e74c3c' }}>已停用</span>}
            </div>

            <div style={{ fontSize: 11, color: 'var(--text-muted)' }}>
              已发现 {s.tools_count} 个工具
              {s.last_checked_at ? ` · 上次检查 ${new Date(s.last_checked_at + 'Z').toLocaleString()}` : ''}
              {s.last_error ? ` · ${s.last_error}` : ''}
            </div>

            {/* 配额说明：一份凭据 = 一个共享配额池 */}
            {s.auth_type !== 'none' && (
              <div style={{ fontSize: 11, color: 'var(--text-inactive)' }}>
                配额由配置者的账号提供，所有被分享的成员共用。
              </div>
            )}

            <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
              {isOwner && s.auth_type === 'oauth2' && (
                <button style={btn('var(--accent-blue)')} onClick={() => startOAuth(s)}>
                  {s.has_credentials ? '重新授权' : '授权连接'}
                </button>
              )}
              {isOwner && s.auth_type === 'bearer' && (
                <button style={btn('var(--accent-blue)')} onClick={() => { setBearerFor(s.id); setBearerToken(''); }}>
                  设置 Token
                </button>
              )}
              <button style={btn()} onClick={() => runTest(s)}>测试</button>
              {isOwner && (
                <>
                  <button style={btn()} onClick={() => editServer(s)}>编辑</button>
                  <button style={btn()} onClick={() => setShareFor(s.id)}>分享</button>
                  <button style={btn()} onClick={() => api.setRemoteMcpEnabled(s.id, !s.enabled).then(refresh)}>
                    {s.enabled ? '停用' : '启用'}
                  </button>
                  {s.has_credentials && (
                    <button style={btn('#e67e22')} onClick={() => api.clearRemoteMcpCredentials(s.id).then(() => { setMsg('已清除凭据'); refresh(); })}>
                      清除凭据
                    </button>
                  )}
                  <button style={btn('#e74c3c')} onClick={() => setDeleteTarget(s)}>删除</button>
                </>
              )}
            </div>

            {/* bearer 设置 */}
            {bearerFor === s.id && (
              <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                <input style={{ ...input, flex: 1 }} type="password" value={bearerToken}
                  placeholder="粘贴 access_token（静态 Bearer）"
                  onChange={e => setBearerToken(e.target.value)} />
                <button style={btn('var(--accent-blue)')} onClick={async () => {
                  try {
                    const r = await api.saveRemoteMcpCredentials(s.id, bearerToken.trim());
                    setMsg(r.ok ? `✓ 已保存，${r.tools_count ?? 0} 个工具` : `✗ ${r.error}`);
                    setBearerFor(null); refresh();
                  } catch (e: any) { setMsg(`保存失败：${e?.message || e}`); }
                }}>保存</button>
                <button style={btn()} onClick={() => setBearerFor(null)}>取消</button>
              </div>
            )}

            {/* OAuth 授权面板 */}
            {oauth && oauth.serverId === s.id && (
              <div style={{
                display: 'flex', flexDirection: 'column', gap: 8, padding: 12, borderRadius: 6,
                backgroundColor: 'var(--surface-2)',
                border: `1px ${oauth.loopback ? 'dashed' : 'solid'} ${oauth.loopback ? 'var(--border-light)' : 'var(--accent-blue)'}`,
              }}>
                <div style={{ fontSize: 12, color: 'var(--text-primary)', fontWeight: 600 }}>
                  授权 {s.name}
                  <span style={{ marginLeft: 8, fontWeight: 400, color: 'var(--text-muted)' }}>
                    {oauth.status === 'pending' ? '等待授权…' : oauth.status === 'ok' ? '已完成' : oauth.error || '失败'}
                    {oauth.status === 'pending' && ` · 回调端口 ${oauth.port}`}
                  </span>
                </div>

                {oauth.warning && <div style={{ fontSize: 11, color: '#e67e22' }}>{oauth.warning}</div>}

                {oauth.status === 'pending' && (
                  <>
                    {/* ① 打开授权页 */}
                    <div style={{ fontSize: 12, color: 'var(--text-primary)', lineHeight: 1.8 }}>
                      <strong>①</strong> 在打开的授权页里用 Sensor Tower 账号登录并同意。
                      <a href={oauth.authorizeUrl} target="_blank" rel="noreferrer"
                        style={{ marginLeft: 6, color: 'var(--accent-blue)' }}>
                        授权页没自动打开？点这里
                      </a>
                    </div>

                    {/* ② 复制回调地址 */}
                    <div style={{ fontSize: 12, color: 'var(--text-primary)', lineHeight: 1.8 }}>
                      <strong>②</strong> 同意后浏览器会跳到一个<span style={{ color: '#e67e22' }}>打不开的页面</span>
                      （地址形如 <code style={{ background: 'var(--surface-1)', padding: '1px 4px', borderRadius: 2 }}>http://localhost:{oauth.port}/callback?code=…&amp;state=…</code>）。
                      <strong>这是正常的</strong> —— 复制浏览器地址栏里的<span style={{ color: '#e67e22' }}>整条 URL</span>。
                    </div>

                    {/* ③ 粘贴 */}
                    <div style={{ fontSize: 12, color: 'var(--text-primary)' }}>
                      <strong>③</strong> 粘贴到下面并点「完成授权」：
                    </div>
                    <textarea value={oauth.paste} autoFocus={!oauth.loopback}
                      onChange={e => setOauth(o => (o ? { ...o, paste: e.target.value } : o))}
                      rows={2} placeholder="http://localhost:43975/callback?code=...&state=..."
                      style={{ ...input, resize: 'vertical', fontFamily: 'monospace' }} />

                    {oauth.loopback && (
                      <div style={{ fontSize: 11, color: 'var(--text-muted)' }}>
                        你正从本机访问，环回回调通常会自动完成 —— 若上方状态一直停在「等待授权…」，再用上面的粘贴方式。
                      </div>
                    )}

                    <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                      <button style={btn('var(--accent-blue)')} onClick={submitPaste} disabled={!oauth.paste.trim()}>
                        完成授权
                      </button>
                      <button style={btn()} onClick={() => setOauth(null)}>取消</button>
                    </div>
                  </>
                )}
                {oauth.status !== 'pending' && (
                  <div style={{ display: 'flex', gap: 6 }}>
                    <button style={btn()} onClick={() => setOauth(null)}>关闭</button>
                  </div>
                )}
              </div>
            )}
          </div>
        );
      })}

      {/* 新增/编辑表单 */}
      {showForm && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10, padding: 12, borderRadius: 6, border: '1px solid var(--border-light)', backgroundColor: 'var(--surface-2)' }}>
          <div style={{ fontSize: 12, fontWeight: 600 }}>{form.id ? '编辑服务器' : '新增服务器'}</div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
            {field('name', '名称（工具前缀，小写字母/数字/下划线/连字符）', 'sensortower')}
            <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
              <label style={label}>传输方式</label>
              <select style={input} value={form.transport} onChange={e => setForm(f => ({ ...f, transport: e.target.value }))}>
                <option value="http">http（Streamable HTTP）</option>
                <option value="sse">sse</option>
                <option value="stdio">stdio（本地进程）</option>
              </select>
            </div>
          </div>

          {form.transport === 'stdio' ? (
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
              {field('command', 'command（uvx / npx / python / node / docker）', 'uvx')}
              {field('args', 'args（空格分隔）', 'sensortower-mcp')}
            </div>
          ) : (
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
              {field('url', '服务器地址（MCP 端点）', 'https://mcp.example.com/mcp')}
              <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
                <label style={label}>认证方式</label>
                <select style={input} value={form.auth_type} onChange={e => setForm(f => ({ ...f, auth_type: e.target.value }))}>
                  <option value="oauth2">oauth2（授权码 + PKCE，推荐）</option>
                  <option value="bearer">bearer（静态 token）</option>
                  <option value="none">none（无需认证）</option>
                </select>
              </div>
            </div>
          )}

          {form.transport !== 'stdio' && form.auth_type === 'oauth2' && (
            <>
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
                {field('auth_register_url', 'DCR 注册地址', 'https://mcp.example.com/mcp/register')}
                {field('auth_authorize_url', '授权地址', 'https://mcp.example.com/oauth/authorize')}
                {field('auth_token_url', 'Token 地址', 'https://mcp.example.com/oauth/token')}
                {field('auth_scope', 'Scope', 'data_read')}
              </div>
              {field('auth_resource', 'Resource indicator（RFC8707，可留空）', 'https://mcp.example.com/mcp')}
            </>
          )}

          <div style={{ display: 'flex', gap: 8 }}>
            <button onClick={saveForm} disabled={saving}
              style={{ ...btn('var(--accent-blue)'), padding: '5px 18px', fontSize: 12 }}>
              {saving ? '保存中...' : '保存'}
            </button>
            <button onClick={() => { setShowForm(false); setForm({ ...EMPTY_FORM }); }} style={{ ...btn(), padding: '5px 14px', fontSize: 12 }}>取消</button>
          </div>
        </div>
      )}

      {/* 分享弹窗：强制 collaborative（复制会分裂凭据） */}
      <ShareDialog
        open={shareFor !== null}
        onClose={() => setShareFor(null)}
        count={1}
        forceMode="collaborative"
        onShare={async (targets, _mode, permission) => {
          if (shareFor === null) return;
          const r = await api.shareRemoteMcpServers([shareFor], targets, permission);
          setMsg(`✓ 已分享给 ${r.shared} 个成员`);
        }}
      />

      {/* 删除服务器确认弹窗（审计 P2-5：自研内联确认，替代原生 confirm） */}
      {deleteTarget && (
        <div onClick={() => setDeleteTarget(null)} style={overlayStyle}>
          {/* 审计 P2-12：role/aria-modal/tabIndex 弹窗语义 */}
          <div ref={deleteDialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={dialogStyle}>
            <p style={{ margin: 0, fontSize: 13, color: 'var(--text-primary)' }}>删除 {deleteTarget.name}？</p>
            <p style={{ margin: '6px 0 0', fontSize: 11, color: 'var(--text-muted)' }}>已分享的成员将立即失去该工具。</p>
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end', marginTop: 14 }}>
              <button onClick={() => setDeleteTarget(null)} style={saveCancelBtn}>取消</button>
              <button onClick={confirmDeleteServer} style={dangerBtn}>删除</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};
