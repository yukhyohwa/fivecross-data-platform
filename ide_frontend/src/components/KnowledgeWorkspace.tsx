import React, { useCallback, useEffect, useRef, useState } from 'react';
import { useStore } from '../stores/useStore';
import { api } from '../services/api';
import { useToast } from './Toast';
import { KnowledgeEditor } from './KnowledgeEditor';
import { KnowledgeListSidebar } from './KnowledgeListSidebar';
import { KnowledgeAgentPanel } from './KnowledgeAgentPanel';
import { BookOpen, Sparkles, RefreshCw, Save, Upload, FilePlus2, FileText, Loader2, History, Trash2 } from 'lucide-react';
import { SideTab, WindowTabs, overlayStyle, saveDialogStyle, saveCancelBtn, saveConfirmBtn, toolbarIconBtn, fmtBytes, useColWidthDrag, ColResizeHandle, SaveNameDialog, StripBtn, ColMergeCtrl, ColStackSplit } from './wsCommon';
import { VersionHistoryDialog } from './VersionHistoryDialog';
import { RecycleBinDialog } from './RecycleBinDialog';
import { useDialog } from '../lib/useDialog';

const NEW_TEMPLATE = '# 新文档\n\n在这里写背景知识、业务口径说明等，供 AI 在生成分析结论时参考。\n';

/* ---------- 文件读取（上传文档汇总弹窗用） ---------- */

async function readFileText(file: File): Promise<string> {
  const buf = await file.arrayBuffer();
  try { return new TextDecoder('utf-8', { fatal: true }).decode(buf); }
  catch {
    try { return new TextDecoder('gbk').decode(buf); }
    catch { return new TextDecoder('utf-8').decode(buf); }
  }
}

async function fileToBase64(file: File): Promise<string> {
  const buf = await file.arrayBuffer();
  const bytes = new Uint8Array(buf);
  let bin = '';
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    bin += String.fromCharCode.apply(null, Array.from(bytes.subarray(i, i + chunk)));
  }
  return btoa(bin);
}

async function fileToSource(file: File): Promise<{ name: string; content: string }> {
  if (/\.xmind$/i.test(file.name)) {
    const r = await api.parseXmind(file.name, await fileToBase64(file));
    return { name: file.name, content: r.text || '' };
  }
  return { name: file.name, content: await readFileText(file) };
}

/** 知识库管理工作台（仿专项管理布局）：左栏[知识库文档/AI源生]，右侧=文档编辑器。
 * 支持多窗口（顶部 tab 条）并存切换；表结构知识库改为刷新按钮悬停提示（不再单独占下半区）。 */
