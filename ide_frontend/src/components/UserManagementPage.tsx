import React, { useState, useEffect, useCallback } from 'react';
import { useToast } from './Toast';
import { api } from '../services/api';
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

interface IdentityRow {
  key: string;
  name: string;
  permission_points: string;
  games: string;
  access_levels: string;
  is_builtin: number;
}

interface UserRow {
  id: string;
  username: string;
  role: string;
  is_active: number;
  login_attempts: number;
  last_login_at: string | null;
  created_at: string;
  joydata_email: string;
  identity?: string[];
  identity_name?: string[];
  is_custom?: boolean;
  extra_permissions?: string;
  extra_games?: string;
  extra_access_levels?: string;
}

/** extra_permissions / extra_games 在 /api/auth/users 里是原始 JSON 字符串，前端解析成数组。 */
const parseStrList = (raw: string | string[] | null | undefined): string[] => {
  if (Array.isArray(raw)) return raw;
  try { const v = JSON.parse(raw || '[]'); return Array.isArray(v) ? v : []; } catch { return []; }
};

/** 身份 key / 名称列表：后端多身份返回 string[]，兼容滚动部署期间旧后端仍传单字符串。 */
const identityList = (raw: string[] | string | null | undefined): string[] => {
  if (Array.isArray(raw)) return raw;
  if (!raw) return [];
  return [raw];
};

/** access_levels JSON 对象解析：{sql/kb/skill: [L1..L3]}；损坏/缺失回空对象。 */
const parseLevelsObj = (raw: string | Record<string, any> | null | undefined): Record<string, string[]> => {
  if (raw && typeof raw === 'object' && !Array.isArray(raw)) return raw as Record<string, string[]>;
  const s: string = typeof raw === 'string' ? raw : '';
  try { const v = JSON.parse(s || '{}'); return v && typeof v === 'object' && !Array.isArray(v) ? v : {}; } catch { return {}; }
};

/** 规范化某身份的机密档位集合：只保留 sql/kb/skill 三键 + 合法档位值，缺失/空 → 默认 L3。 */
const normalizeLevels = (raw: string | Record<string, any> | null | undefined): AccessLevels => {
  const obj = parseLevelsObj(raw);
  const out = { sql: [], kb: [], skill: [] } as AccessLevels;
  for (const t of LEVEL_TYPES) {
    const v = obj[t.key];
    out[t.key] = Array.isArray(v) ? v.filter((l) => (CONFIDENTIALITY_LEVELS as readonly string[]).includes(l)) : [];
    if (out[t.key].length === 0) out[t.key] = ['L3'];
  }
  return out;
};

/** 生效档位 = 身份自带 ∪ 额外授权（与后端 effective_access_levels 同口径）。 */
const mergeLevels = (base: AccessLevels, extra: Record<string, string[]>): AccessLevels => {
  const out = { sql: [], kb: [], skill: [] } as AccessLevels;
  for (const t of LEVEL_TYPES) {
    const ev = Array.isArray(extra[t.key]) ? extra[t.key].filter((l) => (CONFIDENTIALITY_LEVELS as readonly string[]).includes(l)) : [];
    const merged = [...new Set([...(base[t.key] || []), ...ev])];
    out[t.key] = merged.length ? merged : ['L3'];
  }
  return out;
};

/** 反推「额外」档位 = 生效档位 − 身份自带（保存时写回 extra_access_levels）。 */
const diffLevels = (effective: AccessLevels, base: AccessLevels): Record<string, string[]> => {
  const out: Record<string, string[]> = {};
  for (const t of LEVEL_TYPES) {
    const extra = (effective[t.key] || []).filter((l) => !(base[t.key] || []).includes(l));
    if (extra.length) out[t.key] = extra;
  }
  return out;
};

/** 系统管理 → 用户管理：列出 ide_data.db users 表全部账号，支持新增用户 + 管理员重置密码 +
 *  搜索（用户名 + fcdata 邮箱）+ 身份/状态筛选 + 用户授权（身份 + 额外权限点 + 额外游戏）。 */
