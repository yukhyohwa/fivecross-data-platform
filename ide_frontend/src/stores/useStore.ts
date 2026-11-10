import { create } from 'zustand';
import { persist } from 'zustand/middleware';
import { api } from '../services/api';
import type { QueryResultData } from '../types';

export interface EditorTab {
  id: string;
  label: string;
  sql: string;
}

export interface ResultTab {
  id: string;
  label: string;
  sql: string;
  results: QueryResultData[] | null;
  error: string | null;
}

export interface SkillDraft {
  name: string;
  level: string;
  content: string;
  sqls: string[];
  docs: string[];
  forecast: any;
}

const EMPTY_SKILL: SkillDraft = { name: '', level: '通用', content: '', sqls: [], docs: [], forecast: null };

export interface KbDraft {
  name: string;
  level: string;
  content: string;
}

const EMPTY_KB: KbDraft = { name: '', level: '通用', content: '' };

export interface ModelDraft {
  name: string;
  desc: string;
  input: 'sql' | 'upload';
  granularity: string;
  sql: string;
  hist_days: number | null;
  hist_months: number | null;
  horizon_days: number | null;
  horizon_months: number | null;
  window: number | null;
  code: string;
  sources: any[];
  transformed_sqls: Record<string, string | null>;
  problems: string[];
  builtin: boolean; // 内置能力只读（forecast.py 内置，不可覆盖/删除）
}

const EMPTY_MODEL: ModelDraft = {
  name: '', desc: '', input: 'sql', granularity: 'day', sql: '',
  hist_days: null, hist_months: null, horizon_days: null, horizon_months: null, window: null,
  code: '', sources: [], transformed_sqls: {}, problems: [], builtin: false,
};

export interface SkillWindow {
  id: string;
  label: string;
  draft: SkillDraft;
  info: any; // 关联情况缓存（readSkill 结果），随窗口切换恢复
  savedName: string | null; // 已保存名称（未保存草稿为 null）
}

export interface KbWindow {
  id: string;
  label: string;
  draft: KbDraft;
  savedName: string | null;
}

/** 专项执行（本窗口运行）状态：/api/chat preset SSE 流式累积；seq 防旧流污染新流 */
export interface SkillRunState {
  skill: string;
  seq: number;
  running: boolean;
  status: string;           // 当前状态行（stage/progress 最新值）
  steps: string[];          // 运行过程（stage 累计；progress 心跳只更新状态行不追加）
  meta: { source: string; skill?: string } | null;
  sqls: { name: string | null; sql: string; explain: string | null }[];
  tables: { name: string | null; table: { columns: string[]; rows: Record<string, unknown>[] }; sql: string | null }[];
  charts: any[];
  answer: string;           // markdown 报告
  error: string;
  usage: any;
  elapsed: number | null;
  /** 本轮执行自动生成的缺口建议卡片 seq（null=无/未触发）；执行结果面板据此提示「查看 AI源生」 */
  gapSeq: number | null;
}

/** 报告缺口与补数建议卡片（2026-10-29 起改为手动触发）：reportMd 留给失败重试；game = 专项绑定游戏
 *  （缺口修复/调整按其执行，不走右上角选中游戏——通用级专项跨游戏执行时口径才一致）；seq 单调递增防旧卡重复消费 */
export interface SkillGapCardState {
  skill: string;
  reportMd: string;
  gaps: any[];
  whitelist: any[];
  seq: number;
  game?: string | null;
  error?: string;
}

/** 缺口建议生成状态（手动触发，瞬态不持久化）：running=分析中，error=失败信息（成功走 skillGapCard + gapSeq） */
export interface SkillGapStatusState {
  running: boolean;
  error: string | null;
}

interface AppState {
  // Navigation (persisted across refresh)
  mainNav: string;
  aiSubNav: string;
  analysisSubNav: string;
  // 跨组跳转意图：指标详情「在 SQL 数据中打开」→ 切到 analysis/sql 并打开指定文件（瞬态，不持久化）
  openSqlFile: string | null;
  // 专项执行（本窗口运行，不再跳聊天窗口）：执行状态 + SSE 流式累积结果，瞬态不持久化
  skillRun: SkillRunState | null;

  // 当前用户生效权限点（/me 下发，含 analysis_edit/analysis_delete 细粒度动作点）；
  // null = 未加载完成 / 匿名回落（视为全量，不拦编辑）。瞬态，不持久化。
  myPermissions: string[] | null;

  // 个人定制上下文：非 null（='个人'）时 SQL/专项/知识库 列表只显示该层级、新建与保存强制该层级（瞬态，不持久化）
  scopeLevel: string | null;

  // 持久化工作区归属用户 id；账号切换（登录/登出）时据此清空用户绑定态（resetUserWorkspace）
  userKey: string | null;

  // Editor (tabs)
  editorTabs: EditorTab[];
  activeEditorTabId: string | null;
  nextEditorTabNumber: number;
  sql: string;
  selectedSql: string | null;
  maxRows: number;

  // Agent
  agentMode: 'auto' | 'confirm';
  agentEditorTabId: string | null;
  agentResultTabCounter: number;

