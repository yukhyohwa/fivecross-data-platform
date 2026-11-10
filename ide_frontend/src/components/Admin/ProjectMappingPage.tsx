import React, { useEffect, useState } from 'react';
import { api } from '../../services/api';
import { overlayStyle, dialogStyle, saveCancelBtn, dangerBtn } from '../wsCommon';
import { useDialog } from '../../lib/useDialog';

type MappingRow = { database_name: string; project_id: string; updated_at?: string };
type Project = { id: string; name: string };

/** 系统管理 → 项目映射：维护数据库名 → BI 项目 全局映射（仅 admin 可进入/可写） */
export const ProjectMappingPage: React.FC = () => {
  const [mappings, setMappings] = useState<MappingRow[]>([]);
  const [projects, setProjects] = useState<Project[]>([]);
  const [tokenValid, setTokenValid] = useState(false);
  const [tokenSet, setTokenSet] = useState(false);
  const [loading, setLoading] = useState(false);
  const [msg, setMsg] = useState('');
  // 新增行
  const [newDb, setNewDb] = useState('');
  const [newPid, setNewPid] = useState('');
  // 删除确认弹窗目标（审计 P2-5：内联确认替代原生 confirm）
  const [deleteTarget, setDeleteTarget] = useState<string | null>(null);

  // 审计 P2-12：删除确认弹窗接入 useDialog（Escape 关闭 + 打开聚焦 + 关闭还原焦点）
  const deleteDialogRef = useDialog(deleteTarget !== null, () => setDeleteTarget(null));

  const load = async () => {
    setLoading(true);
    try {
      const cfg = await api.getBIConfig();
      setTokenValid(cfg.token_valid);
      setTokenSet(cfg.token_set);
      const [m] = await Promise.all([api.getBiMappings()]);
      setMappings(m.list || []);
      if (cfg.token_valid) {
        const p = await api.getBiProjects().catch(() => ({ list: [] }));
        setProjects(p.list || []);
      } else {
        setProjects([]);
      }
    } catch (e: any) {
      setMsg(`✗ 加载失败: ${e.message}`);
    }
    setLoading(false);
  };

  useEffect(() => { load(); }, []);

  const projectName = (pid: string) => {
    const hit = projects.find((p) => p.id === pid);
    return hit ? hit.name : `项目 ${pid}`;
  };

  const handleChange = async (db: string, pid: string) => {
    try {
      await api.setBiProjectMapping(db, pid);
      setMappings((list) => list.map((r) => (r.database_name === db ? { ...r, project_id: pid } : r)));
      setMsg('✓ 已保存');
    } catch (e: any) { setMsg(`✗ 保存失败: ${e.message}`); }
  };

  const handleDelete = (db: string) => {
    setDeleteTarget(db); // 审计 P2-5：内联确认弹窗替代原生 confirm
  };

  /** 删除确认弹窗「删除」按钮的执行体（审计 P2-5） */
  const confirmDelete = async () => {
    if (!deleteTarget) return;
    const db = deleteTarget;
    setDeleteTarget(null);
    try {
      await api.deleteBiProjectMapping(db);
      setMappings((list) => list.filter((r) => r.database_name !== db));
      setMsg('✓ 已删除');
    } catch (e: any) { setMsg(`✗ 删除失败: ${e.message}`); }
  };

  const handleAdd = async () => {
    if (!newDb.trim() || !newPid) { setMsg('请填写数据库名并选择项目'); return; }
    try {
      await api.setBiProjectMapping(newDb.trim(), newPid);
      setMappings((list) => {
        const rest = list.filter((r) => r.database_name !== newDb.trim());
        return [...rest, { database_name: newDb.trim(), project_id: newPid }].sort((a, b) => a.database_name.localeCompare(b.database_name));
      });
      setNewDb(''); setNewPid('');
      setMsg('✓ 已新增');
    } catch (e: any) { setMsg(`✗ 新增失败: ${e.message}`); }
  };

  const selectCls: React.CSSProperties = {
    padding: '4px 8px', borderRadius: 4, border: '1px solid var(--border-light)',
    backgroundColor: 'var(--surface-2)', color: 'var(--text-primary)', fontSize: 12, outline: 'none', maxWidth: 200,
  };
  const inputCls: React.CSSProperties = {
    padding: '4px 8px', borderRadius: 4, border: '1px solid var(--border-light)',
    backgroundColor: 'var(--surface-2)', color: 'var(--text-primary)', fontSize: 12, outline: 'none',
  };

  return (
    <div style={{ flex: 1, display: 'flex', flexDirection: 'column', padding: 12, gap: 10, backgroundColor: 'var(--surface-3)', color: 'var(--text-primary)', overflow: 'auto' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '8px 12px', backgroundColor: 'var(--surface-heavy)', borderRadius: 6, border: '1px solid var(--border-light)' }}>
        <span style={{ fontSize: 12, fontWeight: 600 }}>项目映射（全局）</span>
        <span style={{ fontSize: 11, color: 'var(--text-muted)' }}>数据库名 → BI 项目 · 所有用户生效 · 即时生效</span>
        <button onClick={load} disabled={loading}
          style={{ marginLeft: 'auto', fontSize: 11, padding: '3px 10px', borderRadius: 4, border: '1px solid var(--border-light)', backgroundColor: 'transparent', color: 'var(--text-secondary)', cursor: 'pointer' }}>
          {loading ? '加载中...' : '刷新'}
        </button>
      </div>

      {!tokenValid && (
        <div style={{ padding: '8px 12px', borderRadius: 6, border: '1px solid #e74c3c66', backgroundColor: '#e74c3c14', color: '#e74c3c', fontSize: 12 }}>
          {tokenSet ? 'BI Token 已过期，无法获取项目列表。请到 AI配置 → MCP管理 → BI 平台配置 更新 Token。' : '未配置 BI Token，无法获取项目列表。请到 AI配置 → MCP管理 → BI 平台配置 配置后刷新。'}
          <span style={{ marginLeft: 8, color: 'var(--text-muted)' }}>已有映射行仍可修改/删除，但项目下拉不可用。</span>
        </div>
      )}

      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
        <thead>
          <tr>
            <th style={{ textAlign: 'left', padding: '6px 10px', borderBottom: '1px solid var(--border-light)', color: 'var(--text-muted)' }}>数据库名</th>
            <th style={{ textAlign: 'left', padding: '6px 10px', borderBottom: '1px solid var(--border-light)', color: 'var(--text-muted)' }}>关联项目</th>
            <th style={{ textAlign: 'right', padding: '6px 10px', borderBottom: '1px solid var(--border-light)', color: 'var(--text-muted)', width: 60 }}>操作</th>
          </tr>
        </thead>
        <tbody>
          {mappings.map((row) => (
            <tr key={row.database_name}>
              <td style={{ padding: '5px 10px', borderBottom: '1px solid var(--border-light)', fontFamily: 'monospace' }}>{row.database_name}</td>
              <td style={{ padding: '5px 10px', borderBottom: '1px solid var(--border-light)' }}>
                <select value={row.project_id} disabled={!tokenValid} onChange={(e) => handleChange(row.database_name, e.target.value)} style={selectCls}>
                  {projects.map((p) => (
                    <option key={p.id} value={p.id}>{p.name} ({p.id})</option>
                  ))}
                </select>
                <span style={{ marginLeft: 6, fontSize: 11, color: 'var(--text-muted)' }}>{projectName(row.project_id)}</span>
              </td>
              <td style={{ padding: '5px 10px', borderBottom: '1px solid var(--border-light)', textAlign: 'right' }}>
                <button onClick={() => handleDelete(row.database_name)}
                  style={{ fontSize: 11, padding: '2px 8px', borderRadius: 4, border: '1px solid #e74c3c55', backgroundColor: 'transparent', color: '#e74c3c', cursor: 'pointer' }}>删除</button>
              </td>
            </tr>
          ))}
          {mappings.length === 0 && (
            <tr><td colSpan={3} style={{ padding: 16, textAlign: 'center', color: 'var(--text-muted)', borderBottom: '1px solid var(--border-light)' }}>暂无映射，请添加</td></tr>
          )}
        </tbody>
      </table>

      {/* 新增行 */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '8px 12px', backgroundColor: 'var(--surface-heavy)', borderRadius: 6, border: '1px solid var(--border-light)' }}>
        <span style={{ fontSize: 11, color: 'var(--text-muted)' }}>＋ 添加</span>
        <input value={newDb} onChange={(e) => setNewDb(e.target.value)} placeholder="数据库名（如 dw_ods）" style={{ ...inputCls, width: 180 }} />
        <select value={newPid} disabled={!tokenValid} onChange={(e) => setNewPid(e.target.value)} style={{ ...selectCls, flex: 1 }}>
          <option value="">选择项目</option>
          {projects.map((p) => (
            <option key={p.id} value={p.id}>{p.name} ({p.id})</option>
          ))}
        </select>
        <button onClick={handleAdd}
          style={{ fontSize: 11, padding: '4px 14px', borderRadius: 4, border: 'none', backgroundColor: 'var(--accent-blue)', color: '#fff', cursor: 'pointer' }}>保存</button>
      </div>

      {msg && <span style={{ fontSize: 12, color: msg.startsWith('✓') ? '#4caf50' : '#e74c3c' }}>{msg}</span>}

      {/* 删除映射确认弹窗（审计 P2-5：自研内联确认，替代原生 confirm） */}
      {deleteTarget && (
        <div onClick={() => setDeleteTarget(null)} style={overlayStyle}>
          {/* 审计 P2-12：role/aria-modal/tabIndex 弹窗语义 */}
          <div ref={deleteDialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={dialogStyle}>
            <p style={{ margin: 0, fontSize: 13, color: 'var(--text-primary)' }}>删除数据库「{deleteTarget}」的项目映射？</p>
            <p style={{ margin: '6px 0 0', fontSize: 11, color: 'var(--text-muted)' }}>此操作不可撤销。</p>
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
