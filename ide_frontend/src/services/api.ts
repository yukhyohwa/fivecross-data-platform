const TOKEN_KEY = 'wb_jwt_token';
// VITE_API_BASE 为空时走相对路径，由 nginx 反代 /api/ 到 backend（Docker 部署场景）
const API_BASE = import.meta.env.VITE_API_BASE || '';

/** 聊天消息 content：普通字符串，或 OpenAI 风格内容块（支持 image_url 图片） */
export type ChatContent = string | Array<Record<string, any>>;
export type ChatMessage = { role: string; content: ChatContent };

/** 报表指标标签（MySQL 全局表，直接改库；is_nday=1 时 metric_key 为家族关键词） */
export interface QuotaTag {
  id: number;
  metric_key: string;
  tag_name: string;
  is_nday: number;
  sort_order: number;
  /** 指标说明（弹窗/报表列头 hover 展示）；空串=无说明 */
  description?: string;
}

function getToken(): string | null {
  return localStorage.getItem(TOKEN_KEY);
}

export function setToken(token: string | null) {
  if (token) localStorage.setItem(TOKEN_KEY, token);
  else localStorage.removeItem(TOKEN_KEY);
}

/** Clear auth data on logout/401. Layout preferences (sql-ide-storage) are kept. */
export function clearUserCache() {
  localStorage.removeItem(TOKEN_KEY);
  localStorage.removeItem('wb_jwt_user');
  // 对抗审查三轮（F10/F11）：这里不得调 scopeMiscToUser(null)——401（令牌 8h 过期）与
  // 登出都会走到本函数，无条件清杂项键会让同账号重登时游戏选择/游戏模式/看板探索历史收藏
  // 全部丢失且不可恢复。跨账号隔离由 scopeWorkspaceToUser 开头的 scopeMiscToUser(userId)
  // 盖章比对兜底（在 userKey 早退之前执行，任何换账号路径都会清）；同账号 stamp 一致则保留。
  // Do NOT remove sql-ide-storage — it contains layout preferences
  // that should persist across sessions.
}

/** 用户绑定态的工作区字段（sql-ide-storage 中）：账号切换时清空，防跨账号看到上一账号的编辑器页签/结果“历史”。
 *  布局偏好（splitPos/侧栏/schema 缓存等）不在此列，跨账号保留。 */
const USER_BOUND_WS_KEYS = [
  'editorTabs', 'activeEditorTabId', 'nextEditorTabNumber',
  'sql', 'selectedSql',
  'resultTabs', 'activeResultTabId', 'nextTabNumber',
  'agentEditorTabId', 'agentResultTabCounter',
];

/** sessionStorage 里按用户绑定的 AI 对话键（各 AI 侧栏的静态键）：账号切换时按 stamp 清空，防上一账号对话被下一账号看到。 */
const USER_BOUND_SESSION_KEYS = [
  'sql-ide-agent-msgs-v2',      // AI源生（AgentPanel）
  'sql-ide-skill-agent-msgs',   // 专项 AI 侧栏（SkillAgentPanel）
  'sql-ide-kb-agent-msgs',      // 知识库 AI 侧栏（KnowledgeAgentPanel）
  'sql-ide-model-agent-msgs',   // 算法 AI 侧栏（ModelsAgentPanel）
];
const SESSION_USER_STAMP = 'sql-ide-session-user';

/** localStorage 里按用户绑定的杂项键：游戏选择（chatbi.game）、聊天页游戏模式（chatbi.game.mode）与
 *  FCData 看板探索历史/收藏（explore_*_<reportId>），账号切换时清空，防上一账号的选择/筛选条件泄漏给下一账号。 */
const USER_BOUND_MISC_KEYS = ['chatbi.game', 'chatbi.game.mode'];
/** 杂项键的用户归属戳（独立于 sql-ide-storage 的 userKey）：scopeMiscToUser 据此判断是否要清 */
const MISC_USER_STAMP = 'chatbi-user-stamp';

/**
 * 把用户绑定的杂项 localStorage 键归属到指定用户：stamp 与当前用户不一致（含无 stamp 的
 * 历史数据）时清空并盖章；一致则保留。匿名（null/''/anonymous）一律清空且不留 stamp。
 * 独立于 scopeWorkspaceToUser 的 userKey：工作区无状态（userKey 早退）时杂项键仍要按账号收口。
 * 只在 scopeWorkspaceToUser 开头调用（换账号时清上一账号残留）；登出/401 的 clearUserCache
 * 不调它——同账号重登必须保留自己的游戏选择与看板收藏（对抗审查三轮 F10/F11）。
 */
export function scopeMiscToUser(userId: string | null | undefined): void {
  try {
    const stampUser = userId && userId !== 'anonymous' ? userId : '';
    if (localStorage.getItem(MISC_USER_STAMP) === stampUser) return;
    for (const k of USER_BOUND_MISC_KEYS) localStorage.removeItem(k);
    const staleKeys: string[] = [];
    for (let i = 0; i < localStorage.length; i++) {
      const k = localStorage.key(i);
      if (k && (k.startsWith('explore_history_') || k.startsWith('explore_favorites_'))) staleKeys.push(k);
    }
    for (const k of staleKeys) localStorage.removeItem(k);
    if (stampUser) localStorage.setItem(MISC_USER_STAMP, stampUser);
    else localStorage.removeItem(MISC_USER_STAMP);
  } catch {}
}

/**
 * 把 sessionStorage 里用户绑定的 AI 对话归属到指定用户（每标签页独立执行）：
 * stamp 与当前用户不一致（含遗留无 stamp）时清空全部对话键并盖章；一致则保留。
 * 与 localStorage 的 userKey 无关——多标签页场景下另一标签页已盖章时，本标签页仍需按自己的 stamp 判断。
 */
export function scopeSessionToUser(userId: string | null | undefined): void {
  if (!userId || userId === 'anonymous') return;
  try {
    if (sessionStorage.getItem(SESSION_USER_STAMP) === userId) return;
    for (const k of USER_BOUND_SESSION_KEYS) sessionStorage.removeItem(k);
    // 评审 M6：不再在此清 chatbi.game.mode（localStorage）——它是工作区级偏好、由
    // scopeWorkspaceToUser 的 USER_BOUND_MISC_KEYS 在账号真正切换时清；这里按标签页
    // 清会把「换个标签页/重挂 iframe」误当成切账号，用户每次开新标签页都要重选游戏模式
    sessionStorage.setItem(SESSION_USER_STAMP, userId);
  } catch {}
}