  // Results (tabs)
  resultTabs: ResultTab[];
  activeResultTabId: string | null;
  nextTabNumber: number;
  isExecuting: boolean;

  // Convenience references (synced from active tab)
  results: QueryResultData[] | null;
  error: string | null;

  // SQL 执行历史：当前 AI 会话 id（AI源生 新建对话时更新，历史记录侧栏按它拉取）
  sqlSessionId: string;

  // SQL 文件选中状态 + 列表刷新信号（保存/格式化按钮在编辑器竖条，跨侧栏/工作台共享）
  selectedSqlFile: { name: string; level: string } | null;
  sqlFilesVersion: number;

  // 专项（Skill）编辑态 + 列表刷新信号（跨 列表侧栏 / 工作台 / AI 侧栏 共享，瞬态不持久化）
  skillDraft: SkillDraft | null;
  selectedSkill: { name: string; level: string } | null;
  skillFilesVersion: number;

  // 知识库文档（Kb）编辑态 + 列表刷新信号（瞬态不持久化）
  kbDraft: KbDraft | null;
  selectedKb: { name: string; level: string } | null;
  kbFilesVersion: number;

  // 算法模型（Model）编辑态 + 列表刷新信号（单草稿，瞬态不持久化）
  modelDraft: ModelDraft | null;
  selectedModel: string | null;
  modelFilesVersion: number;

  // 专项 / 知识库多窗口（瞬态不持久化）：多窗口并存切换，切换时草稿+关联情况随活动窗口恢复
  skillWindows: SkillWindow[];
  activeSkillWindowId: string | null;
  kbWindows: KbWindow[];
  activeKbWindowId: string | null;

  // Schema sidebar
  showSchema: boolean;

  // Sidebar layout
  sidebarColumns: string[][] | null;
  sidebarColWidths: Record<string, number> | null;
  sidebarFlex: Record<string, number>;
  splitPos: number;        // SQL 工作台上下分屏（独立）
  skillSplitPos: number;   // 专项工作台上下分屏（与 SQL/算法互不影响）
  modelSplitPos: number;   // 算法工作台上下分屏（与 SQL/专项互不影响）

  // 侧栏向左合并（专项/知识库/算法 双栏；SQL 管理用 sidebarColumns/sidebarFlex 自身机制）：
  // merged=列表栏与 AI源生栏合并为一列上下堆叠；stackFlex=合并列中列表占比（0.15-0.85）
  skillSidebarMerged: boolean;
  skillStackFlex: number;
  kbSidebarMerged: boolean;
  kbStackFlex: number;
  modelSidebarMerged: boolean;
  modelStackFlex: number;

  // Schema cache (persisted to localStorage) — 游戏库 schema，非用户连接
  schemaDbs: string[];
  schemaTables: Record<string, any[]>;
  schemaCols: Record<string, any[]>;
  schemaExpandedDbs: string[];
  schemaExpandedTbls: string[];
  schemaCurrentDb: string;

  // Navigation actions
  setMainNav: (nav: string) => void;
  setAiSubNav: (nav: string) => void;
  setAnalysisSubNav: (nav: string) => void;
  requestOpenSqlFile: (file: string) => void;
  clearOpenSqlFile: () => void;
  /** 专项执行（本窗口）：begin 重置状态并返回新 seq（旧流按 seq 作废）；update 累积流式事件；clear 清空面板 */
  beginSkillRun: (skill: string) => number;
  updateSkillRun: (patch: Partial<SkillRunState>) => void;
  clearSkillRun: () => void;
  /** 报告缺口与补数建议卡片（2026-10-29 起手动触发）：执行完成后点「提炼修改建议」生成，
   *  「AI源生」面板按 seq 消费渲染进对话；瞬态不持久化（执行结果本身也不持久化） */
  skillGapCard: SkillGapCardState | null;
  setSkillGapCard: (card: SkillGapCardState | null) => void;
  /** 缺口建议生成状态（手动触发）：running=分析中（进度条+中断），error=失败信息；瞬态不持久化 */
  skillGapStatus: SkillGapStatusState;
  setSkillGapStatus: (s: SkillGapStatusState) => void;
  setMyPermissions: (p: string[] | null) => void;
  setScopeLevel: (level: string | null) => void;
  setUserKey: (key: string | null) => void;
  /** 账号切换：清空用户绑定态（编辑器页签/选中 SQL/结果页签/会话），保留布局偏好 */
  resetUserWorkspace: () => void;

