import React, { useCallback, useEffect, useState } from 'react';
import { useStore } from '../stores/useStore';
import { api } from '../services/api';
import { useToast } from './Toast';
import { ModelsEditor } from './ModelsEditor';
import { ModelsListSidebar } from './ModelsListSidebar';
import { ModelsAgentPanel } from './ModelsAgentPanel';
import { ModelsAssociationPanel } from './ModelsAssociationPanel';
import { VersionHistoryDialog } from './VersionHistoryDialog';
import { RecycleBinDialog } from './RecycleBinDialog';
import { ManualAssocDialog } from './ManualAssocDialog';
import { SideTab, SplitHandle, overlayStyle, dialogStyle, saveCancelBtn, dangerBtn, toolbarIconBtn, useColWidthDrag, ColResizeHandle, useSplitDrag, StripBtn, ColMergeCtrl, ColStackSplit, ActionConfirmDialog } from './wsCommon';
import { useDialog } from '../lib/useDialog';
import { Boxes, Sparkles, Link2, Snowflake, RefreshCw, Save, Trash2, Pencil, Lock, History, Paperclip } from 'lucide-react';

const EMPTY_MODEL = {
  name: '', desc: '', input: 'sql' as const, granularity: 'day', sql: '',
  hist_days: null, hist_months: null, horizon_days: null, horizon_months: null, window: null,
  code: '', sources: [] as any[], transformed_sqls: {} as Record<string, string | null>, problems: [] as string[], builtin: false,
};

/** 算法管理工作台（仿专项管理，去层级）：左栏[模型列表/AI源生]，右上半=名称/描述/输入 + 代码 + 竖排按钮，右下半=关联情况。单草稿。
 *  默认只读（view），点竖排「编辑」解锁后改名称/描述/代码并保存；参数由「自动关联 SQL」/AI 推断回填，不再提供手工参数面板。 */