/**
 * 把持久化工作区（sql-ide-storage）归属到指定用户：
 * - 无 userKey 的历史数据：视为属于未知账号，先整体备份到 sql-ide-ws-backup-legacy（可人工恢复）再清空（一次性迁移，隐私优先）；
 * - userKey 与当前用户不一致：清空用户绑定字段（上一账号草稿备份到 sql-ide-ws-backup-<旧key>），并清掉杂项用户键；
 * - 一致：不动（保留本账号未保存的草稿/结果）。
 * 返回 true 表示发生过清空（调用方需同步 resetUserWorkspace 重置内存态）。
 * anonymous/空 id 一律跳过（匿名回落不误清他人工作区）。
 */
export function scopeWorkspaceToUser(userId: string | null | undefined): boolean {
  // 杂项键收口放在最前：与 userKey 是否变化无关——登出→匿名、无工作区状态、userKey 巧合相同
  // 等所有早退路径下，游戏选择/游戏模式/看板探索仍必须按账号隔离（对抗审查二轮）
  scopeMiscToUser(userId);
  if (!userId || userId === 'anonymous') return false;
  try {
    const raw = localStorage.getItem('sql-ide-storage');
    const parsed = raw ? JSON.parse(raw) : null;
    const state = parsed && parsed.state && typeof parsed.state === 'object' ? parsed.state : null;
    if (!state) return false;
    if (state.userKey === userId) return false;
    // 清空前先备份：遗留态备份到 legacy 键；换账号备份到上一账号名下（静默销毁留恢复余地）
    const backup: Record<string, any> = {};
    for (const k of USER_BOUND_WS_KEYS) {
      if (state[k] !== undefined) backup[k] = state[k];
    }
    if (Object.keys(backup).length) {
      const backupKey = state.userKey ? `sql-ide-ws-backup-${state.userKey}` : 'sql-ide-ws-backup-legacy';
      try { localStorage.setItem(backupKey, JSON.stringify(backup)); } catch {}
    }
    for (const k of USER_BOUND_WS_KEYS) delete state[k];
    state.userKey = userId;
    localStorage.setItem('sql-ide-storage', JSON.stringify(parsed));
    return true;
  } catch {
    return false;
  }
}

export function getStoredToken(): string | null {
  return getToken();
}

/** 游戏库选择：读 Layout 游戏切换器写入的 localStorage['chatbi.game']，
 *  作为 X-Game 头随每个 /api/* 请求下发（data_ai 侧 get_game 依赖它绑定游戏库）。 */
function getGameHeader(): Record<string, string> {
  try {
    const g = localStorage.getItem('chatbi.game');
    return g ? { 'X-Game': g } : {};
  } catch {
    return {};
  }
}

async function request<T>(path: string, options?: RequestInit): Promise<T> {
  const token = getToken();
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    ...getGameHeader(),
    ...options?.headers as Record<string, string>,
  };
  if (token) {
    headers['Authorization'] = `Bearer ${token}`;
  }
  // 与 vanilla auth.js 同一套共享令牌网关：配置了 wb_auth_token 时随请求下发 X-Auth-Token
  try {
    const gateway = localStorage.getItem('wb_auth_token');
    if (gateway && !headers['X-Auth-Token']) headers['X-Auth-Token'] = gateway;
  } catch {}

  const res = await fetch(`${API_BASE}${path}`, { ...options, headers });

  if (res.status === 401 && path !== '/api/auth/login') {
    // 登录端点自身的 401（密码错误/无账号）不走「令牌过期」重载——由调用方
    // （LoginForm）展示后端 detail（如「用户名或密码错误」），其余 401 视为会话失效
    clearUserCache();
    window.location.reload();
    throw new Error('未登录');
  }

  if (!res.ok) {
    const err = await res.json().catch(() => ({ detail: res.statusText }));
    throw new Error(err.detail || '请求失败');
  }
  return res.json();
}