  // Actions
  addEditorTab: () => void;
  switchEditorTab: (id: string) => void;
  closeEditorTab: (id: string) => void;
  setEditorTabSql: (id: string, sql: string) => void;
  setSql: (sql: string) => void;
  setActiveEditorTabLabel: (label: string) => void;
  setSelectedSql: (sql: string | null) => void;
  setMaxRows: (n: number) => void;
  // Agent actions
  toggleAgentMode: () => void;
  getOrCreateAgentEditorTab: () => string;
  createAgentResultTab: (summary: string) => string;
  setResultTabData: (id: string, sql: string, results: QueryResultData[]) => void;
  setShowSchema: (show: boolean) => void;
  setSidebarColumns: (cols: string[][] | null) => void;
  setSidebarColWidths: (w: Record<string, number> | null) => void;
  setSidebarFlex: (f: Record<string, number>) => void;
  setSplitPos: (pos: number) => void;
  setSkillSplitPos: (pos: number) => void;
  setModelSplitPos: (pos: number) => void;
  setSkillSidebarMerged: (v: boolean) => void;
  setSkillStackFlex: (f: number) => void;
  setKbSidebarMerged: (v: boolean) => void;
  setKbStackFlex: (f: number) => void;
  setModelSidebarMerged: (v: boolean) => void;
  setModelStackFlex: (f: number) => void;
  setSchemaDbs: (dbs: string[]) => void;
  setSchemaTables: (tables: Record<string, any[]>) => void;
  setSchemaCols: (cols: Record<string, any[]>) => void;
  setSchemaExpandedDbs: (dbs: string[]) => void;
  setSchemaExpandedTbls: (tbls: string[]) => void;
  setSchemaCurrentDb: (db: string) => void;
  clearSchemaCache: () => void;
  setSqlSessionId: (id: string) => void;
  setSelectedSqlFile: (f: { name: string; level: string } | null) => void;
  bumpSqlFiles: () => void;
  setSkillDraft: (patch: Partial<SkillDraft> | null) => void;
  setSelectedSkill: (f: { name: string; level: string } | null) => void;
  bumpSkillFiles: () => void;
  setKbDraft: (patch: Partial<KbDraft> | null) => void;
  setSelectedKb: (f: { name: string; level: string } | null) => void;
  bumpKbFiles: () => void;
  setModelDraft: (patch: Partial<ModelDraft> | null) => void;
  setSelectedModel: (name: string | null) => void;
  bumpModelFiles: () => void;
  openSkillWindow: (name: string, draft: SkillDraft, info?: any) => void;
  newSkillWindow: (draft: SkillDraft) => void;
  activateSkillWindow: (id: string) => void;
  closeSkillWindow: (id: string) => void;
  syncSkillWindowInfo: (info: any, windowId?: string | null) => void;
  openKbWindow: (name: string, draft: KbDraft) => void;
  newKbWindow: (draft: KbDraft) => void;
  activateKbWindow: (id: string) => void;
  closeKbWindow: (id: string) => void;
  executeSql: (newTab?: boolean) => Promise<void>;
  switchResultTab: (id: string) => void;
  closeResultTab: (id: string) => void;
  clearAgentResultTabs: () => void;
}

const MAX_AGENT_RESULT_TABS = 10;

const isAgentTab = (t: ResultTab) => t.label.startsWith('🤖');

const makeTab = (label: string): ResultTab => ({
  id: `tab-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`,
  label,
  sql: '',
  results: null,
  error: null,
});

const defaultTab = makeTab('结果 1');

function syncFromTab(tab: ResultTab | null) {
  if (!tab) return { results: null, error: null };
  return { results: tab.results, error: tab.error };
}

