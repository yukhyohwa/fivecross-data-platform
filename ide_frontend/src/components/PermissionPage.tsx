import React, { useCallback, useEffect, useState } from 'react';
import { api } from '../services/api';
import { useToast } from './Toast';
import { overlayStyle, dialogStyle, saveCancelBtn, dangerBtn } from './wsCommon';
import { useDialog } from '../lib/useDialog';

/** 权限点显示名映射（审计 P2-3）：清单本身改由后端 GET /api/permissions/points 下发，
 *  这里只做 key → 中文名 展示映射，未知点回显 key 本身。
 *  审计 P2-4 复核：personal/workspace 已从后端清单删除，映射条目一并移除，避免死条目残留。 */
const PERMISSION_POINT_LABELS: Record<string, string> = {
  apps: '用户应用',
  analysis: '分析配置',
  analysis_edit: '新增/修改 专项·知识库·SQL·算法',
  analysis_delete: '删除 专项·知识库·SQL·算法',
  ai: 'AI配置',
  system: '系统管理',
  sql_use: 'SQL查询使用',
  kb_use: '知识库查询',
  skill_use: '专项使用',
  model_use: '算法使用',
};

/** 资产机密档位（L1 绝密 / L2 机密 / L3 秘密），SQL/知识库/专项 三类各带多选集合；算法不分档。 */
const CONFIDENTIALITY_LEVELS = ['L1', 'L2', 'L3'] as const;
const CONFIDENTIALITY_LABELS: Record<string, string> = { L1: 'L1·绝密', L2: 'L2·机密', L3: 'L3·秘密' };
const LEVEL_TYPES: { key: 'sql' | 'kb' | 'skill'; label: string }[] = [
  { key: 'sql', label: 'SQL' },
  { key: 'kb', label: '知识库' },
  { key: 'skill', label: '专项' },
];

type AccessLevels = Record<'sql' | 'kb' | 'skill', string[]>;
type Identity = { key: string; name: string; permission_points: string; games: string; access_levels: string; is_builtin: number };
type EmailMapping = { id: number; identity_key: string; identity_name: string; match_type: string; pattern: string };

const parseList = (raw: string | string[]): string[] => {
  if (Array.isArray(raw)) return raw;
  try { const v = JSON.parse(raw || '[]'); return Array.isArray(v) ? v : []; } catch { return []; }
};

/** access_levels JSON 对象解析：{sql/kb/skill: [L1..L3]}；损坏/缺失回空对象。 */
const parseObj = (raw: string | Record<string, any> | null | undefined): Record<string, string[]> => {
  if (raw && typeof raw === 'object' && !Array.isArray(raw)) return raw as Record<string, string[]>;
  const s: string = typeof raw === 'string' ? raw : '';
  try { const v = JSON.parse(s || '{}'); return v && typeof v === 'object' && !Array.isArray(v) ? v : {}; } catch { return {}; }
};

/** 规范化某身份的机密档位集合：只保留 sql/kb/skill 三键 + 合法档位值，缺失/空 → 默认 L3。 */
const normalizeLevels = (raw: string | Record<string, any> | null | undefined): AccessLevels => {
  const obj = parseObj(raw);
  const out = { sql: [], kb: [], skill: [] } as AccessLevels;
  for (const t of LEVEL_TYPES) {
    const v = obj[t.key];
    out[t.key] = Array.isArray(v) ? v.filter((l) => (CONFIDENTIALITY_LEVELS as readonly string[]).includes(l)) : [];
    if (out[t.key].length === 0) out[t.key] = ['L3'];
  }
  return out;
};

