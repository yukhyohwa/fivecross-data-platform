import React, { useState, useEffect, useRef } from 'react';
import { useToast } from './Toast';
import { useStore } from '../stores/useStore';
import { api } from '../services/api';
import { useDialog } from '../lib/useDialog';
import { overlayStyle } from './wsCommon';
import { Database, BookOpen, Sparkles, AlertTriangle, Package, Pencil, Trash2, Save, Wand2, Loader2, GripVertical, NotebookPen, ChevronDown, ChevronRight } from 'lucide-react';

/** forecast 字段可能是能力名字符串，或 {method, ...覆盖项} 对象，取方法名回显（同 vanilla forecastName）。 */
function forecastName(fc: any): string {
  if (!fc) return '';
  return typeof fc === 'string' ? fc : (fc.method || '');
}

const kindLabel: Record<string, string> = { sql: 'SQL', model: '模型', doc: '文档' };
// 展示 kind（sql/model/doc）→ 后端 API kind（sql/model/knowledge）
const apiKindOf = (display: string) => (display === 'doc' ? 'knowledge' : display);

interface SnapRow { kind: 'sql' | 'model' | 'doc'; key: string; src: string; fp: string; }

/** 专项右下半区：左右分栏 —— 左「关联情况」（只读），右「内嵌快照」（就地编辑 / AI 改写 / 删除）。 */
export const SkillAssociationPanel: React.FC<{ data: any; onRefresh: () => void }> = ({ data, onRefresh }) => {
  const { success, error: toastError } = useToast();
  const myPermissions = useStore((s) => s.myPermissions);
  const canEdit = myPermissions === null || myPermissions.includes('analysis_edit');
  const [leftPct, setLeftPct] = useState(50);
  const [edit, setEdit] = useState<{ kind: SnapRow['kind']; key: string; src: string; fp: string } | null>(null);
  const [content, setContent] = useState('');
  const [instruction, setInstruction] = useState('');
  const [status, setStatus] = useState('');
  const [saving, setSaving] = useState(false);
  const [aiLoading, setAiLoading] = useState(false);
  const [deleteTarget, setDeleteTarget] = useState<{ kind: SnapRow['kind']; key: string } | null>(null);
  const [notesText, setNotesText] = useState('');
  const [notesSaving, setNotesSaving] = useState(false);
  const [notesOpen, setNotesOpen] = useState(false);
  // 左右分屏拖拽上下文（审计 P2-12：pointer 捕获替代 window 监听/body cursor，触屏可拖）
  const vsplitDragCtx = useRef<{ rect: DOMRect } | null>(null);
  // 快照编辑 / 删除确认弹窗无障碍：Escape 关闭 + 焦点管理（审计 P2-12）
  const editDialogRef = useDialog(!!edit, () => setEdit(null));
  const delDialogRef = useDialog(!!deleteTarget, () => setDeleteTarget(null));

  // 选中专项/刷新后同步笔记槽内容
  useEffect(() => {
    setNotesText(data?.notes || '');
  }, [data?.name, data?.notes]);

  if (!data || !data.name) {
    return (
      <div style={{ height: '100%', display: 'flex', alignItems: 'center', justifyContent: 'center', color: 'var(--text-inactive)', fontSize: 12, padding: 16, textAlign: 'center' }}>
        选择或保存专项后显示关联情况与内嵌快照
      </div>
    );
  }

  const sqls: string[] = data.sqls || [];
  const docs: string[] = data.docs || [];
  const forecast = forecastName(data.forecast);
  const drift: { kind: string; key: string; name: string }[] = data.drift || [];
  const prov = data.provenance || {};
  const nSql = Object.keys(prov.sql || {}).length;
  const nModel = Object.keys(prov.models || {}).length;
  const nDoc = Object.keys(prov.knowledge || {}).length;

  const stale = new Set(drift.map((d) => `${d.kind}:${d.key}`));

  const rows: SnapRow[] = [
    ...Object.keys(prov.sql || {}).map((k) => ({ kind: 'sql' as const, key: k, src: (prov.sql[k] || {}).source, fp: (prov.sql[k] || {}).fingerprint })),
    ...Object.keys(prov.models || {}).map((k) => ({ kind: 'model' as const, key: k, src: (prov.models[k] || {}).source, fp: (prov.models[k] || {}).fingerprint })),
    ...Object.keys(prov.knowledge || {}).map((k) => ({ kind: 'doc' as const, key: k, src: (prov.knowledge[k] || {}).source, fp: (prov.knowledge[k] || {}).fingerprint })),
  ];

  const embeddedContent = (kind: SnapRow['kind'], key: string) => {
    if (kind === 'sql') return (data.embedded_sqls || {})[key];
    if (kind === 'model') return (data.embedded_models || {})[key];
    return (data.embedded_docs || {})[key];
  };

  const shortFp = (fp: any) => (fp ? String(fp).slice(0, 8) : '—');

  const openSnapshot = (r: SnapRow) => {
    setEdit({ kind: r.kind, key: r.key, src: r.src, fp: r.fp });
    setContent(embeddedContent(r.kind, r.key) || '');
    setInstruction('');
    setStatus('');
  };

  const saveSnapshot = async () => {
    if (!edit) return;
    setSaving(true);
    try {
      await api.editSkillSnapshot(data.name, apiKindOf(edit.kind), edit.key, content);
      success(`已写回${kindLabel[edit.kind]}快照「${edit.key}」`);
      setEdit(null);
      onRefresh();
    } catch (e: any) {
      setStatus('❌ 保存失败：' + (e.message || '未知错误'));
    } finally { setSaving(false); }
  };

  const aiSnapshot = async () => {
    if (!edit) return;
    const inst = instruction.trim();
    if (!inst) { setStatus('请先填写改写要求'); return; }
    setAiLoading(true);
    setStatus('⏳ AI 改写中…');
    try {
      const r = await api.aiSkillSnapshot(data.name, apiKindOf(edit.kind), edit.key, inst);
      setContent(r.content || '');
      setStatus('✅ AI 已改写，请人审后点「保存」写回快照');
    } catch (e: any) {
      setStatus('❌ AI 改写失败：' + (e.message || '未知错误'));
    } finally { setAiLoading(false); }
  };

  const confirmDeleteSnapshot = async () => {
    if (!deleteTarget) return;
    const t = deleteTarget;
    setDeleteTarget(null);
    try {
      await api.deleteSkillSnapshot(data.name, apiKindOf(t.kind), t.key);
      success(`已删除快照「${t.key}」（运行回退全局源）`);
      onRefresh();
    } catch (e: any) {
      toastError(e.message || '删除失败');
    }
  };

  const saveNotes = async () => {
    if (!data.name) return;
    setNotesSaving(true);
    try {
      await api.setSkillNotes(data.name, notesText);
      success('已保存专项笔记');
      onRefresh();
    } catch (e: any) {
      toastError(e.message || '保存笔记失败');
    } finally {
      setNotesSaving(false);
    }
  };

  // 左右分割拖拽（审计 P2-12：pointer 捕获替代 window 监听/body cursor，触屏可拖；
  // 键盘微调由 VSplitHandle 的 value/onDelta 驱动，左右方向键步进 4%，clamp 与拖拽一致 20-80）
  const onVSplitPointerDown = (e: React.PointerEvent) => {
    const container = document.getElementById('skill-assoc-split');
    if (!container) return;
    e.currentTarget.setPointerCapture(e.pointerId);
    vsplitDragCtx.current = { rect: container.getBoundingClientRect() };
  };
  const onVSplitPointerMove = (e: React.PointerEvent) => {
    const ctx = vsplitDragCtx.current;
    if (!ctx) return;
    const pct = ((e.clientX - ctx.rect.left) / ctx.rect.width) * 100;
    setLeftPct(Math.min(80, Math.max(20, pct)));
  };
  const onVSplitPointerUp = () => { vsplitDragCtx.current = null; };
  const onVSplitKeyDelta = (px: number) => setLeftPct((cur) => Math.min(80, Math.max(20, cur + (px > 0 ? 4 : -4))));

  return (
    <div id="skill-assoc-split" style={{ height: '100%', display: 'flex', flexDirection: 'row', overflow: 'hidden' }}>
      {/* 左栏：关联情况（只读） */}
      <div style={{ width: `${leftPct}%`, minWidth: 0, overflowY: 'auto', padding: 12, backgroundColor: 'var(--surface-1)', borderRight: '1px solid var(--border-light)' }}>
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, alignItems: 'center', marginBottom: 8 }}>
          <span style={{ fontSize: 12, fontWeight: 600, color: 'var(--text-primary)' }}>关联情况</span>
          <span style={{ fontSize: 11, color: 'var(--text-muted)' }}>
            SQL {sqls.length} 条 · 文档 {docs.length} 篇 · 预测 {forecast ? `「${forecast}」` : '无'}
          </span>
        </div>

        {drift.length > 0 && (
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '6px 8px', borderRadius: 4, backgroundColor: 'var(--tint-amber-bg)', border: '1px solid var(--tint-amber-border)', marginBottom: 8 }}>
            <AlertTriangle size={13} style={{ color: '#f90', flexShrink: 0 }} />
            <span style={{ fontSize: 11, color: '#f90' }}>{drift.length} 个来源已更新，运行仍用冻结内容，需点「刷新快照」</span>
          </div>
        )}

        <Group label="关联 SQL" icon={<Database size={12} style={{ color: '#8ab4f8' }} />}>
          {sqls.length === 0 ? <Empty text="暂无关联 SQL" /> : sqls.map((s) => (
            <Row key={s} text={s} stale={stale.has(`sql:${s}`)} />
          ))}
        </Group>

        <Group label="关联文档" icon={<BookOpen size={12} style={{ color: '#5a8' }} />}>
          {docs.length === 0 ? <Empty text="暂无关联文档" /> : docs.map((d) => (
            <Row key={d} text={d} stale={stale.has(`doc:${d}`)} />
          ))}
        </Group>

        <Group label="关联预测能力" icon={<Sparkles size={12} style={{ color: '#f90' }} />}>
          <span style={{ fontSize: 11, color: 'var(--text-secondary)' }}>{forecast ? forecast : '不预测'}</span>
        </Group>
      </div>

      {/* 垂直分割线（审计 P2-12：pointer 捕获触屏可拖 + 键盘左右方向键微调） */}
      <div
        onPointerDown={onVSplitPointerDown}
        onPointerMove={onVSplitPointerMove}
        onPointerUp={onVSplitPointerUp}
        onPointerCancel={onVSplitPointerUp}
      >
        <VSplitHandle value={leftPct} onDelta={onVSplitKeyDelta} />
      </div>

      {/* 右栏：内嵌快照（可编辑 / AI 改写 / 删除） */}
      <div style={{ width: `${100 - leftPct}%`, minWidth: 0, overflowY: 'auto', padding: 12, backgroundColor: 'var(--surface-1)' }}>
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, alignItems: 'center', marginBottom: 8 }}>
          <span style={{ fontSize: 12, fontWeight: 600, color: 'var(--text-primary)' }}>内嵌快照</span>
          <span style={{ fontSize: 11, color: 'var(--text-muted)' }}>
            {nSql} SQL · {nModel} 模型 · {nDoc} 知识
          </span>
        </div>

        {data.bundle === false && (
          <p style={{ fontSize: 11, color: 'var(--text-muted)', margin: '0 0 8px' }}>旧格式专项（无内嵌快照）：重新点「保存」即可升级为自包含快照包。</p>
        )}

        <Group label="点名称编辑 · 🗑 删除回退全局源" icon={<Package size={12} style={{ color: 'var(--accent-amber)' }} />}>
          {rows.length === 0 ? <Empty text="（暂无快照）" /> : rows.map((r) => {
            const isStale = stale.has(`${r.kind}:${r.key}`);
            return (
              <div key={`${r.kind}:${r.key}`} style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
                <button onClick={() => openSnapshot(r)}
                  title={`查看 / 就地编辑冻结内容（源 ${r.src || '?'} · 指纹 ${shortFp(r.fp)}）`}
                  style={{ display: 'flex', alignItems: 'center', gap: 4, background: 'none', border: 'none', padding: 0, cursor: 'pointer', flex: 1, minWidth: 0 }}>
                  <Pencil size={11} style={{ color: 'var(--text-muted)', flexShrink: 0 }} />
                  <span style={{ fontSize: 11, color: isStale ? '#e74c3c' : 'var(--text-primary)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                    {kindLabel[r.kind]}「{r.key}」← {r.src || '?'} · {shortFp(r.fp)}
                  </span>
                  {isStale && <span style={{ color: '#e74c3c', fontSize: 10, flexShrink: 0 }}>源已更新</span>}
                </button>
                <button onClick={() => setDeleteTarget({ kind: r.kind, key: r.key })}
                  disabled={!canEdit}
                  aria-label={`删除快照 ${kindLabel[r.kind]}「${r.key}」`}
                  title={canEdit ? '删除该快照（回退全局源）' : '仅可查看（无新增/修改权限）'}
                  style={{ background: 'none', border: 'none', color: 'var(--text-inactive)', cursor: canEdit ? 'pointer' : 'not-allowed', padding: 0, display: 'flex', flexShrink: 0, opacity: canEdit ? 1 : 0.4 }}>
                  <Trash2 size={11} />
                </button>
              </div>
            );
          })}
        </Group>

        {/* 专项笔记：独立笔记槽（与其他快照分组一致——标题左对齐，条目点开再展示编辑） */}
        <Group label="专项笔记" icon={<NotebookPen size={12} style={{ color: '#5a8' }} />}>
          <button onClick={() => setNotesOpen((v) => !v)}
            title="点开查看 / 编辑本专项笔记（报告时随方法说明注入）"
            style={{ display: 'flex', alignItems: 'center', gap: 5, background: 'none', border: 'none', padding: 0, cursor: 'pointer' }}>
            {notesOpen ? <ChevronDown size={11} style={{ color: 'var(--text-muted)', flexShrink: 0 }} /> : <ChevronRight size={11} style={{ color: 'var(--text-muted)', flexShrink: 0 }} />}
            <span style={{ fontSize: 11, color: 'var(--text-primary)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
              点开查看 / 编辑{notesText ? `（${notesText.trim().length} 字）` : '（空）'}
            </span>
          </button>
          {notesOpen && (
            <div style={{ marginTop: 6 }}>
              <textarea value={notesText} onChange={(e) => setNotesText(e.target.value)} rows={6}
                placeholder="补充口径 / 经验 / 已知数据坑…"
                style={{ width: '100%', padding: '6px 8px', borderRadius: 4, border: '1px solid var(--text-muted)', backgroundColor: 'var(--surface-1)', color: 'var(--text-on-accent)', fontSize: 12, outline: 'none', resize: 'vertical', boxSizing: 'border-box', fontFamily: 'inherit' }} />
              <div style={{ display: 'flex', justifyContent: 'flex-end', marginTop: 6 }}>
                <button onClick={saveNotes} disabled={notesSaving || !canEdit} title={canEdit ? '保存笔记' : '仅可查看（无新增/修改权限）'}
                  style={{ display: 'flex', alignItems: 'center', gap: 4, padding: '4px 10px', borderRadius: 4, border: 'none', backgroundColor: 'var(--accent-blue)', color: '#fff', cursor: canEdit ? 'pointer' : 'not-allowed', fontSize: 11, opacity: notesSaving || !canEdit ? 0.6 : 1 }}>
                  <Save size={11} /> {notesSaving ? '保存中…' : '保存笔记'}
                </button>
              </div>
            </div>
          )}
        </Group>
      </div>

      {/* 快照编辑弹窗 */}
      {edit && (
        <div onClick={() => setEdit(null)} style={overlayStyle}>
          <div ref={editDialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={modalStyle}>
            <p style={{ margin: 0, fontSize: 13, fontWeight: 600, color: 'var(--text-primary)' }}>
              {kindLabel[edit.kind]}「{edit.key}」
            </p>
            <p style={{ margin: '4px 0 0', fontSize: 11, color: 'var(--text-muted)' }}>
              快照自「{edit.src || '?'}」· 源指纹 {shortFp(edit.fp)}（就地编辑只改冻结内容，不改源）
            </p>
            <textarea value={content} onChange={(e) => setContent(e.target.value)} rows={12}
              style={{ width: '100%', marginTop: 10, padding: '8px', borderRadius: 4, border: '1px solid var(--text-muted)', backgroundColor: 'var(--surface-1)', color: 'var(--text-on-accent)', fontSize: 12, outline: 'none', resize: 'vertical', boxSizing: 'border-box', fontFamily: 'var(--font-mono, monospace)' }} />
            <div style={{ display: 'flex', gap: 6, marginTop: 8 }}>
              <input value={instruction} onChange={(e) => setInstruction(e.target.value)}
                onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); aiSnapshot(); } }}
                placeholder="AI 改写要求（如：去掉 XX 字段、按日粒度聚合）"
                style={{ flex: 1, padding: '5px 8px', borderRadius: 4, border: '1px solid var(--text-muted)', backgroundColor: 'var(--surface-1)', color: 'var(--text-on-accent)', fontSize: 12, outline: 'none' }} />
              <button onClick={aiSnapshot} disabled={aiLoading}
                style={{ display: 'flex', alignItems: 'center', gap: 4, padding: '5px 10px', borderRadius: 4, border: 'none', backgroundColor: 'var(--accent-amber)', color: '#fff', cursor: 'pointer', fontSize: 12, opacity: aiLoading ? 0.6 : 1 }}>
                {aiLoading ? <Loader2 size={12} style={{ animation: 'spin 1s linear infinite' }} /> : <Wand2 size={12} />} AI 改写
              </button>
            </div>
            <div style={{ minHeight: 16, fontSize: 11, color: 'var(--text-secondary)', marginTop: 6 }}>{status}</div>
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end', marginTop: 8 }}>
              <button onClick={() => setEdit(null)} style={cancelBtn}>取消</button>
              <button onClick={saveSnapshot} disabled={saving || !canEdit} title={canEdit ? '保存' : '仅可查看（无新增/修改权限）'}
                style={{ ...saveBtn, opacity: saving || !canEdit ? 0.6 : 1 }}>
                <Save size={12} /> {saving ? '保存中…' : '保存'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* 删除快照确认弹窗 */}
      {deleteTarget && (
        <div onClick={() => setDeleteTarget(null)} style={overlayStyle}>
          <div ref={delDialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={confirmStyle}>
            <p style={{ margin: 0, fontSize: 13, color: 'var(--text-primary)' }}>确定删除「{deleteTarget.key}」的快照吗？</p>
            <p style={{ margin: '6px 0 0', fontSize: 11, color: 'var(--text-muted)' }}>删除后运行将回退到全局源。</p>
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end', marginTop: 14 }}>
              <button onClick={() => setDeleteTarget(null)} style={cancelBtn}>取消</button>
              <button onClick={confirmDeleteSnapshot} style={dangerBtn}>删除</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};

const Group: React.FC<{ label: string; icon: React.ReactNode; children: React.ReactNode }> = ({ label, icon, children }) => (
  <div style={{ marginBottom: 10 }}>
    <div style={{ display: 'flex', alignItems: 'center', gap: 5, marginBottom: 4 }}>
      {icon}
      <span style={{ fontSize: 11, fontWeight: 600, color: 'var(--text-secondary)' }}>{label}</span>
    </div>
    <div style={{ display: 'flex', flexDirection: 'column', gap: 2, paddingLeft: 17 }}>{children}</div>
  </div>
);

const Row: React.FC<{ text: string; stale: boolean }> = ({ text, stale }) => (
  <div style={{ display: 'flex', alignItems: 'center', gap: 5, fontSize: 11 }}>
    <span style={{ color: stale ? '#e74c3c' : 'var(--text-primary)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', flex: 1 }}>{text}</span>
    {stale && <span style={{ color: '#e74c3c', fontSize: 10, flexShrink: 0 }}>源已更新</span>}
  </div>
);

const Empty: React.FC<{ text: string }> = ({ text }) => <span style={{ fontSize: 11, color: 'var(--text-inactive)' }}>{text}</span>;

/** 左右分屏分隔条（审计 P2-12：role=separator + aria-orientation=vertical + 左右方向键微调；
 * 拖拽由父层 pointer 捕获驱动，value 供 aria-valuenow 回显）。 */
const VSplitHandle: React.FC<{ value?: number; onDelta?: (px: number) => void }> = ({ value, onDelta }) => {
  const [hovered, setHovered] = useState(false);
  return (
    <div
      role="separator"
      aria-orientation="vertical"
      aria-label="左右分屏分隔条"
      aria-valuenow={value == null ? undefined : Math.round(value)}
      aria-valuemin={0}
      aria-valuemax={100}
      tabIndex={onDelta ? 0 : undefined}
      onKeyDown={onDelta ? (e) => {
        if (e.key === 'ArrowRight') { e.preventDefault(); onDelta(40); }
        else if (e.key === 'ArrowLeft') { e.preventDefault(); onDelta(-40); }
      } : undefined}
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      style={{
        width: 5, cursor: 'col-resize', flexShrink: 0, touchAction: 'none',
        backgroundColor: hovered ? 'var(--accent-blue)' : 'var(--surface-1)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        borderLeft: '1px solid var(--border-light)', borderRight: '1px solid var(--border-light)',
        transition: 'background-color 0.15s',
      }}
    >
      <GripVertical size={10} style={{ color: hovered ? 'var(--accent-blue)' : 'var(--text-muted)' }} />
    </div>
  );
};

// 审计 P2-12 核验：遮罩统一复用 wsCommon.overlayStyle（带 padding:12，窄屏卡片不贴边），删除本地重复定义
const modalStyle: React.CSSProperties = { backgroundColor: 'var(--surface-2)', border: '1px solid var(--border-light)', borderRadius: 8, padding: '16px 18px', width: 'min(560px,94vw)', maxWidth: '92%', maxHeight: '80vh', overflowY: 'auto', boxShadow: '0 8px 30px rgba(0,0,0,0.3)' };
// 审计 P2-12：minWidth 改 width:min(Npx,94vw)，补 maxHeight 80vh 防窄屏溢出
const confirmStyle: React.CSSProperties = { backgroundColor: 'var(--surface-2)', border: '1px solid var(--border-light)', borderRadius: 8, padding: '16px 18px', width: 'min(300px,94vw)', maxWidth: '90%', maxHeight: '80vh', overflowY: 'auto', boxShadow: '0 8px 30px rgba(0,0,0,0.3)' };
const cancelBtn: React.CSSProperties = { padding: '5px 12px', borderRadius: 5, border: '1px solid var(--text-muted)', backgroundColor: 'transparent', color: 'var(--text-secondary)', cursor: 'pointer', fontSize: 12 };
const saveBtn: React.CSSProperties = { display: 'flex', alignItems: 'center', gap: 4, padding: '5px 12px', borderRadius: 5, border: 'none', backgroundColor: 'var(--accent-blue)', color: '#fff', cursor: 'pointer', fontSize: 12 };
const dangerBtn: React.CSSProperties = { padding: '5px 12px', borderRadius: 5, border: 'none', backgroundColor: '#e74c3c', color: '#fff', cursor: 'pointer', fontSize: 12 };

export default SkillAssociationPanel;
