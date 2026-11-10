import React, { useEffect, useMemo, useRef, useState } from 'react';
import { useStore } from '../stores/useStore';
import { api } from '../services/api';
import { useToast } from './Toast';
import { SQLEditor } from './SQLEditor';
import { EditorTabs } from './EditorTabs';
import { ResultTable } from './ResultTable';
import { QueryHistory } from './QueryHistory';
import { SchemaSidebar } from './SchemaSidebar';
import { SqlFilesSidebar } from './SqlFilesSidebar';
import { AgentPanel } from './AgentPanel';
import { VersionHistoryDialog } from './VersionHistoryDialog';
import { RecycleBinDialog } from './RecycleBinDialog';
import { SideTab, SplitHandle, useColWidthDrag, ColResizeHandle, useSplitDrag, SaveNameDialog, StripBtn, ColMergeCtrl } from './wsCommon';
import { Database, GripHorizontal, Table2, History, Sparkles, Play, Plus, FileCode, Wand2, Save, FilePlus2, Braces, Trash2 } from 'lucide-react';

/**
 * SQL 数据工作台（融合后）：写 SQL → 执行 → 结果表，数据源绑游戏库（X-Game）。
 * 左侧四栏：SQL数据 / 数据库 / AI源生 / 历史记录，去掉用户连接与保存为指标。
 */
