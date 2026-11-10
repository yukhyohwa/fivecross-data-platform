import React, { useEffect, useState } from 'react';
import { api } from '../../services/api';

type Slot = { key: string; label: string; desc: string; model: string; source: string; override: string | null; auto_model: string };

/** 来源徽标配色：模型管理=蓝（本页覆盖）、环境变量=橙（部署级）、任务默认=紫、系统默认=灰 */
const SOURCE_COLORS: Record<string, string> = {
  模型管理: '#4c9aff',
  环境变量: '#ffa726',
  任务默认: '#ab7ae0',
  系统默认: 'var(--text-muted)',
};

/** 未保存修改的草稿存 sessionStorage：刷新/误关页面后恢复，避免无声丢失（对抗审查） */
const DRAFT_KEY = 'model-mgmt-drafts';

const readDrafts = (): Record<string, string> => {
  try {
    const raw = sessionStorage.getItem(DRAFT_KEY);
    return raw ? JSON.parse(raw) : {};
  } catch {
    return {};
  }
};

const writeDrafts = (edits: Record<string, string>) => {
  try {
    if (Object.keys(edits).length) sessionStorage.setItem(DRAFT_KEY, JSON.stringify(edits));
    else sessionStorage.removeItem(DRAFT_KEY);
  } catch { /* 隐私模式等存储不可用：仅失去草稿恢复能力，不影响保存 */ }
};

/**
 * 系统管理 → 模型管理：全站 LLM 模型槽位统一调整（2026-10-26）。
 * 槽位清单即「全站 LLM 使用位置盘点」：主对话/深度分析/SQL/知识库/专项/算法/报告三模型/
 * 缺口修复/指标拆分/全局兜底。解析优先级：模型管理 > 环境变量 > 任务默认 > 系统默认。
 * 保存 = PUT /api/admin/config/models，后端校验合法模型名后落盘 model_config.json，全站即时生效。
 * 权限：写操作仅 system 权限（与后端 has_perm(user,'system') 同口径），无权限仅可查看。
 */
