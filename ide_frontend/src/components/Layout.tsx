import React, { useEffect, useRef, useState } from 'react';
import { useStore } from '../stores/useStore';
import { IndicatorPage } from './Indicator/IndicatorPage';
import { MCPPage } from './MCP/MCPPage';
import { UserManagementPage } from './UserManagementPage';
import { PermissionPage } from './PermissionPage';
import { IframePage } from './IframePage';
import { SqlWorkspace } from './SqlWorkspace';
import { SkillWorkspace } from './SkillWorkspace';
import { KnowledgeWorkspace } from './KnowledgeWorkspace';
import { ModelsWorkspace } from './ModelsWorkspace';
import { PersonalWorkspace } from './PersonalWorkspace';
import { GlossaryPage } from './Config/GlossaryPage';
import { ProjectMappingPage } from './Admin/ProjectMappingPage';
import { ModelManagementPage } from './Admin/ModelManagementPage';
import { api } from '../services/api';
import { UserMenu } from './UserMenu';
import { Sun, Moon } from 'lucide-react';
import { cn } from '../lib/utils';
import { useTheme } from './ThemeProvider';

type SubItem = { key: string; label: string };

// 用户应用 / 分析配置 → iframe 嵌入 FiveCross 聊天页；个人配置为 React 页
// 订阅报告已并入「个人定制」（PersonalWorkspace 内 tab）
const GROUPS: { key: string; label: string }[] = [
  { key: 'apps', label: '用户应用' },
  { key: 'analysis', label: '分析配置' },
  { key: 'ai', label: 'AI配置' },
  { key: 'system', label: '系统管理' },
];

// 权限点全集改由后端 GET /api/permissions/points 下发（审计 P2-3），前端不再硬编码清单；
// 匿名回落/未登录时视为全量（清单拉取失败时保持 null = 全量放行，不隐藏导航）。

// 用户应用 / 分析配置 → iframe 嵌入 data_ai vanilla 页面；panel（FCData看板）/personal（个人定制）为 React 页
// 订阅报告已并入「个人定制」（PersonalWorkspace 内 tab），此处不重复挂导航项
const APPS_ITEMS: SubItem[] = [
  { key: 'chat', label: '聊天窗口' },
  { key: 'personal', label: '个人定制' },
];
const APPS_SRC: Record<string, string> = {
  chat: '/app/chat.html',
};
const ANALYSIS_ITEMS: SubItem[] = [
  { key: 'skill', label: '专项管理' },
  { key: 'knowledge', label: '知识库管理' },
  { key: 'sql', label: 'SQL管理' },
  { key: 'models', label: '算法管理' },
];
// 所有由 iframe 承载的 vanilla 页面（合并，供 keep-alive 常驻容器遍历）；分析配置四项已全部 React 化
const IFRAME_SRCS: Record<string, string> = { ...APPS_SRC };

const AI_ITEMS: SubItem[] = [
  { key: 'indicators', label: '指标管理' },
  { key: 'glossary', label: '术语与口径' },
  { key: 'mcp', label: 'MCP管理' },
  // 记忆管理已挪「用户应用 → 个人定制」（记忆增强 2026-10-21 用户拍板：唯一入口）；
  // 术语与口径（2026-10-23 记忆重组）：原随记忆页迁入个人定制的系统级配置，回归 AI配置
];
const SYSTEM_ITEMS: SubItem[] = [
  { key: 'users', label: '用户管理' },
  { key: 'permissions', label: '权限管理' },
  { key: 'project-mapping', label: '项目映射' },
  { key: 'model-config', label: '模型管理' },
];

