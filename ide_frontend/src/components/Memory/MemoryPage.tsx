import React, { useState, useEffect } from 'react';
import { api } from '../../services/api';
import { useToast } from '../Toast';
import { ShareDialog } from '../ShareDialog';
import { downloadJson, pickJsonFile, exportFilename } from '../../lib/importExport';
import { overlayStyle, dialogStyle, saveCancelBtn, dangerBtn } from '../wsCommon';
import { useDialog } from '../../lib/useDialog';
import { Trash2, Edit3, Download, Upload } from 'lucide-react';

interface Memory {
  id: number;
  category: string;
  content: string;
  source: string;
  hit_count: number;
  scope: string;
  mem_type: string;   // 记忆增强：日常|专项|SQL|知识库|算法
  bind_name: string;  // 记忆增强：绑定的资产名（日常为空）
  created_at: string;
  updated_at: string;
}

/** 类型徽标配色（记忆增强 2026-10-21） */
const MEM_TYPE_STYLE: Record<string, React.CSSProperties> = {
  '日常': { backgroundColor: 'var(--surface-heavy)', color: 'var(--text-secondary)' },
  '专项': { backgroundColor: 'var(--tint-amber-bg)', color: 'var(--accent-amber-text)' },
  'SQL': { backgroundColor: 'var(--tint-blue-bg)', color: 'var(--accent-blue)' },
  '知识库': { backgroundColor: 'var(--tint-green-bg)', color: 'var(--success-text)' },
  '算法': { backgroundColor: 'var(--tint-red-bg)', color: 'var(--error-text)' },
};
const MEM_TYPES = ['日常', '专项', 'SQL', '知识库', '算法'];

