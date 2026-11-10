import React from 'react';
import { GripHorizontal, Plus, X } from 'lucide-react';
import { useStore } from '../stores/useStore';
import { useDialog } from '../lib/useDialog';

/**
 * 各工作台共享外壳小件（P1-12 收敛）：侧栏 Tab 条 / 多窗口 Tab 条 / 分屏拖拽条 /
 * 列宽拖拽 hook+手柄 / 保存弹窗 / 竖条按钮 / 通用弹窗与按钮样式 / 字节格式化。
 * 由 SqlWorkspace / SkillWorkspace / KnowledgeWorkspace / ModelsWorkspace 及各列表侧栏
 * 共享，避免逐字复制（原四类复制：侧栏拖拽×3-4、上下分屏×3、保存弹窗×3、竖条按钮×4）。
 */

/** ask_user 收口消息正文末尾的「N. 选项」编号列表（下一轮用户按编号回复的映射依据）：
 * 渲染时剥离，避免与下方可点选项卡片重复展示；任何一行对不上（选项文本含换行等）则原样返回 */
export const stripOptionLines = (content: string, options: string[] | undefined) => {
  if (!options || !options.length) return content;
  const lines = content.split('\n');
  let end = lines.length;
  for (let i = options.length; i >= 1; i--) {
    const expect = `${i}. ${options[i - 1]}`.trim();
    if ((lines[end - 1] || '').trim() === expect) end -= 1;
    else break;
  }
  return end === lines.length ? content : lines.slice(0, end).join('\n');
};

export const SideTab: React.FC<{ icon: React.ReactNode; label: string; active: boolean; onClick: () => void }> = ({ icon, label, active, onClick }) => (
  <button
    onClick={onClick}
    title={label}
    aria-label={label}
    aria-pressed={active}
    style={{
      width: 'var(--col-iconbar)', height: 40, display: 'flex', alignItems: 'center', justifyContent: 'center',
      border: 'none', borderLeft: active ? '3px solid var(--accent-blue)' : '3px solid transparent',
      backgroundColor: active ? 'var(--surface-1)' : 'transparent', color: active ? 'var(--text-primary)' : 'var(--text-inactive)',
      cursor: 'pointer', flexShrink: 0,
      transition: 'background-color 0.1s, color 0.1s',
    }}
    onMouseEnter={(e) => { if (!active) (e.currentTarget as HTMLElement).style.color = 'var(--text-secondary)'; }}
    onMouseLeave={(e) => { if (!active) (e.currentTarget as HTMLElement).style.color = 'var(--text-inactive)'; }}
  >
    {icon}
  </button>
);

/** 多窗口 tab 条（专项/知识库工作台共用，镜像 SQL 的 EditorTabs，去掉行数控件）。
 * 审计 P2-12：role=tablist/tab + Enter/Space 切换 + 关闭钮 aria-label。 */