export const Layout: React.FC = () => {
  const { theme, toggle: toggleTheme } = useTheme();
  const { mainNav, aiSubNav, analysisSubNav, setMainNav, setAiSubNav, setAnalysisSubNav, clearOpenSqlFile, setMyPermissions } = useStore();
  const [appsSubNav, setAppsSubNav] = useState('chat');
  const [systemSubNav, setSystemSubNav] = useState('users');
  const [reloadKey, setReloadKey] = useState(0);

  // RBAC：当前用户生效权限点（/api/auth/me；匿名回落/未登录 = 后端下发的全量清单）
  const [permissions, setPermissions] = useState<string[] | null>(null);
  useEffect(() => {
    // 先取后端权限点全集（审计 P2-3），me 无 permissions 字段时用它作全量回落
    let allPoints: string[] | null = null;
    api.getPermissionPoints()
      .then((r) => { allPoints = r.points || []; })
      .catch(() => { allPoints = null; })
      .finally(() => {
        api.getMe()
          .then((u) => {
            setPermissions(u.permissions || allPoints || null); // null = 匿名回落/全量，不拦导航
            setMyPermissions(u.permissions || null); // null = 匿名回落/全量，不拦编辑
          })
          .catch(() => {
            setPermissions(allPoints); // 未登录/匿名：全量清单放行（清单失败则 null = 全量放行）
            setMyPermissions(null);
          });
      });
  }, [setMyPermissions]);
  const visibleGroups = GROUPS.filter((g) => !permissions || permissions.includes(g.key));
  // 权限加载后，若当前 mainNav 已不在允许集内（如失去 system），回退到可用组
  useEffect(() => {
    if (permissions && mainNav && !permissions.includes(mainNav)) {
      setMainNav(permissions.includes('apps') ? 'apps' : (permissions[0] || 'apps'));
    }
  }, [permissions, mainNav, setMainNav]);

  // iframe 保活：vanilla 页面（聊天/记录/报告/专项/知识库/算法）一旦访问过就不再卸载，
  // 切走只 display:none，让聊天流在后台继续执行、切回来内容不丢。
  const activeIframeKey = (() => {
    if (mainNav === 'apps') return appsSubNav === 'personal' ? null : appsSubNav;
    if (mainNav === 'analysis' && analysisSubNav !== 'sql' && analysisSubNav !== 'skill' && analysisSubNav !== 'knowledge' && analysisSubNav !== 'models') return analysisSubNav;
    return null;
  })();
  const [mountedIframes, setMountedIframes] = useState<Set<string>>(() => (activeIframeKey ? new Set([activeIframeKey]) : new Set()));
  useEffect(() => {
    if (activeIframeKey) {
      setMountedIframes((prev) => (prev.has(activeIframeKey) ? prev : new Set(prev).add(activeIframeKey)));
    }
  }, [activeIframeKey]);
  // 当前渲染要挂载的 iframe 集合 = 已访问过的 ∪ 当前激活的（激活项即使首次进入也立即渲染，避免一帧空内容）
  const renderedIframeKeys = new Set(mountedIframes);
  if (activeIframeKey) renderedIframeKeys.add(activeIframeKey);

  // 游戏切换器：读 data_ai 的 /api/games（不经 /ide 前缀），写 localStorage['chatbi.game']，
  // iframe 内页面靠 nav.js 注入 X-Game 头取数；切换后重载 iframe。
  type GameMeta = {
    key: string;
    name: string;
    source_group?: string;
    source_type?: string;
    client_engine?: string;
    client_region?: string;
    game_id?: string;
  };
  const [games, setGames] = useState<GameMeta[]>([]);
  const [sourceFilter, setSourceFilter] = useState<string>(() => {
    try { return localStorage.getItem('chatbi.source') || 'all'; } catch { return 'all'; }
  });
  const [gameFamily, setGameFamily] = useState('all');
  // 评审 L5：三态拉取（loading/error/ready）——此前 .catch(() => {}) 吞掉失败，
  // 选择器静默显示「无游戏权限」，实为网络/后端错误；现在失败显式标错 + 重试按钮。
  // 对抗审查二轮：失败时一次性 5s 自动重拉（网络抖动/后端重启窗口自愈），再失败不循环
  const [gamesState, setGamesState] = useState<'loading' | 'error' | 'ready'>('loading');
  const [gamesReload, setGamesReload] = useState(0);
  const autoRetried = useRef(false);   // 本次失败后是否已自动重试过（成功即复位）
  const retryTimer = useRef<number | null>(null);
  const [gameKey, setGameKey] = useState<string>(() => {
    try { return localStorage.getItem('chatbi.game') || ''; } catch { return ''; }
  });

  // 旧版持久化 mainNav（editor/bot/admin）→ 归位到「用户应用」
  useEffect(() => {
    if (!GROUPS.some((g) => g.key === mainNav)) setMainNav('apps');
  }, [mainNav, setMainNav]);

  // 记忆增强 2026-10-21：aiSubNav 持久化于 localStorage，升级前打开过「记忆管理」的用户
  // 残留 aiSubNav='memory'，会渲染指标页却无任何 tab 高亮——进入 AI 配置时兜底归位。
  useEffect(() => {
    if (mainNav === 'ai' && aiSubNav && !AI_ITEMS.some((i) => i.key === aiSubNav)) {
      setAiSubNav('indicators');
    }
  }, [mainNav, aiSubNav, setAiSubNav]);

  // 壳导航哈希同步（P1-16）：支持 '#/analysis/<sql|skill|knowledge|models>' 深链；
  // 挂载时读取一次并监听 hashchange 同步到分析配置二级导航，其余 hash 一律忽略（只读不写）。
  useEffect(() => {
    const applyHash = () => {
      const m = window.location.hash.match(/^#\/analysis\/(sql|skill|knowledge|models)$/);
      if (!m) return;
      setMainNav('analysis');
      setAnalysisSubNav(m[1]);
    };
    applyHash();
    window.addEventListener('hashchange', applyHash);
    return () => window.removeEventListener('hashchange', applyHash);
  }, [setMainNav, setAnalysisSubNav]);

  useEffect(() => {
    let alive = true;
    setGamesState('loading');
    api.getGames()
      .then((data) => {
        if (!alive) return;
        autoRetried.current = false;  // 拉取成功：复位一次性自动重试标记
        const gs: { key: string; name: string }[] = data.games || [];
        setGames(gs);
        setGamesState('ready');
        const fallback = data.default || (gs[0]?.key ?? '');
        setGameKey((cur) => {
          if (!cur || !gs.some((g) => g.key === cur)) return fallback;
          return cur;
        });
        // 游戏选择是用户绑定态：回退结果必须写回 localStorage，否则 getGameHeader（api.ts）
        // 与 nav.js 每次请求仍注入上一账号/已失效的游戏 key，被后端 get_game 403 硬拦。
        try {
          const stored = localStorage.getItem('chatbi.game');
          if (!stored || !gs.some((g) => g.key === stored)) {
            if (fallback) localStorage.setItem('chatbi.game', fallback);
            else localStorage.removeItem('chatbi.game');
          }
        } catch {}
      })
      .catch(() => {
        if (!alive) return;
        setGamesState('error');
        // 一次性 5s 自动重拉：网络抖动/后端重启窗口静默自愈一次；再失败不循环
        // （error 态横幅与顶栏按钮兜底，用户可手动重试）
        if (!autoRetried.current) {
          retryTimer.current = window.setTimeout(() => {
            retryTimer.current = null;
            // F9（对抗审查三轮）：标记在重试真正发起时消费，而非调度时——用户在计时器
            // 触发前手动重试会让上一版"调度即消费"的标记被幽灵消耗，后续失败不再自愈
            autoRetried.current = true;
            if (alive) setGamesReload((n) => n + 1);
          }, 5000);
        }
      });
    return () => {
      alive = false;
      if (retryTimer.current !== null) {
        window.clearTimeout(retryTimer.current);
        retryTimer.current = null;
      }
    };
  }, [gamesReload]);

  const sourceOf = (g: GameMeta) => {
    if (g.source_type === 'local_backup' || g.source_group === '本地备份') return 'backup';
    if (g.source_group === '数数中国') return 'ta_cn';
    if (g.source_group === '数数海外') return 'ta_global';
    if (g.source_group === '阿里云中国') return 'odps_cn';
    if (g.source_group === '阿里云海外') return 'odps_global';
    if (g.client_engine === 'ta') return g.client_region === 'china' ? 'ta_cn' : 'ta_global';
    if (g.client_engine === 'odps') return g.client_region === 'china' ? 'odps_cn' : 'odps_global';
    return 'backup';
  };
  const familyOf = (g: GameMeta) => {
    const n = (g.name || g.key).toLowerCase();
    if (n.includes('slam dunk') || n.includes('灌篮')) return 'slam_dunk';
    if (n.includes('kuroko') || n.includes('黑子')) return 'kuroko';
    if (n.includes('shin-chan') || n.includes('蜡笔')) return 'shinchan';
    if (n.includes('jump assemble') || n.includes('jump')) return 'jump';
    if (n.includes('saint seiya') || n.includes('圣斗士')) return 'saint_seiya';
    if (n.includes('captain') || n.includes('足球小将') || n.includes('队长小翼')) return 'captain_tsubasa';
    if (n.includes('three kingdoms') || n.includes('三国')) return 'three_kingdoms';
    if (n.includes('debug')) return 'debug';
    return 'other';
  };
  const familyLabel = (key: string) => ({
    slam_dunk: 'Slam Dunk', kuroko: 'Kuroko', shinchan: 'Crayon Shin-chan', jump: 'Jump Assemble',
    saint_seiya: 'Saint Seiya', captain_tsubasa: 'Captain Tsubasa', three_kingdoms: 'Three Kingdoms', debug: 'Debug', other: 'Other',
  } as Record<string, string>)[key] || key;
  const sourceOptions = [
    ['all', '全部'], ['ta_cn', '数数中国'], ['ta_global', '数数海外'],
    ['odps_cn', '阿里云中国'], ['odps_global', '阿里云海外'], ['backup', '本地备份'],
  ];
  const sourceGames = games.filter((g) => sourceFilter === 'all' || sourceOf(g) === sourceFilter);
  const familyKeys = [...new Set(sourceGames.map(familyOf))].sort();
  const filteredGames = sourceGames.filter((g) => gameFamily === 'all' || familyOf(g) === gameFamily);

  const onSourceChange = (value: string) => {
    setSourceFilter(value);
    setGameFamily('all');
    try { localStorage.setItem('chatbi.source', value); } catch {}
  };
  const onFamilyChange = (value: string) => {
    setGameFamily(value);
    const candidates = sourceGames.filter((g) => value === 'all' || familyOf(g) === value);
    if (candidates.length && !candidates.some((g) => g.key === gameKey)) {
      const next = candidates[0].key;
      setGameKey(next);
      try { localStorage.setItem('chatbi.game', next); } catch {}
      setReloadKey((n) => n + 1);
    }
  };

  const onGameChange = (k: string) => {
    setGameKey(k);
    try { if (k) localStorage.setItem('chatbi.game', k); else localStorage.removeItem('chatbi.game'); } catch {}
    setReloadKey((n) => n + 1);
  };

  const NavTab: React.FC<{ active: boolean; onClick: () => void; children: React.ReactNode }> = ({ active, onClick, children }) => (
    <button onClick={onClick} aria-current={active ? 'page' : undefined} className={cn(
      'px-3 py-1 rounded text-xs cursor-pointer border-none transition-colors whitespace-nowrap',
      active ? 'bg-secondary text-foreground font-semibold' : 'bg-transparent text-muted-foreground hover:text-foreground hover:bg-accent'
    )}>{children}</button>
  );

  // 审计 P2-12：二级导航窄屏横向滚动，按钮不换行
  const Level2Nav: React.FC<{ items: SubItem[]; active: string; onChange: (k: string) => void }> = ({ items, active, onChange }) => (
    <div className="flex gap-0.5 px-3 py-0.5 bg-secondary/30 border-b border-border shrink-0 items-center overflow-x-auto">
      {items.map((item) => (
        <button key={item.key} onClick={() => onChange(item.key)} aria-current={active === item.key ? 'page' : undefined} className={cn(
          'px-2.5 py-1 text-[11px] cursor-pointer border-none rounded-b border-b-2 transition-colors whitespace-nowrap shrink-0',
          active === item.key ? 'bg-accent text-sql-accent border-sql-accent font-medium'
            : 'bg-transparent text-muted-foreground border-transparent hover:text-foreground'
        )}>{item.label}</button>
      ))}
    </div>
  );

  const subNav = (() => {
    switch (mainNav) {
      case 'apps': return <Level2Nav items={APPS_ITEMS} active={appsSubNav} onChange={setAppsSubNav} />;
      case 'analysis': return <Level2Nav items={ANALYSIS_ITEMS} active={analysisSubNav} onChange={(k) => { clearOpenSqlFile(); setAnalysisSubNav(k); }} />;
      case 'ai': return <Level2Nav items={AI_ITEMS} active={aiSubNav} onChange={setAiSubNav} />;
      case 'system': return <Level2Nav items={SYSTEM_ITEMS} active={systemSubNav} onChange={setSystemSubNav} />;
      default: return null;
    }
  })();

  const page = (() => {
    switch (mainNav) {
      case 'apps':
        if (appsSubNav === 'personal') return <PersonalWorkspace />;
        return null; // chat → iframe 保活容器
      case 'analysis':
        if (analysisSubNav === 'sql') return <SqlWorkspace />;
        if (analysisSubNav === 'skill') return <SkillWorkspace />;
        if (analysisSubNav === 'knowledge') return <KnowledgeWorkspace />;
        if (analysisSubNav === 'models') return <ModelsWorkspace />;
        return null;
      case 'ai':
        if (aiSubNav === 'mcp') return <MCPPage />;
        if (aiSubNav === 'glossary') return <GlossaryPage />;
        return <IndicatorPage />;
      case 'system':
        if (systemSubNav === 'permissions') return <PermissionPage />;
        if (systemSubNav === 'project-mapping') return <ProjectMappingPage />;
        if (systemSubNav === 'model-config') return <ModelManagementPage />;
        return <UserManagementPage />;
      default: return null;
    }
  })();

  return (
    <div className="h-screen flex flex-col bg-background text-foreground">
      {/* 审计 P2-12：窄屏允许顶栏换行（品牌字 ≤640px 隐藏、导航不换行、右侧控件组靠右） */}
      <header className="flex items-center justify-between flex-wrap gap-y-1 px-3 py-1 border-b border-border bg-card shrink-0 min-h-[32px] relative z-[2000]">
        <div className="flex items-center gap-1.5 min-w-0 flex-wrap">
          <span className="text-[13px] font-bold text-foreground mr-2 whitespace-nowrap hidden sm:inline">FiveCross 数据平台</span>
          {visibleGroups.map((g) => (
            <NavTab key={g.key} active={mainNav === g.key} onClick={() => setMainNav(g.key)}>{g.label}</NavTab>
          ))}
        </div>
        <div className="flex items-center gap-2 ml-auto flex-wrap justify-end">
          <div className="flex items-center gap-1" title="筛选数据源">
            <span className="text-[11px] text-muted-foreground whitespace-nowrap">数据源</span>
            <select value={sourceFilter} onChange={(e) => onSourceChange(e.target.value)} aria-label="筛选数据源"
              className="h-[24px] w-[112px] px-1.5 rounded border border-border bg-card text-foreground text-[11px] cursor-pointer outline-none">
              {sourceOptions.map(([value, label]) => <option key={value} value={value}>{label}</option>)}
            </select>
          </div>
          <div className="flex items-center gap-1" title="筛选游戏类型">
            <span className="text-[11px] text-muted-foreground whitespace-nowrap">游戏</span>
            <select value={gameFamily} onChange={(e) => onFamilyChange(e.target.value)} aria-label="筛选游戏类型"
              className="h-[24px] w-[112px] px-1.5 rounded border border-border bg-card text-foreground text-[11px] cursor-pointer outline-none">
              <option value="all">全部</option>
              {familyKeys.map((key) => <option key={key} value={key}>{familyLabel(key)}</option>)}
            </select>
            {gamesState === 'error' ? (
              <button onClick={() => setGamesReload((n) => n + 1)} title="游戏列表加载失败，点击重试"
                className="h-[24px] px-2 rounded border border-border bg-card text-foreground text-[11px] cursor-pointer hover:bg-accent">
                游戏加载失败 · 重试
              </button>
            ) : (
            <select value={filteredGames.some((g) => g.key === gameKey) ? gameKey : ''}
              onChange={(e) => onGameChange(e.target.value)} aria-label="选择游戏项目" disabled={filteredGames.length === 0}
              title={filteredGames.length === 0 ? '当前筛选条件下没有游戏' : '选择游戏项目'}
              className="h-[24px] w-[190px] px-1.5 rounded border border-border bg-card text-foreground text-[11px] cursor-pointer outline-none max-[480px]:w-[110px] disabled:cursor-not-allowed disabled:opacity-60">
              {filteredGames.length === 0 ? <option value="">{gamesState === 'loading' ? '加载中…' : '无匹配项目'}</option> : filteredGames.map((g) => (
                <option key={g.key} value={g.key}>{g.name || g.key}</option>
              ))}
            </select>
            )}
          </div>
          <button onClick={toggleTheme} title={theme === 'dark' ? '切换为亮色主题' : '切换为暗色主题'}
            aria-label={theme === 'dark' ? '切换为亮色主题' : '切换为暗色主题'}
            className="flex items-center justify-center w-7 h-7 rounded border border-border bg-transparent text-muted-foreground hover:text-foreground hover:bg-accent transition-colors cursor-pointer">
            {theme === 'dark' ? <Sun className="h-3.5 w-3.5" /> : <Moon className="h-3.5 w-3.5" />}
          </button>
          <UserMenu />
        </div>
      </header>

      {subNav}

      {/* 对抗审查二轮：游戏列表拉取失败时顶栏小按钮不够醒目（窄屏/切换页后更难察觉），
          补一条全宽横幅说明影响面（聊天/看板取数无法绑定游戏）+ 重试入口；自动重试成功即消失 */}
      {gamesState === 'error' && (
        <div className="flex items-center justify-between gap-2 px-3 py-1 bg-accent text-foreground border-b border-border shrink-0">
          <span className="text-[11px]">⚠️ 游戏列表加载失败：聊天/看板取数可能无法绑定游戏，请重试</span>
          <button onClick={() => setGamesReload((n) => n + 1)}
            title="重新加载游戏列表"
            className="h-[22px] px-2 rounded border border-border bg-card text-foreground text-[11px] cursor-pointer hover:bg-secondary shrink-0">
            重试
          </button>
        </div>
      )}

      <div style={{ flex: 1, minHeight: 0, display: 'flex', overflow: 'hidden' }}>
        {/* iframe 保活容器：已访问的 vanilla 页面常驻，仅当前项可见（display:none 不卸载） */}
        {[...renderedIframeKeys].map((key) => {
          const src = IFRAME_SRCS[key];
          if (!src) return null;
          const active = activeIframeKey === key;
          return (
            <div key={key} style={{
              flex: 1, minWidth: 0, minHeight: 0, height: '100%',
              display: active ? 'flex' : 'none', flexDirection: 'column',
            }}>
              <IframePage
                src={src}
                reloadKey={reloadKey}
              />
            </div>
          );
        })}
        {/* React 子页面：承载于 flex 容器，保证 flex:1 + overflow:auto 拿到可视区高度 */}
        {activeIframeKey === null && page != null && (
          <div style={{ flex: 1, minWidth: 0, minHeight: 0, height: '100%', display: 'flex', flexDirection: 'column' }}>{page}</div>
        )}
      </div>
    </div>
  );
};