export const useStore = create<AppState>()(
  persist(
    (set, get) => ({
      // Navigation (persisted)
      mainNav: 'apps',
      aiSubNav: 'indicators',
      analysisSubNav: 'skill',
      openSqlFile: null,
      skillRun: null,
      skillGapCard: null,
      skillGapStatus: { running: false, error: null },
      myPermissions: null,
      scopeLevel: null,
      // 用户归属标记：持久化工作区（编辑器页签/结果等）绑定到该用户，账号切换时清空，防跨账号看到上一账号的“历史”
      userKey: null,

      editorTabs: [{ id: 'ed1', label: '查询 1', sql: '' }],
      activeEditorTabId: 'ed1',
      nextEditorTabNumber: 2,
      sql: '',
      selectedSql: null,
      maxRows: 200,
      // Agent
      agentMode: 'auto',
      agentEditorTabId: null,
      agentResultTabCounter: 0,
      resultTabs: [defaultTab],
      activeResultTabId: defaultTab.id,
      nextTabNumber: 2,
      isExecuting: false,
      results: null,
      error: null,
      sqlSessionId: '',
      selectedSqlFile: null,
      sqlFilesVersion: 0,
      skillDraft: null,
      selectedSkill: null,
      skillFilesVersion: 0,
      kbDraft: null,
      selectedKb: null,
      kbFilesVersion: 0,
      modelDraft: null,
      selectedModel: null,
      modelFilesVersion: 0,
      skillWindows: [],
      activeSkillWindowId: null,
      kbWindows: [],
      activeKbWindowId: null,
      showSchema: false,
      sidebarColumns: null,
      sidebarColWidths: null,
      sidebarFlex: {},
      splitPos: 55,
      skillSplitPos: 55,
      modelSplitPos: 55,
      skillSidebarMerged: false,
      skillStackFlex: 0.5,
      kbSidebarMerged: false,
      kbStackFlex: 0.5,
      modelSidebarMerged: false,
      modelStackFlex: 0.5,
      schemaDbs: [],
      schemaTables: {},
      schemaCols: {},
      schemaExpandedDbs: [],
      schemaExpandedTbls: [],
      schemaCurrentDb: '',

      setMainNav: (nav) => set({ mainNav: nav }),
      setAiSubNav: (nav) => set({ aiSubNav: nav }),
      setAnalysisSubNav: (nav) => set({ analysisSubNav: nav }),
      clearOpenSqlFile: () => set({ openSqlFile: null }),
      requestOpenSqlFile: (file) => set({ mainNav: 'analysis', analysisSubNav: 'sql', openSqlFile: file }),
      beginSkillRun: (skill) => {
        const seq = (get().skillRun?.seq ?? 0) + 1;
        set({
          skillRun: {
            skill, seq, running: true, status: '正在执行…', steps: [],
            meta: null, sqls: [], tables: [], charts: [], answer: '', error: '', usage: null, elapsed: null,
            gapSeq: null,
          },
          // 新一轮执行：旧缺口建议卡与生成进度一并作废
          skillGapCard: null,
          skillGapStatus: { running: false, error: null },
        });
        return seq;
      },
      updateSkillRun: (patch) => set((s) => (s.skillRun ? { skillRun: { ...s.skillRun, ...patch } } : {})),
      clearSkillRun: () => set({ skillRun: null, skillGapCard: null, skillGapStatus: { running: false, error: null } }),
      setSkillGapCard: (card) => set({ skillGapCard: card }),
      setSkillGapStatus: (s) => set({ skillGapStatus: s }),
      setMyPermissions: (p) => set({ myPermissions: p }),
      setScopeLevel: (level) => set({ scopeLevel: level }),
      setUserKey: (key) => set({ userKey: key }),
      // 账号切换时清空用户绑定态（编辑器页签/选中 SQL/结果页签/会话），保留布局偏好（splitPos/侧栏等）
      resetUserWorkspace: () => set({
        editorTabs: [{ id: 'ed1', label: '查询 1', sql: '' }],
        activeEditorTabId: 'ed1',
        nextEditorTabNumber: 2,
        sql: '',
        selectedSql: null,
        resultTabs: [defaultTab],
        activeResultTabId: defaultTab.id,
        nextTabNumber: 2,
        agentEditorTabId: null,
        agentResultTabCounter: 0,
        selectedSqlFile: null,
        sqlSessionId: '',
        skillRun: null, // 专项执行结果也按账号隔离
        skillGapCard: null,
        skillGapStatus: { running: false, error: null },
      }),

      setSql: (sql) => {
        const id = get().activeEditorTabId;
        if (!id) { set({ sql }); return; }
        // Update React state immediately for responsive typing
        set({
          sql,
          editorTabs: get().editorTabs.map((t) =>
            t.id === id ? { ...t, sql } : t
          ),
        });
      },
      setSelectedSql: (sql) => set({ selectedSql: sql }),
      setMaxRows: (n) => set({ maxRows: Math.max(1, Math.min(99999, n)) }),
      // Agent actions
      toggleAgentMode: () => set((s) => ({ agentMode: s.agentMode === 'auto' ? 'confirm' : 'auto' })),
      getOrCreateAgentEditorTab: () => {
        const { editorTabs, agentEditorTabId } = get();
        const existing = editorTabs.find((t) => t.id === agentEditorTabId);
        if (existing) return existing.id;
        const tab: EditorTab = {
          id: 'ed-agent-' + Date.now(),
          label: '🤖 AI Agent',
          sql: '',
        };
        set({ editorTabs: [...editorTabs, tab], agentEditorTabId: tab.id });
        return tab.id;
      },
      createAgentResultTab: (summary: string) => {
        const { nextTabNumber, resultTabs, agentResultTabCounter } = get();
        const counter = agentResultTabCounter + 1;
        const label = `🤖 ${summary.slice(0, 8)} #${counter}`;
        const tab: ResultTab = {
          id: `tab-agent-${Date.now()}-${counter}`,
          label,
          sql: '',
          results: null,
          error: null,
        };
        let tabs = [...resultTabs, tab];
        // 上限 10（仅 AI 结果页）：超出丢弃最旧的 AI 结果页；人工结果页不受影响
        const aiIdx = tabs.map((t, i) => (isAgentTab(t) ? i : -1)).filter(i => i >= 0);
        if (aiIdx.length > MAX_AGENT_RESULT_TABS) {
          const drop = new Set(aiIdx.slice(0, aiIdx.length - MAX_AGENT_RESULT_TABS));
          tabs = tabs.filter((_, i) => !drop.has(i));
        }
        const activeId = tabs.some(t => t.id === tab.id) ? tab.id : (tabs[tabs.length - 1]?.id ?? null);
        const activeTab = tabs.find(t => t.id === activeId) || null;
        set({
          resultTabs: tabs,
          activeResultTabId: activeId,
          nextTabNumber: nextTabNumber + 1,
          agentResultTabCounter: counter,
          ...syncFromTab(activeTab),
        });
        return tab.id;
      },
      setResultTabData: (id, sql, results) => {
        const tabs = get().resultTabs.map((t) =>
          t.id === id ? { ...t, sql, results, error: null } : t
        );
        const tab = tabs.find((t) => t.id === id) || null;
        set({ resultTabs: tabs, ...syncFromTab(tab) });
      },
      setShowSchema: (show) => set({ showSchema: show }),
      setSidebarColumns: (cols) => set({ sidebarColumns: cols }),
      setSidebarColWidths: (w) => set({ sidebarColWidths: w }),
      setSidebarFlex: (f) => set({ sidebarFlex: f }),
      setSplitPos: (v) => set({ splitPos: v }),
      setSkillSplitPos: (v) => set({ skillSplitPos: v }),
      setModelSplitPos: (v) => set({ modelSplitPos: v }),
      setSkillSidebarMerged: (v) => set({ skillSidebarMerged: v }),
      setSkillStackFlex: (f) => set({ skillStackFlex: f }),
      setKbSidebarMerged: (v) => set({ kbSidebarMerged: v }),
      setKbStackFlex: (f) => set({ kbStackFlex: f }),
      setModelSidebarMerged: (v) => set({ modelSidebarMerged: v }),
      setModelStackFlex: (f) => set({ modelStackFlex: f }),
      setSchemaDbs: (dbs) => set({ schemaDbs: dbs }),
      setSchemaTables: (tables) => set({ schemaTables: tables }),
      setSchemaCols: (cols) => set({ schemaCols: cols }),
      setSchemaExpandedDbs: (dbs) => set({ schemaExpandedDbs: dbs }),
      setSchemaExpandedTbls: (tbls) => set({ schemaExpandedTbls: tbls }),
      setSchemaCurrentDb: (db) => set({ schemaCurrentDb: db }),
      clearSchemaCache: () => set({ schemaDbs: [], schemaTables: {}, schemaCols: {}, schemaExpandedDbs: [], schemaExpandedTbls: [], schemaCurrentDb: '' }),
      setSqlSessionId: (id) => set({ sqlSessionId: id }),
      setSelectedSqlFile: (f) => set({ selectedSqlFile: f }),
      bumpSqlFiles: () => set((s) => ({ sqlFilesVersion: s.sqlFilesVersion + 1 })),
      setSkillDraft: (patch) => set((s) => {
        const draft = patch === null ? null : { ...(s.skillDraft || EMPTY_SKILL), ...patch };
        const windows = s.activeSkillWindowId
          ? s.skillWindows.map((w) => w.id === s.activeSkillWindowId
              ? { ...w, draft: draft ?? w.draft, label: (draft?.name?.trim() || w.savedName || '未命名') }
              : w)
          : s.skillWindows;
        return { skillDraft: draft, skillWindows: windows };
      }),
      setSelectedSkill: (f) => set((s) => ({
        selectedSkill: f,
        skillWindows: s.activeSkillWindowId
          ? s.skillWindows.map((w) => w.id === s.activeSkillWindowId ? { ...w, savedName: f?.name ?? null } : w)
          : s.skillWindows,
      })),
      bumpSkillFiles: () => set((s) => ({ skillFilesVersion: s.skillFilesVersion + 1 })),
      setKbDraft: (patch) => set((s) => {
        const draft = patch === null ? null : { ...(s.kbDraft || EMPTY_KB), ...patch };
        const windows = s.activeKbWindowId
          ? s.kbWindows.map((w) => w.id === s.activeKbWindowId
              ? { ...w, draft: draft ?? w.draft, label: (draft?.name?.trim() || w.savedName || '未命名') }
              : w)
          : s.kbWindows;
        return { kbDraft: draft, kbWindows: windows };
      }),
      setSelectedKb: (f) => set((s) => ({
        selectedKb: f,
        kbWindows: s.activeKbWindowId
          ? s.kbWindows.map((w) => w.id === s.activeKbWindowId ? { ...w, savedName: f?.name ?? null } : w)
          : s.kbWindows,
      })),
      bumpKbFiles: () => set((s) => ({ kbFilesVersion: s.kbFilesVersion + 1 })),
      setModelDraft: (patch) => set((s) => ({
        modelDraft: patch === null ? null : { ...(s.modelDraft || EMPTY_MODEL), ...patch },
      })),
      setSelectedModel: (name) => set({ selectedModel: name }),
      bumpModelFiles: () => set((s) => ({ modelFilesVersion: s.modelFilesVersion + 1 })),

      // ── 专项多窗口 ──
      openSkillWindow: (name, draft, info) => set((s) => {
        const existing = s.skillWindows.find((w) => w.savedName === name);
        if (existing) {
          const windows = s.skillWindows.map((w) => w.id === existing.id
            ? { ...w, draft, info: info ?? w.info, label: name }
            : w);
          return {
            skillWindows: windows,
            activeSkillWindowId: existing.id,
            skillDraft: draft,
            selectedSkill: { name, level: draft.level },
          };
        }
        const id = 'skw-' + Date.now() + '-' + Math.random().toString(36).slice(2, 6);
        const w: SkillWindow = { id, label: name, draft, info: info ?? null, savedName: name };
        return {
          skillWindows: [...s.skillWindows, w],
          activeSkillWindowId: id,
          skillDraft: draft,
          selectedSkill: { name, level: draft.level },
        };
      }),
      newSkillWindow: (draft) => {
        const id = 'skw-' + Date.now() + '-' + Math.random().toString(36).slice(2, 6);
        const w: SkillWindow = { id, label: draft.name?.trim() || '未命名', draft, info: null, savedName: null };
        set((s) => ({ skillWindows: [...s.skillWindows, w], activeSkillWindowId: id, skillDraft: draft, selectedSkill: null }));
      },
      activateSkillWindow: (id) => set((s) => {
        const w = s.skillWindows.find((x) => x.id === id);
        if (!w) return {};
        return {
          activeSkillWindowId: id,
          skillDraft: w.draft,
          selectedSkill: w.savedName ? { name: w.savedName, level: w.draft.level } : null,
        };
      }),
      closeSkillWindow: (id) => set((s) => {
        const idx = s.skillWindows.findIndex((x) => x.id === id);
        if (idx < 0) return {};
        const windows = s.skillWindows.filter((x) => x.id !== id);
        if (windows.length === 0) {
          return { skillWindows: [], activeSkillWindowId: null, skillDraft: null, selectedSkill: null };
        }
        let activeId = s.activeSkillWindowId;
        if (activeId === id) activeId = windows[Math.min(idx, windows.length - 1)].id;
        const w = windows.find((x) => x.id === activeId);
        return {
          skillWindows: windows,
          activeSkillWindowId: activeId,
          skillDraft: w?.draft ?? null,
          selectedSkill: w?.savedName ? { name: w.savedName, level: w.draft.level } : null,
        };
      }),
      // windowId 缺省 = 当前激活窗口；显式传 null 表示无目标（不写任何窗口）
      syncSkillWindowInfo: (info, windowId) => set((s) => {
        const target = windowId === undefined ? s.activeSkillWindowId : windowId;
        return {
          skillWindows: target
            ? s.skillWindows.map((w) => w.id === target ? { ...w, info } : w)
            : s.skillWindows,
        };
      }),

      // ── 知识库多窗口 ──
      openKbWindow: (name, draft) => set((s) => {
        const existing = s.kbWindows.find((w) => w.savedName === name);
        if (existing) {
          const windows = s.kbWindows.map((w) => w.id === existing.id ? { ...w, draft, label: name } : w);
          return {
            kbWindows: windows,
            activeKbWindowId: existing.id,
            kbDraft: draft,
            selectedKb: { name, level: draft.level },
          };
        }
        const id = 'kbw-' + Date.now() + '-' + Math.random().toString(36).slice(2, 6);
        const w: KbWindow = { id, label: name, draft, savedName: name };
        return {
          kbWindows: [...s.kbWindows, w],
          activeKbWindowId: id,
          kbDraft: draft,
          selectedKb: { name, level: draft.level },
        };
      }),
      newKbWindow: (draft) => {
        const id = 'kbw-' + Date.now() + '-' + Math.random().toString(36).slice(2, 6);
        const w: KbWindow = { id, label: draft.name?.trim() || '未命名', draft, savedName: null };
        set((s) => ({ kbWindows: [...s.kbWindows, w], activeKbWindowId: id, kbDraft: draft, selectedKb: null }));
      },
      activateKbWindow: (id) => set((s) => {
        const w = s.kbWindows.find((x) => x.id === id);
        if (!w) return {};
        return {
          activeKbWindowId: id,
          kbDraft: w.draft,
          selectedKb: w.savedName ? { name: w.savedName, level: w.draft.level } : null,
        };
      }),
      closeKbWindow: (id) => set((s) => {
        const idx = s.kbWindows.findIndex((x) => x.id === id);
        if (idx < 0) return {};
        const windows = s.kbWindows.filter((x) => x.id !== id);
        if (windows.length === 0) {
          return { kbWindows: [], activeKbWindowId: null, kbDraft: null, selectedKb: null };
        }
        let activeId = s.activeKbWindowId;
        if (activeId === id) activeId = windows[Math.min(idx, windows.length - 1)].id;
        const w = windows.find((x) => x.id === activeId);
        return {
          kbWindows: windows,
          activeKbWindowId: activeId,
          kbDraft: w?.draft ?? null,
          selectedKb: w?.savedName ? { name: w.savedName, level: w.draft.level } : null,
        };
      }),

      addEditorTab: () => {
        const n = get().nextEditorTabNumber;
        const tab: EditorTab = {
          id: `ed-${Date.now()}-${n}`,
          label: `查询 ${n}`,
          sql: '',
        };
        set({
          editorTabs: [...get().editorTabs, tab],
          activeEditorTabId: tab.id,
          nextEditorTabNumber: n + 1,
          sql: '',
        });
      },

      switchEditorTab: (id) => {
        const tab = get().editorTabs.find((t) => t.id === id);
        if (!tab) return;
        set({ activeEditorTabId: id, sql: tab.sql });
      },

      closeEditorTab: (id) => {
        const { editorTabs, activeEditorTabId } = get();
        if (editorTabs.length <= 1) return;
        const idx = editorTabs.findIndex((t) => t.id === id);
        const newTabs = editorTabs.filter((t) => t.id !== id);
        let newId = activeEditorTabId;
        if (activeEditorTabId === id) {
          newId = newTabs[Math.min(idx, newTabs.length - 1)].id;
        }
        const tab = newTabs.find((t) => t.id === newId) || null;
        set({
          editorTabs: newTabs,
          activeEditorTabId: newId,
          sql: tab?.sql || '',
        });
      },

      setEditorTabSql: (id, sql) => {
        const st = get();
        set({
          editorTabs: st.editorTabs.map((t) =>
            t.id === id ? { ...t, sql } : t
          ),
          // 编辑的是当前活动 tab 时同步全局 sql，编辑器立即生效
          ...(st.activeEditorTabId === id ? { sql } : {}),
        });
      },

      // 打开已有 SQL 文件时把活动标签页改名成文档名（全新标签仍默认「查询 N」）
      setActiveEditorTabLabel: (label) => set((s) => ({
        editorTabs: s.editorTabs.map((t) =>
          t.id === s.activeEditorTabId ? { ...t, label } : t
        ),
      })),

      switchResultTab: (id) => {
        const tab = get().resultTabs.find((t) => t.id === id) || null;
        set({ activeResultTabId: id, ...syncFromTab(tab) });
      },

      closeResultTab: (id) => {
        const { resultTabs, activeResultTabId } = get();
        const newTabs = resultTabs.filter((t) => t.id !== id);
        if (newTabs.length === 0) {
          set({ resultTabs: [], activeResultTabId: null, results: null, error: null });
          return;
        }
        const idx = resultTabs.findIndex((t) => t.id === id);
        let newActiveId = activeResultTabId;
        if (activeResultTabId === id || !newTabs.some(t => t.id === newActiveId)) {
          const newIdx = Math.min(idx, newTabs.length - 1);
          newActiveId = newTabs[newIdx].id;
        }
        const activeTab = newTabs.find((t) => t.id === newActiveId) || null;
        set({
          resultTabs: newTabs,
          activeResultTabId: newActiveId,
          ...syncFromTab(activeTab),
        });
      },

      clearAgentResultTabs: () => {
        const { resultTabs, activeResultTabId } = get();
        const kept = resultTabs.filter((t) => !isAgentTab(t));
        if (kept.length === 0) {
          set({ resultTabs: [], activeResultTabId: null, results: null, error: null });
          return;
        }
        let newActiveId = activeResultTabId;
        if (newActiveId === null || !kept.some(t => t.id === newActiveId)) {
          newActiveId = kept[kept.length - 1].id;
        }
        const activeTab = kept.find((t) => t.id === newActiveId) || null;
        set({ resultTabs: kept, activeResultTabId: newActiveId, ...syncFromTab(activeTab) });
      },

      executeSql: async (newTab = false) => {
        const { sql, selectedSql, resultTabs, activeResultTabId, nextTabNumber, sqlSessionId } = get();
        const sqlToExecute = selectedSql || sql;

        if (!sqlToExecute.trim()) {
          set({ error: '请输入 SQL 语句' });
          return;
        }
        // 结果页为空时（全被关闭），查询按钮也需新建一个结果页
        const createNew = newTab || resultTabs.length === 0;
        set({ isExecuting: true });
        const startedAt = Date.now();
        const record = (status: string, rowCount: number) => {
          api.addSqlHistory({
            session_id: sqlSessionId || '',
            sql: sqlToExecute,
            status,
            row_count: rowCount,
            duration_ms: Date.now() - startedAt,
          }).catch(() => {});
        };
        try {
          const response = await api.runSql(sqlToExecute);
          if (response.ok && response.table) {
            const t = response.table;
            const rows = t.rows.map((r) => Object.fromEntries(t.columns.map((c, i) => [c, r[i]])));
            const resultData: QueryResultData = {
              type: 'select',
              columns: t.columns,
              rows,
              row_count: t.total_rows,
              execution_time: (Date.now() - startedAt) / 1000,
            };
            record('ok', t.total_rows);
            if (createNew) {
              const tab = makeTab(`结果 ${nextTabNumber}`);
              tab.sql = sqlToExecute;
              tab.results = [resultData];
              const newTabs = [...resultTabs, tab];
              set({
                resultTabs: newTabs,
                activeResultTabId: tab.id,
                nextTabNumber: nextTabNumber + 1,
                ...syncFromTab(tab),
              });
            } else {
              const updatedTabs = resultTabs.map((t) => {
                if (t.id !== activeResultTabId) return t;
                return { ...t, sql: sqlToExecute, results: [resultData], error: null };
              });
              const updatedTab = updatedTabs.find((t) => t.id === activeResultTabId) || null;
              set({ resultTabs: updatedTabs, ...syncFromTab(updatedTab) });
            }
          } else {
            const errMsg = response.error || '执行失败';
            record('error', 0);
            if (createNew) {
              const tab = makeTab(`结果 ${nextTabNumber}`);
              tab.sql = sqlToExecute;
              tab.error = errMsg;
              const newTabs = [...resultTabs, tab];
              set({
                resultTabs: newTabs,
                activeResultTabId: tab.id,
                nextTabNumber: nextTabNumber + 1,
                ...syncFromTab(tab),
              });
            } else {
              const updatedTabs = resultTabs.map((t) => {
                if (t.id !== activeResultTabId) return t;
                return { ...t, sql: sqlToExecute, results: null, error: errMsg };
              });
              const updatedTab = updatedTabs.find((t) => t.id === activeResultTabId) || null;
              set({ resultTabs: updatedTabs, ...syncFromTab(updatedTab) });
            }
          }
        } catch (e) {
          const msg = e instanceof Error ? e.message : '执行失败';
          record('error', 0);
          if (createNew) {
            const tab = makeTab(`结果 ${nextTabNumber}`);
            tab.sql = sqlToExecute;
            tab.error = msg;
            const newTabs = [...resultTabs, tab];
            set({
              resultTabs: newTabs,
              activeResultTabId: tab.id,
              nextTabNumber: nextTabNumber + 1,
              ...syncFromTab(tab),
            });
          } else {
            const updatedTabs = resultTabs.map((t) => {
              if (t.id !== activeResultTabId) return t;
              return { ...t, results: null, error: msg };
            });
            set({ resultTabs: updatedTabs, results: null, error: msg });
          }
        } finally {
          set({ isExecuting: false });
        }
      },
    }),
    {
      name: 'sql-ide-storage',
      // v2：融合后 store 结构大改（去掉用户连接/多后端等字段）。旧 sql-ide（/ide 时代）在
      // 同一 origin 下用同名 key 'sql-ide-storage' 持久化，结构不兼容；直接丢弃旧状态重来，
      // 避免重水化后（如 resultTabs/editorTabs 项缺 label）渲染崩溃白屏。
      version: 2,
      migrate: (persisted: any, version: number) => {
        if ((version ?? 0) < 2) return {} as any;
        return persisted as any;
      },
      partialize: (state) => ({
        mainNav: state.mainNav,
        aiSubNav: state.aiSubNav,
        analysisSubNav: state.analysisSubNav,
        userKey: state.userKey,
        editorTabs: state.editorTabs,
        activeEditorTabId: state.activeEditorTabId,
        nextEditorTabNumber: state.nextEditorTabNumber,
        sql: state.sql,
        selectedSql: state.selectedSql,
        maxRows: state.maxRows,
        resultTabs: state.resultTabs,
        activeResultTabId: state.activeResultTabId,
        nextTabNumber: state.nextTabNumber,
        // Agent
        agentMode: state.agentMode,
        agentEditorTabId: state.agentEditorTabId,
        agentResultTabCounter: state.agentResultTabCounter,
        showSchema: state.showSchema,
        sidebarColumns: state.sidebarColumns,
        sidebarColWidths: state.sidebarColWidths,
        sidebarFlex: state.sidebarFlex,
        splitPos: state.splitPos,
        skillSplitPos: state.skillSplitPos,
        modelSplitPos: state.modelSplitPos,
        skillSidebarMerged: state.skillSidebarMerged,
        skillStackFlex: state.skillStackFlex,
        kbSidebarMerged: state.kbSidebarMerged,
        kbStackFlex: state.kbStackFlex,
        modelSidebarMerged: state.modelSidebarMerged,
        modelStackFlex: state.modelStackFlex,
        schemaDbs: state.schemaDbs,
        schemaTables: state.schemaTables,
        schemaCols: state.schemaCols,
        schemaExpandedDbs: state.schemaExpandedDbs,
        schemaExpandedTbls: state.schemaExpandedTbls,
        schemaCurrentDb: state.schemaCurrentDb,
      }),
    }
  )
);

// 多标签页账号切换同步：另一标签页登录/切换账号并重写 sql-ide-storage 的 userKey 时，本标签页
// 内存里仍持有上一账号的页签/结果，继续操作会把旧账号工作区以旧 userKey 写回（ping-pong 泄漏），
// 且请求已带新账号 token 不会触发 401。这里检测到 userKey 变化即整页重载：重新走
// getMe → scopeWorkspaceToUser 引导流程，一切状态（编辑器/列表/对话）以新账号干净重建。
if (typeof window !== 'undefined') {
  window.addEventListener('storage', (e) => {
    if (e.key !== 'sql-ide-storage') return;
    try {
      const parsed = e.newValue ? JSON.parse(e.newValue) : null;
      const remoteState = parsed && parsed.state && typeof parsed.state === 'object' ? parsed.state : null;
      const remoteKey = remoteState && remoteState.userKey;
      if (!remoteKey || remoteKey === useStore.getState().userKey) return;
      window.location.reload();
    } catch {}
  });
}