export const WindowTabs: React.FC<{
  tabs: { id: string; label: string }[];
  activeId: string | null;
  onSwitch: (id: string) => void;
  onClose: (id: string) => void;
  onNew: () => void;
  newTitle?: string;
}> = ({ tabs, activeId, onSwitch, onClose, onNew, newTitle = '新建窗口' }) => (
  <div style={{ display: 'flex', alignItems: 'center', borderBottom: '1px solid var(--border-light)', backgroundColor: 'var(--surface-1)', flexShrink: 0 }}>
    <div role="tablist" aria-label="窗口标签页" style={{ display: 'flex', alignItems: 'center', flex: 1, minWidth: 0, overflowX: 'auto', overflowY: 'hidden' }}>
      {tabs.map((t) => {
        const active = t.id === activeId;
        return (
          <div key={t.id}
            role="tab" aria-selected={active} tabIndex={0}
            onClick={() => onSwitch(t.id)}
            onKeyDown={(e) => {
              // 焦点在关闭按钮上时，Enter/Space 交给按钮自身合成 click（关闭而非切换），不拦截
              if (e.target !== e.currentTarget) return;
              if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onSwitch(t.id); }
            }}
            style={{
              display: 'flex', alignItems: 'center', gap: 6, padding: '5px 10px', cursor: 'pointer', fontSize: 12,
              color: active ? 'var(--text-primary)' : 'var(--text-muted)',
              borderRight: '1px solid var(--surface-heavy)',
              backgroundColor: active ? 'var(--surface-2)' : 'transparent',
              borderBottom: active ? '2px solid var(--accent-blue)' : '2px solid transparent',
              whiteSpace: 'nowrap', userSelect: 'none', maxWidth: 160, flexShrink: 0,
            }}>
            <span style={{ overflow: 'hidden', textOverflow: 'ellipsis' }}>{t.label}</span>
            {tabs.length > 1 && (
              <button onClick={(e) => { e.stopPropagation(); onClose(t.id); }}
                aria-label={`关闭 ${t.label}`}
                style={{ background: 'none', border: 'none', color: 'var(--text-muted)', cursor: 'pointer', padding: 0, display: 'flex' }}>
                <X size={11} />
              </button>
            )}
          </div>
        );
      })}
      <button onClick={onNew} title={newTitle} aria-label={newTitle}
        style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', padding: '5px 10px', border: 'none', background: 'none', color: 'var(--text-muted)', cursor: 'pointer', fontSize: 14, flexShrink: 0 }}>
        <Plus size={14} />
      </button>
    </div>
  </div>
);

/** 上下分屏拖拽条。审计 P2-12：pointer 事件（触屏可拖）+ role=separator + 方向键微调。
 * onMouseDown 仅作旧调用兼容；新代码传 onPointerDown（配 setPointerCapture）、
 * value（0-100，供 aria-valuenow）与 onDelta（键盘微调，正值向下/向右）。 */
export const SplitHandle: React.FC<{
  onMouseDown?: (e: React.MouseEvent) => void;
  onPointerDown?: (e: React.PointerEvent) => void;
  value?: number;
  onDelta?: (px: number) => void;
  ariaLabel?: string;
}> = ({ onMouseDown, onPointerDown, value, onDelta, ariaLabel = '分屏分隔条' }) => {
  const [hovered, setHovered] = React.useState(false);
  return (
    <div
      onMouseDown={onMouseDown}
      onPointerDown={onPointerDown}
      role="separator"
      aria-orientation="horizontal"
      aria-label={ariaLabel}
      aria-valuenow={value == null ? undefined : Math.round(value)}
      aria-valuemin={0}
      aria-valuemax={100}
      tabIndex={onDelta ? 0 : undefined}
      onKeyDown={onDelta ? (e) => {
        if (e.key === 'ArrowDown' || e.key === 'ArrowRight') { e.preventDefault(); onDelta(40); }
        else if (e.key === 'ArrowUp' || e.key === 'ArrowLeft') { e.preventDefault(); onDelta(-40); }
      } : undefined}
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      style={{
        height: 5, cursor: 'row-resize', flexShrink: 0, touchAction: 'none',
        backgroundColor: hovered ? 'var(--accent-blue)' : 'var(--surface-1)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        borderTop: '1px solid var(--border-light)', borderBottom: '1px solid var(--border-light)',
        transition: 'background-color 0.15s',
      }}
    >
      <GripHorizontal size={10} style={{ color: hovered ? 'var(--accent-blue)' : 'var(--text-muted)' }} />
    </div>
  );
};

// ── P1-12 收敛：列宽拖拽 hook + 手柄 / 分屏拖拽 hook ──

/** 侧栏列宽拖拽（审计 P2-12：pointer 捕获替代 window/document 鼠标监听与 body 光标，
 * 触屏可拖；拖拽起点以拖柄所在列的实际渲染宽度为基准，兼容 var() 响应式默认宽）。
 * 单个 ref 支持多列复用：onPointerDown(colKey, getW?) 返回该列手柄的事件处理函数。
 * getW 覆盖默认起点宽（默认取手柄父元素宽；SQL 工作台按 col-<idx> 元素取宽）。
 * stepPx 为左右方向键微调步进（默认 40，SQL 工作台用 20）。 */