export const UserManagementPage: React.FC = () => {
  const { success: toastSuccess, error: toastError } = useToast();
  const [users, setUsers] = useState<UserRow[]>([]);
  const [identities, setIdentities] = useState<IdentityRow[]>([]);
  const [games, setGames] = useState<{ key: string; name: string }[]>([]);
  const [loading, setLoading] = useState(true);
  const [forbidden, setForbidden] = useState(false);
  const [showCreate, setShowCreate] = useState(false);
  const [newUsername, setNewUsername] = useState('');
  // 默认密码 123456（P1-17 内部建号策略：初始账号默认密码，登录后尽快修改）
  const [newPassword, setNewPassword] = useState('123456');
  const [creating, setCreating] = useState(false);
  const [resetTarget, setResetTarget] = useState<UserRow | null>(null);
  const [resetPassword, setResetPassword] = useState('');
  const [resetting, setResetting] = useState(false);
  const [editingEmailId, setEditingEmailId] = useState<string | null>(null);
  const [editingEmailValue, setEditingEmailValue] = useState('');
  const [savingEmail, setSavingEmail] = useState(false);
  // 审计 P1-17：邮箱后缀会自动归入身份时，先弹管理员显式确认再保存
  const [emailConfirm, setEmailConfirm] = useState<{ u: UserRow; email: string; identityName: string } | null>(null);
  const [deletingId, setDeletingId] = useState<string | null>(null);
  // 权限点清单（审计 P2-3）：后端驱动，空数组兜底（授权弹窗权限点区域显示提示）
  const [permissionPoints, setPermissionPoints] = useState<string[]>([]);
  const permissionLabel = (key: string) => PERMISSION_POINT_LABELS[key] || key;
  // 删除确认弹窗目标（审计 P2-5：内联确认替代 window.confirm）
  const [deleteTarget, setDeleteTarget] = useState<UserRow | null>(null);

  // 搜索 + 筛选
  const [search, setSearch] = useState('');
  const [identityFilter, setIdentityFilter] = useState(''); // '' = 全部身份
  const [statusFilter, setStatusFilter] = useState<'all' | 'active' | 'inactive'>('all');

  // 用户授权弹窗
  const [authTarget, setAuthTarget] = useState<UserRow | null>(null);
  const [authIdentities, setAuthIdentities] = useState<string[]>([]);
  const [authPerms, setAuthPerms] = useState<string[]>([]);
  const [authGames, setAuthGames] = useState<string[]>([]);
  const [authLevels, setAuthLevels] = useState<AccessLevels>({ sql: ['L3'], kb: ['L3'], skill: ['L3'] });
  const [savingAuth, setSavingAuth] = useState(false);

  const [currentUsername, setCurrentUsername] = useState<string>(() => {
    try { return JSON.parse(localStorage.getItem('wb_jwt_user') || '{}').username || ''; } catch { return ''; }
  });

  // 审计 P2-12：各弹窗接入 useDialog（Escape 关闭 + 打开聚焦 + 关闭还原焦点）
  const createDialogRef = useDialog(showCreate, () => setShowCreate(false));
  const resetDialogRef = useDialog(resetTarget !== null, () => setResetTarget(null));
  const authDialogRef = useDialog(authTarget !== null, () => setAuthTarget(null));
  const deleteDialogRef = useDialog(deleteTarget !== null, () => setDeleteTarget(null));
  const emailConfirmDialogRef = useDialog(emailConfirm !== null, () => setEmailConfirm(null));

  const load = useCallback(() => {
    setLoading(true);
    setForbidden(false);
    api.getUsers()
      .then((list) => setUsers(Array.isArray(list) ? list : []))
      .catch((e) => {
        const msg = e instanceof Error ? e.message : '';
        if (/管理员|admin|403|权限/i.test(msg)) setForbidden(true);
        else toastError(msg || '加载用户失败');
      })
      .finally(() => setLoading(false));
  }, [toastError]);

  useEffect(() => { load(); }, [load]);

  // 身份列表 + 游戏列表 + 权限点清单（供授权弹窗 + 身份筛选），加载一次即可。
  useEffect(() => {
    api.listIdentities().then((ids) => setIdentities(Array.isArray(ids) ? ids : [])).catch(() => {});
    api.getGames().then((r) => setGames((r as any).games || [])).catch(() => {});
    // 审计 P2-3：权限点清单后端驱动
    api.getPermissionPoints().then((r) => setPermissionPoints(r.points || [])).catch(() => {});
  }, []);

  const filteredUsers = users.filter((u) => {
    if (search.trim()) {
      const q = search.trim().toLowerCase();
      const hit = (u.username || '').toLowerCase().includes(q) || (u.joydata_email || '').toLowerCase().includes(q);
      if (!hit) return false;
    }
    if (identityFilter && !identityList(u.identity_name).includes(identityFilter)) return false;
    if (statusFilter === 'active' && !u.is_active) return false;
    if (statusFilter === 'inactive' && u.is_active) return false;
    return true;
  });

  const handleCreate = async () => {
    if (newUsername.trim().length < 3 || newPassword.length < 6) {
      toastError('用户名至少 3 个字符，密码至少 6 位');
      return;
    }
    setCreating(true);
    try {
      await api.createUser(newUsername.trim(), newPassword);
      toastSuccess('用户已创建');
      setNewUsername('');
      setNewPassword('123456');
      setShowCreate(false);
      load();
    } catch (e) {
      toastError(e instanceof Error ? e.message : '创建失败');
    } finally {
      setCreating(false);
    }
  };

  const handleReset = async () => {
    if (!resetTarget || resetPassword.length < 6) {
      toastError('密码至少 6 位');
      return;
    }
    setResetting(true);
    try {
      await api.adminResetPassword(resetTarget.id, resetPassword);
      toastSuccess(`已重置「${resetTarget.username}」的密码`);
      setResetTarget(null);
      setResetPassword('');
    } catch (e) {
      toastError(e instanceof Error ? e.message : '重置失败');
    } finally {
      setResetting(false);
    }
  };

  // 审计 P1-17：与后端 permissions._email_identity 同口径（先精确、再最长后缀），用于保存前预判
  const resolveEmailIdentityName = (email: string, mappings: { identity_name: string; match_type: string; pattern: string }[]) => {
    const em = email.toLowerCase();
    let bestName = '';
    let bestLen = 0;
    for (const m of mappings) {
      const p = (m.pattern || '').toLowerCase();
      if (!p) continue;
      if (m.match_type === 'exact') {
        if (em === p) return m.identity_name || '';
      } else if (em.endsWith(p) && p.length > bestLen) {
        bestName = m.identity_name || '';
        bestLen = p.length;
      }
    }
    return bestName;
  };

  const doSaveEmail = async (email: string) => {
    if (!editingEmailId) return;
    setSavingEmail(true);
    try {
      const r = await api.setUserFCDataEmail(editingEmailId, email);
      const autoName = r?.auto_identity_name || '';
      // 落库后披露自动归入的身份，管理员可据此再显式调整「授权」（审计 P1-17）
      toastSuccess(autoName
        ? `fcdata 邮箱已更新，该邮箱自动归入身份「${autoName}」`
        : 'fcdata 邮箱已更新');
      setEditingEmailId(null);
      load();
    } catch (e) {
      toastError(e instanceof Error ? e.message : '保存失败');
    } finally {
      setSavingEmail(false);
    }
  };

  const handleSaveEmail = async () => {
    if (!editingEmailId) return;
    const email = editingEmailValue.trim();
    if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      toastError('邮箱格式不正确');
      return;
    }
    const u = users.find((x) => x.id === editingEmailId);
    // 无显式身份且邮箱命中映射 → 弹管理员显式确认（有显式身份时邮箱映射不生效，直接保存）
    if (u && identityList(u.identity).length === 0 && email) {
      try {
        const mappings = await api.listEmailMappings();
        const autoName = resolveEmailIdentityName(email, Array.isArray(mappings) ? mappings : []);
        if (autoName) {
          setEmailConfirm({ u, email, identityName: autoName });
          return;
        }
      } catch { /* 映射拉取失败不阻断保存，落库后响应里仍会带回 auto_identity 披露 */ }
    }
    await doSaveEmail(email);
  };

  const fmtTime = (s: string | null) => {
    if (!s) return '—';
    return s.replace('T', ' ').slice(0, 19);
  };

  const handleDelete = async (u: UserRow) => {
    if (u.username === 'anonymous') { toastError('anonymous 是系统回落占位，不可删除'); return; }
    if (u.username === currentUsername) { toastError('不能删除当前登录账号'); return; }
    setDeleteTarget(u); // 审计 P2-5：内联确认弹窗替代 window.confirm
  };

  /** 删除确认弹窗「删除」按钮的执行体（审计 P2-5） */
  const confirmDelete = async () => {
    if (!deleteTarget) return;
    const u = deleteTarget;
    setDeleteTarget(null);
    setDeletingId(u.id);
    try {
      await api.deleteUser(u.id);
      toastSuccess(`用户「${u.username}」已删除`);
      load();
    } catch (e) {
      toastError(e instanceof Error ? e.message : '删除失败');
    } finally {
      setDeletingId(null);
    }
  };

  // ── 用户授权 ──
  const identityOf = (key: string) => identities.find((i) => i.key === key);
  // 生效集 = 所选身份「并集」 ∪ 额外授权；弹窗里直接编辑生效集，保存时反推「额外」写回后端
  const identityPermsOf = (key: string) => (identityOf(key) ? parseStrList(identityOf(key)!.permission_points) : []);
  const identityGamesOf = (key: string) => (identityOf(key) ? parseStrList(identityOf(key)!.games) : []);
  const identityLevelsOf = (key: string): AccessLevels => normalizeLevels(identityOf(key)?.access_levels);
  // 多身份并集（用户可同时挂多个身份，权限/游戏/档位取并集）
  const basePermsOf = (keys: string[]) => {
    const s = new Set<string>();
    keys.forEach((k) => identityPermsOf(k).forEach((p) => s.add(p)));
    return [...s];
  };
  const baseGamesOf = (keys: string[]) => {
    let full = false;
    const s = new Set<string>();
    keys.forEach((k) => { const g = identityGamesOf(k); if (g.includes('*')) full = true; g.forEach((x) => s.add(x)); });
    return full ? ['*'] : [...s];
  };
  const baseLevelsOf = (keys: string[]): AccessLevels => {
    const acc: AccessLevels = { sql: [], kb: [], skill: [] };
    keys.forEach((k) => {
      const lv = identityLevelsOf(k);
      acc.sql = [...new Set([...acc.sql, ...lv.sql])];
      acc.kb = [...new Set([...acc.kb, ...lv.kb])];
      acc.skill = [...new Set([...acc.skill, ...lv.skill])];
    });
    for (const t of LEVEL_TYPES) if (acc[t.key].length === 0) acc[t.key] = ['L3'];
    return acc;
  };
  const authAllGames = baseGamesOf(authIdentities).includes('*');

  const openAuth = (u: UserRow) => {
    setAuthTarget(u);
    const keys = identityList(u.identity);
    const basePerms = basePermsOf(keys);
    const baseGames = baseGamesOf(keys);
    const baseLevels = baseLevelsOf(keys);
    const extraPerms = parseStrList(u.extra_permissions);
    const extraGames = parseStrList(u.extra_games);
    const extraLevels = parseLevelsObj(u.extra_access_levels);
    setAuthIdentities(keys);
    setAuthPerms([...new Set([...basePerms, ...extraPerms])]);
    setAuthGames(baseGames.includes('*') ? games.map((g) => g.key) : [...new Set([...baseGames, ...extraGames])]);
    setAuthLevels(mergeLevels(baseLevels, extraLevels));
  };
  // 联动：勾选/取消身份时，权限点/游戏/机密档位回填到「所选身份并集」，并保留已追加的额外授权
  const toggleIdentity = (key: string) => {
    const selected = authIdentities.includes(key);
    const nextKeys = selected ? authIdentities.filter((k) => k !== key) : [...authIdentities, key];
    const oldBasePerms = basePermsOf(authIdentities);
    const oldBaseGames = baseGamesOf(authIdentities);
    const oldBaseLevels = baseLevelsOf(authIdentities);
    const extraPerms = authPerms.filter((p) => !oldBasePerms.includes(p));
    // 旧身份已含全游戏时无「额外游戏」概念（生效集即全游戏），反推额外应为空，避免取消全游戏身份后把全量游戏误当额外授权
    const extraGames = oldBaseGames.includes('*') ? [] : authGames.filter((g) => !oldBaseGames.includes(g));
    const extraLevels = diffLevels(authLevels, oldBaseLevels);
    setAuthIdentities(nextKeys);
    const nb = basePermsOf(nextKeys);
    const ng = baseGamesOf(nextKeys);
    const nl = baseLevelsOf(nextKeys);
    setAuthPerms([...new Set([...nb, ...extraPerms])]);
    setAuthGames(ng.includes('*') ? games.map((g) => g.key) : [...new Set([...ng, ...extraGames])]);
    setAuthLevels(mergeLevels(nl, extraLevels));
  };
  const saveAuth = async () => {
    if (!authTarget) return;
    setSavingAuth(true);
    try {
      const identPerms = basePermsOf(authIdentities);
      const identGames = baseGamesOf(authIdentities);
      const identLevels = baseLevelsOf(authIdentities);
      const extraPerms = authPerms.filter((p) => !identPerms.includes(p));
      const extraGames = identGames.includes('*') ? [] : authGames.filter((g) => !identGames.includes(g));
      const extraAccessLevels = diffLevels(authLevels, identLevels);
      await api.updateUserPermissions(authTarget.id, { identity: authIdentities, extra_permissions: extraPerms, extra_games: extraGames, extra_access_levels: extraAccessLevels });
      toastSuccess(`已保存「${authTarget.username}」的授权`);
      setAuthTarget(null);
      load();
    } catch (e) {
      toastError(e instanceof Error ? e.message : '保存失败');
    } finally {
      setSavingAuth(false);
    }
  };

  return (
    <div style={{ flex: 1, display: 'flex', flexDirection: 'column', padding: 16, gap: 12, backgroundColor: 'var(--surface-3)', color: 'var(--text-primary)', overflow: 'auto' }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <div>
          <h3 style={{ margin: 0, fontSize: 14, color: 'var(--text-heading)' }}>用户管理</h3>
          <p style={{ margin: '4px 0 0', fontSize: 12, color: 'var(--text-muted)' }}>共 {users.length} 个账号（含匿名回落占位）</p>
        </div>
        <button onClick={() => setShowCreate(true)}
          style={{ padding: '6px 14px', borderRadius: 6, border: 'none', background: 'var(--accent-blue)', color: '#fff', cursor: 'pointer', fontSize: 13, fontWeight: 500 }}>
          ＋ 新增用户
        </button>
      </div>

      {/* 搜索 + 筛选 */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
        <input
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="搜索用户名 / fcdata 邮箱"
          style={{ width: 220, padding: '5px 10px', borderRadius: 6, border: '1px solid var(--text-inactive)', background: 'var(--surface-1)', color: 'var(--text-primary)', fontSize: 12, outline: 'none' }}
        />
        <select
          value={identityFilter}
          onChange={(e) => setIdentityFilter(e.target.value)}
          style={{ padding: '5px 8px', borderRadius: 6, border: '1px solid var(--text-inactive)', background: 'var(--surface-1)', color: 'var(--text-primary)', fontSize: 12, outline: 'none', cursor: 'pointer' }}
        >
          <option value="">全部身份</option>
          {identities.map((id) => (
            <option key={id.key} value={id.name}>{id.name}</option>
          ))}
        </select>
        <div style={{ display: 'flex', gap: 0, border: '1px solid var(--text-inactive)', borderRadius: 6, overflow: 'hidden' }}>
          {[
            { key: 'all', label: '全部状态' },
            { key: 'active', label: '启用' },
            { key: 'inactive', label: '禁用' },
          ].map((s) => (
            <button key={s.key} onClick={() => setStatusFilter(s.key as any)}
              style={{ padding: '5px 12px', border: 'none', cursor: 'pointer', fontSize: 12,
                backgroundColor: statusFilter === s.key ? 'var(--accent-blue)' : 'transparent',
                color: statusFilter === s.key ? '#fff' : 'var(--text-secondary)' }}>
              {s.label}
            </button>
          ))}
        </div>
        <span style={{ fontSize: 12, color: 'var(--text-muted)' }}>显示 {filteredUsers.length} / {users.length}</span>
      </div>

      {forbidden ? (
        <div style={{ padding: '24px 16px', textAlign: 'center', color: 'var(--text-muted)', fontSize: 13 }}>
          ⚠️ 需要管理员权限才能查看用户列表。请用管理员账号登录。
        </div>
      ) : loading ? (
        <div style={{ padding: '24px 16px', textAlign: 'center', color: 'var(--text-muted)', fontSize: 13 }}>加载中…</div>
      ) : filteredUsers.length === 0 ? (
        <div style={{ padding: '24px 16px', textAlign: 'center', color: 'var(--text-muted)', fontSize: 13 }}>暂无匹配的用户</div>
      ) : (
        <div style={{ border: '1px solid var(--border-light)', borderRadius: 8, overflow: 'auto', backgroundColor: 'var(--surface-1)' }}>
          <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
            <thead>
              <tr style={{ backgroundColor: 'var(--surface-2)' }}>
                {['用户名', '身份', 'fcdata 邮箱', '状态', '登录失败', '最后登录', '创建时间', '操作'].map((h) => (
                  <th key={h} style={{ textAlign: 'left', padding: '8px 12px', fontWeight: 600, color: 'var(--text-secondary)', borderBottom: '1px solid var(--border-light)', whiteSpace: 'nowrap' }}>{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {filteredUsers.map((u) => {
                const isAnon = u.username === 'anonymous';
                return (
                  <tr key={u.id} style={{ borderBottom: '1px solid var(--border-light)' }}>
                    <td style={{ padding: '8px 12px' }}>
                      <strong style={{ color: 'var(--text-heading)' }}>{u.username}</strong>
                      {isAnon && <span style={{ marginLeft: 6, fontSize: 11, color: 'var(--text-muted)' }}>(匿名回落占位)</span>}
                    </td>
                    <td style={{ padding: '8px 12px' }}>
                      {identityList(u.identity_name).length === 0 ? (
                        <span style={{ padding: '2px 8px', borderRadius: 10, fontSize: 11, backgroundColor: 'var(--surface-2)', color: 'var(--text-secondary)' }}>默认</span>
                      ) : (
                        identityList(u.identity_name).map((n) => (
                          <span key={n} style={{ marginRight: 4, padding: '2px 8px', borderRadius: 10, fontSize: 11, backgroundColor: 'var(--tint-blue-bg)', color: 'var(--accent-blue)' }}>{n}</span>
                        ))
                      )}
                      {u.is_custom && (
                        <span style={{ marginLeft: 6, padding: '2px 8px', borderRadius: 10, fontSize: 11, backgroundColor: 'var(--tint-amber-bg, var(--surface-2))', color: 'var(--accent-amber, #c9a227)' }}>自定义</span>
                      )}
                    </td>
                    <td style={{ padding: '8px 12px' }}>
                      {editingEmailId === u.id ? (
                        <span style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}>
                          <input
                            value={editingEmailValue}
                            onChange={(e) => setEditingEmailValue(e.target.value)}
                            placeholder="fcdata 邮箱"
                            autoFocus
                            style={{ width: 160, padding: '3px 6px', borderRadius: 4, border: '1px solid var(--text-inactive)', background: 'var(--surface-1)', color: 'var(--text-primary)', fontSize: 12, outline: 'none' }}
                          />
                          <button onClick={handleSaveEmail} disabled={savingEmail}
                            style={{ padding: '2px 8px', borderRadius: 4, border: 'none', background: 'var(--accent-blue)', color: '#fff', cursor: 'pointer', fontSize: 11, whiteSpace: 'nowrap' }}>
                            {savingEmail ? '…' : '保存'}
                          </button>
                          <button onClick={() => setEditingEmailId(null)} disabled={savingEmail}
                            style={{ padding: '2px 8px', borderRadius: 4, border: '1px solid var(--text-inactive)', background: 'transparent', color: 'var(--text-secondary)', cursor: 'pointer', fontSize: 11 }}>
                            取消
                          </button>
                        </span>
                      ) : (
                        <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
                          <span style={{ color: u.joydata_email ? 'var(--text-primary)' : 'var(--text-muted)' }}>{u.joydata_email || '未绑定'}</span>
                          {!isAnon && (
                            <button onClick={() => { setEditingEmailId(u.id); setEditingEmailValue(u.joydata_email || ''); }}
                              style={{ padding: '2px 8px', borderRadius: 4, border: '1px solid var(--text-inactive)', background: 'transparent', color: 'var(--text-secondary)', cursor: 'pointer', fontSize: 11, whiteSpace: 'nowrap' }}>
                              编辑
                            </button>
                          )}
                        </span>
                      )}
                    </td>
                    <td style={{ padding: '8px 12px' }}>
                      <span style={{ color: u.is_active ? '#5a5' : '#e74c3c' }}>{u.is_active ? '● 启用' : '○ 禁用'}</span>
                    </td>
                    <td style={{ padding: '8px 12px', color: 'var(--text-secondary)' }}>{u.login_attempts ?? 0}</td>
                    <td style={{ padding: '8px 12px', color: 'var(--text-secondary)' }}>{fmtTime(u.last_login_at)}</td>
                    <td style={{ padding: '8px 12px', color: 'var(--text-secondary)' }}>{fmtTime(u.created_at)}</td>
                    <td style={{ padding: '8px 12px' }}>
                      {!isAnon && (
                        <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
                          <button onClick={() => openAuth(u)}
                            style={{ padding: '3px 10px', borderRadius: 4, border: '1px solid var(--text-inactive)', background: 'transparent', color: 'var(--text-secondary)', cursor: 'pointer', fontSize: 11, whiteSpace: 'nowrap' }}>
                            授权
                          </button>
                          <button onClick={() => { setResetTarget(u); setResetPassword(''); }}
                            style={{ padding: '3px 10px', borderRadius: 4, border: '1px solid var(--text-inactive)', background: 'transparent', color: 'var(--text-secondary)', cursor: 'pointer', fontSize: 11, whiteSpace: 'nowrap' }}>
                            重置密码
                          </button>
                          <button onClick={() => handleDelete(u)} disabled={deletingId === u.id}
                            style={{ padding: '3px 10px', borderRadius: 4, border: '1px solid var(--text-inactive)', background: 'transparent', color: '#e74c3c', cursor: 'pointer', fontSize: 11, whiteSpace: 'nowrap', opacity: deletingId === u.id ? 0.6 : 1 }}>
                            {deletingId === u.id ? '删除中…' : '删除'}
                          </button>
                        </span>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      {/* 新增用户弹窗 */}
      {showCreate && (
        <div onClick={() => setShowCreate(false)} style={overlayStyle}>
          {/* 审计 P2-12：role/aria-modal/tabIndex 弹窗语义，遮罩点击关闭 */}
          <div ref={createDialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={modalStyle}>
            <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--text-heading)', marginBottom: 12 }}>新增用户</div>
            <div style={{ marginBottom: 10 }}><label style={labelStyle}>用户名（≥3 字符，建议公司邮箱姓名前缀）</label>
              <input value={newUsername} onChange={(e) => setNewUsername(e.target.value)} style={inputStyle} placeholder="例：zhangsan" autoFocus /></div>
            <div style={{ marginBottom: 10 }}><label style={labelStyle}>密码（默认 123456，用户登录后请尽快修改）</label>
              <input type="password" value={newPassword} onChange={(e) => setNewPassword(e.target.value)} style={inputStyle} placeholder="默认 123456" /></div>
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end', marginTop: 16 }}>
              <button onClick={() => setShowCreate(false)} disabled={creating}
                style={{ padding: '6px 14px', borderRadius: 6, border: '1px solid var(--text-inactive)', background: 'transparent', color: 'var(--text-primary)', cursor: 'pointer', fontSize: 13 }}>取消</button>
              <button onClick={handleCreate} disabled={creating}
                style={{ padding: '6px 14px', borderRadius: 6, border: 'none', background: 'var(--accent-blue)', color: '#fff', cursor: 'pointer', fontSize: 13, opacity: creating ? 0.6 : 1 }}>
                {creating ? '创建中…' : '创建'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* 重置密码弹窗 */}
      {resetTarget && (
        <div onClick={() => setResetTarget(null)} style={overlayStyle}>
          {/* 审计 P2-12：role/aria-modal/tabIndex 弹窗语义，遮罩点击关闭 */}
          <div ref={resetDialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={modalStyle}>
            <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--text-heading)', marginBottom: 4 }}>重置密码</div>
            <div style={{ fontSize: 12, color: 'var(--text-muted)', marginBottom: 12 }}>用户：{resetTarget.username}</div>
            <div style={{ marginBottom: 10 }}><label style={labelStyle}>新密码（≥6 位）</label>
              <input type="password" value={resetPassword} onChange={(e) => setResetPassword(e.target.value)} style={inputStyle} autoFocus /></div>
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end', marginTop: 16 }}>
              <button onClick={() => setResetTarget(null)} disabled={resetting}
                style={{ padding: '6px 14px', borderRadius: 6, border: '1px solid var(--text-inactive)', background: 'transparent', color: 'var(--text-primary)', cursor: 'pointer', fontSize: 13 }}>取消</button>
              <button onClick={handleReset} disabled={resetting}
                style={{ padding: '6px 14px', borderRadius: 6, border: 'none', background: 'var(--accent-blue)', color: '#fff', cursor: 'pointer', fontSize: 13, opacity: resetting ? 0.6 : 1 }}>
                {resetting ? '重置中…' : '确认重置'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* 邮箱→身份自动归入确认弹窗（审计 P1-17：管理员显式确认后再落库） */}
      {emailConfirm && (
        <div onClick={() => setEmailConfirm(null)} style={overlayStyle}>
          <div ref={emailConfirmDialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={modalStyle}>
            <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--text-heading)', marginBottom: 4 }}>确认绑定 fcdata 邮箱</div>
            <div style={{ fontSize: 12, color: 'var(--text-secondary)', marginBottom: 12, lineHeight: 1.7 }}>
              用户：{emailConfirm.u.username}（未显式指定身份）
              <br />邮箱 {emailConfirm.email} 将自动归入身份「<strong style={{ color: 'var(--accent-blue)' }}>{emailConfirm.identityName}</strong>」并按其权限生效。
              <br />如不希望自动归入，请取消后先在「授权」里显式指定身份再绑定。
            </div>
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end', marginTop: 16 }}>
              <button onClick={() => setEmailConfirm(null)} disabled={savingEmail}
                style={{ padding: '6px 14px', borderRadius: 6, border: '1px solid var(--text-inactive)', background: 'transparent', color: 'var(--text-primary)', cursor: 'pointer', fontSize: 13 }}>取消</button>
              <button onClick={() => { const c = emailConfirm; setEmailConfirm(null); doSaveEmail(c.email); }} disabled={savingEmail}
                style={{ padding: '6px 14px', borderRadius: 6, border: 'none', background: 'var(--accent-blue)', color: '#fff', cursor: 'pointer', fontSize: 13, opacity: savingEmail ? 0.6 : 1 }}>
                {savingEmail ? '保存中…' : '确认绑定'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* 用户授权弹窗 */}
      {authTarget && (
        <div onClick={() => setAuthTarget(null)} style={overlayStyle}>
          {/* 审计 P2-12：role/aria-modal/tabIndex 弹窗语义，遮罩点击关闭；宽度 min() 化防窄屏溢出 */}
          <div ref={authDialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={{ ...modalStyle, width: 'min(520px,94vw)' }}>
            <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--text-heading)', marginBottom: 4 }}>用户授权</div>
            <div style={{ fontSize: 12, color: 'var(--text-muted)', marginBottom: 12 }}>用户：{authTarget.username}（权限点/游戏联动所选身份，可再追加；在身份基础上追加即显示「自定义」）</div>

            <div style={{ marginBottom: 12 }}>
              <label style={labelStyle}>身份（可多选；权限点/游戏/档位取所选身份并集，可再追加）</label>
              <div style={{ display: 'flex', flexWrap: 'wrap', gap: '4px 14px', maxHeight: 160, overflow: 'auto' }}>
                {identities.map((id) => {
                  const checked = authIdentities.includes(id.key);
                  return (
                    <label key={id.key} style={{ display: 'flex', alignItems: 'center', gap: 4, cursor: 'pointer', fontSize: 12, color: 'var(--text-secondary)' }}>
                      <input type="checkbox" checked={checked} onChange={() => toggleIdentity(id.key)} />
                      {id.name}
                    </label>
                  );
                })}
              </div>
              {authIdentities.length === 0 && (
                <div style={{ fontSize: 12, color: 'var(--text-muted)', marginTop: 4 }}>未分配身份时走邮箱映射 / 默认身份</div>
              )}
            </div>

            <div style={{ marginBottom: 12 }}>
              <label style={labelStyle}>权限点（联动身份，切换身份自动勾选身份自带；可追加）</label>
              {/* 审计 P2-3：清单后端驱动；拉取失败（空数组）时显示提示，不渲染复选框 */}
              {permissionPoints.length === 0 ? (
                <div style={{ fontSize: 12, color: 'var(--text-muted)' }}>权限点清单加载失败，请刷新页面后重试。</div>
              ) : (
                <div style={{ display: 'flex', flexWrap: 'wrap', gap: '4px 14px' }}>
                  {permissionPoints.map((key) => {
                    const checked = authPerms.includes(key);
                    return (
                      <label key={key} style={{ display: 'flex', alignItems: 'center', gap: 4, cursor: 'pointer', fontSize: 12, color: 'var(--text-secondary)' }}>
                        <input type="checkbox" checked={checked}
                          onChange={() => setAuthPerms(checked ? authPerms.filter((k) => k !== key) : [...authPerms, key])} />
                        {permissionLabel(key)}
                      </label>
                    );
                  })}
                </div>
              )}
            </div>

            <div style={{ marginBottom: 12 }}>
              <label style={labelStyle}>游戏（联动身份：全游戏身份自动全选；自定义身份为空需手动勾选）</label>
              {authAllGames ? (
                <div style={{ fontSize: 12, color: 'var(--text-muted)' }}>身份已含全游戏，该用户自动拥有所有游戏权限</div>
              ) : (
                <div style={{ display: 'flex', flexWrap: 'wrap', gap: '4px 14px', maxHeight: 160, overflow: 'auto' }}>
                  {games.map((g) => {
                    const checked = authGames.includes(g.key);
                    return (
                      <label key={g.key} style={{ display: 'flex', alignItems: 'center', gap: 4, cursor: 'pointer', fontSize: 12, color: 'var(--text-secondary)' }}>
                        <input type="checkbox" checked={checked}
                          onChange={() => setAuthGames(checked ? authGames.filter((k) => k !== g.key) : [...authGames, g.key])} />
                        {g.name && g.name !== g.key ? `${g.name}（${g.key}）` : g.key}
                      </label>
                    );
                  })}
                </div>
              )}
            </div>

            <div style={{ marginBottom: 12 }}>
              <label style={labelStyle}>机密档位（SQL / 知识库 / 专项 各自多选，默认 L3；算法不分档）</label>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                {LEVEL_TYPES.map((t) => {
                  const selected = authLevels[t.key];
                  return (
                    <div key={t.key} style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                      <span style={{ width: 44, fontSize: 12, color: 'var(--text-secondary)', fontWeight: 500 }}>{t.label}</span>
                      {CONFIDENTIALITY_LEVELS.map((l) => {
                        const checked = selected.includes(l);
                        const toggle = () => {
                          const next = checked ? selected.filter((x) => x !== l) : [...selected, l];
                          const final = next.length === 0 ? ['L3'] : next;
                          setAuthLevels({ ...authLevels, [t.key]: final });
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
              <button onClick={() => setAuthTarget(null)} disabled={savingAuth}
                style={{ padding: '6px 14px', borderRadius: 6, border: '1px solid var(--text-inactive)', background: 'transparent', color: 'var(--text-primary)', cursor: 'pointer', fontSize: 13 }}>取消</button>
              <button onClick={saveAuth} disabled={savingAuth}
                style={{ padding: '6px 14px', borderRadius: 6, border: 'none', background: 'var(--accent-blue)', color: '#fff', cursor: 'pointer', fontSize: 13, opacity: savingAuth ? 0.6 : 1 }}>
                {savingAuth ? '保存中…' : '保存授权'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* 删除用户确认弹窗（审计 P2-5：自研内联确认，替代 window.confirm） */}
      {deleteTarget && (
        <div onClick={() => setDeleteTarget(null)} style={overlayStyle}>
          {/* 审计 P2-12：role/aria-modal/tabIndex 弹窗语义 */}
          <div ref={deleteDialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={dialogStyle}>
            <p style={{ margin: 0, fontSize: 13, color: 'var(--text-primary)' }}>确定删除用户「{deleteTarget.username}」？</p>
            <p style={{ margin: '6px 0 0', fontSize: 11, color: 'var(--text-muted)' }}>该操作不可撤销。</p>
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

// overlayStyle 复用 wsCommon（审计 P2-5：确认弹窗与既有弹窗共用同一套遮罩样式）
// 审计 P2-12：固定宽度 min() 化；已有 maxHeight + overflow 滚动，只改宽度
const modalStyle: React.CSSProperties = {
  backgroundColor: 'var(--surface-1)', color: 'var(--text-primary)',
  borderRadius: 10, padding: 20, width: 'min(360px,94vw)', maxWidth: 'calc(100vw - 32px)', maxHeight: 'calc(100vh - 64px)', overflow: 'auto',
  boxShadow: '0 8px 32px rgba(0,0,0,0.24)',
};

const inputStyle: React.CSSProperties = {
  width: '100%', padding: '8px 12px', borderRadius: 6, border: '1px solid var(--text-inactive)',
  backgroundColor: 'var(--surface-1)', color: 'var(--text-on-accent)', fontSize: 14, outline: 'none', boxSizing: 'border-box',
};

const labelStyle: React.CSSProperties = {
  display: 'block', fontSize: 12, color: 'var(--text-secondary)', marginBottom: 4, fontWeight: 500,
};