export const SqlWorkspace: React.FC = () => {
  const {
    openSqlFile, clearOpenSqlFile,
    isExecuting, executeSql,
    setSql, selectedSqlFile, setSelectedSqlFile, bumpSqlFiles,
  } = useStore();
  // 仅可查看：无「新增/修改」权限点时，禁掉保存/另存为（null = 匿名回落/未加载，视为全量）
  const myPermissions = useStore((s) => s.myPermissions);
  const canEdit = myPermissions === null || myPermissions.includes('analysis_edit');
  // 个人定制上下文：强制保存到该层级（个人），并隐藏层级下拉
  const scopeLevel = useStore((s) => s.scopeLevel);
  const { success, error: toastError, toast } = useToast();
  const splitPos = useStore((s) => s.splitPos);
  const setSplitPos = useStore((s) => s.setSplitPos);
  const sidebarColWidths = useStore((s) => s.sidebarColWidths);
  const setSidebarColumns = useStore((s) => s.setSidebarColumns);
  const sidebarFlex = useStore((s) => s.sidebarFlex);
  const setSidebarFlex = useStore((s) => s.setSidebarFlex);

  // ── SQL 保存/另存为（弹窗确认文件名 + 层级 通用/项目/个人）+ 格式化 ──
  const stripExt = (name: string) => name.replace(/\.sql$/i, '');
  const [saveOpen, setSaveOpen] = useState(false);
  const [saveMode, setSaveMode] = useState<'save' | 'saveas'>('save');
  const [saveName, setSaveName] = useState('');
  const [saveLevel, setSaveLevel] = useState('通用');
  const [saveConfidentiality, setSaveConfidentiality] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  // 版本历史弹窗（P1-16）
  const [verOpen, setVerOpen] = useState(false);
  const verName = selectedSqlFile?.name || '';
  // 回收站弹窗（审计建议 8）：已删除工件版本镜像，可恢复/彻底删除
  const [recycleOpen, setRecycleOpen] = useState(false);

  // ── 版本历史回滚后：重新加载 SQL 内容（复用「在 SQL 数据中打开」的载入语义）+ bump 列表（P1-16） ──
  const handleVerRestored = async () => {
    const name = selectedSqlFile?.name;
    bumpSqlFiles();
    if (!name) return;
    try {
      const data = await api.readSql(name);
      // P1-14：单编辑器同样防串——重载期间切到别的 SQL 文件时，不覆盖当前编辑内容
      if (data && typeof data.sql === 'string' && useStore.getState().selectedSqlFile?.name === name) {
        useStore.getState().setSql(data.sql);
        useStore.getState().setActiveEditorTabLabel(stripExt(name));
        useStore.getState().setSelectedSqlFile({ name, level: data.level || '通用' });
      }
    } catch (e: any) {
      toastError(e.message || '重新加载失败');
    }
  };

  const handleFormat = async () => {
    const cur = useStore.getState().sql;
    if (!cur.trim()) { toastError('编辑器为空，无法格式化'); return; }
    try {
      const r = await api.formatSql(cur);
      setSql(r.sql || cur);
      success('已格式化 SQL');
    } catch (e: any) {
      toastError(e.message || '格式化失败');
    }
  };

  // ── flex 化：调 LLM 把 SQL 改造成 starrocks_model 报表模板（flexsql）──
  const [flexing, setFlexing] = useState(false);
  const handleFlexsql = async () => {
    const cur = useStore.getState().sql;
    if (!cur.trim()) { toastError('编辑器为空，无法转换'); return; }
    if (flexing) return;
    setFlexing(true);
    try {
      const r = await api.toFlexsql(cur);
      setSql(r.flexsql || cur);
      success('已转换为 flexsql 模板');
    } catch (e: any) {
      toastError(e.message || 'flex 化失败');
    } finally {
      setFlexing(false);
    }
  };

  const openSave = async (mode: 'save' | 'saveas') => {
    const cur = selectedSqlFile;
    // 预填当前文件名：已保存文件名优先；页面刷新后 selectedSqlFile 丢失（不持久化）但
    // 编辑器页签标签仍保留文档名（editorTabs 持久化），据此回填——保存已打开的文档无需重输名字
    const tab = useStore.getState().editorTabs.find((t) => t.id === useStore.getState().activeEditorTabId);
    const tabName = tab && tab.label && !/^查询\s*\d+$/.test(tab.label) ? stripExt(tab.label) : '';
    setSaveName((cur ? stripExt(cur.name) : '') || tabName || '');
    setSaveLevel(scopeLevel ?? cur?.level ?? '通用');
    setSaveMode(mode);
    // 预填当前机密档位：异步读既有 meta，避免「重存旧资产默认未分级」静默清档（新文件/读失败 → 未分级）
    let conf: string | null = null;
    if (cur?.name) {
      try {
        const data = await api.readSql(cur.name);
        conf = data?.meta?.confidentiality ?? null;
      } catch { /* 保持未分级 */ }
    }
    setSaveConfidentiality(conf);
    setSaveOpen(true);
  };

  const confirmSave = async () => {
    const name = saveName.trim();
    if (!name) { toastError('请输入文件名'); return; }
    if (!useStore.getState().sql.trim()) { toastError('编辑器为空，无法保存'); return; }
    const finalName = /\.sql$/i.test(name) ? name : name + '.sql';
    const level = scopeLevel ?? saveLevel;
    const oldName = selectedSqlFile?.name;
    setSaving(true);
    try {
      // 审计建议 7：改名走服务端 rename（主文件 + 元数据 + 版本库 + 订阅引用/派生指标一并迁移）；
      // 失败用后端 detail 提示并中止保存，不再前端「存新名 + 删旧名」两段式
      if (saveMode === 'save' && oldName && oldName !== finalName) {
        try {
          await api.renameSql(oldName, finalName);
        } catch (e: any) {
          toastError(e.message || '重命名失败'); // 文件仍在旧名下，重试不受影响
          return;
        }
      }
      const r = await api.saveSql(finalName, { sql: useStore.getState().sql, level, meta: { confidentiality: saveConfidentiality } });
      setSelectedSqlFile({ name: finalName, level });
      success(saveMode === 'save' && oldName && oldName !== finalName ? `已重命名并保存「${stripExt(finalName)}」` : `已保存「${stripExt(finalName)}」`);
      // 审计 P1-5：保存成功但质量预检发现问题时，逐条警告展示（后端不阻断保存，problems 随响应返回）
      const problems = Array.isArray(r?.problems) ? r.problems : [];
      if (problems.length > 0) {
        toast(`保存成功，但预检发现 ${problems.length} 个问题：${problems.join('；')}`, 'error');
      }
      bumpSqlFiles();
      setSaveOpen(false);
    } catch (e: any) {
      toastError(e.message || '保存失败');
      // 对抗审查：改名已生效但保存失败（网络抖动等）——旧名已不存在，重试 rename 会
      // 400 死锁；把选中态指向新名，重试保存不再触发 rename
      if (saveMode === 'save' && oldName && oldName !== finalName) {
        setSelectedSqlFile({ name: finalName, level });
        bumpSqlFiles();
      }
    } finally {
      setSaving(false);
    }
  };

  // 打开 SQL 文件（跨组跳转意图：指标详情「在 SQL 数据中打开」）
  useEffect(() => {
    if (!openSqlFile) return;
    (async () => {
      try {
        const data = await api.readSql(openSqlFile);
        if (data && typeof data.sql === 'string') {
          useStore.getState().setSql(data.sql);
          useStore.getState().setActiveEditorTabLabel(stripExt(openSqlFile));
          useStore.getState().setSelectedSqlFile({ name: openSqlFile, level: data.level || '通用' });
          setColumns((prev) => (prev.some((c) => c.includes('files')) ? prev : [...prev, ['files']]));
        }
      } catch (e) { console.error(e); }
      finally { clearOpenSqlFile(); }
    })();
  }, [openSqlFile, clearOpenSqlFile]);

  /* -- 侧栏：4 栏（SQL数据 / 数据库 / AI / 历史记录） -- */
  const SIDEBAR_IDS = ['files', 'schema', 'agent', 'history'] as const;

  const sidebarMap: Record<string, { comp: React.ReactNode; label: string }> = {
    files: { comp: <SqlFilesSidebar onClose={() => toggleSidebar('files')} />, label: 'SQL数据' },
    schema: { comp: <SchemaSidebar onClose={() => toggleSidebar('schema')} />, label: '数据库' },
    agent: { comp: <AgentPanel onClose={() => toggleSidebar('agent')} />, label: 'AI源生' },
    history: { comp: <QueryHistory onClose={() => toggleSidebar('history')} />, label: '历史记录' },
  };

  const [columns, setColumns] = useState<string[][]>(() => {
    const p = useStore.getState().sidebarColumns;
    if (p && p.length) {
      const valid = p.filter((col) => col.some((id) => (SIDEBAR_IDS as readonly string[]).includes(id)));
      if (valid.length) return valid;
    }
    return [['files'], ['schema'], ['agent'], ['history']];
  });

  const isVisible = (id: string) => columns.some((col) => col.includes(id));

  const toggleSidebar = (id: string) => {
    setColumns((prev) => {
      let next: string[][];
      if (prev.some((col) => col.includes(id))) {
        next = prev.map((col) => col.filter((x) => x !== id)).filter((col) => col.length > 0);
      } else {
        next = [...prev, [id]];
      }
      setSidebarColumns(next.length ? next : null);
      return next;
    });
  };

  // 审计 P2-12：默认列宽换响应式 token（桌面值与原默认像素一致；用户拖拽存 store 的数字仍原样生效）
  const colWidths = useMemo(() => {
    const cw = sidebarColWidths || {};
    return columns.map((col) => {
      const key = col[0] || '';
      return cw[key] || (key === 'agent' ? 'var(--col-agent)' : key === 'schema' ? 'var(--col-list)' : key === 'files' ? 'var(--col-files)' : 'var(--col-sidebar)');
    });
  }, [sidebarColWidths, columns]);

  const gsc = () => useStore.getState();
  const mergeLeft = (colIdx: number, sidebarId: string) => {
    if (colIdx <= 0) return;
    const cols = gsc().sidebarColumns ?? columns;
    const newCols = cols.map((col) => col.filter((id) => id !== sidebarId));
    newCols[colIdx - 1] = [...newCols[colIdx - 1], sidebarId];
    setColumns(newCols.filter((col) => col.length > 0));
    setSidebarColumns(newCols.filter((col) => col.length > 0));
  };
  const restoreRight = (colIdx: number, sidebarId: string) => {
    const cols = gsc().sidebarColumns ?? columns;
    const newCols = cols.map((col) => col.filter((id) => id !== sidebarId));
    const insertAt = Math.min(colIdx + 1, newCols.length);
    newCols.splice(insertAt, 0, [sidebarId]);
    setColumns(newCols.filter((col) => col.length > 0));
    setSidebarColumns(newCols.filter((col) => col.length > 0));
  };

  // 审计 P2-12：列内堆叠侧栏高度拖拽 pointer 化（setPointerCapture 触屏可拖；删 window 监听与 body cursor）
  const stackDragRef = useRef<{ id: string; startY: number; startFlex: number; totalH: number } | null>(null);
  const onColStackPointerDown = (colIdx: number, id: string, e: React.PointerEvent<HTMLDivElement>) => {
    e.preventDefault();
    e.currentTarget.setPointerCapture(e.pointerId);
    const el = document.getElementById(`col-${colIdx}`);
    if (!el) return;
    stackDragRef.current = { id, startY: e.clientY, startFlex: (gsc().sidebarFlex || {})[id] || 1, totalH: el.getBoundingClientRect().height };
  };
  const onColStackPointerMove = (e: React.PointerEvent<HTMLDivElement>) => {
    const d = stackDragRef.current;
    if (!d) return;
    const delta = (e.clientY - d.startY) / d.totalH;
    const curFlex = gsc().sidebarFlex || {};
    setSidebarFlex({ ...curFlex, [d.id]: Math.max(0.15, d.startFlex + delta) });
  };
  const onColStackPointerUp = () => { stackDragRef.current = null; };

  // 审计 P2-12 核验：列内堆叠手柄键盘步进（ArrowUp/ArrowDown，步进 0.1，最小 flex 0.15 与拖拽一致）
  const onColStackKeyDown = (id: string, e: React.KeyboardEvent<HTMLDivElement>) => {
    if (e.key !== 'ArrowUp' && e.key !== 'ArrowDown') return;
    e.preventDefault();
    const curFlex = gsc().sidebarFlex || {};
    setSidebarFlex({ ...curFlex, [id]: Math.max(0.15, (curFlex[id] || 1) + (e.key === 'ArrowDown' ? 0.1 : -0.1)) });
  };

  // P1-12 收敛：列宽拖拽/上下分屏拖拽走共享 hook（审计 P2-12 语义不变：起点宽读 col-<idx> 实际渲染宽、
  // 键盘步进 20px、分屏 clamp 15-85 / 键盘步进 4。SQL 特有的列内堆叠拖拽保留本文件）
  const colDrag = useColWidthDrag(20);
  const splitDrag = useSplitDrag('split-container', {
    setPos: setSplitPos,
    getPos: () => useStore.getState().splitPos,
  });

  return (
    <div className="h-full flex flex-col bg-background text-foreground" style={{ minHeight: 0 }}>
      {/* 主区 */}
      <div style={{ flex: 1, display: 'flex', minHeight: 0, overflow: 'hidden' }}>
        {/* 左侧 Tab 条（审计 P2-12：宽走响应式 token，桌面 40px 不变） */}
        <div style={{ width: 'var(--col-iconbar)', flexDirection: 'column', backgroundColor: 'var(--surface-0)', borderRight: '1px solid var(--border-light)', flexShrink: 0, display: 'flex' }}>
          <SideTab icon={<FileCode size={15} />} label="SQL数据" active={isVisible('files')} onClick={() => toggleSidebar('files')} />
          <SideTab icon={<Database size={15} />} label="数据库" active={isVisible('schema')} onClick={() => toggleSidebar('schema')} />
          <SideTab icon={<Sparkles size={15} style={{ color: 'var(--accent-amber)' }} />} label="AI源生" active={isVisible('agent')} onClick={() => toggleSidebar('agent')} />
          <SideTab icon={<History size={15} />} label="历史记录" active={isVisible('history')} onClick={() => toggleSidebar('history')} />
        </div>

        {/* 侧栏列（审计 P2-12：列宽兜底默认也走响应式 token） */}
        <div style={{ display: 'flex', flexShrink: 0 }}>
          {columns.map((col, colIdx) => (
            <div key={colIdx} id={`col-${colIdx}`} style={{ position: 'relative', width: colWidths[colIdx] || 'var(--col-sidebar)', display: 'flex', flexDirection: 'column', flexShrink: 0, overflowX: 'hidden', borderRight: '1px solid var(--border-light)' }}>
              {col.map((sid, sidIdx) => {
                const info = sidebarMap[sid];
                if (!info) return null;
                return (
                  <React.Fragment key={sid}>
                    <div style={{ flex: sidebarFlex[sid] || 1, display: 'flex', flexDirection: 'column', minHeight: 0, position: 'relative' }} className="sidebar-item">
                      {/* 合并控制统一走共享 ColMergeCtrl（2026-10-21 用户要求：SQL 管理位置对齐专项/知识库/算法，
                          悬于头部之下 top:46 而非头部右上角 X 旁边） */}
                      <ColMergeCtrl
                        mergeDisabled={colIdx <= 0}
                        onMergeLeft={colIdx > 0 ? () => mergeLeft(colIdx, sid) : undefined}
                        onRestore={col.length > 1 ? () => restoreRight(colIdx, sid) : undefined}
                      />
                      {info.comp}
                    </div>
                    {sidIdx < col.length - 1 && (
                      /* 审计 P2-12：堆叠分栏手柄 pointer 化 + separator 语义（触屏可拖；审计 P2-12 核验：补键盘方向键微调） */
                      <div
                        onPointerDown={(e) => onColStackPointerDown(colIdx, sid, e)}
                        onPointerMove={onColStackPointerMove}
                        onPointerUp={onColStackPointerUp}
                        onPointerCancel={onColStackPointerUp}
                        onKeyDown={(e) => onColStackKeyDown(sid, e)}
                        tabIndex={0}
                        role="separator"
                        aria-orientation="horizontal"
                        aria-label={`调整「${sidebarMap[sid]?.label || '侧栏'}」分栏高度`}
                        aria-valuenow={Math.round(((sidebarFlex[sid] || 1) / col.reduce((acc, id) => acc + (sidebarFlex[id] || 1), 0)) * 100)}
                        style={{ height: 4, cursor: 'row-resize', touchAction: 'none', backgroundColor: 'var(--surface-1)', flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', borderTop: '1px solid var(--border-light)', borderBottom: '1px solid var(--border-light)' }}>
                        <GripHorizontal size={10} style={{ color: 'var(--text-inactive)' }} />
                      </div>
                    )}
                  </React.Fragment>
                );
              })}
              {/* P1-12 收敛：列宽手柄走共享 ColResizeHandle（起点宽读 col-<idx> 实际渲染宽，键盘步进 20，最小 120） */}
              <ColResizeHandle
                drag={colDrag}
                colKey={col[0] || ''}
                label={sidebarMap[col[0] || '']?.label || '侧栏'}
                getW={() => { const el = document.getElementById(`col-${colIdx}`); return el ? el.getBoundingClientRect().width : 260; }}
                keyGetW={() => { const cur = useStore.getState().sidebarColWidths || {}; const el = document.getElementById(`col-${colIdx}`); return cur[col[0] || ''] ?? (el ? el.getBoundingClientRect().width : 260); }}
              />
            </div>
          ))}
        </div>

        {/* 中间：编辑器 / 结果分屏（审计 P2-12：pointer 拖拽事件挂容器，捕获的手柄事件冒泡至此） */}
        <div id="split-container"
          onPointerMove={splitDrag.onPointerMove}
          onPointerUp={splitDrag.onPointerUp}
          onPointerCancel={splitDrag.onPointerUp}
          style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0, overflow: 'hidden', alignSelf: 'stretch' }}>
          <div style={{ height: `${splitPos}%`, display: 'flex', flexDirection: 'row', minHeight: 0, flexShrink: 0, overflow: 'hidden' }}>
            {/* 竖向小工具条（审计 P2-12：宽走响应式 token，桌面 26px 不变；图标钮补 aria-label） */}
            <div style={{ width: 'var(--col-toolstrip)', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 5, paddingTop: 6, backgroundColor: 'var(--surface-1)', borderRight: '1px solid var(--border-light)', flexShrink: 0 }}>
              <StripBtn icon={<Wand2 size={9} />} bg="var(--accent-amber)" onClick={handleFormat} title="格式化 SQL" />
              <StripBtn icon={flexing ? <span style={{ fontSize: 8 }}>…</span> : <Braces size={9} />} bg="var(--accent-amber)" onClick={handleFlexsql}
                disabled={flexing} title="flex 化：转成 starrocks_model 模板（flexsql）" />
              <StripBtn icon={isExecuting ? <span style={{ fontSize: 8 }}>…</span> : <Play size={9} fill="currentColor" />} bg="var(--accent-blue)" onClick={() => executeSql(false)}
                disabled={isExecuting} busy={isExecuting} title="执行 (Ctrl+Enter)" />
              <StripBtn icon={<Plus size={9} />} bg="var(--accent-blue-dim)" iconColor="var(--strip-icon-on-dim)" onClick={() => executeSql(true)}
                disabled={isExecuting} busy={isExecuting} title="在新标签页执行" />
              <StripBtn icon={<Save size={9} />} bg="#27ae60" onClick={() => openSave('save')} disabled={!canEdit}
                title={canEdit ? '保存（选择层级）' : '仅可查看（无新增/修改权限）'} />
              <StripBtn icon={<FilePlus2 size={9} />} bg="var(--accent-blue-dim)" iconColor="var(--strip-icon-on-dim)" onClick={() => openSave('saveas')} disabled={!canEdit}
                title={canEdit ? '另存为（选择层级）' : '仅可查看（无新增/修改权限）'} />
              <StripBtn icon={<History size={9} />} bg="#8e44ad" onClick={() => setVerOpen(true)} disabled={!selectedSqlFile}
                title={selectedSqlFile ? '版本历史' : '请先保存 SQL 文件（版本历史仅对已保存文件可用）'} />
              {/* 审计建议 8：回收站入口（已删工件版本镜像，保留 30 天，可恢复/彻底删除） */}
              <StripBtn icon={<Trash2 size={9} />} bg="#7f8c8d" onClick={() => setRecycleOpen(true)} title="回收站（已删除工件，可恢复/彻底删除）" />
            </div>
            <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0, overflow: 'hidden' }}>
              <EditorTabs />
              <div style={{ flex: 1, minHeight: 0, borderBottom: '1px solid var(--border-light)' }}>
                <SQLEditor />
              </div>
            </div>
          </div>

          {/* P1-12 收敛：分屏手柄走共享 hook（pointer 捕获 + value/onDelta 键盘微调，clamp 15-85 与旧实现一致） */}
          <SplitHandle
            onPointerDown={splitDrag.onPointerDown}
            value={splitPos}
            onDelta={splitDrag.onKeyDelta}
            ariaLabel="编辑器与结果分屏分隔条"
          />

          <div style={{ height: `${100 - splitPos}%`, display: 'flex', flexDirection: 'column', minHeight: 0, flexShrink: 0, overflow: 'hidden' }}>
            <ResultTable />
          </div>
        </div>
      </div>

      {verOpen && verName && (
        <VersionHistoryDialog kind="sql" name={verName} onClose={() => setVerOpen(false)} onRestored={handleVerRestored} />
      )}

      {/* 审计建议 8：回收站（已删工件版本镜像，恢复/彻底删除需 analysis_delete） */}
      <RecycleBinDialog open={recycleOpen} onClose={() => setRecycleOpen(false)} />

      {/* 保存 / 另存为弹窗（P1-12 收敛：共享 SaveNameDialog，自带 useDialog 无障碍收口） */}
      <SaveNameDialog
        open={saveOpen}
        title={saveMode === 'save' ? '保存 SQL 文件' : '另存为 SQL 文件'}
        label="文件名（自动补 .sql 后缀）"
        placeholder="例如 revenue_trend"
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

export default SqlWorkspace;