export const MemoryPage: React.FC<{ active?: boolean }> = ({ active = true }) => {
  const { success, error: toastError } = useToast();

  // ── 记忆（记忆重组 2026-10-23：候选确认/术语/口径已迁出至「AI配置 → 术语与口径」，
  //    本页只承载个人记忆留档）──
  const [items, setItems] = useState<Memory[]>([]);
  const [loading, setLoading] = useState(false);
  const [search, setSearch] = useState('');
  const [filterCat, setFilterCat] = useState('');
  const [filterType, setFilterType] = useState('');  // 记忆增强：类型筛选
  const [selected, setSelected] = useState<Set<number>>(new Set());
  // 决策 5（2026-10-21）：新建/编辑弹窗 + 类型/绑定资产下拉（行内编辑移除，统一走弹窗）
  const [memDialog, setMemDialog] = useState<null | { mode: 'new' } | { mode: 'edit'; mem: Memory }>(null);
  const [memForm, setMemForm] = useState({ content: '', category: '', mem_type: '日常', bind_name: '' });
  const [memSaving, setMemSaving] = useState(false);
  const [assetOptions, setAssetOptions] = useState<{ skill: string[]; sql: string[]; doc: string[]; model: string[] }>(
    { skill: [], sql: [], doc: [], model: [] },
  );
  const memDialogRef = useDialog(memDialog !== null, () => { if (!memSaving) setMemDialog(null); });
  // 对抗验证 2026-10-21：load 是普通 async 闭包，重载后校验需最新序号，
  // 用 ref 序号守卫避免旧快照晚到覆盖新数据
  const loadSeqRef = React.useRef(0);
  // 外层激活沿：区分「外层切回」（只刷新记忆列表）与「内部 tab 切换」（按 tab 拉取）
  const prevActiveRef = React.useRef(false);
  const [shareOpen, setShareOpen] = useState(false);
  // 删除确认弹窗目标（审计 P2-5：内联确认替代 window.confirm）
  const [confirmDel, setConfirmDel] = useState<{ kind: 'one'; id: number } | { kind: 'selected'; count: number } | null>(null);

  // 审计 P2-12：删除确认弹窗接入 useDialog（Escape 关闭 + 打开聚焦 + 关闭还原焦点）
  const confirmDialogRef = useDialog(confirmDel !== null, () => setConfirmDel(null));

  const load = async () => {
    // 对抗验证 2026-10-21：请求序号守卫——切 tab 往返产生并发在途请求时，
    // 旧快照晚到不得覆盖新数据（F17 引入的重载路径上的竞态）
    const seq = ++loadSeqRef.current;
    setLoading(true);
    try {
      const res = await api.listMemories();
      if (seq !== loadSeqRef.current) return;
      const list = res.items || [];
      setItems(list);
      // 幽灵清理：勾选态裁剪到实际存在的行（同会话 agent 可能已删改），
      // 避免全选框错位、批量删除打到不存在的 id
      const ids = new Set(list.map((m: Memory) => m.id));
      setSelected(prev => {
        const next = new Set([...prev].filter(i => ids.has(i)));
        return next.size === prev.size ? prev : next;
      });
      // 编辑弹窗打开期间该记忆被删（同会话 agent 删除）→ 关闭弹窗避免保存打到已删 id
      setMemDialog(prev => (prev && prev.mode === 'edit' && !ids.has(prev.mem.id) ? null : prev));
    } catch {
      if (seq === loadSeqRef.current) toastError('加载记忆失败');
    }
    finally { if (seq === loadSeqRef.current) setLoading(false); }
  };

  // 首载由下方 effect 覆盖：唯一调用方（PersonalWorkspace）以 active=false 挂载，
  // 首次加载发生在外层切回（active false→true）时；这里不再单独挂载加载

  // 记忆增强 2026-10-21：memory 页随「个人定制」六 tab 常驻挂载，同会话内 agent 沉淀的
  // 新记忆不会自动出现——父层以 active prop 通知外层切回「个人记忆」tab，此处重新加载。
  useEffect(() => {
    const outerEnter = active && !prevActiveRef.current;
    prevActiveRef.current = active;
    if (!active) return; // 外层切走时不动（内容常驻）
    if (outerEnter) load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [active]);

  const filtered = items.filter(m => {
    const matchSearch = !search || m.content.includes(search) || m.category.includes(search) || (m.bind_name || '').includes(search);
    const matchCat = !filterCat || m.category === filterCat;
    const matchType = !filterType || (m.mem_type || '日常') === filterType;
    return matchSearch && matchCat && matchType;
  });

  const categories = [...new Set(items.map(m => m.category))].sort();

  const toggleSelect = (id: number) => {
    setSelected(prev => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  };

  const toggleAll = () => {
    if (selected.size === filtered.length) setSelected(new Set());
    else setSelected(new Set(filtered.map(m => m.id)));
  };

  // ── 新建/编辑弹窗（决策 5：类型 + 绑定资产下拉）──
  const loadAssetOptions = async () => {
    // 绑定资产候选：用户可见的专项/SQL/知识库文档/算法名。任一失败不影响编辑。
    try {
      const [sk, sq, dc, md] = await Promise.allSettled([
        api.listSkills(), api.listSqls(), api.listDocs(), api.listModels(),
      ]);
      setAssetOptions({
        skill: sk.status === 'fulfilled' ? (sk.value.skills || []).map((s: any) => s.name) : [],
        sql: sq.status === 'fulfilled' ? (sq.value.sqls || []).map((s: any) => s.name || '').filter(Boolean) : [],
        doc: dc.status === 'fulfilled' ? (dc.value.docs || []) : [],
        model: md.status === 'fulfilled' ? (((md.value as any).models || []) as any[]).map((m: any) => m.name || m) : [],
      });
    } catch { /* 非致命：下拉为空也可保存 */ }
  };

  const openMemDialog = (mode: 'new' | 'edit', m?: Memory) => {
    loadAssetOptions();
    if (m) {
      setMemForm({ content: m.content, category: m.category, mem_type: m.mem_type || '日常', bind_name: m.bind_name || '' });
      setMemDialog({ mode: 'edit', mem: m });
    } else {
      setMemForm({ content: '', category: '', mem_type: '日常', bind_name: '' });
      setMemDialog({ mode: 'new' });
    }
  };

  const saveMemDialog = async () => {
    const f = memForm;
    if (!f.content.trim()) { toastError('内容不能为空'); return; }
    const dlg = memDialog;
    if (!dlg) return;
    setMemSaving(true);
    try {
      // 日常类型不绑定资产：绑定下拉已禁用，保存时统一清空（后端「日常⇒无绑定」不变量双保险）
      const bind = f.mem_type === '日常' ? '' : f.bind_name.trim();
      if (dlg.mode === 'new') {
        await api.createMemory(f.content, f.category.trim() || 'data_note', 'private', f.mem_type, bind);
        success('已创建');
      } else {
        await api.updateMemory(dlg.mem.id, {
          content: f.content, category: f.category, mem_type: f.mem_type, bind_name: bind,
        });
        success('已更新');
      }
      setMemDialog(null);
      load();
    } catch (e: any) { toastError('保存失败: ' + (e?.message || '')); }
    finally { setMemSaving(false); }
  };

  const deleteOne = (id: number) => {
    setConfirmDel({ kind: 'one', id }); // 审计 P2-5：内联确认弹窗替代 window.confirm
  };

  const deleteSelected = () => {
    if (!selected.size) return;
    setConfirmDel({ kind: 'selected', count: selected.size }); // 审计 P2-5：内联确认弹窗替代 window.confirm
  };

  /** 删除确认弹窗「删除」按钮的执行体（审计 P2-5） */
  const confirmDelete = async () => {
    if (!confirmDel) return;
    const target = confirmDel;
    setConfirmDel(null);
    try {
      if (target.kind === 'one') {
        await api.deleteMemory(target.id);
        success('已删除');
      } else {
        for (const id of selected) { try { await api.deleteMemory(id); } catch {} }
        setSelected(new Set());
        success(`已删除 ${target.count} 条`);
      }
      load();
    } catch { toastError('删除失败'); }
  };

  const handleShare = async (targetUserIds: string[]) => {
    const res = await api.shareMemories([...selected], targetUserIds);
    success(`已分享 ${res.shared} 条记忆`);
  };

  const handleExport = async () => {
    try {
      const data = await api.exportMemories(selected.size > 0 ? [...selected] : undefined);
      downloadJson(data, exportFilename('memories'));
      success(`已导出 ${data.count} 条记忆`);
    } catch (e: any) { toastError('导出失败: ' + e.message); }
  };

  const handleImport = async () => {
    const data = await pickJsonFile();
    if (!data || !data.items) {
      if (data) toastError('文件格式不正确，缺少 items 字段');
      return;
    }
    try {
      const result = await api.importMemories(data.items);
      if (result.errors.length > 0) {
        toastError(`${result.errors.length} 条导入失败`);
      }
      success(`成功导入 ${result.created}/${result.total} 条记忆`);
      load();
    } catch (e: any) { toastError('导入失败: ' + e.message); }
  };

  const formatTime = (iso: string) => {
    const d = new Date(iso);
    const diff = Date.now() - d.getTime();
    const h = Math.floor(diff / 3600000);
    if (h < 1) return '刚才';
    if (h < 24) return `${h}小时前`;
    return `${Math.floor(h / 24)}天前`;
  };

  return (
    <div style={{ height: '100%', display: 'flex', flexDirection: 'column', padding: 16, gap: 12, overflow: 'hidden', backgroundColor: 'var(--surface-3)', color: 'var(--text-primary)' }}>
      {/* 记忆重组 2026-10-23：候选确认/术语/口径已迁至「AI配置 → 术语与口径」，本页只承载个人记忆 */}
      <div style={{ display: 'flex', gap: 2, borderBottom: '1px solid var(--border-light)', paddingBottom: 4, flexShrink: 0 }}>
        <span style={{ fontSize: 12, color: 'var(--text-muted)', padding: '4px 2px' }}>
          个人记忆（{items.length} 条）：对话中沉淀的口径/偏好/事实，深度分析按需召回，仅供你本人使用。
        </span>
      </div>

      <div style={{ flex: 1, minHeight: 0, overflowY: 'auto' }}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 8 }}>
              <div style={{ display: 'flex', gap: 8, flex: 1 }}>
                <input value={search} onChange={e => setSearch(e.target.value)} placeholder="搜索记忆内容..."
                  style={{ flex: 1, maxWidth: 240, padding: '5px 10px', borderRadius: 5, border: '1px solid var(--border-light)', backgroundColor: 'var(--surface-1)', color: 'var(--text-primary)', fontSize: 12, outline: 'none' }} />
                <select value={filterCat} onChange={e => setFilterCat(e.target.value)}
                  style={{ padding: '5px 8px', borderRadius: 5, border: '1px solid var(--border-light)', backgroundColor: 'var(--surface-1)', color: 'var(--text-primary)', fontSize: 12, cursor: 'pointer' }}>
                  <option value="">全部分类</option>
                  {categories.map(c => <option key={c} value={c}>{c}</option>)}
                </select>
                <select value={filterType} onChange={e => setFilterType(e.target.value)}
                  style={{ padding: '5px 8px', borderRadius: 5, border: '1px solid var(--border-light)', backgroundColor: 'var(--surface-1)', color: 'var(--text-primary)', fontSize: 12, cursor: 'pointer' }}>
                  <option value="">全部类型</option>
                  {MEM_TYPES.map(t => <option key={t} value={t}>{t}</option>)}
                </select>
              </div>
              <div style={{ display: 'flex', gap: 6 }}>
                <button onClick={() => openMemDialog('new')}
                  style={{ fontSize: 12, padding: '5px 12px', borderRadius: 5, border: 'none', backgroundColor: 'var(--accent-blue)', color: '#fff', cursor: 'pointer' }}>
                  新建记忆
                </button>
                <button onClick={handleImport}
                  style={{ fontSize: 12, padding: '5px 12px', borderRadius: 5, border: '1px solid var(--text-muted)', backgroundColor: 'transparent', color: 'var(--text-muted)', cursor: 'pointer' }}>
                  <Upload size={12} style={{ marginRight: 4, verticalAlign: 'middle' }} />
                  导入
                </button>
                {selected.size > 0 && (
                  <>
                    <button onClick={handleExport}
                      style={{ fontSize: 12, padding: '5px 12px', borderRadius: 5, border: '1px solid var(--text-muted)', backgroundColor: 'transparent', color: 'var(--text-muted)', cursor: 'pointer' }}>
                      <Download size={12} style={{ marginRight: 4, verticalAlign: 'middle' }} />
                      导出 ({selected.size})
                    </button>
                    <button onClick={() => setShareOpen(true)}
                      style={{ fontSize: 12, padding: '5px 12px', borderRadius: 5, border: '1px solid var(--accent-blue)', backgroundColor: 'transparent', color: 'var(--accent-blue)', cursor: 'pointer' }}>
                      批量分享 ({selected.size})
                    </button>
                    <button onClick={deleteSelected}
                      style={{ fontSize: 12, padding: '5px 12px', borderRadius: 5, border: '1px solid var(--tint-red-border)', backgroundColor: 'transparent', color: '#e74c3c', cursor: 'pointer' }}>
                      批量删除 ({selected.size})
                    </button>
                  </>
                )}
              </div>
            </div>

            {loading && <div style={{ textAlign: 'center', color: 'var(--text-muted)', fontSize: 12 }}>加载中...</div>}

            {!loading && filtered.length === 0 && (
              <div style={{ textAlign: 'center', color: 'var(--text-inactive)', fontSize: 12, marginTop: 30 }}>
                暂无记忆。Agent 在对话中调用 save_memory 后，记忆会出现在这里。
              </div>
            )}

            {filtered.length > 0 && (
              <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
                <thead>
                  <tr style={{ backgroundColor: 'var(--surface-heavy)', textAlign: 'left' }}>
                    <th style={{ padding: '6px 8px', width: 28 }}>
                      <input type="checkbox" checked={selected.size === filtered.length && filtered.length > 0} onChange={toggleAll} />
                    </th>
                    <th style={{ padding: '6px 8px', width: 100 }}>分类</th>
                    <th style={{ padding: '6px 8px', width: 120 }}>类型/绑定</th>
                    <th style={{ padding: '6px 8px' }}>内容</th>
                    <th style={{ padding: '6px 8px', width: 60 }}>来源</th>
                    <th style={{ padding: '6px 8px', width: 40 }}>命中</th>
                    <th style={{ padding: '6px 8px', width: 70 }}>时间</th>
                    <th style={{ padding: '6px 8px', width: 70 }}>操作</th>
                  </tr>
                </thead>
                <tbody>
                  {filtered.map(m => (
                    <tr key={m.id} style={{ borderBottom: '1px solid var(--border-light)' }}>
                      <td style={{ padding: '6px 8px' }}>
                        <input type="checkbox" checked={selected.has(m.id)} onChange={() => toggleSelect(m.id)} />
                      </td>
                      <td style={{ padding: '6px 8px', color: 'var(--accent-amber-text)', whiteSpace: 'nowrap' }}>
                        {m.category}
                      </td>
                      <td style={{ padding: '6px 8px' }}>
                        <span style={{ ...(MEM_TYPE_STYLE[m.mem_type] || MEM_TYPE_STYLE['日常']), padding: '1px 6px', borderRadius: 3, fontSize: 10, whiteSpace: 'nowrap' }}>
                          {m.mem_type || '日常'}
                        </span>
                        {m.bind_name ? (
                          <span style={{ display: 'block', marginTop: 2, fontSize: 10, color: 'var(--text-muted)', whiteSpace: 'nowrap' }}>
                            {m.bind_name}
                          </span>
                        ) : null}
                      </td>
                      <td style={{ padding: '6px 8px', color: 'var(--text-primary)' }}>
                        <span style={{ display: '-webkit-box', WebkitLineClamp: 2, WebkitBoxOrient: 'vertical', overflow: 'hidden' }}>{m.content}</span>
                      </td>
                      <td style={{ padding: '6px 8px', color: 'var(--text-muted)' }}>
                        <span style={{ padding: '1px 5px', borderRadius: 3, backgroundColor: m.source === 'agent' ? 'var(--tint-blue-bg)' : 'var(--surface-heavy)', fontSize: 10 }}>
                          {m.source}
                        </span>
                      </td>
                      <td style={{ padding: '6px 8px', textAlign: 'center', color: 'var(--text-muted)' }}>{m.hit_count}</td>
                      <td style={{ padding: '6px 8px', color: 'var(--text-muted)' }}>{formatTime(m.updated_at || m.created_at)}</td>
                      <td style={{ padding: '6px 8px' }}>
                        <div style={{ display: 'flex', gap: 4 }}>
                          {/* 审计 P2-12：纯图标按钮补 aria-label；决策 5：编辑统一走弹窗（含类型/绑定下拉） */}
                          <button onClick={() => openMemDialog('edit', m)} title="编辑" aria-label="编辑"
                            style={{ background: 'none', border: 'none', cursor: 'pointer', color: 'var(--text-muted)', padding: 2 }}><Edit3 size={13} /></button>
                          <button onClick={() => deleteOne(m.id)} title="删除" aria-label="删除"
                            style={{ background: 'none', border: 'none', cursor: 'pointer', color: '#e74c3c', padding: 2 }}><Trash2 size={13} /></button>
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>
      </div>

      <ShareDialog
        open={shareOpen}
        onClose={() => setShareOpen(false)}
        onShare={handleShare}
        count={selected.size}
        showModeSelect={false}
      />

      {/* 新建/编辑记忆弹窗（决策 5：类型 5 选 1 + 绑定资产下拉；日常类型禁用绑定） */}
      {memDialog && (
        <div onClick={() => { if (!memSaving) setMemDialog(null); }} style={overlayStyle}>
          <div ref={memDialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={{ ...dialogStyle, width: 'min(520px, 92vw)' }}>
            <p style={{ margin: 0, fontSize: 14, fontWeight: 600, color: 'var(--text-primary)' }}>
              {memDialog.mode === 'new' ? '新建记忆' : '编辑记忆'}
            </p>
            <div style={{ marginTop: 12, display: 'flex', flexDirection: 'column', gap: 10 }}>
              <div>
                <label style={{ fontSize: 12, color: 'var(--text-secondary)', display: 'block', marginBottom: 4 }}>内容</label>
                <textarea value={memForm.content} onChange={e => setMemForm(f => ({ ...f, content: e.target.value }))} rows={4}
                  placeholder="值得记住的口径/偏好/事实..."
                  style={{ width: '100%', padding: '8px 10px', borderRadius: 5, border: '1px solid var(--border-light)', backgroundColor: 'var(--surface-1)', color: 'var(--text-primary)', fontSize: 12.5, outline: 'none', resize: 'vertical', boxSizing: 'border-box', fontFamily: 'inherit' }} />
              </div>
              <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap' }}>
                <div style={{ flex: 1, minWidth: 140 }}>
                  <label style={{ fontSize: 12, color: 'var(--text-secondary)', display: 'block', marginBottom: 4 }}>分类</label>
                  <input value={memForm.category} onChange={e => setMemForm(f => ({ ...f, category: e.target.value }))}
                    placeholder="data_note"
                    style={{ width: '100%', padding: '6px 10px', borderRadius: 5, border: '1px solid var(--border-light)', backgroundColor: 'var(--surface-1)', color: 'var(--text-primary)', fontSize: 12.5, outline: 'none', boxSizing: 'border-box' }} />
                </div>
                <div style={{ flex: 1, minWidth: 140 }}>
                  <label style={{ fontSize: 12, color: 'var(--text-secondary)', display: 'block', marginBottom: 4 }}>类型</label>
                  <select value={memForm.mem_type} onChange={e => setMemForm(f => ({ ...f, mem_type: e.target.value }))}
                    style={{ width: '100%', padding: '6px 10px', borderRadius: 5, border: '1px solid var(--border-light)', backgroundColor: 'var(--surface-1)', color: 'var(--text-primary)', fontSize: 12.5, outline: 'none', cursor: 'pointer' }}>
                    {MEM_TYPES.map(t => <option key={t} value={t}>{t}</option>)}
                  </select>
                </div>
              </div>
              <div>
                <label style={{ fontSize: 12, color: 'var(--text-secondary)', display: 'block', marginBottom: 4 }}>绑定资产</label>
                <select value={memForm.bind_name} disabled={memForm.mem_type === '日常'}
                  onChange={e => setMemForm(f => ({ ...f, bind_name: e.target.value }))}
                  style={{ width: '100%', padding: '6px 10px', borderRadius: 5, border: '1px solid var(--border-light)', backgroundColor: memForm.mem_type === '日常' ? 'var(--surface-heavy)' : 'var(--surface-1)', color: 'var(--text-primary)', fontSize: 12.5, outline: 'none', cursor: memForm.mem_type === '日常' ? 'not-allowed' : 'pointer', opacity: memForm.mem_type === '日常' ? 0.6 : 1 }}>
                  <option value="">不绑定</option>
                  {assetOptions.skill.length > 0 && (
                    <optgroup label="专项">
                      {assetOptions.skill.map(n => <option key={`s_${n}`} value={n}>{n}</option>)}
                    </optgroup>
                  )}
                  {assetOptions.sql.length > 0 && (
                    <optgroup label="SQL">
                      {assetOptions.sql.map(n => <option key={`q_${n}`} value={n}>{n}</option>)}
                    </optgroup>
                  )}
                  {assetOptions.doc.length > 0 && (
                    <optgroup label="知识库文档">
                      {assetOptions.doc.map(n => <option key={`d_${n}`} value={n}>{n}</option>)}
                    </optgroup>
                  )}
                  {assetOptions.model.length > 0 && (
                    <optgroup label="算法模型">
                      {assetOptions.model.map(n => <option key={`m_${n}`} value={n}>{n}</option>)}
                    </optgroup>
                  )}
                </select>
                <p style={{ margin: '4px 0 0', fontSize: 11, color: 'var(--text-muted)', lineHeight: 1.6 }}>
                  {memForm.mem_type === '日常'
                    ? '日常类型不绑定资产（保存时自动清空）。'
                    : '绑定后，提问命中资产名时该记忆优先召回。想解除绑定请选类型「日常」——「日常」下保存即解绑。'}
                </p>
              </div>
            </div>
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end', marginTop: 16 }}>
              <button onClick={() => { if (!memSaving) setMemDialog(null); }} style={saveCancelBtn} disabled={memSaving}>取消</button>
              <button onClick={saveMemDialog} disabled={memSaving}
                style={{ ...saveCancelBtn, backgroundColor: 'var(--accent-blue)', color: '#fff', border: 'none', cursor: memSaving ? 'not-allowed' : 'pointer', opacity: memSaving ? 0.6 : 1 }}>
                {memSaving ? '保存中...' : '保存'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* 删除确认弹窗（审计 P2-5：自研内联确认，替代 window.confirm） */}
      {confirmDel && (
        <div onClick={() => setConfirmDel(null)} style={overlayStyle}>
          {/* 审计 P2-12：role/aria-modal/tabIndex 弹窗语义 */}
          <div ref={confirmDialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={dialogStyle}>
            <p style={{ margin: 0, fontSize: 13, color: 'var(--text-primary)' }}>
              {confirmDel.kind === 'one' ? '确认删除这条记忆？' : `确认删除 ${confirmDel.count} 条记忆？`}
            </p>
            <p style={{ margin: '6px 0 0', fontSize: 11, color: 'var(--text-muted)' }}>此操作不可撤销。</p>
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end', marginTop: 14 }}>
              <button onClick={() => setConfirmDel(null)} style={saveCancelBtn}>取消</button>
              <button onClick={confirmDelete} style={dangerBtn}>删除</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};