/** 游戏授权：只有「全游戏 / 自定义」两种模式。全游戏 = 身份默认所有游戏；自定义 = 手动勾选（初始为空）。 */
const GamePicker: React.FC<{
  games: { key: string; name: string }[];
  allGames: boolean;
  selected: string[];
  onAllGames: (v: boolean) => void;
  onToggle: (key: string) => void;
}> = ({ games, allGames, selected, onAllGames, onToggle }) => {
  const sel = new Set(selected);
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
      <div style={{ display: 'flex', gap: 16 }}>
        <label style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12, color: 'var(--text-primary)', cursor: 'pointer', fontWeight: 600 }}>
          <input type="radio" checked={allGames} onChange={() => onAllGames(true)} />
          全游戏
        </label>
        <label style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12, color: 'var(--text-primary)', cursor: 'pointer', fontWeight: 600 }}>
          <input type="radio" checked={!allGames} onChange={() => onAllGames(false)} />
          自定义
        </label>
      </div>
      {allGames ? (
        <div style={{ fontSize: 12, color: 'var(--text-muted)' }}>该身份默认拥有所有游戏的权限</div>
      ) : (
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: '6px 14px', paddingLeft: 20, maxHeight: 180, overflow: 'auto' }}>
          {games.length === 0 ? (
            <div style={{ fontSize: 12, color: 'var(--text-muted)' }}>暂无游戏可选</div>
          ) : games.map((g) => (
            <label key={g.key} style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12, color: 'var(--text-secondary)', cursor: 'pointer' }}>
              <input type="checkbox" checked={sel.has(g.key)} onChange={() => onToggle(g.key)} />
              {g.name && g.name !== g.key ? `${g.name}（${g.key}）` : g.key}
            </label>
          ))}
        </div>
      )}
    </div>
  );
};