export const api = {
  // ── Auth ──
  login(username: string, password: string) {
    return request<{ user: { id: string; username: string }; access_token: string; refresh_token: string; expires_at: string }>(
      '/api/auth/login', { method: 'POST', body: JSON.stringify({ username, password }) }
    );
  },
  createUser(username: string, password: string) {
    // 审计 P1-17：公开注册已下线，建号走管理员专用端点（内部后台，账号由管理员在用户管理里开）
    return request<{ id: string; username: string }>(
      '/api/auth/users', { method: 'POST', body: JSON.stringify({ username, password }) }
    );
  },
  refreshToken(refresh_token: string) {
    return request<{ access_token: string; refresh_token: string; expires_at: string }>(
      '/api/auth/refresh', { method: 'POST', body: JSON.stringify({ refresh_token }) }
    );
  },
  getMe() {
    return request<{ id: string; username: string; role: string; last_login_at?: string; identity?: string[]; identity_name?: string[]; permissions?: string[]; games?: string[]; is_custom?: boolean; llm_access?: 'admin' | 'configured' | 'required' }>('/api/auth/me');
  },
  logout() {
    return request<{ message: string }>('/api/auth/logout', { method: 'POST' }).catch(() => {});
  },
  changePassword(old_password: string, new_password: string) {
    return request<{ message: string }>('/api/auth/change-password', { method: 'PUT', body: JSON.stringify({ old_password, new_password }) });
  },
  getUsers() {
    return request<{ id: string; username: string; role: string; is_active: number; login_attempts: number; last_login_at: string; created_at: string; joydata_email: string; identity: string[]; identity_name: string[]; is_custom: boolean; extra_permissions: string; extra_games: string; extra_access_levels: string }[]>('/api/auth/users');
  },
  getUsersBasic() {
    return request<{ id: string; username: string }[]>('/api/auth/users/basic');
  },
  adminResetPassword(userId: string, new_password: string) {
    return request<{ message: string }>(`/api/auth/users/${userId}/reset-password`, { method: 'PUT', body: JSON.stringify({ new_password }) });
  },
  /** 管理员维护 data_ai 账号 ↔ joydata 邮箱映射（看板「每人各看各的」身份来源）；响应带回邮箱自动归入的身份（审计 P1-17） */
  setUserFCDataEmail(userId: string, joydata_email: string) {
    return request<{ message: string; joydata_email: string; auto_identity: string; auto_identity_name: string }>(`/api/auth/users/${userId}/joydata-email`, { method: 'PUT', body: JSON.stringify({ joydata_email }) });
  },
  deleteUser(userId: string) {
    return request<{ message: string }>(`/api/auth/users/${userId}`, { method: 'DELETE' });
  },

  // ── 权限管理（RBAC）──
  /** 权限点全集清单，后端驱动（审计 P2-3）：前端不再硬编码权限点，personal/workspace 等孤儿点自然消失。 */
  getPermissionPoints() {
    return request<{ points: string[] }>('/api/permissions/points');
  },
  listIdentities() {
    return request<{ key: string; name: string; permission_points: string; games: string; access_levels: string; is_builtin: number }[]>('/api/permissions/identities');
  },
  createIdentity(data: { key: string; name: string; permission_points: string[]; games: string[]; access_levels?: Record<string, string[]> }) {
    return request<any>('/api/permissions/identities', { method: 'POST', body: JSON.stringify(data) });
  },
  updateIdentity(key: string, data: { name: string; permission_points: string[]; games: string[]; access_levels?: Record<string, string[]> }) {
    return request<any>(`/api/permissions/identities/${encodeURIComponent(key)}`, { method: 'PUT', body: JSON.stringify({ key, ...data }) });
  },
  deleteIdentity(key: string) {
    return request<{ message: string }>(`/api/permissions/identities/${encodeURIComponent(key)}`, { method: 'DELETE' });
  },
  listEmailMappings() {
    return request<{ id: number; identity_key: string; identity_name: string; match_type: string; pattern: string }[]>('/api/permissions/email-mappings');
  },
  addEmailMapping(data: { identity_key: string; match_type: string; pattern: string }) {
    return request<any>('/api/permissions/email-mappings', { method: 'POST', body: JSON.stringify(data) });
  },
  deleteEmailMapping(id: number) {
    return request<{ message: string }>(`/api/permissions/email-mappings/${id}`, { method: 'DELETE' });
  },
  listPermissionUsers() {
    return request<{ id: string; username: string; identity: string[]; identity_name: string[]; permissions: string[]; games: string[]; extra_permissions: string[]; extra_games: string[]; extra_access_levels: Record<string, string[]>; is_custom: boolean; joydata_email: string }[]>('/api/permissions/users');
  },
  updateUserPermissions(userId: string, data: { identity: string[]; extra_permissions: string[]; extra_games: string[]; extra_access_levels?: Record<string, string[]> }) {
    return request<any>(`/api/permissions/users/${userId}`, { method: 'PUT', body: JSON.stringify(data) });
  },

  // ── 游戏库（data_ai 侧） ──
  getGames() {
    return request<{ games: { key: string; name: string; region: string; short_name: string; description: string; db: string }[]; default: string }>('/api/games');
  },
  getModels() {
    return request<{ models: string[]; default: string }>('/api/models');
  },
  // 游戏库 schema（绑当前 X-Game，非用户连接）
  getGameSchema() {
    return request<{ databases: string[]; default_db: string; tables: string[] }>('/api/schema');
  },
  getGameTables(db: string) {
    return request<{ db: string; tables: string[] }>(`/api/schema/${encodeURIComponent(db)}/tables`);
  },
  getGameColumns(db: string, table: string) {
    return request<{ db: string; table: string; columns: { name: string; type: string; comment: string }[] }>(
      `/api/schema/${encodeURIComponent(db)}/${encodeURIComponent(table)}`
    );
  },

  // ── SQL 文件（/api/admin/sqls，游戏库取数口径） ──
  listSqls() {
    return request<{ sqls: any[] }>('/api/admin/sqls');
  },
  readSql(name: string) {
    return request<any>(`/api/admin/sqls/${encodeURIComponent(name)}`);
  },
  saveSql(name: string, data: { sql: string; meta?: any; level?: string; sources?: any[] }) {
    // problems：保存前质量预检结果（空列表=通过），不阻断保存，前端按需警告展示（P1-5）
    return request<{ ok: boolean; name: string; problems?: string[] }>(`/api/admin/sqls/${encodeURIComponent(name)}`, {
      method: 'POST', body: JSON.stringify(data),
    });
  },
  deleteSql(name: string) {
    return request<{ ok: boolean }>(`/api/admin/sqls/${encodeURIComponent(name)}`, { method: 'DELETE' });
  },
  /** 服务端重命名 SQL（审计建议 7）：订阅引用 + 派生指标跟随更新；不再由前端删旧文件。 */
  renameSql(oldName: string, newName: string) {
    return request<{ ok: boolean; old: string; new: string; indicators: number; refs: number }>('/api/admin/sqls/rename', {
      method: 'POST', body: JSON.stringify({ old: oldName, new: newName }),
    });
  },
  runSql(sql: string) {
    return request<{ ok: boolean; table?: { columns: string[]; rows: any[][]; total_rows: number }; error?: string }>(
      '/api/admin/sqls/run', { method: 'POST', body: JSON.stringify({ sql }) }
    );
  },
  generateSql(description: string, model?: string, existing?: string) {
    return request<{ sql: string; raw: string; sources: any[] }>('/api/admin/sqls/generate', {
      method: 'POST', body: JSON.stringify({ description, ...(model ? { model } : {}), existing: existing || '' }),
    });
  },
  formatSql(sql: string) {
    return request<{ ok: boolean; sql: string }>('/api/admin/sqls/format', { method: 'POST', body: JSON.stringify({ sql }) });
  },
  toFlexsql(sql: string) {
    return request<{ ok: boolean; flexsql: string }>('/api/admin/sqls/to-flexsql', { method: 'POST', body: JSON.stringify({ sql }) });
  },

  // ── 专项（/api/admin/skills：方法说明 + 关联 SQL/文档/预测 + 内嵌快照）──
  listSkills() {
    return request<{ skills: { name: string; sqls: string[]; docs: string[]; level: string; code?: string; online?: boolean }[] }>('/api/admin/skills');
  },
  /** 上线/下线专项：下线后对聊天/自由对话/Agent 不可见（不可点名/不可选/不可引用），专项管理仍可见可编辑。 */
  setSkillOnline(name: string, online: boolean) {
    return request<{ ok: boolean; name: string; online: boolean }>(`/api/admin/skills/${encodeURIComponent(name)}/online`, { method: 'POST', body: JSON.stringify({ online }) });
  },
  readSkill(name: string) {
    return request<any>(`/api/admin/skills/${encodeURIComponent(name)}`);
  },
  saveSkill(name: string, data: { content?: string; sqls?: string[]; docs?: string[]; level?: string; forecast?: any; frozen?: any; confidentiality?: string | null }) {
    return request<any>(`/api/admin/skills/${encodeURIComponent(name)}`, { method: 'POST', body: JSON.stringify(data) });
  },
  deleteSkill(name: string) {
    return request<{ ok: boolean }>(`/api/admin/skills/${encodeURIComponent(name)}`, { method: 'DELETE' });
  },
  /** 服务端重命名（订阅引用跟随更新；不再由前端删旧文件）。400 名称冲突/不存在（detail 中文），403 无归属权。 */
  renameSkill(oldName: string, newName: string) {
    return request<{ ok: boolean; old: string; new: string; subscriptions_updated: number }>('/api/admin/skills/rename', {
      method: 'POST', body: JSON.stringify({ old: oldName, new: newName }),
    });
  },
  generateSkill(description: string, model?: string, existing?: string, noteSkill?: string) {
    return request<any>('/api/admin/skills/generate', {
      method: 'POST', body: JSON.stringify({ description, ...(model ? { model } : {}), existing: existing || '', ...(noteSkill ? { note_skill: noteSkill } : {}) }),
    });
  },
  associateSkill(name: string, data: { description: string; existing_sqls: string[]; existing_docs: string[] }) {
    return request<any>(`/api/admin/skills/${encodeURIComponent(name)}/associate`, { method: 'POST', body: JSON.stringify(data) });
  },
  planSkill(name: string, data: { content: string; model?: string; level?: string; forecast?: any }) {
    return request<any>(`/api/admin/skills/${encodeURIComponent(name)}/plan`, { method: 'POST', body: JSON.stringify(data) });
  },
  /** 可绑定的预测/算法能力（专项「手动关联」候选，含 input/granularity 等元数据） */
  forecastCapabilities() {
    return request<{ capabilities: any[] }>('/api/admin/skills/forecast-capabilities');
  },
  refreshSkill(name: string) {
    return request<any>(`/api/admin/skills/${encodeURIComponent(name)}/refresh`, { method: 'POST' });
  },
  getSkillNotes(name: string) {
    return request<{ name: string; notes: string }>(`/api/admin/skills/${encodeURIComponent(name)}/notes`);
  },
  setSkillNotes(name: string, content: string) {
    return request<{ ok: boolean; name: string }>(`/api/admin/skills/${encodeURIComponent(name)}/notes`, { method: 'POST', body: JSON.stringify({ content }) });
  },
  // 内嵌快照（kind ∈ sql | model | knowledge）：就地编辑 / AI 改写 / 删除
  editSkillSnapshot(name: string, kind: string, key: string, content: string) {
    return request<{ ok: boolean }>(`/api/admin/skills/${encodeURIComponent(name)}/snapshot/edit`, { method: 'POST', body: JSON.stringify({ kind, key, content }) });
  },
  aiSkillSnapshot(name: string, kind: string, key: string, instruction: string) {
    return request<{ ok: boolean; content: string }>(`/api/admin/skills/${encodeURIComponent(name)}/snapshot/ai`, { method: 'POST', body: JSON.stringify({ kind, key, instruction }) });
  },
  deleteSkillSnapshot(name: string, kind: string, key: string) {
    return request<{ ok: boolean }>(`/api/admin/skills/${encodeURIComponent(name)}/snapshot/delete`, { method: 'POST', body: JSON.stringify({ kind, key }) });
  },

  // ── 算法模型（/api/admin/models：AI 生成模型代码 + 自动关联 SQL + 专属 SQL 快照 + 刷新快照）──
  listModels() {
    return request<any>('/api/admin/models');
  },
  readModel(name: string) {
    return request<any>(`/api/admin/models/${encodeURIComponent(name)}`);
  },
  // 注意：save 的 name 在 body 里（后端 ModelSave），不在 URL
  saveModel(data: any) {
    return request<any>('/api/admin/models/save', { method: 'POST', body: JSON.stringify(data) });
  },
  deleteModel(name: string) {
    return request<{ ok: boolean }>(`/api/admin/models/${encodeURIComponent(name)}`, { method: 'DELETE' });
  },
  /** 服务端重命名模型（审计建议 7）：.py + manifest + 冻结 SQL + 版本库一并迁移。 */
  renameModel(oldName: string, newName: string) {
    return request<{ ok: boolean; old: string; new: string }>('/api/admin/models/rename', {
      method: 'POST', body: JSON.stringify({ old: oldName, new: newName }),
    });
  },
  generateModel(description: string, model?: string, boundSqlNames?: string[], existing?: string) {
    return request<any>('/api/admin/models/generate', {
      method: 'POST',
      body: JSON.stringify({ description, ...(model ? { model } : {}), bound_sql_names: boundSqlNames || [], existing: existing || '' }),
    });
  },
  associateModel(description: string, model?: string) {
    return request<any>('/api/admin/models/associate', { method: 'POST', body: JSON.stringify({ description, ...(model ? { model } : {}) }) });
  },
  planModel(name: string, data: { description: string; code: string; sql: string; model?: string }) {
    return request<any>(`/api/admin/models/${encodeURIComponent(name)}/plan`, { method: 'POST', body: JSON.stringify(data) });
  },
  refreshModel(name: string) {
    return request<any>(`/api/admin/models/${encodeURIComponent(name)}/refresh`, { method: 'POST' });
  },

  // ── 知识库（/api/knowledge + /api/admin/knowledge：文档 CRUD + AI 汇总 + 表结构重建）──
  listDocs() {
    // 管理侧列表：只按 游戏/层级/归属 隔离（不做使用权限+机密过滤），带机密档位供徽标展示
    return request<{ docs: string[]; doc_levels: Record<string, string>; doc_confidentiality: Record<string, string | null> }>('/api/admin/knowledge/docs');
  },
  readDoc(name: string) {
    return request<{ kind: string; name: string; content: string; level?: string; confidentiality?: string | null }>(`/api/admin/knowledge/docs/${encodeURIComponent(name)}`);
  },
  saveDoc(name: string, data: { content: string; level?: string; confidentiality?: string | null }) {
    return request<any>(`/api/admin/knowledge/docs/${encodeURIComponent(name)}`, { method: 'POST', body: JSON.stringify(data) });
  },
  deleteDoc(name: string) {
    return request<{ ok: boolean }>(`/api/admin/knowledge/docs/${encodeURIComponent(name)}`, { method: 'DELETE' });
  },
  /** 服务端重命名文档（审计建议 7）：主文件 + 元数据 + 版本库一并迁移，订阅引用跟随更新。 */
  renameDoc(oldName: string, newName: string) {
    return request<{ ok: boolean; old: string; new: string; refs: number }>('/api/admin/knowledge/rename', {
      method: 'POST', body: JSON.stringify({ kind: 'docs', old: oldName, new: newName }),
    });
  },
  summarizeKnowledge(model: string, sources: { name: string; content: string }[], extra: string, existing: string) {
    return request<{ draft: string; title: string }>('/api/admin/knowledge/summarize', { method: 'POST', body: JSON.stringify({ model, sources, extra, existing }) });
  },
  parseXmind(name: string, dataB64: string) {
    return request<{ name: string; text: string }>('/api/admin/knowledge/parse-xmind', { method: 'POST', body: JSON.stringify({ name, data_b64: dataB64 }) });
  },
  getSchemaStatus() {
    return request<{ exists: boolean; path?: string; generated_at?: string; tables?: number; bytes?: number; error?: string }>('/api/admin/knowledge/schema-status');
  },
  rebuildSchema() {
    return request<any>('/api/admin/knowledge/rebuild-schema', { method: 'POST' });
  },

  // ── 版本历史（/api/admin/versions：四类工件时间倒序快照 + 回滚，回滚前自动备份当前）──
  listVersions(kind: string, name: string) {
    return request<{ versions: { file: string; size: number; mtime: number; mtime_str: string }[] }>(
      `/api/admin/versions?kind=${encodeURIComponent(kind)}&name=${encodeURIComponent(name)}`
    );
  },
  restoreVersion(data: { kind: string; name: string; version_file: string }) {
    return request<{ ok: boolean }>('/api/admin/versions/restore', { method: 'POST', body: JSON.stringify(data) });
  },
  diffVersion(kind: string, name: string, versionFile: string) {
    // P1-16：版本对比（只读，「版本 vs 当前」统一 diff）
    return request<{ diff: string; truncated: boolean }>(
      `/api/admin/versions/diff?kind=${encodeURIComponent(kind)}&name=${encodeURIComponent(name)}&version_file=${encodeURIComponent(versionFile)}`
    );
  },
  // ── 回收站（审计建议 8：删除侧版本化，源文件删除后 30 天可从 _versions 恢复）──
  listVersionsDeleted() {
    return request<{ items: { rel: string; versions: number; latest_mtime: number; latest_str: string }[] }>('/api/admin/versions/deleted');
  },
  restoreDeleted(rel: string, versionFile?: string) {
    return request<{ ok: boolean }>('/api/admin/versions/deleted/restore', {
      method: 'POST', body: JSON.stringify({ rel, ...(versionFile ? { version_file: versionFile } : {}) }),
    });
  },
  purgeDeleted(rel: string) {
    return request<{ ok: boolean }>('/api/admin/versions/deleted', { method: 'DELETE', body: JSON.stringify({ rel }) });
  },

  // ── 订阅报告（/api/reports/subscriptions，data_ai 侧：个人订阅列表 + 取消订阅） ──
  listSubscriptions() {
    return request<{ subscriptions: any[] }>('/api/reports/subscriptions');
  },
  deleteSubscription(id: string) {
    return request<{ ok: boolean }>(`/api/reports/subscriptions/${encodeURIComponent(id)}`, { method: 'DELETE' });
  },

  // ── SQL 执行历史（按 AI 会话存，供 SQL 编辑器「历史记录」侧栏） ──
  listSqlHistory(sessionId?: string) {
    const q = sessionId ? `?session_id=${encodeURIComponent(sessionId)}` : '';
    return request<{ items: { id: number; session_id: string; game: string; sql: string; status: string; row_count: number; duration_ms: number; created_at: string }[] }>(`/api/sql-history${q}`);
  },
  addSqlHistory(record: { session_id?: string; sql: string; status?: string; row_count?: number; duration_ms?: number }) {
    return request<{ id: number }>('/api/sql-history', { method: 'POST', body: JSON.stringify(record) });
  },
  clearSqlHistory(sessionId?: string) {
    const q = sessionId ? `?session_id=${encodeURIComponent(sessionId)}` : '';
    return request<{ ok: boolean }>(`/api/sql-history${q}`, { method: 'DELETE' });
  },

  // ── 深度分析 Agent（单一 agentic 循环） ──
  getAgentConfig() {
    return request<{ api_key: string; model: string; api_base: string }>('/api/agent/config');
  },
  saveAgentConfig(cfg: { api_key: string; model: string; api_base: string }) {
    return request('/api/agent/config', { method: 'PUT', body: JSON.stringify(cfg) });
  },
  testLLMConnection(params: { api_key: string; model: string; api_base: string }) {
    return request<{ success: boolean; message: string }>('/api/agent/test-llm', { method: 'POST', body: JSON.stringify(params) });
  },
  /** 深度分析 SSE 流 — 返回 AsyncGenerator，每次 yield 一个事件（agent_start/plan_text/tool_start/tool_done/answer/question/final/error）。 */
  async *deepAgentChatStream(
    message: string,
    history: ChatMessage[],
    model?: string,
    signal?: AbortSignal,
  ): AsyncGenerator<any> {
    const token = getToken();
    const resp = await fetch('/api/agent/chat/stream', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...getGameHeader(),
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify({ message, history, ...(model ? { model } : {}) }),
      signal,
    });
    if (!resp.ok) {
      const err = await resp.json().catch(() => ({ detail: resp.statusText }));
      throw new Error(err.detail || '请求失败');
    }
    const reader = resp.body!.getReader();
    const decoder = new TextDecoder();
    let buf = '';
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      const lines = buf.split('\n');
      buf = lines.pop() ?? '';
      for (const line of lines) {
        if (line.startsWith('data: ')) {
          try {
            yield JSON.parse(line.slice(6));
          } catch {}
        }
      }
    }
  },

  /** 聊天窗口 /api/chat SSE 流（与 vanilla app.js streamChat 同一协议：stage/answer/sql/data/charts/usage/done…）。
   *  用于专项管理「执行」在本窗口直跑 preset 流程；认证头与 request() 一致（Bearer + X-Game + X-Auth-Token）。 */
  async *chatStream(body: Record<string, unknown>, signal?: AbortSignal): AsyncGenerator<any> {
    const token = getToken();
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      ...getGameHeader(),
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    };
    try {
      const gateway = localStorage.getItem('wb_auth_token');
      if (gateway && !headers['X-Auth-Token']) headers['X-Auth-Token'] = gateway;
    } catch {}
    const resp = await fetch(`${API_BASE}/api/chat`, {
      method: 'POST', headers, body: JSON.stringify(body), signal,
    });
    if (!resp.ok) {
      const err = await resp.json().catch(() => ({ detail: resp.statusText }));
      throw new Error(err.detail || '请求失败');
    }
    const reader = resp.body!.getReader();
    const decoder = new TextDecoder();
    let buf = '';
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      const lines = buf.split('\n');
      buf = lines.pop() ?? '';
      for (const line of lines) {
        if (line.startsWith('data: ')) {
          try {
            yield JSON.parse(line.slice(6));
          } catch {}
        }
      }
    }
  },

  // ── 报告缺口与补数建议（2026-10-26 从聊天窗口 to-C 移除，仅保留在专项管理 to-B 侧；
  //     2026-10-29 起改为执行完成后手动触发，卡片渲染在「AI源生」对话里。订阅报告页 /reports/{id}/gaps
  //     已同批摘除。模型走任务槽位 gap（模型管理可调），空串=任务默认。X-Game 随 request() 统一下发。
  //     signal：面板「中断」时中止本次分析（客户端 abort，后端尽力止损）。 ──
  chatGaps(skill: string | null, reportMd: string, signal?: AbortSignal) {
    return request<{ skill: string | null; gaps: any[]; whitelist: any[] }>(
      '/api/chat/gaps',
      { method: 'POST', body: JSON.stringify({ model: '', skill, report_md: reportMd }), signal },
    );
  },
  gapWhitelistAdd(skill: string | null, gap: Record<string, unknown>) {
    return request<{ ok?: boolean; message?: string }>(
      '/api/chat/gap-whitelist',
      { method: 'POST', body: JSON.stringify({ skill, gap }) },
    );
  },
  gapWhitelistList(skill: string | null) {
    const q = skill ? `?skill=${encodeURIComponent(skill)}` : '';
    return request<{ skill: string | null; whitelist: any[] }>(`/api/chat/gap-whitelist${q}`);
  },
  gapWhitelistRemove(sig: string, skill: string | null) {
    const q = skill ? `?skill=${encodeURIComponent(skill)}` : '';
    return request<{ ok?: boolean; message?: string }>(
      `/api/chat/gap-whitelist/${encodeURIComponent(sig)}${q}`,
      { method: 'DELETE' },
    );
  },
  gapFix(skill: string | null, gap: Record<string, unknown>, game?: string | null) {
    return request<any>(
      '/api/chat/gap-fix',
      { method: 'POST', body: JSON.stringify({ model: '', skill, gap }), ...(game ? { headers: { 'X-Game': game } } : {}) },
    );
  },
  gapFixApply(skill: string | null, draft: Record<string, unknown>, game?: string | null) {
    return request<{ ok?: boolean; message?: string }>(
      '/api/chat/gap-fix/apply',
      { method: 'POST', body: JSON.stringify({ model: '', skill, draft }), ...(game ? { headers: { 'X-Game': game } } : {}) },
    );
  },
  gapAnswer(skill: string | null, gap: Record<string, unknown>, answer: string, game?: string | null) {
    return request<any>(
      '/api/chat/gap-answer',
      { method: 'POST', body: JSON.stringify({ model: '', skill, gap, answer }), ...(game ? { headers: { 'X-Game': game } } : {}) },
    );
  },
  gapAnswerApply(skill: string | null, draft: Record<string, unknown>, gap: Record<string, unknown>, game?: string | null) {
    return request<{ ok?: boolean; message?: string }>(
      '/api/chat/gap-answer/apply',
      { method: 'POST', body: JSON.stringify({ model: '', skill, draft, gap }), ...(game ? { headers: { 'X-Game': game } } : {}) },
    );
  },

  // ── Users (for share) ──
  listUsersBasic() {
    return request<{ id: string; username: string }[]>('/api/auth/users/basic');
  },

  // ── Share ──
  shareIndicators(ids: number[], targetUserIds: string[], mode: 'collaborative'|'copy', permission: 'read'|'write') {
    return request<{ shared: number }>('/api/indicators/share', {
      method: 'POST',
      body: JSON.stringify({ ids, target_user_ids: targetUserIds, mode, permission }),
    });
  },
  shareMemories(ids: number[], targetUserIds: string[]) {
    return request<{ shared: number }>('/api/memory/share', {
      method: 'POST',
      body: JSON.stringify({ ids, target_user_ids: targetUserIds }),
    });
  },

  // ── Memory management ──
  listMemories(scope?: string, category?: string) {
    const params = new URLSearchParams();
    if (scope) params.set('scope', scope);
    if (category) params.set('category', category);
    const qs = params.toString();
    return request<{ items: any[] }>(`/api/memory${qs ? '?' + qs : ''}`);
  },
  createMemory(content: string, category: string, scope: string, mem_type = '日常', bind_name = '') {
    return request<{ id: number; message: string }>('/api/memory', {
      method: 'POST', body: JSON.stringify({ content, category, scope, mem_type, bind_name }),
    });
  },
  updateMemory(id: number, data: { content?: string; category?: string; scope?: string; mem_type?: string; bind_name?: string }) {
    return request<{ message: string }>(`/api/memory/${id}`, {
      method: 'PUT', body: JSON.stringify(data),
    });
  },
  deleteMemory(id: number) {
    return request<{ message: string }>(`/api/memory/${id}`, { method: 'DELETE' });
  },

  // Memory import/export
  exportMemories(ids?: number[]) {
    const q = ids?.length ? `?ids=${ids.join(',')}` : '';
    return request<any>(`/api/memory/export${q}`);
  },
  importMemories(items: any[]) {
    return request<{ created: number; errors: any[]; total: number }>('/api/memory/import', {
      method: 'POST',
      body: JSON.stringify({ items }),
    });
  },
  // ── 术语表 / 口径（glossary.md / metrics.json，data_ai 侧 /api/admin/config/*，
  //    记忆重组 2026-10-23：随「AI配置 → 术语与口径」页使用；原 importGlossary 迁移函数已移除）──
  getGlossaryConfig() {
    return request<{ content: string; candidates: { term: string; column: string; source: string }[] }>('/api/admin/config/glossary');
  },
  saveGlossaryConfig(content: string) {
    return request<{ ok: boolean }>('/api/admin/config/glossary', { method: 'POST', body: JSON.stringify({ content }) });
  },
  confirmGlossaryEntries(entries: { term: string; column: string }[]) {
    return request<{ ok: boolean; added: number; removed: number }>('/api/admin/config/glossary/confirm', { method: 'POST', body: JSON.stringify({ entries }) });
  },
  getMetricsConfig() {
    return request<{ content: string; error: string | null }>('/api/admin/config/metrics');
  },
  saveMetricsConfig(content: string) {
    return request<{ ok: boolean }>('/api/admin/config/metrics', { method: 'POST', body: JSON.stringify({ content }) });
  },

  // ── 模型管理（系统管理 → 模型管理：全站 LLM 模型槽位，仅系统管理员可读写）──
  getModelManagement() {
    return request<{
      slots: { key: string; label: string; desc: string; model: string; source: string; override: string | null; auto_model: string }[];
      models: string[];
      default: string;
    }>('/api/admin/config/models');
  },
  putModelManagement(overrides: Record<string, string>) {
    // overrides 值：模型名 = 覆盖；空串 = 清除覆盖（回落环境变量/任务默认/系统默认）
    return request<{ slots: any[]; stored: Record<string, string> }>('/api/admin/config/models', {
      method: 'PUT',
      body: JSON.stringify({ overrides }),
    });
  },

  // ── Health ──
  checkHealth() {
    return request<{ status: string }>('/api/health');
  },

  // ── Indicators ──
  getIndicators(params?: { search?: string; domain?: string; status?: string; page?: number; size?: number }) {
    const q = new URLSearchParams();
    if (params?.search) q.set('search', params.search);
    if (params?.domain) q.set('domain', params.domain);
    if (params?.status) q.set('status', params.status);
    if (params?.page) q.set('page', String(params.page));
    if (params?.size) q.set('size', String(params.size));
    const qs = q.toString();
    return request<{ items: any[]; total: number; page: number; size: number }>(`/api/indicators${qs ? '?' + qs : ''}`);
  },
  getIndicator(id: number) { return request<any>(`/api/indicators/${id}`); },
  createIndicator(data: any) { return request<any>('/api/indicators', { method: 'POST', body: JSON.stringify(data) }); },
  updateIndicator(id: number, data: any) { return request<any>(`/api/indicators/${id}`, { method: 'PUT', body: JSON.stringify(data) }); },
  deleteIndicator(id: number) { return request<any>(`/api/indicators/${id}`, { method: 'DELETE' }); },
  getIndicatorDomains() { return request<{ domains: string[] }>('/api/indicators/domains').then((r) => (r && r.domains) || []); },
  migrateIndicators() { return request<any>('/api/indicators/migrate', { method: 'POST' }); },

  // Indicator folders
  getIndicatorFolders() { return request<any[]>('/api/indicators/folders'); },
  createIndicatorFolder(name: string, parentId?: number) { return request<any>('/api/indicators/folders', { method: 'POST', body: JSON.stringify({ name, parent_id: parentId }) }); },
  renameIndicatorFolder(folderId: number, name: string) { return request<any>(`/api/indicators/folders/${folderId}`, { method: 'PUT', body: JSON.stringify({ name }) }); },
  deleteIndicatorFolder(folderId: number) { return request<any>(`/api/indicators/folders/${folderId}`, { method: 'DELETE' }); },

  // Parse SQL (AI analysis)
  parseSqlIndicator(sql: string, metricName?: string) {
    return request<any>('/api/indicators/parse-sql', { method: 'POST', body: JSON.stringify({ sql, metric_name: metricName || '' }) });
  },

  // 指标自动生成（data_ai 侧 /api/*，draft 待人工确认）
  scanSqlIndicators() { return request<any>('/api/indicators/scan-sql', { method: 'POST' }); },
  confirmIndicator(id: number) { return request<any>(`/api/indicators/${id}/confirm`, { method: 'POST' }); },
  importMetricsJson() { return request<any>('/api/indicators/import-metrics-json', { method: 'POST' }); },
  generateFromSql(sqlName: string) { return request<any>('/api/indicators/generate-from-sql', { method: 'POST', body: JSON.stringify({ sql_name: sqlName }) }); },

  // Indicator import/export
  exportIndicators(ids?: number[]) {
    const q = ids?.length ? `?ids=${ids.join(',')}` : '';
    return request<any>(`/api/indicators/export${q}`);
  },
  importIndicators(items: any[]) {
    return request<{ created: number; errors: any[]; total: number }>('/api/indicators/import', {
      method: 'POST',
      body: JSON.stringify({ items }),
    });
  },

  // ── 报表指标标签 ──
  getQuotaTags() {
    return request<{ items: QuotaTag[] }>('/api/quota-tags');
  },

  // ── MCP ──
  getMCPTools() {
    return request<{ name: string; description: string }[]>('/api/mcp/tools');
  },

  // ── 统一 FiveCross 工具目录（深度分析工具 + MCP 工具合并，可编辑描述/启停）──
  getToolCatalog() {
    return request<{ key: string; name: string; description: string; source: string; enabled: boolean; edited: boolean }[]>(
      '/api/mcp/catalog'
    );
  },
  saveToolMeta(key: string, description: string | null, enabled: boolean) {
    return request<{ message: string; key: string }>('/api/mcp/catalog', {
      method: 'PUT',
      body: JSON.stringify({ key, description, enabled }),
    });
  },

  // ── BI 平台配置 ──
  getBIConfig() {
    return request<{ base_url: string; project_id: string; project_name: string; token_set: boolean; token_valid: boolean; token_expires_at: string | null }>('/api/bi-config');
  },
  saveBIConfig(data: { base_url?: string; project_id?: string; project_name?: string; token?: string }) {
    return request<{ ok: boolean }>('/api/bi-config', { method: 'POST', body: JSON.stringify(data) });
  },
  clearBIToken() {
    return request<{ ok: boolean }>('/api/bi-config/token', { method: 'DELETE' });
  },

  // ── BI 项目 + 数据库↔项目映射 ──
  getBiProjects() {
    return request<{ list: { id: string; name: string }[]; count: number }>('/api/bi-config/projects');
  },
  getBiMappings() {
    return request<{ list: { database_name: string; project_id: string; updated_at?: string }[] }>('/api/bi-config/mappings');
  },
  setBiProjectMapping(database_name: string, project_id: string) {
    return request<{ ok: boolean }>('/api/bi-config/mappings', {
      method: 'POST',
      body: JSON.stringify({ database_name, project_id }),
    });
  },
  deleteBiProjectMapping(database_name: string) {
    return request<{ ok: boolean }>(`/api/bi-config/mappings/${encodeURIComponent(database_name)}`, { method: 'DELETE' });
  },

  // ── BI 扫码登录（Playwright） ──
  startQrLogin(base_url: string) {
    return request<{ login_id: string }>('/api/bi-config/qr-login/start', {
      method: 'POST',
      body: JSON.stringify({ base_url }),
    });
  },
  getQrLoginStatus(login_id: string) {
    return request<{ state: string; message: string; page_url?: string; frame_urls?: string[]; btn_hint?: string }>(`/api/bi-config/qr-login/${login_id}/status`);
  },
  /** 拉取二维码 PNG，返回 object URL（失败返回 null）。 */
  async getQrLoginQr(login_id: string): Promise<string | null> {
    const token = getToken();
    const res = await fetch(`${API_BASE}/api/bi-config/qr-login/${login_id}/qr`, {
      headers: { ...getGameHeader(), ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    });
    if (!res.ok) return null;
    const blob = await res.blob();
    return URL.createObjectURL(blob);
  },

  // ── 远程 MCP 服务器（通用配置层，Sensor Tower 只是第一行）──
  listRemoteMcpServers() {
    return request<any[]>('/api/remote-mcp');
  },
  saveRemoteMcpServer(data: any) {
    return request<any>('/api/remote-mcp', { method: 'POST', body: JSON.stringify(data) });
  },
  deleteRemoteMcpServer(id: number) {
    return request<{ ok: boolean }>(`/api/remote-mcp/${id}`, { method: 'DELETE' });
  },
  setRemoteMcpEnabled(id: number, enabled: boolean) {
    return request<{ ok: boolean }>(`/api/remote-mcp/${id}/enable`, {
      method: 'POST', body: JSON.stringify({ enabled }),
    });
  },
  saveRemoteMcpCredentials(id: number, access_token: string) {
    return request<any>(`/api/remote-mcp/${id}/credentials`, {
      method: 'POST', body: JSON.stringify({ access_token }),
    });
  },
  clearRemoteMcpCredentials(id: number) {
    return request<{ ok: boolean }>(`/api/remote-mcp/${id}/credentials`, { method: 'DELETE' });
  },
  testRemoteMcpServer(id: number) {
    return request<{ ok: boolean; tools_count?: number; tools?: any[]; error?: string }>(
      `/api/remote-mcp/${id}/test`, { method: 'POST' });
  },
  startRemoteMcpOAuth(id: number) {
    return request<{
      authorize_url: string; state: string; callback_port: number;
      redirect_uri: string; listener_warning?: string; loopback_reachable: boolean;
    }>(`/api/remote-mcp/${id}/oauth/start`, { method: 'POST', body: JSON.stringify({}) });
  },
  completeRemoteMcpOAuth(callback_url: string) {
    return request<{ ok: boolean; server_id: number; tools_count?: number; error?: string }>(
      '/api/remote-mcp/oauth/complete',
      { method: 'POST', body: JSON.stringify({ callback_url }) });
  },
  remoteMcpOAuthStatus(state: string) {
    return request<{ status: string; ok?: boolean; tools_count?: number; error?: string }>(
      `/api/remote-mcp/oauth/status?state=${encodeURIComponent(state)}`);
  },
  /** 分享给成员。只支持共同创作（复制会分裂凭据）—— 与 shareIndicators 同签名，mode 恒为 collaborative。 */
  shareRemoteMcpServers(ids: number[], targetUserIds: string[], permission: 'read' | 'write') {
    return request<{ shared: number }>('/api/remote-mcp/share', {
      method: 'POST',
      body: JSON.stringify({ ids, target_user_ids: targetUserIds, permission }),
    });
  },
  unshareRemoteMcpServer(id: number, userId: string) {
    return request<{ ok: boolean }>(`/api/remote-mcp/${id}/share/${userId}`, { method: 'DELETE' });
  },
  listRemoteMcpShares(id: number) {
    return request<{ user_ids: string[] }>(`/api/remote-mcp/${id}/shares`);
  },
  // ── FCData MCP 连接（per-user OAuth；「用户应用-FCData看板」原站模式 + 对话/SQL 取数授权）──
  joydataStatus() {
    return request<{ connected: boolean; expires_at: number; connected_at?: string; updated_at?: string; mcp_url: string; web_url: string }>('/api/joydata/status');
  },
  joydataWebUrl() {
    return request<{ url: string }>('/api/joydata/web-url');
  },
  joydataOauthStart() {
    return request<{ authorize_url: string; state: string }>('/api/joydata/oauth/start', { method: 'POST', body: JSON.stringify({}) });
  },
  joydataOauthStatus(state: string) {
    // 后端 pending_status 扁平返回：{status: 'pending'|'ok'|'error'|'expired'|'forbidden', ok, tools_count, error}
    return request<{ status: string; ok?: boolean; tools_count?: number; error?: string }>(
      `/api/joydata/oauth/status?state=${encodeURIComponent(state)}`);
  },
  joydataDisconnect() {
    return request<{ ok: boolean }>('/api/joydata/disconnect', { method: 'POST' });
  },
  joydataProjects() {
    return request<{ connected: boolean; projects: { id: string; name: string; code: string }[] }>('/api/joydata/projects');
  },
};