export const ModelManagementPage: React.FC = () => {
  const [slots, setSlots] = useState<Slot[]>([]);
  const [models, setModels] = useState<string[]>([]);
  const [defaultModel, setDefaultModel] = useState('');
  const [loading, setLoading] = useState(false);
  const [saving, setSaving] = useState(false);
  const [msg, setMsg] = useState('');
  const [isAdmin, setIsAdmin] = useState(false);
  // 有未保存修改时点「刷新」先内联确认（审计 P2-5：自研内联确认替代 window.confirm）
  const [confirmRefresh, setConfirmRefresh] = useState(false);
  // 本页编辑中的槽位覆盖：key → 模型名；'' = 清除覆盖回到「自动」（未编辑的键不在 map 里）
  const [edits, setEdits] = useState<Record<string, string>>({});

  // 与后端 has_perm(user, 'system') 同口径（/me 返回生效权限点），参考 GlossaryPage（对抗审查 2026-10-23 二轮）
  useEffect(() => {
    api.getMe().then(u => setIsAdmin((u?.permissions || []).includes('system'))).catch(() => setIsAdmin(false));
  }, []);

  const load = async (discardDrafts = false) => {
    setLoading(true);
    try {
      const d = await api.getModelManagement();
      setSlots(d.slots);
      setModels(d.models);
      setDefaultModel(d.default);
      const drafts = discardDrafts ? {} : readDrafts();
      // 只恢复仍然存在的槽位键：槽位清单变更后旧草稿键会被后端忽略，提前裁剪并告知
      const validKeys = new Set(d.slots.map((s: Slot) => s.key));
      const restored: Record<string, string> = {};
      Object.keys(drafts).forEach((k) => { if (validKeys.has(k)) restored[k] = drafts[k]; });
      const restoredCount = Object.keys(restored).length;
      const dropped = Object.keys(drafts).length - restoredCount;
      setEdits(restored);
      setMsg(restoredCount ? `已恢复 ${restoredCount} 项未保存修改，点击「保存修改」生效${dropped ? `（${dropped} 项已失效槽位忽略）` : ''}` : '');
    } catch (e: any) {
      setMsg(`✗ 加载失败: ${e.message}`);
    }
    setLoading(false);
  };

  useEffect(() => { load(); }, []);

  // 草稿持久化：编辑变化即写 sessionStorage（保存/刷新成功后清空）
  useEffect(() => { writeDrafts(edits); }, [edits]);

  // 某行是否有未保存的变更（编辑值与当前 override 不同）
  const isChanged = (s: Slot): boolean => {
    const v = edits[s.key];
    return v !== undefined && v !== (s.override ?? '');
  };
  const dirtyCount = slots.filter(isChanged).length;
  const busy = saving || loading;

  const handleSave = async () => {
    if (dirtyCount === 0 || saving) return;
    setSaving(true);
    try {
      const d = await api.putModelManagement(edits);
      setSlots(d.slots);
      setEdits({});
      setMsg('✓ 已保存，全站即时生效');
    } catch (e: any) {
      setMsg(`✗ 保存失败: ${e.message}`);
    }
    setSaving(false);
  };

  /** 恢复全部默认 = 仅把「存在覆盖或非空编辑」的槽位标记为清除（未动过的键不标脏，仍走保存按钮落盘） */
  const handleResetAll = () => {
    const all: Record<string, string> = {};
    slots.forEach((s) => {
      if ((s.override ?? '') !== '' || (edits[s.key] !== undefined && edits[s.key] !== '')) all[s.key] = '';
    });
    if (!Object.keys(all).length) {
      setMsg('没有可重置的覆盖项');
      return;
    }
    setEdits(all);
    setMsg('已把有覆盖的槽位重置为「自动」，点击「保存修改」后生效');
  };

  const handleRefresh = () => {
    if (dirtyCount > 0) {
      setConfirmRefresh(true);
      return;
    }
    load();
  };

  /** 下拉当前显示值：有编辑显示编辑值；无编辑显示 override（无 override 则落到「自动」选项） */
  const selectValue = (s: Slot): string => {
    const v = edits[s.key];
    if (v !== undefined) return v;
    return s.override ?? '';
  };

  const selectCls: React.CSSProperties = {
    padding: '4px 8px', borderRadius: 4, border: '1px solid var(--border-light)',
    backgroundColor: 'var(--surface-2)', color: 'var(--text-primary)', fontSize: 12, outline: 'none', minWidth: 210,
  };
  const tagCls: React.CSSProperties = {
    fontSize: 10, padding: '1px 7px', borderRadius: 8, border: '1px solid currentColor', whiteSpace: 'nowrap',
  };
  const btnCls: React.CSSProperties = {
    fontSize: 11, padding: '3px 10px', borderRadius: 4, border: '1px solid var(--border-light)',
    backgroundColor: 'transparent', color: 'var(--text-secondary)', cursor: 'pointer',
  };

  return (
    <div style={{ flex: 1, display: 'flex', flexDirection: 'column', padding: 12, gap: 10, backgroundColor: 'var(--surface-3)', color: 'var(--text-primary)', overflow: 'auto' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '8px 12px', backgroundColor: 'var(--surface-heavy)', borderRadius: 6, border: '1px solid var(--border-light)', flexWrap: 'wrap' }}>
        <span style={{ fontSize: 12, fontWeight: 600 }}>模型管理（全局）</span>
        <span style={{ fontSize: 11, color: 'var(--text-muted)' }}>全站 LLM 模型槽位 · 保存后即时生效</span>
        <div style={{ marginLeft: 'auto', display: 'flex', gap: 8 }}>
          {confirmRefresh ? (
            <>
              <span style={{ fontSize: 11, color: '#e67e22' }}>放弃未保存修改并刷新？</span>
              <button onClick={() => { setConfirmRefresh(false); load(true); }} disabled={busy} aria-label="确认放弃修改并刷新" style={{ ...btnCls, color: '#e74c3c' }}>
                确认刷新
              </button>
              <button onClick={() => setConfirmRefresh(false)} disabled={busy} aria-label="取消刷新" style={btnCls}>
                取消
              </button>
            </>
          ) : (
            <button onClick={handleRefresh} disabled={busy} aria-label="重新加载模型配置" style={btnCls}>
              {loading ? '加载中...' : '刷新'}
            </button>
          )}
          <button onClick={handleResetAll} disabled={busy || !isAdmin} aria-label="恢复全部默认" style={{ ...btnCls, opacity: !isAdmin ? 0.5 : 1, cursor: !isAdmin ? 'not-allowed' : 'pointer' }}>
            恢复全部默认
          </button>
          <button onClick={handleSave} disabled={dirtyCount === 0 || saving || !isAdmin} aria-label="保存模型配置修改"
            style={{ fontSize: 11, padding: '3px 12px', borderRadius: 4, border: 'none', backgroundColor: dirtyCount === 0 ? 'var(--border-light)' : 'var(--accent-blue)', color: dirtyCount === 0 ? 'var(--text-muted)' : '#fff', cursor: dirtyCount === 0 || !isAdmin ? 'not-allowed' : 'pointer' }}>
            {saving ? '保存中...' : `保存修改${dirtyCount ? `（${dirtyCount}）` : ''}`}
          </button>
        </div>
      </div>

      {!isAdmin && (
        <div style={{ padding: '8px 12px', borderRadius: 6, border: '1px solid var(--border-light)', backgroundColor: 'var(--surface-heavy)', fontSize: 11, color: 'var(--text-secondary)' }}>
          只读模式：仅系统管理员可修改模型槽位（查看不受限）。
        </div>
      )}

      <div style={{ padding: '8px 12px', borderRadius: 6, border: '1px solid var(--border-light)', backgroundColor: 'var(--surface-heavy)', fontSize: 11, color: 'var(--text-secondary)', lineHeight: 1.7 }}>
        优先级：<b>模型管理</b> &gt; 环境变量 &gt; 任务默认 &gt; 系统默认（{defaultModel}）。<br />
        个人 LLM Key/模型在右上角用户菜单配置（仅覆盖主对话/深度分析）；Jev 质检模型走网关契约、不在此管理。误改后点「恢复全部默认」即可回到出厂档位。
      </div>

      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
        <thead>
          <tr>
            <th style={{ textAlign: 'left', padding: '6px 10px', borderBottom: '1px solid var(--border-light)', color: 'var(--text-muted)', width: 130 }}>槽位</th>
            <th style={{ textAlign: 'left', padding: '6px 10px', borderBottom: '1px solid var(--border-light)', color: 'var(--text-muted)' }}>用途说明</th>
            <th style={{ textAlign: 'left', padding: '6px 10px', borderBottom: '1px solid var(--border-light)', color: 'var(--text-muted)', width: 240 }}>生效模型</th>
            <th style={{ textAlign: 'left', padding: '6px 10px', borderBottom: '1px solid var(--border-light)', color: 'var(--text-muted)', width: 90 }}>来源</th>
            <th style={{ textAlign: 'right', padding: '6px 10px', borderBottom: '1px solid var(--border-light)', color: 'var(--text-muted)', width: 110 }}>操作</th>
          </tr>
        </thead>
        <tbody>
          {slots.map((s) => (
            <tr key={s.key} style={isChanged(s) ? { backgroundColor: 'var(--surface-heavy)' } : undefined}>
              <td style={{ padding: '6px 10px', borderBottom: '1px solid var(--border-light)', fontWeight: 600, whiteSpace: 'nowrap' }}>
                {s.label}
                {s.key === 'fallback' && <span title="任何 LLM 调用主模型失败时自动切换" style={{ color: '#e67e22', fontSize: 10, marginLeft: 4 }}>⚠</span>}
              </td>
              <td style={{ padding: '6px 10px', borderBottom: '1px solid var(--border-light)', color: 'var(--text-muted)', fontSize: 11 }}>{s.desc}</td>
              <td style={{ padding: '6px 10px', borderBottom: '1px solid var(--border-light)' }}>
                <select value={selectValue(s)} onChange={(e) => setEdits((m) => ({ ...m, [s.key]: e.target.value }))}
                  disabled={busy || !isAdmin} aria-label={`${s.label} 模型选择`}
                  style={{ ...selectCls, cursor: busy || !isAdmin ? 'not-allowed' : 'pointer', opacity: busy || !isAdmin ? 0.6 : 1 }}>
                  <option value="">{(s.override ?? '') !== '' ? `自动（清除覆盖后 ${s.auto_model}）` : `自动（${s.model}）`}</option>
                  {models.map((m) => (
                    <option key={m} value={m}>{m}{m === defaultModel ? '（系统默认）' : ''}</option>
                  ))}
                </select>
              </td>
              <td style={{ padding: '6px 10px', borderBottom: '1px solid var(--border-light)' }}>
                <span style={{ ...tagCls, color: SOURCE_COLORS[s.source] || 'var(--text-muted)' }}>{s.source}</span>
              </td>
              <td style={{ padding: '6px 10px', borderBottom: '1px solid var(--border-light)', textAlign: 'right', whiteSpace: 'nowrap' }}>
                {isChanged(s) && <span style={{ ...tagCls, color: '#ffa726', marginRight: 6 }}>待保存</span>}
                {(s.override || edits[s.key] !== undefined) && (
                  <button onClick={() => setEdits((m) => ({ ...m, [s.key]: '' }))} title="清除覆盖，回到自动档位"
                    disabled={busy || !isAdmin} aria-label={`重置 ${s.label} 槽位`}
                    style={{ fontSize: 11, padding: '2px 8px', borderRadius: 4, border: '1px solid var(--border-light)', backgroundColor: 'transparent', color: 'var(--text-secondary)', cursor: busy || !isAdmin ? 'not-allowed' : 'pointer' }}>
                    重置
                  </button>
                )}
              </td>
            </tr>
          ))}
          {slots.length === 0 && (
            <tr><td colSpan={5} style={{ padding: 16, textAlign: 'center', color: 'var(--text-muted)', borderBottom: '1px solid var(--border-light)' }}>加载中…</td></tr>
          )}
        </tbody>
      </table>

      <span aria-live="polite" style={{ fontSize: 12, color: msg.startsWith('✓') ? '#4caf50' : msg.startsWith('✗') ? '#e74c3c' : 'var(--text-secondary)' }}>{msg}</span>
    </div>
  );
};