/** 系统管理 → 权限管理：身份 CRUD + 企业邮箱映射（用户授权已并入用户管理页）。 */
export const PermissionPage: React.FC = () => {
  const { success: toastSuccess, error: toastError } = useToast();
  const [tab, setTab] = useState<'identities' | 'email'>('identities');
  const [identities, setIdentities] = useState<Identity[]>([]);
  const [emailMappings, setEmailMappings] = useState<EmailMapping[]>([]);
  const [games, setGames] = useState<{ key: string; name: string }[]>([]);
  const [loading, setLoading] = useState(true);
  // 权限点清单（审计 P2-3）：组件挂载时从后端拉取，加载失败给空数组兜底（权限点区域显示提示，不渲染复选框）
  const [permissionPoints, setPermissionPoints] = useState<string[]>([]);
  const permissionLabel = (key: string) => PERMISSION_POINT_LABELS[key] || key;

  // 身份编辑弹窗
  const [editing, setEditing] = useState<Identity | null>(null);
  const [creating, setCreating] = useState(false);
  const [formKey, setFormKey] = useState('');
  const [formName, setFormName] = useState('');
  const [formPoints, setFormPoints] = useState<string[]>([]);
  const [formAllGames, setFormAllGames] = useState(true);
  const [formGames, setFormGames] = useState<string[]>([]);
  const [formAccessLevels, setFormAccessLevels] = useState<AccessLevels>({ sql: ['L3'], kb: ['L3'], skill: ['L3'] });
  const [saving, setSaving] = useState(false);

  // 删除确认弹窗（审计 P2-5：收敛 window.confirm 为自研内联确认）
  const [confirmTarget, setConfirmTarget] = useState<{ kind: 'identity'; identity: Identity } | { kind: 'email'; mapping: EmailMapping } | null>(null);

  // 邮箱映射弹窗
  const [showEmailForm, setShowEmailForm] = useState(false);
  const [emailIdentity, setEmailIdentity] = useState('');
  const [emailMatch, setEmailMatch] = useState<'exact' | 'suffix'>('exact');
  const [emailPattern, setEmailPattern] = useState('');
  const [savingEmail, setSavingEmail] = useState(false);

  // 审计 P2-12：各弹窗接入 useDialog（Escape 关闭 + 打开聚焦 + 关闭还原焦点）
  const identityDialogRef = useDialog(creating || editing !== null, () => { setCreating(false); setEditing(null); });
  const emailDialogRef = useDialog(showEmailForm, () => setShowEmailForm(false));
  const confirmDialogRef = useDialog(confirmTarget !== null, () => setConfirmTarget(null));

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [ids, ems, gs, pts] = await Promise.all([
        api.listIdentities(),
        api.listEmailMappings(),
        api.getGames(),
        api.getPermissionPoints().catch(() => ({ points: [] as string[] })),
      ]);
      setIdentities(ids || []);
      setEmailMappings(ems || []);
      setGames((gs as any).games || []);
      setPermissionPoints(pts.points || []);
    } catch (e) {
      toastError(e instanceof Error ? e.message : '加载失败');
    } finally {
      setLoading(false);
    }
  }, [toastError]);

  useEffect(() => { load(); }, [load]);

  // ── 身份 ──
  const openCreate = () => {
    setCreating(true); setEditing(null);
    setFormKey(''); setFormName('');
    // 默认权限点由后端清单决定（审计 P2-3）：默认勾 apps（存在时），不再硬编码已删除的 personal 孤儿点
    setFormPoints(permissionPoints.includes('apps') ? ['apps'] : []);
    setFormAllGames(true); setFormGames([]);
    setFormAccessLevels({ sql: ['L3'], kb: ['L3'], skill: ['L3'] });
  };
  const openEdit = (id: Identity) => {
    setCreating(false); setEditing(id);
    setFormKey(id.key); setFormName(id.name);
    const pts = parseList(id.permission_points);
    setFormPoints(pts);
    const gs = parseList(id.games);
    setFormAllGames(gs.includes('*'));
    setFormGames(gs.filter((k) => k !== '*'));
    setFormAccessLevels(normalizeLevels(id.access_levels));
  };
  const saveIdentity = async () => {
    if (!formName.trim()) { toastError('身份名称不能为空'); return; }
    if (creating && !formKey.trim()) { toastError('身份标识(key)不能为空'); return; }
    setSaving(true);
    const games = formAllGames ? ['*'] : formGames;
    try {
      if (creating) {
        await api.createIdentity({ key: formKey.trim(), name: formName.trim(), permission_points: formPoints, games, access_levels: formAccessLevels });
        toastSuccess('身份已创建');
      } else if (editing) {
        await api.updateIdentity(editing.key, { name: formName.trim(), permission_points: formPoints, games, access_levels: formAccessLevels });
        toastSuccess('身份已保存');
      }
      setCreating(false); setEditing(null);
      load();
    } catch (e) {
      toastError(e instanceof Error ? e.message : '保存失败');
    } finally {
      setSaving(false);
    }
  };
  const removeIdentity = (id: Identity) => {
    if (id.is_builtin) { toastError('内置身份不可删除，可编辑其权限点/游戏'); return; }
    setConfirmTarget({ kind: 'identity', identity: id }); // 审计 P2-5：内联确认弹窗替代 window.confirm
  };

  // ── 邮箱映射 ──
  const saveEmailMapping = async () => {
    if (!emailPattern.trim()) { toastError('匹配规则不能为空'); return; }
    if (!emailIdentity) { toastError('请选择身份'); return; }
    setSavingEmail(true);
    try {
      await api.addEmailMapping({ identity_key: emailIdentity, match_type: emailMatch, pattern: emailPattern.trim() });
      toastSuccess('映射已添加');
      setShowEmailForm(false);
      load();
    } catch (e) {
      toastError(e instanceof Error ? e.message : '添加失败');
    } finally {
      setSavingEmail(false);
    }
  };
  const removeEmailMapping = (m: EmailMapping) => {
    setConfirmTarget({ kind: 'email', mapping: m }); // 审计 P2-5：内联确认弹窗替代 window.confirm
  };

  /** 内联确认弹窗「删除」按钮的执行体（审计 P2-5） */
  const confirmRemove = async () => {
    if (!confirmTarget) return;
    const target = confirmTarget;
    setConfirmTarget(null);
    try {
      if (target.kind === 'identity') {
        await api.deleteIdentity(target.identity.key);
        toastSuccess('身份已删除');
      } else {
        await api.deleteEmailMapping(target.mapping.id);
        toastSuccess('映射已删除');
      }
      load();
    } catch (e) {
      toastError(e instanceof Error ? e.message : '删除失败');
    }
  };

  const badge = (text: string, color: string, bg: string) => (
    <span style={{ padding: '2px 8px', borderRadius: 10, fontSize: 11, backgroundColor: bg, color }}>{text}</span>
  );

  return (
    <div style={{ flex: 1, display: 'flex', flexDirection: 'column', padding: 16, gap: 12, backgroundColor: 'var(--surface-3)', color: 'var(--text-primary)', overflow: 'auto' }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <div>
          <h3 style={{ margin: 0, fontSize: 14, color: 'var(--text-heading)' }}>权限管理</h3>
          <p style={{ margin: '4px 0 0', fontSize: 12, color: 'var(--text-muted)' }}>二分法权限：游戏 × 身份。身份挂权限点，用户可按企业邮箱自动归身份；用户授权在「用户管理」页操作。</p>
        </div>
      </div>

      {/* Tabs */}
      <div style={{ display: 'flex', gap: 2, borderBottom: '1px solid var(--border-light)', paddingBottom: 4 }}>
        {[
          { key: 'identities', label: `身份管理 (${identities.length})` },
          { key: 'email', label: `企业邮箱映射 (${emailMappings.length})` },
        ].map((t) => (
          <button key={t.key} onClick={() => setTab(t.key as any)}
            role="tab" aria-selected={tab === t.key}
            style={{ padding: '5px 14px', borderRadius: '4px 4px 0 0', border: 'none', cursor: 'pointer', fontSize: 12,
              backgroundColor: tab === t.key ? 'var(--surface-hover)' : 'transparent', color: tab === t.key ? '#fff' : 'var(--text-muted)' }}>
            {t.label}
          </button>
        ))}
      </div>

      {loading ? (
        <div style={{ textAlign: 'center', color: 'var(--text-muted)', fontSize: 12, padding: 20 }}>加载中…</div>
      ) : (
        <>
          {/* ── 身份管理 ── */}
          {tab === 'identities' && (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              <div>
                <button onClick={openCreate} style={{ padding: '6px 14px', borderRadius: 6, border: 'none', background: 'var(--accent-blue)', color: '#fff', cursor: 'pointer', fontSize: 13 }}>＋ 新增身份</button>
              </div>
              <div style={{ border: '1px solid var(--border-light)', borderRadius: 8, overflow: 'auto', backgroundColor: 'var(--surface-1)' }}>
                <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
                  <thead>
                    <tr style={{ backgroundColor: 'var(--surface-2)' }}>
                      {['身份', '权限点', '机密档位', '游戏', '来源', '操作'].map((h) => (
                        <th key={h} style={{ textAlign: 'left', padding: '8px 12px', fontWeight: 600, color: 'var(--text-secondary)', borderBottom: '1px solid var(--border-light)' }}>{h}</th>
                      ))}
                    </tr>
                  </thead>
                  <tbody>
                    {identities.map((id) => {
                      const pts = parseList(id.permission_points);
                      const gs = parseList(id.games);
                      const lv = normalizeLevels(id.access_levels);
                      const lvText = LEVEL_TYPES.map((t) => {
                        const sel = lv[t.key];
                        const all = CONFIDENTIALITY_LEVELS.every((l) => sel.includes(l));
                        return `${t.label}:${all ? '全档' : sel.join('/')}`;
                      }).join(' · ');
                      return (
                        <tr key={id.key} style={{ borderBottom: '1px solid var(--border-light)' }}>
                          <td style={{ padding: '8px 12px' }}>
                            <strong style={{ color: 'var(--text-heading)' }}>{id.name}</strong>
                            <div style={{ fontSize: 11, color: 'var(--text-muted)' }}>{id.key}</div>
                          </td>
                          <td style={{ padding: '8px 12px', color: 'var(--text-secondary)' }}>
                            {permissionPoints.length > 0 && pts.length === permissionPoints.length ? '全部' : pts.map(permissionLabel).join('、') || '—'}
                          </td>
                          <td style={{ padding: '8px 12px', color: 'var(--text-muted)', fontSize: 11 }}>{lvText}</td>
                          <td style={{ padding: '8px 12px', color: 'var(--text-secondary)' }}>
                            {gs.includes('*') ? '全游戏' : (gs.join('、') || '—')}
                          </td>
                          <td style={{ padding: '8px 12px' }}>{id.is_builtin ? badge('内置', 'var(--accent-amber)', 'transparent') : badge('自定义', 'var(--accent-blue)', 'transparent')}</td>
                          <td style={{ padding: '8px 12px', display: 'flex', gap: 6 }}>
                            <button onClick={() => openEdit(id)} style={miniBtn}>编辑</button>
                            {!id.is_builtin && (
                              <button onClick={() => removeIdentity(id)} style={{ ...miniBtn, color: '#e74c3c' }}>删除</button>
                            )}
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            </div>
          )}

          {/* ── 企业邮箱映射 ── */}
          {tab === 'email' && (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              <div>
                <button onClick={() => { setShowEmailForm(true); setEmailIdentity(identities[0]?.key || ''); setEmailMatch('exact'); setEmailPattern(''); }} style={{ padding: '6px 14px', borderRadius: 6, border: 'none', background: 'var(--accent-blue)', color: '#fff', cursor: 'pointer', fontSize: 13 }}>＋ 新增映射</button>
              </div>
              {emailMappings.length === 0 ? (
                <div style={{ textAlign: 'center', color: 'var(--text-muted)', fontSize: 12, padding: 20 }}>暂无邮箱映射。命中后用户自动归到对应身份。</div>
              ) : (
                <div style={{ border: '1px solid var(--border-light)', borderRadius: 8, overflow: 'auto', backgroundColor: 'var(--surface-1)' }}>
                  <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
                    <thead>
                      <tr style={{ backgroundColor: 'var(--surface-2)' }}>
                        {['身份', '匹配方式', '规则', '操作'].map((h) => (
                          <th key={h} style={{ textAlign: 'left', padding: '8px 12px', fontWeight: 600, color: 'var(--text-secondary)', borderBottom: '1px solid var(--border-light)' }}>{h}</th>
                        ))}
                      </tr>
                    </thead>
                    <tbody>
                      {emailMappings.map((m) => (
                        <tr key={m.id} style={{ borderBottom: '1px solid var(--border-light)' }}>
                          <td style={{ padding: '8px 12px', color: 'var(--text-heading)' }}>{m.identity_name || m.identity_key}</td>
                          <td style={{ padding: '8px 12px', color: 'var(--text-secondary)' }}>{m.match_type === 'exact' ? '精确邮箱' : '后缀/域名'}</td>
                          <td style={{ padding: '8px 12px', color: 'var(--text-secondary)' }}><code>{m.pattern}</code></td>
                          <td style={{ padding: '8px 12px' }}>
                            <button onClick={() => removeEmailMapping(m)} style={{ ...miniBtn, color: '#e74c3c' }}>删除</button>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </div>
          )}
        </>
      )}

      {/* 身份编辑弹窗 */}
      {(creating || editing) && (
        <div onClick={() => { setCreating(false); setEditing(null); }} style={overlayStyle}>
          {/* 审计 P2-12：role/aria-modal/tabIndex 弹窗语义，遮罩点击关闭 */}
          <div ref={identityDialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={modalStyle}>
            <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--text-heading)', marginBottom: 12 }}>{creating ? '新增身份' : `编辑身份：${editing?.name}`}</div>
            <div style={{ marginBottom: 10 }}>
              <label style={labelStyle}>身份标识(key)</label>
              <input value={formKey} disabled={!creating} onChange={(e) => setFormKey(e.target.value)} style={{ ...inputStyle, ...(creating ? {} : { opacity: 0.6 }) }} placeholder="如 ops_normal" />
            </div>
            <div style={{ marginBottom: 10 }}>
              <label style={labelStyle}>身份名称</label>
              <input value={formName} onChange={(e) => setFormName(e.target.value)} style={inputStyle} placeholder="如 运营普通" />
            </div>
            <div style={{ marginBottom: 10 }}>
              <label style={labelStyle}>权限点</label>
              {/* 审计 P2-3：清单后端驱动；拉取失败（空数组）时显示提示，不渲染复选框 */}
              {permissionPoints.length === 0 ? (
                <div style={{ fontSize: 12, color: 'var(--text-muted)' }}>权限点清单加载失败，请刷新页面后重试。</div>
              ) : (
                <div style={{ display: 'flex', flexWrap: 'wrap', gap: '4px 14px' }}>
                  {permissionPoints.map((key) => {
                    const checked = formPoints.includes(key);
                    return (
                      <label key={key} style={{ display: 'flex', alignItems: 'center', gap: 4, cursor: 'pointer', fontSize: 12 }}>
                        <input type="checkbox" checked={checked} onChange={() => setFormPoints(checked ? formPoints.filter((k) => k !== key) : [...formPoints, key])} />
                        {permissionLabel(key)}
                      </label>
                    );
                  })}
                </div>
              )}
            </div>
            <div style={{ marginBottom: 10 }}>
              <label style={labelStyle}>游戏授权</label>
              <GamePicker
                games={games}
                allGames={formAllGames}
                selected={formGames}
                onAllGames={(v) => { setFormAllGames(v); if (!v) setFormGames([]); }}
                onToggle={(k) => setFormGames(formGames.includes(k) ? formGames.filter((x) => x !== k) : [...formGames, k])}
              />
            </div>
            <div style={{ marginBottom: 10 }}>
              <label style={labelStyle}>机密档位（SQL / 知识库 / 专项 各自可多选；算法不分档。默认 L3）</label>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                {LEVEL_TYPES.map((t) => {
                  const selected = formAccessLevels[t.key];
                  return (
                    <div key={t.key} style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                      <span style={{ width: 44, fontSize: 12, color: 'var(--text-secondary)', fontWeight: 500 }}>{t.label}</span>
                      {CONFIDENTIALITY_LEVELS.map((l) => {
                        const checked = selected.includes(l);
                        const toggle = () => {
                          const next = checked ? selected.filter((x) => x !== l) : [...selected, l];
                          // 至少保留一档（默认 L3）：全清时回退 L3
                          const final = next.length === 0 ? ['L3'] : next;
                          setFormAccessLevels({ ...formAccessLevels, [t.key]: final });
                        };
                        return (
                          <label key={l} style={{ display: 'flex', alignItems: 'center', gap: 4, cursor: 'pointer', fontSize: 12, color: 'var(--text-secondary)' }}>
                            <input type="checkbox" checked={checked} onChange={toggle} />
                            {CONFIDENTIALITY_LABELS[l]}
                          </label>
                        );
                      })}
                    </div>
                  );
                })}
              </div>
            </div>
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end', marginTop: 16 }}>
              <button onClick={() => { setCreating(false); setEditing(null); }} disabled={saving} style={cancelBtn}>取消</button>
              <button onClick={saveIdentity} disabled={saving} style={{ ...primaryBtn, opacity: saving ? 0.6 : 1 }}>{saving ? '保存中…' : '保存'}</button>
            </div>
          </div>
        </div>
      )}

      {/* 邮箱映射弹窗 */}
      {showEmailForm && (
        <div onClick={() => setShowEmailForm(false)} style={overlayStyle}>
          {/* 审计 P2-12：role/aria-modal/tabIndex 弹窗语义，遮罩点击关闭 */}
          <div ref={emailDialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={modalStyle}>
            <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--text-heading)', marginBottom: 12 }}>新增企业邮箱映射</div>
            <div style={{ marginBottom: 10 }}>
              <label style={labelStyle}>身份</label>
              <select value={emailIdentity} onChange={(e) => setEmailIdentity(e.target.value)} style={inputStyle}>
                {identities.map((id) => <option key={id.key} value={id.key}>{id.name}</option>)}
              </select>
            </div>
            <div style={{ marginBottom: 10 }}>
              <label style={labelStyle}>匹配方式</label>
              <select value={emailMatch} onChange={(e) => setEmailMatch(e.target.value as any)} style={inputStyle}>
                <option value="exact">精确邮箱（完整地址）</option>
                <option value="suffix">后缀/域名（如 @fcdata.com）</option>
              </select>
            </div>
            <div style={{ marginBottom: 10 }}>
              <label style={labelStyle}>匹配规则</label>
              <input value={emailPattern} onChange={(e) => setEmailPattern(e.target.value)} style={inputStyle} placeholder={emailMatch === 'exact' ? 'zhangsan@fcdata.com' : '@fcdata.com'} autoFocus />
            </div>
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end', marginTop: 16 }}>
              <button onClick={() => setShowEmailForm(false)} disabled={savingEmail} style={cancelBtn}>取消</button>
              <button onClick={saveEmailMapping} disabled={savingEmail} style={{ ...primaryBtn, opacity: savingEmail ? 0.6 : 1 }}>{savingEmail ? '保存中…' : '保存'}</button>
            </div>
          </div>
        </div>
      )}

      {/* 删除确认弹窗（审计 P2-5：自研内联确认，替代 window.confirm） */}
      {confirmTarget && (
        <div onClick={() => setConfirmTarget(null)} style={overlayStyle}>
          {/* 审计 P2-12：role/aria-modal/tabIndex 弹窗语义 */}
          <div ref={confirmDialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={dialogStyle}>
            <p style={{ margin: 0, fontSize: 13, color: 'var(--text-primary)' }}>
              {confirmTarget.kind === 'identity'
                ? `删除身份「${confirmTarget.identity.name}」？`
                : `删除映射「${confirmTarget.mapping.pattern}」？`}
            </p>
            <p style={{ margin: '6px 0 0', fontSize: 11, color: 'var(--text-muted)' }}>此操作不可撤销。</p>
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end', marginTop: 14 }}>
              <button onClick={() => setConfirmTarget(null)} style={saveCancelBtn}>取消</button>
              <button onClick={confirmRemove} style={dangerBtn}>删除</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};

const miniBtn: React.CSSProperties = {
  padding: '3px 10px', borderRadius: 4, border: '1px solid var(--text-inactive)',
  background: 'transparent', color: 'var(--text-secondary)', cursor: 'pointer', fontSize: 11,
};
// 审计 P2-12：固定宽度 min() 化；已有 maxHeight + overflow 滚动，只改宽度
const modalStyle: React.CSSProperties = {
  backgroundColor: 'var(--surface-1)', color: 'var(--text-primary)',
  borderRadius: 10, padding: 20, width: 'min(480px,94vw)', maxWidth: 'calc(100vw - 32px)', maxHeight: 'calc(100vh - 64px)', overflow: 'auto',
  boxShadow: '0 8px 32px rgba(0,0,0,0.24)',
};
const inputStyle: React.CSSProperties = {
  width: '100%', padding: '8px 12px', borderRadius: 6, border: '1px solid var(--text-inactive)',
  backgroundColor: 'var(--surface-1)', color: 'var(--text-primary)', fontSize: 14, outline: 'none', boxSizing: 'border-box',
};
const labelStyle: React.CSSProperties = {
  display: 'block', fontSize: 12, color: 'var(--text-secondary)', marginBottom: 4, fontWeight: 500,
};
const cancelBtn: React.CSSProperties = {
  padding: '6px 14px', borderRadius: 6, border: '1px solid var(--text-inactive)',
  background: 'transparent', color: 'var(--text-primary)', cursor: 'pointer', fontSize: 13,
};
const primaryBtn: React.CSSProperties = {
  padding: '6px 14px', borderRadius: 6, border: 'none', background: 'var(--accent-blue)', color: '#fff', cursor: 'pointer', fontSize: 13,
};