export interface ColDragApi {
  onPointerDown: (colKey: string, getW?: (handle: HTMLElement) => number) => (e: React.PointerEvent<HTMLDivElement>) => void;
  onPointerMove: (e: React.PointerEvent<HTMLDivElement>) => void;
  onPointerUp: () => void;
  onKeyDown: (colKey: string, getW?: (handle: HTMLElement) => number) => (e: React.KeyboardEvent<HTMLDivElement>) => void;
}

export function useColWidthDrag(stepPx = 40): ColDragApi {
  const dragRef = React.useRef<{ colKey: string; startW: number; startX: number } | null>(null);
  const setSidebarColWidths = useStore((s) => s.setSidebarColWidths);
  const parentW = (handle: HTMLElement) => (handle.parentElement ? handle.parentElement.getBoundingClientRect().width : 240);
  return {
    onPointerDown: (colKey, getW) => (e) => {
      e.preventDefault();
      (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
      dragRef.current = { colKey, startW: (getW || parentW)(e.currentTarget as HTMLElement), startX: e.clientX };
    },
    onPointerMove: (e) => {
      const d = dragRef.current;
      if (!d) return;
      const delta = e.clientX - d.startX;
      const cur = useStore.getState().sidebarColWidths || {};
      setSidebarColWidths({ ...cur, [d.colKey]: Math.max(120, d.startW + delta) });
    },
    onPointerUp: () => { dragRef.current = null; },
    onKeyDown: (colKey, getW) => (e) => {
      if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
      e.preventDefault();
      const startW = (getW || parentW)(e.currentTarget as HTMLElement);
      const next = e.key === 'ArrowRight' ? startW + stepPx : startW - stepPx;
      const cur = useStore.getState().sidebarColWidths || {};
      setSidebarColWidths({ ...cur, [colKey]: Math.max(120, next) });
    },
  };
}

/** 列宽手柄统一样式（绝对定位贴列右缘） */
export const colHandleStyle: React.CSSProperties = { position: 'absolute', top: 0, bottom: 0, width: 4, cursor: 'col-resize', backgroundColor: 'transparent', zIndex: 5, right: 0, touchAction: 'none' };

/** 侧栏列宽拖拽手柄（审计 P2-12：role=separator + 左右方向键微调 + 悬停高亮）。
 * drag 来自 useColWidthDrag；getW/keyGetW 覆盖默认（父元素）起点宽，缺省同 getW。 */
export const ColResizeHandle: React.FC<{
  drag: ColDragApi;
  colKey: string;
  label: string;
  getW?: (handle: HTMLElement) => number;
  keyGetW?: (handle: HTMLElement) => number;
}> = ({ drag, colKey, label, getW, keyGetW }) => (
  <div
    onPointerDown={drag.onPointerDown(colKey, getW)}
    onPointerMove={drag.onPointerMove}
    onPointerUp={drag.onPointerUp}
    onPointerCancel={drag.onPointerUp}
    onKeyDown={drag.onKeyDown(colKey, keyGetW || getW)}
    tabIndex={0}
    role="separator"
    aria-orientation="vertical"
    aria-label={`调整「${label}」栏宽度（左右方向键微调）`}
    aria-valuemin={120}
    style={colHandleStyle}
    onMouseEnter={(e) => { (e.currentTarget as HTMLElement).style.backgroundColor = 'var(--accent-blue-faint)'; }}
    onMouseLeave={(e) => { (e.currentTarget as HTMLElement).style.backgroundColor = 'transparent'; }}
  />
);

// ── 侧栏向左合并（专项/知识库/算法 双栏，仿 SQL 管理）：合并控制 + 堆叠分栏手柄 ──

/** 侧栏列右上角浮动合并控制（仿 SQL 管理 sidebar-ctrl）：◀ 合并到左列 / ▶ 恢复独立列。
 * 悬于各栏头部（高约 42px）之下（top:46）：不覆盖头部右上角的清空/关闭按钮
 * （对抗审查 correctness/frontend 轮确认的点击截走问题）；24×24 命中区满足 WCAG 2.5.8。
 * 对齐 SQL 管理交互：容器挂 sidebar-ctrl class，默认隐藏、悬停所在侧栏项
 * （祖先挂 sidebar-item）才显示（index.css:134-136；触屏无 hover 常显）。
 * mergeDisabled：第 0 列（列表列）恒禁用的 ◀（对齐 SQL 管理 colIdx<=0 的禁用态），
 * 让「左侧目录栏所有列都有合并按钮」的感知一致。 */
export const ColMergeCtrl: React.FC<{
  onMergeLeft?: () => void;
  onRestore?: () => void;
  mergeDisabled?: boolean;
}> = ({ onMergeLeft, onRestore, mergeDisabled = false }) => (
  <div className="sidebar-ctrl" style={{ position: 'absolute', top: 46, right: 4, zIndex: 10, display: 'flex', gap: 2 }}>
    {(onMergeLeft || mergeDisabled) && (
      <button onClick={onMergeLeft} disabled={mergeDisabled} title="向左合并" aria-label="向左合并"
        style={{
          ...colMergeCtrlBtn,
          cursor: mergeDisabled ? 'default' : 'pointer',
          color: mergeDisabled ? 'var(--text-muted)' : 'var(--text-secondary)',
          // 禁用 ◀ 是纯展示控件（列表列恒为最左列）：不参与命中测试，点击穿透到下层列表行，
          // 触屏常显态（hover:none）也不会在列表首行右缘留下吞掉点击的 24×24 死区（对抗审查修复）
          pointerEvents: mergeDisabled ? 'none' : undefined,
        }}>◀</button>
    )}
    {onRestore && (
      <button onClick={onRestore} title="恢复独立列" aria-label="恢复独立列"
        style={colMergeCtrlBtn}>▶</button>
    )}
  </div>
);

const colMergeCtrlBtn: React.CSSProperties = {
  background: 'rgba(0,0,0,0.6)', border: 'none', cursor: 'pointer',
  width: 24, height: 24, padding: 0, borderRadius: 3, fontSize: 11,
  color: 'var(--text-secondary)', display: 'flex', alignItems: 'center', justifyContent: 'center',
};

/** 合并列内上下堆叠分栏手柄（审计 P2-12 口径：pointer 捕获触屏可拖 + role=separator +
 * 键盘 ArrowUp/ArrowDown 步进 0.1；value/onFlex 为上半栏 flex 占比，clamp 0.15-0.85）。 */
export const ColStackSplit: React.FC<{ value: number; onFlex: (v: number) => void; label: string }> = ({ value, onFlex, label }) => {
  const ref = React.useRef<{ startY: number; startFlex: number; totalH: number } | null>(null);
  const clamp = (v: number) => Math.min(0.85, Math.max(0.15, v));
  return (
    <div
      onPointerDown={(e) => {
        e.preventDefault();
        e.currentTarget.setPointerCapture(e.pointerId);
        const parent = e.currentTarget.parentElement;
        ref.current = { startY: e.clientY, startFlex: value, totalH: parent ? parent.getBoundingClientRect().height : 300 };
      }}
      onPointerMove={(e) => {
        const d = ref.current;
        if (!d) return;
        onFlex(clamp(d.startFlex + (e.clientY - d.startY) / d.totalH));
      }}
      onPointerUp={() => { ref.current = null; }}
      onPointerCancel={() => { ref.current = null; }}
      onKeyDown={(e) => {
        if (e.key !== 'ArrowUp' && e.key !== 'ArrowDown') return;
        e.preventDefault();
        onFlex(clamp(value + (e.key === 'ArrowDown' ? 0.1 : -0.1)));
      }}
      tabIndex={0}
      role="separator"
      aria-orientation="horizontal"
      aria-label={label}
      aria-valuenow={Math.round(value * 100)}
      aria-valuemin={15}
      aria-valuemax={85}
      style={{
        height: 4, cursor: 'row-resize', touchAction: 'none', backgroundColor: 'var(--surface-1)',
        flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center',
        borderTop: '1px solid var(--border-light)', borderBottom: '1px solid var(--border-light)',
      }}
    >
      <GripHorizontal size={10} style={{ color: 'var(--text-inactive)' }} />
    </div>
  );
};

/** 动作后果确认弹窗（自动关联 / 自动快照 / 刷新快照 共用）：说明清楚该动作会造成的结果，
 * 点「确认执行」后才真正发起；busy 期间取消按钮禁用（动作已在途，不可反悔）。 */
export const ActionConfirmDialog: React.FC<{
  open: boolean;
  title: string;
  lines: string[];
  confirmLabel?: string;
  busy?: boolean;
  onCancel: () => void;
  onConfirm: () => void;
}> = ({ open, title, lines, confirmLabel = '确认执行', busy = false, onCancel, onConfirm }) => {
  const dialogRef = useDialog(open, onCancel);
  if (!open) return null;
  return (
    <div onClick={onCancel} style={overlayStyle}>
      <div ref={dialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={dialogStyle}>
        <p style={{ margin: 0, fontSize: 13, color: 'var(--text-primary)', fontWeight: 600 }}>{title}</p>
        <ul style={{ margin: '10px 0 0', paddingLeft: 18, fontSize: 12, color: 'var(--text-secondary)', lineHeight: 1.9 }}>
          {lines.map((l, i) => <li key={i}>{l}</li>)}
        </ul>
        <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end', marginTop: 14 }}>
          <button onClick={onCancel} disabled={busy} style={saveCancelBtn}>取消</button>
          <button onClick={onConfirm} disabled={busy} style={{ ...saveConfirmBtn, opacity: busy ? 0.6 : 1 }}>{busy ? '执行中…' : confirmLabel}</button>
        </div>
      </div>
    </div>
  );
};

/** 上下分屏拖拽（审计 P2-12：pointer 捕获替代 window 监听/body cursor，触屏可拖）。
 * onPointerDown 挂 SplitHandle（捕获后事件冒泡），onPointerMove/Up 挂分屏容器；
 * 键盘微调由 SplitHandle 的 value/onDelta 驱动（onKeyDelta），clamp 与拖拽一致。 */
export function useSplitDrag(containerId: string, opts: { setPos: (v: number) => void; getPos: () => number; min?: number; max?: number; stepPx?: number }) {
  const { setPos, getPos, min = 15, max = 85, stepPx = 4 } = opts;
  const ctxRef = React.useRef<{ rect: DOMRect } | null>(null);
  return {
    onPointerDown: (e: React.PointerEvent) => {
      e.preventDefault();
      const container = document.getElementById(containerId);
      if (!container) return;
      (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
      ctxRef.current = { rect: container.getBoundingClientRect() };
    },
    onPointerMove: (e: React.PointerEvent) => {
      const ctx = ctxRef.current;
      if (!ctx) return;
      const pct = ((e.clientY - ctx.rect.top) / ctx.rect.height) * 100;
      setPos(Math.min(max, Math.max(min, pct)));
    },
    onPointerUp: () => { ctxRef.current = null; },
    onKeyDelta: (px: number) => setPos(Math.min(max, Math.max(min, getPos() + (px > 0 ? stepPx : -stepPx)))),
  };
}

// ── P1-12 收敛：保存弹窗 + 竖条按钮 ──

// 机密档位（L1绝密/L2机密/L3秘密）：资产是单档位，身份/用户是多档位集合
export const CONFIDENTIALITY_LEVELS = ['L1', 'L2', 'L3'] as const;
export const CONFIDENTIALITY_LABELS: Record<string, string> = { L1: 'L1·绝密', L2: 'L2·机密', L3: 'L3·秘密' };
const CONF_COLORS: Record<string, string> = { L1: '#e74c3c', L2: '#e67e22', L3: '#2980b9' };

/** 资产机密档位徽标；未分级（空/非法）不渲染。 */
export const ConfidentialityBadge: React.FC<{ value?: string | null }> = ({ value }) => {
  if (!value || !(CONFIDENTIALITY_LEVELS as readonly string[]).includes(value)) return null;
  return (
    <span title={`机密档位 ${CONFIDENTIALITY_LABELS[value]}`} style={{
      fontSize: 10, lineHeight: 1, padding: '1px 5px', borderRadius: 3, fontWeight: 600, flexShrink: 0,
      color: CONF_COLORS[value], border: `1px solid ${CONF_COLORS[value]}`, backgroundColor: 'transparent',
    }}>{CONFIDENTIALITY_LABELS[value]}</span>
  );
};

const saveNameFieldStyle: React.CSSProperties = { display: 'block', width: '100%', marginTop: 4, padding: '6px 8px', borderRadius: 4, border: '1px solid var(--text-muted)', backgroundColor: 'var(--surface-1)', color: 'var(--text-on-accent)', fontSize: 12, outline: 'none', boxSizing: 'border-box' };

/** 保存/另存为弹窗（名称 + 层级 通用/项目/个人；个人定制上下文锁层级只读展示）。
 * 审计 P2-12：useDialog 提供 Escape 关闭 + 打开聚焦 + 关闭焦点还原。
 * 2026-10-27 用户反馈：遮罩点击不再关闭弹窗——有名称输入的保存弹窗点外面误触即消失
 * 会丢已输入内容，只允许「取消/确认」按钮关闭（Escape 保留，是有意按键、无键盘焦点丢失）。 */
export const SaveNameDialog: React.FC<{
  open: boolean;
  title: string;
  label: string;
  placeholder?: string;
  name: string;
  onName: (v: string) => void;
  scopeLevel?: string | null;
  level: string;
  onLevel: (v: string) => void;
  saving: boolean;
  onCancel: () => void;
  onConfirm: () => void;
  /** 机密档位（可选）：传入 onConfidentiality 时渲染单档位下拉（未分级/L1/L2/L3） */
  confidentiality?: string | null;
  onConfidentiality?: (v: string | null) => void;
}> = ({ open, title, label, placeholder, name, onName, scopeLevel, level, onLevel, saving, onCancel, onConfirm, confidentiality, onConfidentiality }) => {
  const dialogRef = useDialog(open, onCancel);
  if (!open) return null;
  return (
    <div style={overlayStyle}>
      <div ref={dialogRef} tabIndex={-1} role="dialog" aria-modal="true" style={saveDialogStyle}>
        <p style={{ margin: 0, fontSize: 13, color: 'var(--text-primary)' }}>{title}</p>
        <div style={{ marginTop: 12, display: 'flex', flexDirection: 'column', gap: 8 }}>
          <label style={{ fontSize: 11, color: 'var(--text-secondary)' }}>{label}
            <input value={name} onChange={(e) => onName(e.target.value)} placeholder={placeholder || ''} style={saveNameFieldStyle} />
          </label>
          {scopeLevel ? (
            <div style={{ fontSize: 11, color: 'var(--text-secondary)' }}>
              层级：<span style={{ color: '#5a8', fontWeight: 600 }}>{scopeLevel}</span>（个人定制内仅保存到个人）
            </div>
          ) : (
            <label style={{ fontSize: 11, color: 'var(--text-secondary)' }}>层级
              <select value={level} onChange={(e) => onLevel(e.target.value)} style={saveNameFieldStyle}>
                <option value="通用">通用</option>
                <option value="项目">项目</option>
                <option value="个人">个人</option>
              </select>
            </label>
          )}
          {onConfidentiality && (
            <label style={{ fontSize: 11, color: 'var(--text-secondary)' }}>机密档位（未分级不设限；绝密 L1 / 机密 L2 / 秘密 L3）
              <select value={confidentiality ?? ''} onChange={(e) => onConfidentiality(e.target.value || null)} style={saveNameFieldStyle}>
                <option value="">未分级</option>
                {CONFIDENTIALITY_LEVELS.map((l) => (
                  <option key={l} value={l}>{CONFIDENTIALITY_LABELS[l]}</option>
                ))}
              </select>
            </label>
          )}
        </div>
        <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end', marginTop: 14 }}>
          <button onClick={onCancel} style={saveCancelBtn}>取消</button>
          <button onClick={onConfirm} disabled={saving} style={{ ...saveConfirmBtn, opacity: saving ? 0.6 : 1 }}>{saving ? '保存中…' : '保存'}</button>
        </div>
      </div>
    </div>
  );
};

/** 编辑器旁竖条 16px 小按钮（执行/关联/快照/保存等；审计 P2-12：图标钮补 aria-label）。
 * busy：该动作进行中（0.35）；disabled：不可用（0.4 + not-allowed）；dimmed：其它动作进行中等。 */
export const StripBtn: React.FC<{
  icon: React.ReactNode;
  title: string;
  onClick: () => void;
  disabled?: boolean;
  bg: string;
  /** 图标色（审计：浅底如 --accent-blue-dim 上白图标对比度仅 1.28:1，须传深色图标） */
  iconColor?: string;
  busy?: boolean;
  dimmed?: boolean;
}> = ({ icon, title, onClick, disabled = false, bg, iconColor = '#fff', busy = false, dimmed = false }) => (
  <button onClick={onClick} disabled={disabled} title={title} aria-label={title}
    style={{ width: 16, height: 16, display: 'flex', alignItems: 'center', justifyContent: 'center', borderRadius: 3, border: 'none', backgroundColor: bg, color: iconColor, cursor: disabled ? 'not-allowed' : 'pointer', opacity: busy ? 0.35 : (dimmed || disabled ? 0.4 : 1), padding: 0 }}>
    {icon}
  </button>
);

/** 弹窗遮罩（审计 P2-12：加 padding，窄屏时卡片不贴边） */
export const overlayStyle: React.CSSProperties = { position: 'fixed', inset: 0, backgroundColor: 'rgba(0,0,0,0.45)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 'var(--z-top)', padding: 12 };/** 弹窗卡片（确认类小弹窗；审计 P2-12 核验：minWidth min(280px,94vw)——极窄屏下 min-width 不再压过 max-width 导致贴边裁剪；maxHeight 80vh 防窄屏溢出） */
export const dialogStyle: React.CSSProperties = { backgroundColor: 'var(--surface-2)', border: '1px solid var(--border-light)', borderRadius: 8, padding: '16px 18px', minWidth: 'min(280px, 94vw)', maxWidth: '90%', maxHeight: '80vh', overflowY: 'auto', boxShadow: '0 8px 30px rgba(0,0,0,0.3)' };
/** 弹窗卡片（保存/另存为弹窗；审计 P2-12 核验：minWidth min(300px,94vw) 同上；maxHeight 80vh 防窄屏溢出） */
export const saveDialogStyle: React.CSSProperties = { backgroundColor: 'var(--surface-2)', border: '1px solid var(--border-light)', borderRadius: 8, padding: '16px 18px', minWidth: 'min(300px, 94vw)', maxWidth: '90%', maxHeight: '80vh', overflowY: 'auto', boxShadow: '0 8px 30px rgba(0,0,0,0.3)' };
/** 取消（次）按钮 */
export const saveCancelBtn: React.CSSProperties = { padding: '5px 12px', borderRadius: 5, border: '1px solid var(--text-muted)', backgroundColor: 'transparent', color: 'var(--text-secondary)', cursor: 'pointer', fontSize: 12 };
/** 确认（主）按钮（含图标时也能对齐） */
export const saveConfirmBtn: React.CSSProperties = { display: 'flex', alignItems: 'center', gap: 5, padding: '5px 12px', borderRadius: 5, border: 'none', backgroundColor: 'var(--accent-blue)', color: '#fff', cursor: 'pointer', fontSize: 12 };
/** 危险（删除/回滚）按钮 */
export const dangerBtn: React.CSSProperties = { padding: '5px 12px', borderRadius: 5, border: 'none', backgroundColor: '#e74c3c', color: '#fff', cursor: 'pointer', fontSize: 12 };
/** 工具栏小图标按钮（版本历史入口等） */
export const toolbarIconBtn: React.CSSProperties = { display: 'flex', alignItems: 'center', justifyContent: 'center', width: 22, height: 22, borderRadius: 4, border: '1px solid var(--text-muted)', backgroundColor: 'transparent', color: 'var(--text-secondary)', cursor: 'pointer', padding: 0, flexShrink: 0 };

export function fmtBytes(n: number | undefined | null): string {
  if (n === undefined || n === null) return '';
  return n >= 1048576 ? (n / 1048576).toFixed(1) + ' MB' : Math.max(1, Math.round(n / 1024)) + ' KB';
}
