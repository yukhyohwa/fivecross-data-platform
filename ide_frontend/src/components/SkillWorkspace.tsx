import React, { useCallback, useEffect, useState } from 'react';
import { useStore } from '../stores/useStore';
import { api } from '../services/api';
import { useToast } from './Toast';
import { SkillEditor } from './SkillEditor';
import { SkillListSidebar } from './SkillListSidebar';
import { SkillAgentPanel } from './SkillAgentPanel';
import { SkillAssociationPanel } from './SkillAssociationPanel';
import { SkillRunPanel } from './SkillRunPanel';
import { startSkillStream } from '../services/skillRun';
import { VersionHistoryDialog } from './VersionHistoryDialog';
import { RecycleBinDialog } from './RecycleBinDialog';
import { ManualAssocDialog } from './ManualAssocDialog';
import { SideTab, WindowTabs, SplitHandle, toolbarIconBtn, useColWidthDrag, ColResizeHandle, useSplitDrag, SaveNameDialog, StripBtn, ColMergeCtrl, ColStackSplit, ActionConfirmDialog } from './wsCommon';
import { Target, Sparkles, Link2, Snowflake, RefreshCw, Save, FilePlus2, Play, History, Paperclip, Trash2, CircleCheck, X } from 'lucide-react';

const NEW_TEMPLATE = '# 新专项\n\n描述这个专项的分析角度、关键指标口径、计算逻辑与注意事项。\n';

/** forecast 绑定可能是能力名字符串或 {method, ...} 对象，取方法名（同 SkillAssociationPanel.forecastName）。 */
const fcName = (fc: any): string => (!fc ? '' : typeof fc === 'string' ? fc : (fc.method || ''));

/** 专项管理工作台（仿 SQL管理 布局）：左栏[专项列表/AI源生]，右上半=方法说明 + 四按钮，右下半=关联情况。
 * 支持多窗口（顶部 tab 条）并存切换，切换时方法说明 + 关联情况/内嵌快照随活动窗口恢复。 */