export const KnowledgeWorkspace: React.FC = () => {
  const {
    kbDraft, setKbDraft, selectedKb, setSelectedKb, bumpKbFiles,
    kbWindows, activeKbWindowId, activateKbWindow, closeKbWindow, newKbWindow, openKbWindow,
  } = useStore();
  // 仅可查看：无「新增/修改」权限点时，禁掉保存/另存为/重建表结构库（null = 匿名回落/未加载，视为全量）
  const myPermissions = useStore((s) => s.myPermissions);
  const canEdit = myPermissions === null || myPermissions.includes('analysis_edit');
  // 个人定制上下文：列表只显示该层级，新建/保存强制该层级
  const scopeLevel = useStore((s) => s.scopeLevel);
  const { success, error: toastError } = useToast();
  const sidebarColWidths = useStore((s) => s.sidebarColWidths);
  // 审计 P2-12：默认宽度走响应式 token（窄屏自动收缩），用户拖拽后的自定义像素值仍存 zustand
  const listW: number | string = sidebarColWidths?.['kb-list'] || 'var(--col-list)';
  const agentW: number | string = sidebarColWidths?.['kb-agent'] || 'var(--col-agent)';

  const [showList, setShowList] = useState(true);
  const [showAgent, setShowAgent] = useState(true);
  // 侧栏向左合并（仿 SQL 管理）：merged=列表+AI源生合并一列上下堆叠；stackFlex=合并列中列表占比
  const sidebarMerged = useStore((s) => s.kbSidebarMerged);
  const setSidebarMerged = useStore((s) => s.setKbSidebarMerged);
  const stackFlex = useStore((s) => s.kbStackFlex);
  const setStackFlex = useStore((s) => s.setKbStackFlex);
  // 合并态下隐藏任一栏先解除合并（否则单栏残留在合并列中）
  const toggleList = () => { if (showList && sidebarMerged) setSidebarMerged(false); setShowList((v) => !v); };
  const toggleAgent = () => { if (showAgent && sidebarMerged) setSidebarMerged(false); setShowAgent((v) => !v); };

  // 表结构知识库状态（仅用于刷新按钮悬停提示）
  const [schemaStatus, setSchemaStatus] = useState<any>(null);
  const [rebuilding, setRebuilding] = useState(false);
  const [schemaTip, setSchemaTip] = useState(false);

  // 保存/另存为弹窗（名称 + 层级，与 SQL管理 一致）
  const [saveOpen, setSaveOpen] = useState(false);
  const [saveMode, setSaveMode] = useState<'save' | 'saveas'>('save');
  const [saveName, setSaveName] = useState('');
  const [saveLevel, setSaveLevel] = useState('通用');
  const [saveConfidentiality, setSaveConfidentiality] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  // 版本历史弹窗（P1-16）
  const [verOpen, setVerOpen] = useState(false);
  // 回收站弹窗（审计建议 8）：已删除工件版本镜像，可恢复/彻底删除
  const [recycleOpen, setRecycleOpen] = useState(false);
  const verName = selectedKb?.name || kbDraft?.name?.trim() || '';

  // 上传文档汇总弹窗
  const [sumOpen, setSumOpen] = useState(false);
  const [sumFiles, setSumFiles] = useState<File[]>([]);
  const [sumExtra, setSumExtra] = useState('');
  const [sumStatus, setSumStatus] = useState('');
  const [sumBusy, setSumBusy] = useState(false);
  const [models, setModels] = useState<string[]>([]);
  const [defaultModel, setDefaultModel] = useState('');
  const [sumModel, setSumModel] = useState<string | null>(null);
  const sumFileRef = useRef<HTMLInputElement>(null);

  // 审计 P2-12：弹窗无障碍（Escape 关闭 + 打开时聚焦 + 关闭后焦点还原）
  const sumDialogRef = useDialog(sumOpen, () => { if (!sumBusy) setSumOpen(false); });

  const loadSchemaStatus = useCallback(async () => {
    try { setSchemaStatus(await api.getSchemaStatus()); } catch { /* 保持现状 */ }
  }, []);

  useEffect(() => { loadSchemaStatus(); }, [loadSchemaStatus]);
  useEffect(() => {
    api.getModels().then((r) => { setModels(r.models || []); setDefaultModel(r.default || ''); }).catch(() => {});
  }, []);

  // ── 保存 / 另存为（弹窗确认名称 + 层级；保存且改名才删旧名，另存为不删旧文件） ──
  const openSave = async (mode: 'save' | 'saveas') => {
    // 预填当前文档名：工具栏草稿名优先（用户正在编辑的名字），其次已保存名——
    // 打开已有文档再保存时无需重输名称；另存为同样预填原名（改后缀即可）
    setSaveName((kbDraft?.name || '').trim() || selectedKb?.name || '');
    setSaveLevel(scopeLevel ?? kbDraft?.level ?? selectedKb?.level ?? '通用');
    setSaveMode(mode);
    // 预填当前机密档位：异步读既有 meta，避免「重存旧文档默认未分级」静默清档（新文档/读失败 → 未分级）
    let conf: string | null = null;
    if (selectedKb?.name) {
      try {
        const r = await api.readDoc(selectedKb.name);
        conf = r?.confidentiality ?? null;
      } catch { /* 保持未分级 */ }
    }
    setSaveConfidentiality(conf);
    setSaveOpen(true);
  };

  const confirmSave = async () => {
    const name = saveName.trim();
    if (!name) { toastError('请输入文档名称'); return; }
    if (!(kbDraft?.content || '').trim()) { toastError('文档内容为空，无法保存'); return; }
    const oldName = selectedKb?.name;
    const level = scopeLevel ?? saveLevel;
    setSaving(true);
    try {
      // 审计建议 7：改名走服务端 rename（主文件 + 元数据 + 版本库 + 订阅引用一并迁移）；
      // 失败用后端 detail 提示并中止保存，不再前端「存新名 + 删旧名」两段式
      if (saveMode === 'save' && oldName && oldName !== name) {
        try {
          await api.renameDoc(oldName, name);
        } catch (e: any) {
          toastError(e.message || '重命名失败'); // 文件仍在旧名下，重试不受影响
          return;
        }
      }
      await api.saveDoc(name, { content: kbDraft!.content, level, confidentiality: saveConfidentiality });
      setKbDraft({ name, level });
      setSelectedKb({ name, level });
      success(saveMode === 'saveas' ? `已另存为「${name}」` : (oldName && oldName !== name ? `已重命名并保存「${name}」` : `已保存文档「${name}」`));
      bumpKbFiles();
      setSaveOpen(false);
    } catch (e: any) {
      toastError(e.message || '保存失败');
      // 对抗审查：改名已生效但保存失败（网络抖动等）——旧名已不存在，重试 rename 会
      // 400 死锁；把选中态/草稿名指向新名，重试保存不再触发 rename
      if (saveMode === 'save' && oldName && oldName !== name) {
        setKbDraft({ name, level });
        setSelectedKb({ name, level });
        bumpKbFiles();
      }
    } finally { setSaving(false); }
  };

  // ── 表结构知识库刷新（一键重建） ──
  const handleRebuildSchema = async () => {
    if (rebuilding) return;
    setRebuilding(true);
    try {
      await api.rebuildSchema();
      success('表结构知识库已重建');
      await loadSchemaStatus();
    } catch (e: any) {
      toastError(e.message || '重建失败');
    } finally { setRebuilding(false); }
  };

  // ── 上传文档汇总（弹窗） ──
  const confirmSummarize = async () => {
    if (!sumFiles.length) { setSumStatus('请先选择要上传的文档'); return; }
    if (sumBusy) return;
    setSumBusy(true);
    setSumStatus('正在读取文件…');
    const sources: { name: string; content: string }[] = [];
    try {
      for (const f of sumFiles) sources.push(await fileToSource(f));
    } catch (e: any) {
      setSumStatus('读取失败：' + (e.message || '未知错误'));
      setSumBusy(false);
      return;
    }
    setSumStatus('AI 正在汇总…');
    try {
      const r = await api.summarizeKnowledge(sumModel ?? defaultModel, sources, sumExtra.trim(), '');
      const st = useStore.getState();
      if (!st.activeKbWindowId) st.newKbWindow({ name: '', level: scopeLevel ?? '通用', content: '' });
      setKbDraft({ name: r.title || '', level: scopeLevel ?? '通用', content: r.draft || '' });
      setSelectedKb(null);
      bumpKbFiles();
      success('汇总草稿已放入编辑器');
      setSumOpen(false);
      setSumFiles([]);
      setSumExtra('');
      if (sumFileRef.current) sumFileRef.current.value = '';
    } catch (e: any) {
      setSumStatus('失败：' + (e.message || '未知错误'));
    } finally { setSumBusy(false); }
  };

  const handleNew = () => {
    newKbWindow({ name: '', level: scopeLevel ?? '通用', content: NEW_TEMPLATE });
  };

  // ── 版本历史回滚后：重新加载文档内容（复用列表侧栏的加载语义）+ bump 列表（P1-16） ──
  const handleVerRestored = async () => {
    // P1-14：钉住窗口 id——回滚后的异步重载只写回发起时的窗口，切窗不污染他窗草稿
    const windowId = useStore.getState().activeKbWindowId;
    const name = selectedKb?.name;
    bumpKbFiles();
    if (!name) return;
    try {
      const r = await api.readDoc(name);
      if (useStore.getState().activeKbWindowId === windowId) {
        openKbWindow(name, { name: r.name || name, content: r.content || '', level: r.level || '通用' });
      }
    } catch (e: any) {
      toastError(e.message || '重新加载失败');
    }
  };

  // 侧栏列宽拖拽（P1-12 收敛：共享 hook，审计 P2-12 的 pointer 捕获/键盘微调语义不变）
  const colDrag = useColWidthDrag();

  // 刷新按钮悬停提示内容
  const schemaTipLines = (() => {
    if (rebuilding) return ['重建中…（重读 Excel + 扫库，约数秒）'];
    if (!schemaStatus) return ['加载中…'];
    if (!schemaStatus.exists) return ['尚未生成', '点此首次生成表结构知识库'];
    if (schemaStatus.error) return ['读取失败', schemaStatus.error];
    return [
      `表：${schemaStatus.tables ?? 0} 张`,
      `更新时间：${schemaStatus.generated_at || '未知'}`,
      `文档大小：${fmtBytes(schemaStatus.bytes)}`,
    ];
  })();

  return (
    <div className="h-full flex flex-col bg-background text-foreground" style={{ minHeight: 0 }}>
      <div style={{ flex: 1, display: 'flex', minHeight: 0, overflow: 'hidden' }}>
        {/* 左侧 Tab 条（审计 P2-12：宽度走 --col-iconbar token） */}
        <div style={{ width: 'var(--col-iconbar)', flexDirection: 'column', backgroundColor: 'var(--surface-0)', borderRight: '1px solid var(--border-light)', flexShrink: 0, display: 'flex' }}>
          <SideTab icon={<BookOpen size={15} />} label="知识库文档" active={showList} onClick={toggleList} />
          <SideTab icon={<Sparkles size={15} style={{ color: 'var(--accent-amber)' }} />} label="AI源生" active={showAgent} onClick={toggleAgent} />
        </div>

        {/* 侧栏列（列宽可拖拽，同 SQL 管理；AI源生 栏 ◀ 并入列表列上下堆叠，▶ 恢复独立列）。
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
              <KnowledgeListSidebar onClose={() => { setSidebarMerged(false); setShowList(false); }} />
              {sidebarMerged
                ? <ColMergeCtrl onRestore={() => setSidebarMerged(false)} />
                : (<>
                    {/* 列表列恒为最左列：◀ 禁用态（对齐 SQL 管理 colIdx<=0），仅展示能力 */}
                    <ColMergeCtrl mergeDisabled />
                    <ColResizeHandle drag={colDrag} colKey="kb-list" label="列表" />
                  </>)}
            </div>
          )}
          {sidebarMerged && <ColStackSplit value={stackFlex} onFlex={setStackFlex} label="知识库文档与 AI源生分栏" />}
          {showAgent && (
            <div key="col-agent" className="sidebar-item" style={{
              position: 'relative', display: 'flex', flexDirection: 'column', minHeight: 0, flexShrink: 0,
              ...(sidebarMerged
                ? { flex: 1 - stackFlex }
                : { width: agentW }),
            }}>
              <KnowledgeAgentPanel onClose={() => { setSidebarMerged(false); setShowAgent(false); }} />
              {sidebarMerged
                ? <ColMergeCtrl onRestore={() => setSidebarMerged(false)} />
                : (showList && <ColMergeCtrl onMergeLeft={() => setSidebarMerged(true)} />)}
              {!sidebarMerged && <ColResizeHandle drag={colDrag} colKey="kb-agent" label="AI源生" />}
            </div>
          )}
          {sidebarMerged && <ColResizeHandle drag={colDrag} colKey="kb-list" label="侧栏" />}
        </div>

        {/* 中间：多窗口 tab 条 + 文档编辑器 */}
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0, overflow: 'hidden', alignSelf: 'stretch' }}>
          <WindowTabs
            tabs={kbWindows}
            activeId={activeKbWindowId}
            onSwitch={activateKbWindow}
            onClose={closeKbWindow}
            onNew={handleNew}
            newTitle="新建文档窗口"
          />

          <div style={{ flex: 1, display: 'flex', minHeight: 0, overflow: 'hidden' }}>
            {/* 26px 竖条：上传文档汇总 / 刷新表结构库 / 保存 / 另存为（审计 P2-12：宽度走 --col-toolstrip token，图标钮补 aria-label） */}
            <div style={{ width: 'var(--col-toolstrip)', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 5, paddingTop: 6, backgroundColor: 'var(--surface-1)', borderRight: '1px solid var(--border-light)', flexShrink: 0 }}>
              <StripBtn icon={<Upload size={9} />} bg="var(--accent-amber)" onClick={() => setSumOpen(true)} title="上传文档汇总（弹窗）" />
              <div style={{ position: 'relative' }}>
                <button onClick={handleRebuildSchema} disabled={rebuilding || !canEdit} title={canEdit ? '刷新表结构知识库' : '仅可查看（无新增/修改权限）'}
                  aria-label="刷新表结构知识库"
                  onMouseEnter={() => setSchemaTip(true)} onMouseLeave={() => setSchemaTip(false)}
                  style={{ width: 16, height: 16, display: 'flex', alignItems: 'center', justifyContent: 'center', borderRadius: 3, border: 'none', backgroundColor: '#16a085', color: '#fff', cursor: canEdit ? 'pointer' : 'not-allowed', opacity: rebuilding || !canEdit ? 0.35 : 1, padding: 0 }}>
                  <RefreshCw size={9} />
                </button>
                {schemaTip && (
                  <div style={{
                    position: 'absolute', left: 22, top: -4, zIndex: 500,
                    backgroundColor: 'var(--surface-2)', border: '1px solid var(--border-light)', borderRadius: 6,
                    padding: '8px 10px', boxShadow: '0 4px 16px rgba(0,0,0,0.35)', whiteSpace: 'nowrap',
                    display: 'flex', flexDirection: 'column', gap: 2, fontSize: 11, color: 'var(--text-primary)',
                  }}>
                    {schemaTipLines.map((l, i) => <div key={i}>{l}</div>)}
                  </div>
                )}
              </div>
              <StripBtn icon={<Save size={9} />} bg="#27ae60" onClick={() => openSave('save')} disabled={!canEdit}
                title={canEdit ? '保存（选择层级）' : '仅可查看（无新增/修改权限）'} />
              <StripBtn icon={<FilePlus2 size={9} />} bg="var(--accent-blue-dim)" iconColor="var(--strip-icon-on-dim)" onClick={() => openSave('saveas')} disabled={!canEdit}
                title={canEdit ? '另存为（选择层级）' : '仅可查看（无新增/修改权限）'} />
            </div>

            <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0, overflow: 'hidden' }}>
              {/* 工具栏：名称 + 版本历史（层级在保存弹窗选） */}
              <div style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '6px 10px', borderBottom: '1px solid var(--border-light)', flexShrink: 0 }}>
                <label style={{ fontSize: 11, color: 'var(--text-secondary)', display: 'flex', alignItems: 'center', gap: 4, flex: 1, minWidth: 0 }}>
                  <span style={{ flexShrink: 0 }}>名称</span>
                  <input value={kbDraft?.name || ''} onChange={(e) => setKbDraft({ name: e.target.value })}
                    placeholder="文档名称" disabled={!canEdit}
                    style={{ flex: 1, minWidth: 0, padding: '4px 8px', borderRadius: 4, border: '1px solid var(--text-muted)', backgroundColor: 'var(--surface-1)', color: 'var(--text-on-accent)', fontSize: 12, outline: 'none', opacity: canEdit ? 1 : 0.6 }} />
                </label>
                <button onClick={() => setVerOpen(true)} disabled={!selectedKb} title={selectedKb ? '版本历史' : '请先保存文档（版本历史仅对已保存文档可用）'}
                  aria-label="版本历史"
                  style={{ ...toolbarIconBtn, opacity: selectedKb ? 1 : 0.4, cursor: selectedKb ? 'pointer' : 'not-allowed' }}>
                  <History size={13} style={{ color: 'var(--history-icon)' }} />
                </button>
                {/* 审计建议 8：回收站入口（已删工件版本镜像，保留 30 天，可恢复/彻底删除） */}
                <button onClick={() => setRecycleOpen(true)} aria-label="回收站" title="回收站（已删除工件，可恢复/彻底删除）"
                  style={toolbarIconBtn}>
                  <Trash2 size={13} />
                </button>
              </div>
              <div style={{ flex: 1, minHeight: 0 }}>
                <KnowledgeEditor />
              </div>
            </div>
          </div>
        </div>
      </div>

      {verOpen && verName && (
        <VersionHistoryDialog kind="doc" name={verName} onClose={() => setVerOpen(false)} onRestored={handleVerRestored} />
      )}

      {/* 审计建议 8：回收站（已删工件版本镜像，恢复/彻底删除需 analysis_delete） */}
      <RecycleBinDialog open={recycleOpen} onClose={() => setRecycleOpen(false)} />

      {/* 保存 / 另存为弹窗（P1-12 收敛：共享 SaveNameDialog，自带 useDialog 无障碍收口） */}
      <SaveNameDialog
        open={saveOpen}
        title={saveMode === 'save' ? '保存文档' : '另存为文档'}
        label="名称"
        placeholder="文档名称"
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

      {/* 上传文档汇总弹窗（审计 P2-12：minWidth 360 → min(360px,94vw)，80vh 滚动复用 saveDialogStyle） */}
      {sumOpen && (
        <div onClick={() => { if (!sumBusy) setSumOpen(false); }} style={overlayStyle}>
          <div ref={sumDialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={{ ...saveDialogStyle, minWidth: 'min(360px, 94vw)' }}>
            <p style={{ margin: 0, fontSize: 13, color: 'var(--text-primary)', display: 'flex', alignItems: 'center', gap: 6 }}>
              <Upload size={14} style={{ color: 'var(--accent-amber)' }} /> 上传文档汇总
            </p>
            <div style={{ marginTop: 12, display: 'flex', flexDirection: 'column', gap: 10 }}>
              {/* 审计 P2-12：文件选择框补键盘可达（Enter/Space 触发隐藏 input） */}
              <label
                role="button"
                tabIndex={0}
                aria-label="选择文件（.txt / .md / .xmind，可多选）"
                onKeyDown={(e) => { if ((e.key === 'Enter' || e.key === ' ') && !sumBusy) { e.preventDefault(); sumFileRef.current?.click(); } }}
                style={{ ...uploadBox, cursor: sumBusy ? 'default' : 'pointer' }}>
                <Upload size={14} style={{ color: 'var(--text-muted)' }} />
                <span style={{ fontSize: 12, color: 'var(--text-secondary)' }}>选择文件（.txt / .md / .xmind，可多选）</span>
                <input ref={sumFileRef} type="file" multiple accept=".txt,.md,.markdown,.xmind"
                  disabled={sumBusy}
                  onChange={(e) => setSumFiles(Array.from(e.target.files || []))}
                  style={{ display: 'none' }} />
              </label>
              {sumFiles.length > 0 && (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 2, maxHeight: 120, overflowY: 'auto' }}>
                  {sumFiles.map((f, i) => (
                    <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 5, fontSize: 11, color: 'var(--text-primary)' }}>
                      <FileText size={11} style={{ color: '#5a8', flexShrink: 0 }} />
                      <span style={{ flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{f.name}</span>
                      <span style={{ color: 'var(--text-inactive)', flexShrink: 0 }}>{(f.size / 1024).toFixed(1)} KB</span>
                    </div>
                  ))}
                </div>
              )}
              <label style={{ fontSize: 11, color: 'var(--text-secondary)' }}>LLM 模型
                <select value={sumModel ?? defaultModel} onChange={(e) => setSumModel(e.target.value || null)}
                  style={{ display: 'block', width: '100%', marginTop: 4, padding: '6px 8px', borderRadius: 4, border: '1px solid var(--text-muted)', backgroundColor: 'var(--surface-1)', color: 'var(--text-on-accent)', fontSize: 12, outline: 'none' }}>
                  {models.map((m) => <option key={m} value={m}>{m}{m === defaultModel ? '（默认）' : ''}</option>)}
                </select>
              </label>
              <textarea value={sumExtra} onChange={(e) => setSumExtra(e.target.value)}
                placeholder="补充要求（可选）：汇总的侧重点、输出结构、口径约束…"
                rows={3}
                style={{ width: '100%', padding: '6px 10px', borderRadius: 6, border: '1px solid var(--text-muted)', backgroundColor: 'var(--surface-1)', color: 'var(--text-on-accent)', fontSize: 12, outline: 'none', resize: 'vertical', fontFamily: 'inherit', boxSizing: 'border-box' }} />
              {sumStatus && (
                <div style={{ fontSize: 11, color: sumStatus.startsWith('失败') || sumStatus.startsWith('读取失败') ? '#e74c3c' : 'var(--text-secondary)', lineHeight: 1.6 }}>{sumStatus}</div>
              )}
            </div>
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end', marginTop: 14 }}>
              <button onClick={() => { if (!sumBusy) setSumOpen(false); }} style={saveCancelBtn}>取消</button>
              <button onClick={confirmSummarize} disabled={sumBusy}
                style={{ ...saveConfirmBtn, backgroundColor: 'var(--accent-amber)', opacity: sumBusy ? 0.6 : 1 }}>
                {sumBusy ? <Loader2 size={12} style={{ animation: 'spin 1s linear infinite' }} /> : <Upload size={12} />}
                {sumBusy ? '汇总中…' : '生成汇总'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};

const uploadBox: React.CSSProperties = { display: 'flex', alignItems: 'center', gap: 6, padding: '8px 10px', borderRadius: 6, border: '1px dashed var(--text-muted)', backgroundColor: 'var(--surface-1)' };

export default KnowledgeWorkspace;