export const ModelsWorkspace: React.FC = () => {
  const { modelDraft, setModelDraft, selectedModel, setSelectedModel, bumpModelFiles } = useStore();
  const myPermissions = useStore((s) => s.myPermissions);
  const canEdit = myPermissions === null || myPermissions.includes('analysis_edit');
  const canDelete = myPermissions === null || myPermissions.includes('analysis_delete');
  const { success, error: toastError } = useToast();
  const splitPos = useStore((s) => s.modelSplitPos);
  const setSplitPos = useStore((s) => s.setModelSplitPos);
  const sidebarColWidths = useStore((s) => s.sidebarColWidths);
  // 审计 P2-12：默认宽度走响应式 token（窄屏自动收缩），用户拖拽后的自定义像素值仍存 zustand
  const listW: number | string = sidebarColWidths?.['model-list'] || 'var(--col-list)';
  const agentW: number | string = sidebarColWidths?.['model-agent'] || 'var(--col-agent)';

  const [showList, setShowList] = useState(true);
  const [showAgent, setShowAgent] = useState(true);
  // 侧栏向左合并（仿 SQL 管理）：merged=列表+AI源生合并一列上下堆叠；stackFlex=合并列中列表占比
  const sidebarMerged = useStore((s) => s.modelSidebarMerged);
  const setSidebarMerged = useStore((s) => s.setModelSidebarMerged);
  const stackFlex = useStore((s) => s.modelStackFlex);
  const setStackFlex = useStore((s) => s.setModelStackFlex);
  // 合并态下隐藏任一栏先解除合并（否则单栏残留在合并列中）
  const toggleList = () => { if (showList && sidebarMerged) setSidebarMerged(false); setShowList((v) => !v); };
  const toggleAgent = () => { if (showAgent && sidebarMerged) setSidebarMerged(false); setShowAgent((v) => !v); };
  const [editing, setEditing] = useState(false); // 点「编辑」解锁；选中既有模型 → 只读，新建/未保存 → 可编辑
  const [busy, setBusy] = useState<string | null>(null); // associate | plan | refresh
  // 后果确认（用户要求）：自动关联 SQL / 生成 SQL 快照 / 刷新快照 点确认后才执行
  const [confirmAction, setConfirmAction] = useState<'associate' | 'plan' | 'refresh' | null>(null);
  const [modelInfo, setModelInfo] = useState<any>(null);
  const [deleteOpen, setDeleteOpen] = useState(false);
  // 审计 P2-12：删除确认弹窗无障碍（Escape 关闭 + 聚焦管理）
  const deleteDialogRef = useDialog(deleteOpen, () => setDeleteOpen(false));
  // 版本历史弹窗（P1-16）
  const [verOpen, setVerOpen] = useState(false);
  const verName = selectedModel || (modelDraft?.name?.trim() || '');
  // 回收站弹窗（审计建议 8）：已删除工件版本镜像，可恢复/彻底删除
  const [recycleOpen, setRecycleOpen] = useState(false);
  // 手动关联 SQL 弹窗（人治单选，无 LLM；改绑后旧专属快照失效，需重新「生成SQL快照」）
  const [manualOpen, setManualOpen] = useState(false);
  const [manualSqls, setManualSqls] = useState<string[]>([]);
  const [manualLoading, setManualLoading] = useState(false);
  const [manualSaving, setManualSaving] = useState(false);

  const draft = modelDraft || EMPTY_MODEL;
  const builtin = draft.builtin;
  const inputIsSql = draft.input === 'sql';
  // 只读 = 内置 | 无权限 | 未解锁编辑
  const readOnly = builtin || !canEdit || !editing;

  const reloadInfo = useCallback(async (name: string) => {
    if (!name) { setModelInfo(null); return; }
    try { setModelInfo(await api.readModel(name)); } catch { /* 未保存/不存在则保持现状 */ }
  }, []);

  useEffect(() => {
    if (selectedModel) reloadInfo(selectedModel);
    else setModelInfo(null);
  }, [selectedModel, reloadInfo]);

  // 选中既有模型 → 只读；新建/未保存草稿 → 可编辑
  useEffect(() => {
    setEditing(selectedModel === null);
  }, [selectedModel]);

  const requireName = (): string | null => {
    const name = (draft.name || '').trim();
    if (!name) { toastError('请先填写模型名称'); return null; }
    return name;
  };

  // 保存当前草稿（可选覆盖字段）。返回是否成功；成功后回到只读（锁定）。
  const saveDraft = useCallback(async (overrides?: Partial<typeof EMPTY_MODEL>): Promise<boolean> => {
    const d = { ...(useStore.getState().modelDraft || EMPTY_MODEL), ...(overrides || {}) };
    const name = (d.name || '').trim();
    if (!name) { toastError('请先填写模型名称'); return false; }
    if (!(d.code || '').trim()) { toastError('模型代码为空，无法保存'); return false; }
    const isUpload = d.input === 'upload';
    const oldName = useStore.getState().selectedModel;
    try {
      // 审计建议 7：改名走服务端 rename（主文件 + 元数据 + 版本库一并迁移）；
      // 失败用后端 detail 提示并中止保存，不再前端「存新名 + 删旧名」两段式
      if (oldName && oldName !== name) {
        try {
          await api.renameModel(oldName, name);
        } catch (e: any) {
          toastError(e.message || '重命名失败'); // 文件仍在旧名下，重试不受影响
          return false;
        }
      }
      await api.saveModel({
        name, code: d.code, desc: d.desc || '', input: d.input || 'sql',
        granularity: d.granularity || 'day',
        sql: isUpload ? '' : (d.sql || ''),
        hist_days: d.hist_days, hist_months: d.hist_months,
        horizon_days: d.horizon_days, horizon_months: d.horizon_months,
        window: d.window, sources: d.sources || [],
        transformed_sqls: isUpload ? {} : (d.transformed_sqls || {}),
      });
      setModelDraft({ name });
      setSelectedModel(name);
      setEditing(false); // 保存后回只读
      bumpModelFiles();
      await reloadInfo(name);
      success(oldName && oldName !== name ? `已重命名并保存「${name}」` : `已保存模型「${name}」`);
      return true;
    } catch (e: any) {
      toastError(e.message || '保存失败');
      // 对抗审查：改名已生效但保存失败（网络抖动等）——旧名已不存在，重试 rename 会
      // 400 死锁；把选中态指向新名（draft 名字已是新名），重试保存不再触发 rename
      if (oldName && oldName !== name) {
        setModelDraft({ name });
        setSelectedModel(name);
        bumpModelFiles();
      }
      return false;
    }
  }, [bumpModelFiles, reloadInfo, setModelDraft, setSelectedModel, success, toastError]);

  // ── 自动关联 SQL（一键落盘） ──
  const handleAssociate = async () => {
    if (!requireName()) return;
    setBusy('associate');
    // 对抗审查 MEDIUM：await 期间切到其它模型/新建时，不回写草稿、不落盘
    const pinnedSelection = useStore.getState().selectedModel;
    try {
      const r = await api.associateModel(draft.desc || '');
      if (useStore.getState().selectedModel !== pinnedSelection) {
        toastError('已切换到其它模型，自动关联结果未应用');
        return;
      }
      const patch = {
        sql: r.sql || '',
        granularity: r.granularity || 'day',
        hist_days: r.hist_days ?? null,
        hist_months: r.hist_months ?? null,
        horizon_days: r.horizon_days ?? null,
        horizon_months: r.horizon_months ?? null,
        desc: r.desc || draft.desc || '',
      };
      setModelDraft(patch);
      const ok = await saveDraft(patch);
      if (ok) success(r.sql ? `已自动关联取数 SQL「${r.sql}」` : '未匹配到取数 SQL（可切到「离线上传」）');
    } catch (e: any) {
      toastError(e.message || '自动关联失败');
    } finally { setBusy(null); }
  };

  // ── 生成 SQL 快照（一键落盘） ──
  const handleGenerateSnapshot = async () => {
    if (!requireName()) return;
    if (!(draft.sql || '').trim()) { toastError('请先填写/自动关联取数 SQL'); return; }
    setBusy('plan');
    // 对抗审查 MEDIUM：await 期间切到其它模型/新建时，不回写草稿、不落盘
    const pinnedSelection = useStore.getState().selectedModel;
    try {
      const r = await api.planModel(draft.name.trim(), {
        description: draft.desc || '', code: draft.code || '', sql: draft.sql,
      });
      if (useStore.getState().selectedModel !== pinnedSelection) {
        toastError('已切换到其它模型，快照结果未应用');
        return;
      }
      const patch = {
        transformed_sqls: { [draft.sql]: r.transformed_sql ?? null },
        sources: r.sources || [],
      };
      setModelDraft(patch);
      const ok = await saveDraft(patch);
      if (ok) success('已生成 SQL 快照并落盘');
    } catch (e: any) {
      toastError(e.message || '生成快照失败');
    } finally { setBusy(null); }
  };

  // ── 手动关联 SQL（人治单选，无 LLM，复用 saveDraft 落盘） ──
  const openManual = async () => {
    if (!requireName()) return;
    setManualLoading(true);
    // 对抗审查 MEDIUM：await 期间切到其它模型/新建时不打开弹窗
    const pinnedSelection = useStore.getState().selectedModel;
    try {
      const r = await api.listSqls();
      if (useStore.getState().selectedModel !== pinnedSelection) {
        toastError('已切换到其它模型，未打开手动关联');
        return;
      }
      setManualSqls((r.sqls || []).map((s: any) => s.name));
      setManualOpen(true);
    } catch (e: any) {
      toastError(e.message || '加载 SQL 列表失败');
    } finally { setManualLoading(false); }
  };

  const confirmManual = async (sel: Record<string, string[]>) => {
    const picked = ((sel.sql || [])[0] || '').trim();
    const cur = useStore.getState().modelDraft || EMPTY_MODEL;
    setManualSaving(true);
    try {
      // 改绑 SQL：清空旧专属快照与 SQL 类溯源（服务端随 transformed_sqls 空删除旧冻结件；
      // 新 SQL 的溯源与快照由「生成SQL快照」重建）
      const patch = {
        sql: picked,
        transformed_sqls: {} as Record<string, string | null>,
        sources: (cur.sources || []).filter((s: any) => s && s.kind !== 'sql'),
      };
      setModelDraft(patch);
      const ok = await saveDraft(patch);
      if (!ok) return;
      setManualOpen(false);
      success(picked ? `已手动关联取数 SQL「${picked}」，如需专属快照请点「生成SQL快照」` : '已清除取数 SQL 关联');
    } catch (e: any) {
      toastError(e.message || '保存关联失败');
    } finally { setManualSaving(false); }
  };

  // ── 刷新快照 ──
  const handleRefresh = async () => {
    const name = requireName();
    if (!name) return;
    if (!selectedModel || selectedModel !== name) { toastError('请先保存模型再刷新快照'); return; }
    setBusy('refresh');
    try {
      await api.refreshModel(name);
      success('已刷新快照');
      bumpModelFiles();
      // 对抗审查 LOW：await 期间切走不回写（同 handleVerRestored 口径）
      if (useStore.getState().selectedModel === name) {
        await reloadInfo(name);
      }
    } catch (e: any) {
      toastError(e.message || '刷新失败');
    } finally { setBusy(null); }
  };

  const handleDelete = async () => {
    // 对抗审查：删除必须针对「已保存的模型」（selectedModel）——按草稿名删会把
    // 草稿改名未保存时 draft.name 指向的其它同名模型误删
    const name = selectedModel;
    if (!name) return;
    setDeleteOpen(false);
    try {
      await api.deleteModel(name);
      if (selectedModel === name) { setSelectedModel(null); setModelDraft(null); }
      setModelInfo(null);
      success(`已删除模型「${name}」`);
      bumpModelFiles();
    } catch (e: any) {
      toastError(e.message || '删除失败');
    }
  };

  // ── 版本历史回滚后：重新加载模型内容（映射同列表侧栏，builtin 由当前草稿保留）+ bump 列表（P1-16） ──
  const handleVerRestored = async () => {
    const name = selectedModel || draft.name.trim();
    bumpModelFiles();
    if (!name) return;
    try {
      const r = await api.readModel(name);
      // P1-14：单草稿工作台同样防串——重载期间切到别的模型/新建时，不回写草稿与关联面板
      const stillSelected = useStore.getState().selectedModel === name;
      if (stillSelected) {
        const meta = r.meta || {};
        setModelDraft({
          name: r.name || name,
          desc: meta.desc || '',
          input: meta.input || 'sql',
          granularity: meta.granularity || 'day',
          sql: meta.sql || '',
          hist_days: meta.hist_days ?? null,
          hist_months: meta.hist_months ?? null,
          horizon_days: meta.horizon_days ?? null,
          horizon_months: meta.horizon_months ?? null,
          window: meta.window ?? null,
          code: r.code || '',
          sources: r.sources || [],
          transformed_sqls: (r.model_sql && meta.sql) ? { [meta.sql]: r.model_sql } : {},
          problems: r.problems || [],
        });
        setSelectedModel(r.name || name);
        setEditing(false);
        await reloadInfo(r.name || name);
      }
    } catch (e: any) {
      toastError(e.message || '重新加载失败');
    }
  };

  // 上下分屏拖拽 + 侧栏列宽拖拽（P1-12 收敛：共享 hook，审计 P2-12 的 pointer 捕获/键盘微调语义不变）
  const splitDrag = useSplitDrag('model-split-container', {
    setPos: setSplitPos,
    getPos: () => useStore.getState().modelSplitPos,
    min: 10,
    max: 90,
  });
  const colDrag = useColWidthDrag();

  // 竖排按钮 disabled 提示：无权限 vs 未解锁
  const tip = (label: string) =>
    !canEdit ? '仅可查看（无新增/修改权限）' : (!editing ? `先点「编辑」解锁，再${label}` : label);

  return (
    <div className="h-full flex flex-col bg-background text-foreground" style={{ minHeight: 0 }}>
      <div style={{ flex: 1, display: 'flex', minHeight: 0, overflow: 'hidden' }}>
        {/* 左侧 Tab 条（审计 P2-12：宽度走 --col-iconbar token） */}
        <div style={{ width: 'var(--col-iconbar)', flexDirection: 'column', backgroundColor: 'var(--surface-0)', borderRight: '1px solid var(--border-light)', flexShrink: 0, display: 'flex' }}>
          <SideTab icon={<Boxes size={15} />} label="模型列表" active={showList} onClick={toggleList} />
          <SideTab icon={<Sparkles size={15} style={{ color: 'var(--accent-amber)' }} />} label="AI源生" active={showAgent} onClick={toggleAgent} />
        </div>

        {/* 侧栏列（默认宽度走 token；AI源生 栏 ◀ 并入列表列上下堆叠，▶ 恢复独立列）。
            两栏常驻挂载、合并态只切布局（对抗审查 correctness 轮）：分支切换会卸载重挂 AI 面板，
            把进行中的深度分析流孤立、答复静默丢失 */}
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
              <ModelsListSidebar onClose={() => { setSidebarMerged(false); setShowList(false); }} />
              {sidebarMerged
                ? <ColMergeCtrl onRestore={() => setSidebarMerged(false)} />
                : (<>
                    {/* 列表列恒为最左列：◀ 禁用态（对齐 SQL 管理 colIdx<=0），仅展示能力 */}
                    <ColMergeCtrl mergeDisabled />
                    <ColResizeHandle drag={colDrag} colKey="model-list" label="列表" />
                  </>)}
            </div>
          )}
          {sidebarMerged && <ColStackSplit value={stackFlex} onFlex={setStackFlex} label="模型列表与 AI源生分栏" />}
          {showAgent && (
            <div key="col-agent" className="sidebar-item" style={{
              position: 'relative', display: 'flex', flexDirection: 'column', minHeight: 0, flexShrink: 0,
              ...(sidebarMerged
                ? { flex: 1 - stackFlex }
                : { width: agentW }),
            }}>
              <ModelsAgentPanel onClose={() => { setSidebarMerged(false); setShowAgent(false); }} />
              {sidebarMerged
                ? <ColMergeCtrl onRestore={() => setSidebarMerged(false)} />
                : (showList && <ColMergeCtrl onMergeLeft={() => setSidebarMerged(true)} />)}
              {!sidebarMerged && <ColResizeHandle drag={colDrag} colKey="model-agent" label="AI源生" />}
            </div>
          )}
          {sidebarMerged && <ColResizeHandle drag={colDrag} colKey="model-list" label="侧栏" />}
        </div>

        {/* 中间：编辑器 / 关联情况分屏（审计 P2-12：pointer 拖拽事件挂容器，捕获的手柄事件冒泡至此） */}
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0, overflow: 'hidden', alignSelf: 'stretch' }}>
          <div id="model-split-container"
            onPointerMove={splitDrag.onPointerMove}
            onPointerUp={splitDrag.onPointerUp}
            onPointerCancel={splitDrag.onPointerUp}
            style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0, overflow: 'hidden' }}>
            <div style={{ height: `${splitPos}%`, display: 'flex', flexDirection: 'row', minHeight: 0, flexShrink: 0, overflow: 'hidden' }}>
              {/* 26px 竖条：编辑 / 自动关联SQL / 生成SQL快照 / 刷新快照 / 保存 / 删除（审计 P2-12：宽度走 --col-toolstrip token，图标钮补 aria-label） */}
              {!builtin && (
                <div style={{ width: 'var(--col-toolstrip)', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 5, paddingTop: 6, backgroundColor: 'var(--surface-1)', borderRight: '1px solid var(--border-light)', flexShrink: 0 }}>
                  <StripBtn icon={editing ? <Lock size={9} /> : <Pencil size={9} />} bg={editing ? 'var(--accent-blue)' : 'var(--text-muted)'}
                    onClick={() => setEditing((v) => !v)} disabled={!canEdit} title={editing ? '锁定（完成编辑）' : '编辑'} />
                  {inputIsSql && (
                    <StripBtn icon={<Link2 size={9} />} bg="var(--accent-blue)" onClick={() => setConfirmAction('associate')} disabled={busy !== null || readOnly}
                      busy={busy === 'associate'} dimmed={busy !== null || readOnly} title={tip('自动关联 SQL')} />
                  )}
                  {inputIsSql && (
                    <StripBtn icon={<Paperclip size={9} />} bg="var(--accent-blue-dim)" iconColor="var(--strip-icon-on-dim)" onClick={openManual} disabled={busy !== null || manualLoading || readOnly}
                      busy={manualLoading} dimmed={busy !== null || manualLoading || readOnly} title={tip('手动关联 SQL')} />
                  )}
                  {inputIsSql && (
                    <StripBtn icon={<Snowflake size={9} />} bg="var(--accent-amber)" onClick={() => setConfirmAction('plan')} disabled={busy !== null || readOnly}
                      busy={busy === 'plan'} dimmed={busy !== null || readOnly} title={tip('生成 SQL 快照')} />
                  )}
                  {inputIsSql && (
                    <StripBtn icon={<RefreshCw size={9} />} bg="#16a085" onClick={() => setConfirmAction('refresh')} disabled={busy !== null || readOnly}
                      busy={busy === 'refresh'} dimmed={busy !== null || readOnly} title={tip('刷新快照')} />
                  )}
                  <StripBtn icon={<Save size={9} />} bg="#27ae60" onClick={() => saveDraft()} disabled={readOnly} title={tip('保存')} />
                  <StripBtn icon={<Trash2 size={9} />} bg="#e74c3c" onClick={() => setDeleteOpen(true)} disabled={!canDelete || !selectedModel}
                    title={!canDelete ? '无删除权限' : !selectedModel ? '新建草稿尚未保存，无模型可删' : '删除当前模型'} />
                </div>
              )}

              <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0, overflow: 'hidden' }}>
                {/* 工具栏：名称 / 描述 / 输入方式（默认只读，点「编辑」解锁） */}
                <div style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '6px 10px', borderBottom: '1px solid var(--border-light)', flexShrink: 0, flexWrap: 'wrap' }}>
                  <label style={{ fontSize: 11, color: 'var(--text-secondary)', display: 'flex', alignItems: 'center', gap: 4, minWidth: 0 }}>
                    <span style={{ flexShrink: 0 }}>名称</span>
                    <input value={draft.name} onChange={(e) => setModelDraft({ name: e.target.value })} placeholder="模型名" disabled={readOnly}
                      style={{ width: 130, padding: '4px 8px', borderRadius: 4, border: '1px solid var(--text-muted)', backgroundColor: 'var(--surface-1)', color: 'var(--text-on-accent)', fontSize: 12, outline: 'none', opacity: readOnly ? 0.6 : 1 }} />
                  </label>
                  <label style={{ fontSize: 11, color: 'var(--text-secondary)', display: 'flex', alignItems: 'center', gap: 4, flex: 1, minWidth: 160 }}>
                    <span style={{ flexShrink: 0 }}>描述</span>
                    <input value={draft.desc} onChange={(e) => setModelDraft({ desc: e.target.value })} placeholder="显示名/描述" disabled={readOnly}
                      style={{ flex: 1, minWidth: 0, padding: '4px 8px', borderRadius: 4, border: '1px solid var(--text-muted)', backgroundColor: 'var(--surface-1)', color: 'var(--text-on-accent)', fontSize: 12, outline: 'none', opacity: readOnly ? 0.6 : 1 }} />
                  </label>
                  <label style={{ fontSize: 11, color: 'var(--text-secondary)', display: 'flex', alignItems: 'center', gap: 4 }}>
                    <span style={{ flexShrink: 0 }}>输入</span>
                    <select value={draft.input} onChange={(e) => setModelDraft({ input: e.target.value as 'sql' | 'upload' })} disabled={readOnly}
                      style={{ padding: '4px 6px', borderRadius: 4, border: '1px solid var(--text-muted)', backgroundColor: 'var(--surface-1)', color: 'var(--text-on-accent)', fontSize: 12, outline: 'none', opacity: readOnly ? 0.6 : 1 }}>
                      <option value="sql">自动取数</option>
                      <option value="upload">离线上传</option>
                    </select>
                  </label>
                  <button onClick={() => setVerOpen(true)} disabled={!selectedModel} title={selectedModel ? '版本历史' : '请先保存模型（版本历史仅对已保存模型可用）'}
                    aria-label="版本历史"
                    style={{ ...toolbarIconBtn, opacity: selectedModel ? 1 : 0.4, cursor: selectedModel ? 'pointer' : 'not-allowed' }}>
                    <History size={13} style={{ color: 'var(--history-icon)' }} />
                  </button>
                  {/* 审计建议 8：回收站入口（已删工件版本镜像，保留 30 天，可恢复/彻底删除） */}
                  <button onClick={() => setRecycleOpen(true)} aria-label="回收站" title="回收站（已删除工件，可恢复/彻底删除）"
                    style={toolbarIconBtn}>
                    <Trash2 size={13} />
                  </button>
                </div>

                {/* 编辑器 */}
                <div style={{ flex: 1, minHeight: 0 }}>
                  <ModelsEditor readOnly={readOnly} />
                </div>
              </div>
            </div>

            <SplitHandle
              ariaLabel="编辑器与关联情况分隔条"
              value={splitPos}
              onDelta={splitDrag.onKeyDelta}
              onPointerDown={splitDrag.onPointerDown}
            />

            <div style={{ height: `${100 - splitPos}%`, display: 'flex', flexDirection: 'column', minHeight: 0, flexShrink: 0, overflow: 'hidden' }}>
              <ModelsAssociationPanel data={modelInfo} />
            </div>
          </div>
        </div>
      </div>

      {verOpen && verName && (
        <VersionHistoryDialog kind="model" name={verName} onClose={() => setVerOpen(false)} onRestored={handleVerRestored} />
      )}

      {/* 审计建议 8：回收站（已删工件版本镜像，恢复/彻底删除需 analysis_delete） */}
      <RecycleBinDialog open={recycleOpen} onClose={() => setRecycleOpen(false)} />

      {/* 手动关联 SQL 弹窗：单选取数 SQL，确认后复用 saveDraft 落盘（旧专属快照随改绑失效） */}
      {manualOpen && (
        <ManualAssocDialog
          title={`手动关联取数 SQL — 「${draft.name.trim()}」`}
          saving={manualSaving}
          onCancel={() => setManualOpen(false)}
          onConfirm={confirmManual}
          sections={[{
            key: 'sql', label: '取数 SQL', multi: false,
            options: manualSqls.map((n) => ({ value: n, label: n })),
            selected: draft.sql ? [draft.sql] : [],
            emptyText: '（暂无可用 SQL）',
          }]}
        />
      )}

      {/* 后果确认弹窗（用户要求）：自动关联 SQL / 生成 SQL 快照 / 刷新快照，点确认后才执行 */}
      <ActionConfirmDialog
        open={confirmAction !== null}
        busy={busy !== null}
        title={confirmAction === 'associate' ? '确认自动关联 SQL' : confirmAction === 'plan' ? '确认生成 SQL 快照' : '确认刷新快照'}
        lines={confirmAction === 'associate' ? [
          'AI 将分析模型描述，从当前游戏可用的取数 SQL 中自动挑选最匹配的一条，并回填模型的绑定 SQL、粒度、历史窗/展望期参数与描述后直接保存。',
          '若当前已绑定其它 SQL，会被这次挑选替换。',
          '若描述指向离线上传数据（不从库取数），AI 会返回空绑定，可切到「离线上传」。',
        ] : confirmAction === 'plan' ? [
          '为当前绑定的取数 SQL 生成一条「专属改造 SQL」快照，冻结保存到模型目录并覆盖同名旧快照。',
          '之后预测运行时使用该专属快照；{开始日期}/{结束日期} 占位符原样保留。',
          '全局 SQL 库的源文件不受影响。',
        ] : [
          '按当前绑定的取数 SQL 重新生成专属快照，覆盖旧冻结件。',
          '「源已更新」的漂移告警会随之清除。',
          '全局 SQL 库的源文件不受影响。',
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

      {deleteOpen && (
        <div onClick={() => setDeleteOpen(false)} style={overlayStyle}>
          <div ref={deleteDialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={dialogStyle}>
            <p style={{ margin: 0, fontSize: 13, color: 'var(--text-primary)' }}>确认删除模型「{selectedModel || draft.name.trim()}」？</p>
            <p style={{ margin: '6px 0 0', fontSize: 11, color: 'var(--text-muted)' }}>此操作不可撤销。</p>
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end', marginTop: 14 }}>
              <button onClick={() => setDeleteOpen(false)} style={saveCancelBtn}>取消</button>
              <button onClick={handleDelete} style={dangerBtn}>删除</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};

export default ModelsWorkspace;