export const SkillWorkspace: React.FC = () => {
  const {
    skillDraft, setSkillDraft, selectedSkill, setSelectedSkill, bumpSkillFiles,
    skillWindows, activeSkillWindowId, activateSkillWindow, closeSkillWindow, newSkillWindow, syncSkillWindowInfo,
    beginSkillRun,
  } = useStore();
  // 仅可查看：无「新增/修改」权限点时，禁掉所有写动作（null = 匿名回落/未加载，视为全量）
  const myPermissions = useStore((s) => s.myPermissions);
  const canEdit = myPermissions === null || myPermissions.includes('analysis_edit');
  // 个人定制上下文：列表只显示该层级，新建/保存/自动动作强制该层级
  const scopeLevel = useStore((s) => s.scopeLevel);
  const effLevel = scopeLevel ?? skillDraft?.level ?? '通用';
  const { success, error: toastError } = useToast();
  const splitPos = useStore((s) => s.skillSplitPos);
  const setSplitPos = useStore((s) => s.setSkillSplitPos);
  const sidebarColWidths = useStore((s) => s.sidebarColWidths);
  // 侧栏列宽（复用 SQL 的 sidebarColWidths 持久化，独立 key）
  // 审计 P2-12：无持久化值时改用响应式 token var(--col-list)/var(--col-agent)；
  // 拖拽起点以拖柄所在列的实际渲染宽度为基准（见 onColWidthDragStart）
  const persistedListW = sidebarColWidths?.['skill-list'];
  const persistedAgentW = sidebarColWidths?.['skill-agent'];
  const listW: string | number = persistedListW ?? 'var(--col-list)';
  const agentW: string | number = persistedAgentW ?? 'var(--col-agent)';

  // 关联情况面板数据 = 活动窗口缓存的 info（readSkill 结果）
  const activeWindow = skillWindows.find((w) => w.id === activeSkillWindowId);
  const skillInfo = activeWindow?.info ?? null;
  // 当前专项是否已上线（缺省按上线，向后兼容历史专项）；未保存的专项按钮禁用、不展示状态
  const skillOnline = skillInfo?.online !== false;

  // 侧栏开关（默认两栏都开）
  const [showList, setShowList] = useState(true);
  const [showAgent, setShowAgent] = useState(true);
  // 侧栏向左合并（仿 SQL 管理）：merged=列表+AI源生合并一列上下堆叠；stackFlex=合并列中列表占比
  const sidebarMerged = useStore((s) => s.skillSidebarMerged);
  const setSidebarMerged = useStore((s) => s.setSkillSidebarMerged);
  const stackFlex = useStore((s) => s.skillStackFlex);
  const setStackFlex = useStore((s) => s.setSkillStackFlex);
  // 合并态下隐藏任一栏先解除合并（否则单栏残留在合并列中）
  const toggleList = () => { if (showList && sidebarMerged) setSidebarMerged(false); setShowList((v) => !v); };
  const toggleAgent = () => { if (showAgent && sidebarMerged) setSidebarMerged(false); setShowAgent((v) => !v); };
  const [busy, setBusy] = useState<string | null>(null); // associate | plan | refresh
  // 上线/下线切换进行中（按钮防连点）
  const [toggling, setToggling] = useState(false);
  // 完成后持久提示（横幅，直到下一次动作或手动关闭）：自动关联/生成快照/刷新快照 耗时久，
  // 短暂 toast（3s 自动消失）易错过，补一条常驻「已完成」提示，让用户明确结果
  const [actionDone, setActionDone] = useState<string | null>(null);
  // 后果确认（用户要求）：自动关联 / 自动生成快照 / 刷新快照 点确认后才执行
  const [confirmAction, setConfirmAction] = useState<'associate' | 'plan' | 'refresh' | null>(null);
  // 下半区页签：执行结果（本窗口跑专项）/ 关联情况
  const [bottomTab, setBottomTab] = useState<'run' | 'assoc'>('assoc');
  // 深度思考：执行时报告三模型开推理（结论更严谨但耗时久），随 preset 请求下发给后端
  const [deepThink, setDeepThink] = useState(false);
  const runRunning = useStore((s) => !!s.skillRun?.running);

  // 保存/另存为弹窗（名称 + 层级，与 SQL管理 一致；SaveNameDialog 自带 useDialog 无障碍收口）
  const [saveOpen, setSaveOpen] = useState(false);
  const [saveMode, setSaveMode] = useState<'save' | 'saveas'>('save');
  const [saveName, setSaveName] = useState('');
  const [saveLevel, setSaveLevel] = useState('通用');
  const [saveConfidentiality, setSaveConfidentiality] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  // 版本历史弹窗（P1-16）
  const [verOpen, setVerOpen] = useState(false);
  const verName = selectedSkill?.name || skillDraft?.name?.trim() || '';
  // 回收站弹窗（审计建议 8）：已删除工件版本镜像，可恢复/彻底删除
  const [recycleOpen, setRecycleOpen] = useState(false);
  // 手动关联弹窗（算法 / SQL / 知识库，人治勾选，无 LLM）
  const [manualOpen, setManualOpen] = useState(false);
  const [manualCaps, setManualCaps] = useState<any[]>([]);
  const [manualSqls, setManualSqls] = useState<string[]>([]);
  const [manualDocs, setManualDocs] = useState<string[]>([]);
  const [manualLoading, setManualLoading] = useState(false);
  const [manualSaving, setManualSaving] = useState(false);

  const reloadInfo = useCallback(async (name: string, windowId?: string | null) => {
    // windowId 缺省 = 当前激活窗口；显式传入时定向写回（P1-14：异步完成后不污染已切走的窗口）
    const target = windowId === undefined ? useStore.getState().activeSkillWindowId : windowId;
    if (!name) { syncSkillWindowInfo(null, target); return; }
    try { syncSkillWindowInfo(await api.readSkill(name), target); } catch { /* 未保存/不存在则保持现状 */ }
  }, [syncSkillWindowInfo]);

  // 选中专项 → 载入关联情况（切换窗口时 selectedSkill 变化触发）
  useEffect(() => {
    if (selectedSkill?.name) reloadInfo(selectedSkill.name);
    else syncSkillWindowInfo(null);
  }, [selectedSkill?.name, reloadInfo, syncSkillWindowInfo]);

  // AI 对话生成/调整专项时笔记自动沉淀（SkillAgentPanel 里 bumpSkillFiles 触发）→
  // 重载活动窗口 info，让右下「内嵌快照」区「专项笔记」组即时显示新笔记
  // （skillFilesVersion 原本只有列表侧栏订阅，这里补上工作台侧的刷新）
  const skillFilesVersion = useStore((s) => s.skillFilesVersion);
  useEffect(() => {
    if (selectedSkill?.name) reloadInfo(selectedSkill.name);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [skillFilesVersion]);

  const requireName = (): string | null => {
    const name = (skillDraft?.name || '').trim();
    if (!name) { toastError('请先填写专项名称'); return null; }
    return name;
  };

  // 上线/下线：下线后聊天/自由对话/Agent 不可见（不可点名/不可选/不可引用），专项管理仍可见可编辑
  const toggleOnline = async () => {
    const name = selectedSkill?.name;
    if (!name) return;
    const target = !(skillInfo?.online !== false);   // 缺省按上线（向后兼容），点击即取反
    setToggling(true);
    try {
      await api.setSkillOnline(name, target);
      syncSkillWindowInfo({ ...(skillInfo ?? {}), online: target });
      success(target ? `已上线「${name}」（聊天中可选、可引用）` : `已下线「${name}」（聊天中不可见，仅专项管理可编辑）`);
      bumpSkillFiles();
    } catch (e: any) {
      toastError(e.message || '上线/下线失败');
    } finally {
      setToggling(false);
    }
  };

  // ── 手动关联（人治勾选：算法 / SQL / 知识库，无 LLM，复用保存落盘路径） ──
  const openManual = async () => {
    const name = requireName();
    if (!name) return;
    if (!selectedSkill || selectedSkill.name !== name) {
      toastError('请先保存专项后再手动关联');
      return;
    }
    setManualLoading(true);
    // P1-14：await 期间切窗不回写（弹窗只对发起窗口生效）
    const windowId = useStore.getState().activeSkillWindowId;
    try {
      const [caps, sqls, docs] = await Promise.all([api.forecastCapabilities(), api.listSqls(), api.listDocs()]);
      if (useStore.getState().activeSkillWindowId !== windowId) {
        toastError('已切换到其它窗口，未打开手动关联');
        return;
      }
      setManualCaps((caps.capabilities || []).filter((c: any) => c && c.id));
      setManualSqls((sqls.sqls || []).map((s: any) => s.name));
      setManualDocs(docs.docs || []);
      setManualOpen(true);
    } catch (e: any) {
      toastError(e.message || '加载候选列表失败');
    } finally { setManualLoading(false); }
  };

  const confirmManual = async (sel: Record<string, string[]>) => {
    const name = requireName();
    if (!name) return;
    const content = (skillDraft?.content || '').trim() ? skillDraft!.content : (skillInfo?.content || '');
    if (!content.trim()) { toastError('方法说明为空，无法保存关联'); return; }
    const forecast = (sel.models && sel.models[0]) || null;
    const windowId = useStore.getState().activeSkillWindowId;
    setManualSaving(true);
    try {
      await api.saveSkill(name, {
        content, sqls: sel.sqls || [], docs: sel.docs || [], level: effLevel, forecast,
      });
      // P1-14：仅当仍是发起窗口才回写草稿绑定（避免切窗后污染他窗草稿）
      if (useStore.getState().activeSkillWindowId === windowId) {
        setSkillDraft({ sqls: sel.sqls || [], docs: sel.docs || [], forecast });
      }
      success('已更新手动关联');
      bumpSkillFiles();
      await reloadInfo(name, windowId);
      setManualOpen(false);
    } catch (e: any) {
      toastError(e.message || '保存关联失败');
    } finally { setManualSaving(false); }
  };

  // ── 保存 / 另存为（弹窗确认名称 + 层级；保存且改名才删旧名，另存为不删旧文件） ──
  const openSave = async (mode: 'save' | 'saveas') => {
    // 预填当前文档名：工具栏草稿名优先（用户正在编辑的名字），其次已保存名——
    // 打开已有文档再保存时无需重输名称；另存为同样预填原名（改后缀即可）
    setSaveName((skillDraft?.name || '').trim() || selectedSkill?.name || '');
    setSaveLevel(scopeLevel ?? skillDraft?.level ?? selectedSkill?.level ?? '通用');
    setSaveMode(mode);
    // 预填当前机密档位：异步读既有 meta，避免「重存旧专项默认未分级」静默清档（新专项/读失败 → 未分级）
    let conf: string | null = null;
    if (selectedSkill?.name) {
      try {
        const r = await api.readSkill(selectedSkill.name);
        conf = r?.confidentiality ?? null;
      } catch { /* 保持未分级 */ }
    }
    setSaveConfidentiality(conf);
    setSaveOpen(true);
  };

  const confirmSave = async () => {
    const name = saveName.trim();
    if (!name) { toastError('请输入专项名称'); return; }
    if (!(skillDraft?.content || '').trim()) { toastError('方法说明为空，无法保存'); return; }
    const oldName = selectedSkill?.name;
    const level = scopeLevel ?? saveLevel;
    setSaving(true);
    try {
      // P1-15：改名走服务端 rename（订阅引用跟随更新）；失败用后端 detail 提示并中止保存，不再前端删旧文件
      if (saveMode === 'save' && oldName && oldName !== name) {
        try {
          await api.renameSkill(oldName, name);
        } catch (e: any) {
          toastError(e.message || '重命名失败'); // 文件仍在旧名下，重试不受影响
          return;
        }
      }
      await api.saveSkill(name, {
        content: skillDraft!.content, sqls: skillDraft!.sqls || [], docs: skillDraft!.docs || [],
        level, forecast: skillDraft!.forecast ?? null, confidentiality: saveConfidentiality,
      });
      setSkillDraft({ name, level });
      setSelectedSkill({ name, level });
      success(saveMode === 'saveas' ? `已另存为「${name}」` : (oldName && oldName !== name ? `已重命名并保存「${name}」` : `已保存专项「${name}」`));
      bumpSkillFiles();
      setSaveOpen(false);
      await reloadInfo(name);
    } catch (e: any) {
      toastError(e.message || '保存失败');
      // 对抗审查：改名已生效但保存失败（网络抖动等）——旧名已不存在，重试 rename 会
      // 400 死锁；把选中态/草稿名指向新名，重试保存不再触发 rename
      if (saveMode === 'save' && oldName && oldName !== name) {
        setSkillDraft({ name, level });
        setSelectedSkill({ name, level });
        bumpSkillFiles();
      }
    } finally { setSaving(false); }
  };

  // ── 自动关联（一键落盘） ──
  const handleAssociate = async () => {
    const name = requireName();
    if (!name) return;
    // P1-14：异步启动时钉住窗口 id，完成后仅当该窗口仍为激活窗口才回写草稿/选中态，
    // 关联信息则按窗口 id 定向写回，避免切窗后污染他窗草稿与选中态
    const windowId = useStore.getState().activeSkillWindowId;
    setBusy('associate');
    setActionDone(null);
    try {
      const r = await api.associateSkill(name, {
        description: skillDraft?.content || '', existing_sqls: skillDraft?.sqls || [], existing_docs: skillDraft?.docs || [],
      });
      const sqls = r.sqls || [], docs = r.docs || [], forecast = r.forecast ?? skillDraft?.forecast ?? null;
      await api.saveSkill(name, {
        content: skillDraft?.content || '', sqls, docs, level: effLevel, forecast,
      });
      if (useStore.getState().activeSkillWindowId === windowId) {
        setSkillDraft({ sqls, docs, forecast });
        setSelectedSkill({ name, level: effLevel });
      }
      success(`已自动关联 SQL ${sqls.length} 条 · 文档 ${docs.length} 篇`);
      setActionDone(`自动关联完成：SQL ${sqls.length} 条 · 文档 ${docs.length} 篇`);
      bumpSkillFiles();
      await reloadInfo(name, windowId);
    } catch (e: any) {
      toastError(e.message || '自动关联失败');
    } finally { setBusy(null); }
  };

  // ── 自动生成快照（一键落盘） ──
  const handleGenerateSnapshot = async () => {
    const name = requireName();
    if (!name) return;
    // P1-14：同上，钉住窗口 id，异步完成后仅当仍是激活窗口才回写草稿/选中态
    const windowId = useStore.getState().activeSkillWindowId;
    setBusy('plan');
    setActionDone(null);
    try {
      const r = await api.planSkill(name, {
        content: skillDraft?.content || '', level: effLevel, forecast: skillDraft?.forecast ?? null,
      });
      const content = r.content || skillDraft?.content || '';
      const sqls = r.sqls || [], docs = r.docs || [], forecast = r.forecast ?? skillDraft?.forecast ?? null;
      await api.saveSkill(name, { content, sqls, docs, level: effLevel, forecast, frozen: r.frozen });
      if (useStore.getState().activeSkillWindowId === windowId) {
        setSkillDraft({ content, sqls, docs, forecast });
        setSelectedSkill({ name, level: effLevel });
      }
      success('已自动生成快照并落盘');
      setActionDone('自动生成快照完成，已保存到本专项');
      bumpSkillFiles();
      await reloadInfo(name, windowId);
    } catch (e: any) {
      toastError(e.message || '生成快照失败');
    } finally { setBusy(null); }
  };

  // ── 刷新快照 ──
  const handleRefresh = async () => {
    const name = requireName();
    if (!name) return;
    if (!selectedSkill) { toastError('请先保存专项再刷新快照'); return; }
    setBusy('refresh');
    setActionDone(null);
    // 对抗审查 LOW：钉住窗口 id，await 期间切窗不回写他窗（同 handleVerRestored 口径）
    const windowId = useStore.getState().activeSkillWindowId;
    try {
      await api.refreshSkill(name);
      success('已刷新快照');
      setActionDone('快照已刷新');
      bumpSkillFiles();
      await reloadInfo(name, windowId);
    } catch (e: any) {
      toastError(e.message || '刷新失败');
    } finally { setBusy(null); }
  };

  // ── 执行：在本窗口直接跑当前专项（preset 流程，结果流式渲染在下方「执行结果」面板），不再跳聊天窗口 ──
  const handleExecute = () => {
    const name = (skillDraft?.name || '').trim();
    if (!name) { toastError('请先填写专项名称'); return; }
    // 按名加载已保存专项（绑定 SQL / 快照 / 方法说明），未保存的名称无法执行
    if (!selectedSkill || selectedSkill.name !== name) {
      toastError('请先保存专项后再执行（当前名称尚未保存）');
      return;
    }
    const seq = beginSkillRun(name);
    startSkillStream(name, seq, deepThink); // 流在模块级跑，切走导航结果不丢（同聊天 iframe 保活）
    setBottomTab('run');
    success(`正在本窗口执行专项「${name}」`);
  };

  const handleNew = () => {
    newSkillWindow({ name: '', level: scopeLevel ?? '通用', content: NEW_TEMPLATE, sqls: [], docs: [], forecast: null });
  };

  // ── 版本历史回滚后：重新加载工件内容（草稿 + 选中态 + 关联情况）+ bump 列表（P1-16） ──
  const handleVerRestored = async () => {
    // P1-14：钉住窗口 id——回滚后的异步重载只写回发起时的窗口，切窗不污染他窗草稿/选中态
    const windowId = useStore.getState().activeSkillWindowId;
    const name = selectedSkill?.name;
    bumpSkillFiles();
    if (!name) return;
    try {
      const r = await api.readSkill(name);
      if (useStore.getState().activeSkillWindowId === windowId) {
        setSkillDraft({
          name: r.name || name, content: r.content || '', level: r.level || '通用',
          sqls: r.sqls || [], docs: r.docs || [], forecast: r.forecast || null,
        });
        setSelectedSkill({ name: r.name || name, level: r.level || '通用' });
      }
      await reloadInfo(name, windowId);
    } catch (e: any) {
      toastError(e.message || '重新加载失败');
    }
  };

  // 上下分屏拖拽 + 侧栏列宽拖拽（P1-12 收敛：共享 hook，审计 P2-12 的 pointer 捕获/键盘微调语义不变）
  const splitDrag = useSplitDrag('skill-split-container', {
    setPos: setSplitPos,
    getPos: () => useStore.getState().skillSplitPos,
  });
  const colDrag = useColWidthDrag();

  return (
    <div className="h-full flex flex-col bg-background text-foreground" style={{ minHeight: 0 }}>
      <div style={{ flex: 1, display: 'flex', minHeight: 0, overflow: 'hidden' }}>
        {/* 左侧 Tab 条（审计 P2-12：宽度走响应式 token --col-iconbar） */}
        <div style={{ width: 'var(--col-iconbar)', flexDirection: 'column', backgroundColor: 'var(--surface-0)', borderRight: '1px solid var(--border-light)', flexShrink: 0, display: 'flex' }}>
          <SideTab icon={<Target size={15} />} label="专项列表" active={showList} onClick={toggleList} />
          <SideTab icon={<Sparkles size={15} style={{ color: 'var(--accent-amber)' }} />} label="AI源生" active={showAgent} onClick={toggleAgent} />
        </div>

        {/* 侧栏列（列宽可拖拽，同 SQL 管理；AI源生 栏 ◀ 并入列表列上下堆叠，▶ 恢复独立列）。
            两栏常驻挂载、合并态只切布局（对抗审查 correctness 轮）：合并/恢复/隐藏若走分支切换
            会整树卸载重挂 AI 面板，把进行中的深度分析流孤立、答复静默丢失 */}
        <div style={{
          position: 'relative',
          display: 'flex',
          flexDirection: sidebarMerged ? 'column' : 'row',
          width: sidebarMerged ? listW : undefined,
          flexShrink: 0,
          minHeight: 0,
          overflowX: 'hidden',
          borderRight: '1px solid var(--border-light)',
        }}>
          {showList && (
            <div key="col-list" className="sidebar-item" style={{
              position: 'relative', display: 'flex', flexDirection: 'column', minHeight: 0, flexShrink: 0,
              ...(sidebarMerged
                ? { flex: stackFlex }
                : { width: listW, borderRight: '1px solid var(--border-light)' }),
            }}>
              <SkillListSidebar onClose={() => { setSidebarMerged(false); setShowList(false); }} />
              {sidebarMerged
                ? <ColMergeCtrl onRestore={() => setSidebarMerged(false)} />
                : (<>
                    {/* 列表列恒为最左列：◀ 禁用态（对齐 SQL 管理 colIdx<=0），仅展示能力 */}
                    <ColMergeCtrl mergeDisabled />
                    <ColResizeHandle drag={colDrag} colKey="skill-list" label="专项列表" />
                  </>)}
            </div>
          )}
          {sidebarMerged && <ColStackSplit value={stackFlex} onFlex={setStackFlex} label="专项列表与 AI源生分栏" />}
          {showAgent && (
            <div key="col-agent" className="sidebar-item" style={{
              position: 'relative', display: 'flex', flexDirection: 'column', minHeight: 0, flexShrink: 0,
              ...(sidebarMerged
                ? { flex: 1 - stackFlex }
                : { width: agentW }),
            }}>
              <SkillAgentPanel onClose={() => { setSidebarMerged(false); setShowAgent(false); }} />
              {sidebarMerged
                ? <ColMergeCtrl onRestore={() => setSidebarMerged(false)} />
                : (showList && <ColMergeCtrl onMergeLeft={() => setSidebarMerged(true)} />)}
              {!sidebarMerged && <ColResizeHandle drag={colDrag} colKey="skill-agent" label="AI源生" />}
            </div>
          )}
          {sidebarMerged && <ColResizeHandle drag={colDrag} colKey="skill-list" label="侧栏" />}
        </div>

        {/* 中间：多窗口 tab 条 + 方法说明/关联情况分屏 */}
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0, overflow: 'hidden', alignSelf: 'stretch' }}>
          <WindowTabs
            tabs={skillWindows}
            activeId={activeSkillWindowId}
            onSwitch={activateSkillWindow}
            onClose={closeSkillWindow}
            onNew={handleNew}
            newTitle="新建专项窗口"
          />

          {/* 完成后持久提示横幅（自动关联/生成快照/刷新快照）：常驻到下一次动作或手动关闭 */}
          {actionDone && (
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 10px', backgroundColor: 'var(--tint-green-bg)', borderBottom: '1px solid var(--tint-green-border)', flexShrink: 0 }}>
              <CircleCheck size={13} style={{ color: 'var(--success-text)', flexShrink: 0 }} />
              <span style={{ fontSize: 12, color: 'var(--text-primary)', flex: 1 }}>{actionDone}</span>
              <button onClick={() => setActionDone(null)} aria-label="关闭完成提示" style={{ background: 'none', border: 'none', color: 'var(--text-muted)', cursor: 'pointer', padding: 0, display: 'flex', flexShrink: 0 }}>
                <X size={13} />
              </button>
            </div>
          )}

          <div id="skill-split-container" style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0, overflow: 'hidden' }}>
            <div style={{ height: `${splitPos}%`, display: 'flex', flexDirection: 'row', minHeight: 0, flexShrink: 0, overflow: 'hidden' }}>
              {/* 竖条小工具条（审计 P2-12：宽度走响应式 token --col-toolstrip）：执行 / 自动关联 / 自动生成快照 / 刷新快照 / 保存 / 另存为 */}
              <div style={{ width: 'var(--col-toolstrip)', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 5, paddingTop: 6, backgroundColor: 'var(--surface-1)', borderRight: '1px solid var(--border-light)', flexShrink: 0 }}>
                <StripBtn icon={<Play size={9} />} bg="var(--accent-blue)" onClick={handleExecute} disabled={!canEdit}
                  title={canEdit ? '执行（在本窗口运行并展示结果）' : '仅可查看（无新增/修改权限）'} />
                <StripBtn icon={<Link2 size={9} />} bg="var(--accent-blue)" onClick={() => setConfirmAction('associate')} disabled={busy !== null || !canEdit}
                  busy={busy === 'associate'} dimmed={busy !== null || !canEdit}
                  title={canEdit ? '自动关联' : '仅可查看（无新增/修改权限）'} />
                <StripBtn icon={<Paperclip size={9} />} bg="var(--accent-blue-dim)" iconColor="var(--strip-icon-on-dim)" onClick={openManual} disabled={busy !== null || manualLoading || !canEdit}
                  busy={manualLoading} dimmed={busy !== null || manualLoading || !canEdit}
                  title={canEdit ? '手动关联（算法 / SQL / 知识库）' : '仅可查看（无新增/修改权限）'} />
                <StripBtn icon={<Snowflake size={9} />} bg="var(--accent-amber)" onClick={() => setConfirmAction('plan')} disabled={busy !== null || !canEdit}
                  busy={busy === 'plan'} dimmed={busy !== null || !canEdit}
                  title={canEdit ? '自动生成快照' : '仅可查看（无新增/修改权限）'} />
                <StripBtn icon={<RefreshCw size={9} />} bg="#16a085" onClick={() => setConfirmAction('refresh')} disabled={busy !== null || !canEdit}
                  busy={busy === 'refresh'} dimmed={busy !== null || !canEdit}
                  title={canEdit ? '刷新快照' : '仅可查看（无新增/修改权限）'} />
                <StripBtn icon={<Save size={9} />} bg="#27ae60" onClick={() => openSave('save')} disabled={!canEdit}
                  title={canEdit ? '保存（选择层级）' : '仅可查看（无新增/修改权限）'} />
                <StripBtn icon={<FilePlus2 size={9} />} bg="var(--accent-blue-dim)" iconColor="var(--strip-icon-on-dim)" onClick={() => openSave('saveas')} disabled={!canEdit}
                  title={canEdit ? '另存为（选择层级）' : '仅可查看（无新增/修改权限）'} />
              </div>

              <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0, overflow: 'hidden' }}>
                {/* 工具栏：名称 + 版本历史（执行=切到 AI 对话窗口跑当前专项；审计 P2-12：窄屏可换行） */}
                <div style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 6, padding: '6px 10px', borderBottom: '1px solid var(--border-light)', flexShrink: 0 }}>
                  <label style={{ fontSize: 11, color: 'var(--text-secondary)', display: 'flex', alignItems: 'center', gap: 4, flex: 1, minWidth: 0 }}>
                    <span style={{ flexShrink: 0 }}>名称</span>
                    <input value={skillDraft?.name || ''} onChange={(e) => setSkillDraft({ name: e.target.value })}
                      placeholder="专项名称" disabled={!canEdit}
                      style={{ flex: 1, minWidth: 0, padding: '4px 8px', borderRadius: 4, border: '1px solid var(--text-muted)', backgroundColor: 'var(--surface-1)', color: 'var(--text-on-accent)', fontSize: 12, outline: 'none', opacity: canEdit ? 1 : 0.6 }} />
                  </label>
                  <label title="执行时报告三模型开「深度思考」（推理），结论更严谨但耗时久（可能数分钟）；关闭可快速获取报告"
                    style={{ display: 'inline-flex', alignItems: 'center', gap: 4, fontSize: 11, color: 'var(--text-secondary)', cursor: 'pointer', whiteSpace: 'nowrap' }}>
                    <input type="checkbox" checked={deepThink} onChange={(e) => setDeepThink(e.target.checked)}
                      style={{ accentColor: 'var(--accent-blue)' }} />
                    <span>💭 深度思考</span>
                  </label>
                  {/* 上线/下线状态标识 + 切换按钮：下线后聊天/自由对话/Agent 不可见，专项管理仍可见可编辑 */}
                  <button onClick={toggleOnline} disabled={!selectedSkill || !canEdit || toggling}
                    aria-label={selectedSkill ? (skillOnline ? `下线 ${selectedSkill.name}` : `上线 ${selectedSkill.name}`) : '上线/下线'}
                    style={{
                      display: 'inline-flex', alignItems: 'center', gap: 5, whiteSpace: 'nowrap', flexShrink: 0,
                      fontSize: 11, fontWeight: 600, padding: '3px 9px', borderRadius: 4,
                      color: skillOnline ? 'var(--success-text)' : 'var(--text-muted)',
                      background: skillOnline ? 'var(--tint-green-bg)' : 'var(--surface-2)',
                      border: '1px solid ' + (skillOnline ? 'var(--tint-green-border)' : 'var(--border-light)'),
                      cursor: selectedSkill && canEdit && !toggling ? 'pointer' : 'not-allowed',
                      opacity: selectedSkill ? 1 : 0.55,
                    }}
                    title={!selectedSkill ? '请先保存专项（上线/下线仅对已保存专项可用）'
                      : !canEdit ? '仅可查看（无新增/修改权限）'
                      : skillOnline ? '已上线，点击下线（聊天中不再可选/可引用）' : '已下线，点击上线（开放给聊天选择/引用）'}>
                    <span style={{ width: 7, height: 7, borderRadius: '50%', background: skillOnline ? 'var(--success-text)' : 'var(--text-inactive)', flexShrink: 0 }} />
                    {toggling ? '…' : skillOnline ? '已上线' : '已下线'}
                  </button>
                  <button onClick={() => setVerOpen(true)} disabled={!selectedSkill} aria-label="版本历史" title={selectedSkill ? '版本历史' : '请先保存专项（版本历史仅对已保存专项可用）'}
                    style={{ ...toolbarIconBtn, opacity: selectedSkill ? 1 : 0.4, cursor: selectedSkill ? 'pointer' : 'not-allowed' }}>
                    <History size={13} style={{ color: 'var(--history-icon)' }} />
                  </button>
                  {/* 审计建议 8：回收站入口（已删工件版本镜像，保留 30 天，可恢复/彻底删除） */}
                  <button onClick={() => setRecycleOpen(true)} aria-label="回收站" title="回收站（已删除工件，可恢复/彻底删除）"
                    style={toolbarIconBtn}>
                    <Trash2 size={13} />
                  </button>
                </div>
                <div style={{ flex: 1, minHeight: 0, borderBottom: '1px solid var(--border-light)' }}>
                  <SkillEditor />
                </div>
              </div>
            </div>

            {/* 上下分屏分隔条（审计 P2-12：pointer 捕获触屏可拖；value/onDelta 支持键盘方向键微调） */}
            <div
              onPointerDown={splitDrag.onPointerDown}
              onPointerMove={splitDrag.onPointerMove}
              onPointerUp={splitDrag.onPointerUp}
              onPointerCancel={splitDrag.onPointerUp}
            >
              <SplitHandle value={splitPos} onDelta={splitDrag.onKeyDelta} />
            </div>

            <div style={{ height: `${100 - splitPos}%`, display: 'flex', flexDirection: 'column', minHeight: 0, flexShrink: 0, overflow: 'hidden' }}>
              {/* 下半区页签：执行结果 / 关联情况（执行中在「执行结果」页签显示运行中圆点） */}
              <div style={{ display: 'flex', gap: 0, padding: '0 10px', borderBottom: '1px solid var(--border-light)', flexShrink: 0, backgroundColor: 'var(--surface-1)' }}>
                {([
                  { key: 'run', label: '执行结果', dot: runRunning },
                  { key: 'assoc', label: '关联情况', dot: false },
                ] as const).map((t) => (
                  <button
                    key={t.key}
                    onClick={() => setBottomTab(t.key)}
                    aria-current={bottomTab === t.key ? 'page' : undefined}
                    style={{
                      padding: '5px 12px', fontSize: 11, cursor: 'pointer', background: 'transparent', border: 'none',
                      borderBottom: `2px solid ${bottomTab === t.key ? 'var(--accent-blue)' : 'transparent'}`,
                      color: bottomTab === t.key ? 'var(--text-primary)' : 'var(--text-muted)',
                      fontWeight: bottomTab === t.key ? 600 : 400,
                      display: 'inline-flex', alignItems: 'center', gap: 4,
                    }}>
                    {t.dot && <span style={{ width: 7, height: 7, borderRadius: '50%', background: 'var(--accent-blue)', animation: 'pulse 1.5s ease-in-out infinite' }} />}
                    {t.label}
                  </button>
                ))}
              </div>
              <div style={{ flex: 1, minHeight: 0, overflow: 'hidden' }}>
                {bottomTab === 'run'
                  ? <SkillRunPanel onOpenAgent={() => { setShowAgent(true); }} />
                  : <SkillAssociationPanel data={skillInfo} onRefresh={() => { if (selectedSkill?.name) reloadInfo(selectedSkill.name); }} />}
              </div>
            </div>
          </div>
        </div>
      </div>

      {verOpen && verName && (
        <VersionHistoryDialog kind="skill" name={verName} onClose={() => setVerOpen(false)} onRestored={handleVerRestored} />
      )}

      {/* 审计建议 8：回收站（已删工件版本镜像，恢复/彻底删除需 analysis_delete） */}
      <RecycleBinDialog open={recycleOpen} onClose={() => setRecycleOpen(false)} />

      {/* 手动关联弹窗：算法（单选）/ SQL（多选）/ 知识库（多选），确认后复用保存路径落盘 */}
      {manualOpen && (
        <ManualAssocDialog
          title={`手动关联 — 「${(skillDraft?.name || '').trim()}」`}
          saving={manualSaving}
          onCancel={() => setManualOpen(false)}
          onConfirm={confirmManual}
          sections={[
            {
              key: 'models', label: '算法（预测能力）', multi: false,
              options: manualCaps.map((c: any) => ({
                value: c.id, label: c.name || c.id,
                tag: c.input === 'upload' ? '离线上传' : (c.granularity ? `粒度 ${c.granularity}` : ''),
              })),
              selected: [fcName(skillInfo?.forecast ?? skillDraft?.forecast ?? null)].filter(Boolean),
              emptyText: '（暂无可用算法能力）',
            },
            {
              key: 'sqls', label: 'SQL', multi: true,
              options: manualSqls.map((n) => ({ value: n, label: n })),
              selected: skillInfo?.sqls ?? skillDraft?.sqls ?? [],
              emptyText: '（暂无可用 SQL）',
            },
            {
              key: 'docs', label: '知识库文档', multi: true,
              options: manualDocs.map((n) => ({ value: n, label: n })),
              selected: skillInfo?.docs ?? skillDraft?.docs ?? [],
              emptyText: '（暂无可用知识库文档）',
            },
          ]}
        />
      )}

      {/* 后果确认弹窗（用户要求）：自动关联 / 自动生成快照 / 刷新快照，点确认后才执行 */}
      <ActionConfirmDialog
        open={confirmAction !== null}
        busy={busy !== null}
        title={confirmAction === 'associate' ? '确认自动关联' : confirmAction === 'plan' ? '确认自动生成快照' : '确认刷新快照'}
        lines={confirmAction === 'associate' ? [
          'AI 将分析本专项的方法说明，从当前游戏可用的取数 SQL 与知识库文档中自动挑选关联对象，并直接保存到本专项。',
          '已有关联的 SQL 与文档全部保留（只增不减）；AI 新挑选的会加入绑定列表。',
          '预测能力绑定：AI 有建议时会替换原绑定，没有建议则保持不变。',
          '不会改动方法说明（skill.md）。',
        ] : confirmAction === 'plan' ? [
          'AI 会按本专项方法说明规划绑定 SQL（已有绑定→改写，缺失→生成），把知识库文档精简为要点，并冻结保存进本专项目录（覆盖同名旧快照）。',
          '方法说明（skill.md）本身也可能被 AI 规范化改写后一并保存。',
          '之后执行本专项时使用的是这些冻结快照；全局 SQL 库的源文件不受影响。',
          'AI 改写耗时较长，请耐心等待。',
        ] : [
          '对源已改动（漂移）的绑定 SQL/文档，重新改写并覆盖本专项内的冻结快照；未漂移的保持不变。',
          '若方法说明（skill.md）自上次生成快照后已改动，则全部绑定重写（否则只刷新漂移件）。',
          '执行本专项时使用的冻结快照将被替换为新版本。',
        ]}
        onCancel={() => setConfirmAction(null)}
        onConfirm={() => {
          const a = confirmAction;
          setConfirmAction(null);
          if (a === 'associate') handleAssociate();
          else if (a === 'plan') handleGenerateSnapshot();
          else if (a === 'refresh') handleRefresh();
        }}
      />

      {/* 保存 / 另存为弹窗（P1-12 收敛：共享 SaveNameDialog） */}
      <SaveNameDialog
        open={saveOpen}
        title={saveMode === 'save' ? '保存专项' : '另存为专项'}
        label="名称"
        placeholder="专项名称"
        name={saveName}
        onName={setSaveName}
        scopeLevel={scopeLevel ?? null}
        level={saveLevel}
        onLevel={setSaveLevel}
        confidentiality={saveConfidentiality}
        onConfidentiality={setSaveConfidentiality}
        saving={saving}
        onCancel={() => setSaveOpen(false)}
        onConfirm={confirmSave}
      />
    </div>
  );
};

export default SkillWorkspace;
