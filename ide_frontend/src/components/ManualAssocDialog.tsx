import React, { useRef, useState } from 'react';
import { useDialog } from '../lib/useDialog';
import { overlayStyle } from './wsCommon';

export interface AssocOption { value: string; label: string; tag?: string }
export interface AssocSection {
  key: string;
  label: string;
  multi: boolean;            // false=单选（再点取消选择）
  options: AssocOption[];
  selected: string[];        // 初始选中值
  emptyText?: string;
  searchable?: boolean;
}

/** 手动关联弹窗：分区勾选（算法/SQL/知识库…，单选多选混用）+ 每区搜索，
 *  确认回传 {key: 选中值[]} 由调用方落盘。
 *  审计 P2-12 口径：Escape 关闭 + 焦点管理（useDialog）；行按钮带 checkbox/radio 语义 + aria-checked。 */
export const ManualAssocDialog: React.FC<{
  title: string;
  sections: AssocSection[];
  saving?: boolean;
  onCancel: () => void;
  onConfirm: (sel: Record<string, string[]>) => void;
}> = ({ title, sections, saving, onCancel, onConfirm }) => {
  // saving 期间取消/Escape 一律失效（否则弹窗已关而确认的保存请求仍在途，尾部会污染已切换的草稿）
  const savingRef = useRef(false);
  savingRef.current = !!saving;
  const doCancel = () => { if (!savingRef.current) onCancel(); };
  const dialogRef = useDialog(true, doCancel);
  // 初始选中只在挂载时取一次（弹窗打开期间外部数据变化不回灌）
  const [sel, setSel] = useState<Record<string, string[]>>(() =>
    Object.fromEntries(sections.map((s) => [s.key, [...(s.selected || [])]])));
  const [q, setQ] = useState<Record<string, string>>({});

  const toggle = (key: string, value: string, multi: boolean) => {
    setSel((cur) => {
      const list = cur[key] || [];
      if (multi) {
        return { ...cur, [key]: list.includes(value) ? list.filter((v) => v !== value) : [...list, value] };
      }
      // 单选：再点已选项 = 取消（置空，如「不预测」）
      return { ...cur, [key]: list[0] === value ? [] : [value] };
    });
  };

  const total = Object.values(sel).reduce((n, l) => n + (l || []).length, 0);

  const rowBtn: React.CSSProperties = {
    display: 'flex', alignItems: 'center', gap: 6, width: '100%', background: 'none',
    border: 'none', padding: '3px 4px', cursor: 'pointer', borderRadius: 4, textAlign: 'left',
  };

  return (
    <div onClick={doCancel} style={overlayStyle}>
      <div ref={dialogRef} tabIndex={-1} role="dialog" aria-modal="true" aria-label={title}
        onClick={(e) => e.stopPropagation()} style={modalStyle}>
        <p style={{ margin: 0, fontSize: 13, fontWeight: 600, color: 'var(--text-primary)' }}>{title}</p>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 12, marginTop: 10, maxHeight: '56vh', overflowY: 'auto', paddingRight: 2 }}>
          {sections.map((s) => {
            const query = (q[s.key] || '').trim().toLowerCase();
            const opts = query
              ? s.options.filter((o) => `${o.label} ${o.tag || ''}`.toLowerCase().includes(query))
              : s.options;
            const picked = sel[s.key] || [];
            return (
              <div key={s.key}>
                <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8, marginBottom: 5 }}>
                  <span style={{ fontSize: 11, fontWeight: 600, color: 'var(--text-secondary)' }}>
                    {s.label}
                    <span style={{ fontWeight: 400, color: 'var(--text-muted)' }}>（已选 {picked.length}）</span>
                  </span>
                  {s.searchable !== false && (
                    <input value={q[s.key] || ''} onChange={(e) => setQ((c) => ({ ...c, [s.key]: e.target.value }))}
                      placeholder="搜索…" aria-label={`搜索${s.label}`}
                      style={{ width: 120, padding: '3px 8px', borderRadius: 4, border: '1px solid var(--text-muted)', backgroundColor: 'var(--surface-1)', color: 'var(--text-on-accent)', fontSize: 11, outline: 'none' }} />
                  )}
                </div>
                <div role={s.multi ? 'group' : 'radiogroup'} aria-label={s.label}
                  style={{ maxHeight: 190, overflowY: 'auto', border: '1px solid var(--border-light)', borderRadius: 5, padding: 4, backgroundColor: 'var(--surface-1)' }}>
                  {/* 已选但已不在候选集的值：显示为「当前绑定·已不可用」幽灵行，点击取消绑定 */}
                  {picked.filter((v) => !s.options.some((o) => o.value === v)).map((v) => (
                    <button key={v} type="button" onClick={() => toggle(s.key, v, s.multi)}
                      role={s.multi ? 'checkbox' : 'radio'} aria-checked={true} style={rowBtn}>
                      <span style={{
                        width: 13, height: 13, flexShrink: 0, borderRadius: s.multi ? 3 : '50%',
                        border: '1.5px solid var(--error-text)', backgroundColor: 'var(--error-text)',
                        display: 'inline-flex', alignItems: 'center', justifyContent: 'center', color: '#fff', fontSize: 9,
                      }}>
                        ✕
                      </span>
                      <span style={{ fontSize: 11, color: 'var(--error-text)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', flex: 1 }}>
                        当前绑定·已不可用（点击取消）
                      </span>
                    </button>
                  ))}
                  {opts.length === 0 ? (
                    <span style={{ display: 'block', padding: '6px 8px', fontSize: 11, color: 'var(--text-inactive)' }}>
                      {query ? '（无匹配项）' : (s.emptyText || '（暂无可用）')}
                    </span>
                  ) : opts.map((o) => {
                    const on = picked.includes(o.value);
                    return (
                      <button key={o.value} type="button" onClick={() => toggle(s.key, o.value, s.multi)}
                        role={s.multi ? 'checkbox' : 'radio'} aria-checked={on} style={rowBtn}>
                        <span style={{
                          width: 13, height: 13, flexShrink: 0, borderRadius: s.multi ? 3 : '50%',
                          border: `1.5px solid ${on ? 'var(--accent-blue)' : 'var(--text-muted)'}`,
                          backgroundColor: on ? 'var(--accent-blue)' : 'transparent',
                          display: 'inline-flex', alignItems: 'center', justifyContent: 'center', color: '#fff', fontSize: 9,
                        }}>
                          {on && '✓'}
                        </span>
                        <span style={{ fontSize: 11, color: on ? 'var(--text-primary)' : 'var(--text-secondary)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', flex: 1 }}>
                          {o.label}
                        </span>
                        {o.tag && (
                          <span style={{ fontSize: 10, color: 'var(--text-muted)', flexShrink: 0, maxWidth: 140, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                            {o.tag}
                          </span>
                        )}
                      </button>
                    );
                  })}
                </div>
              </div>
            );
          })}
        </div>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginTop: 12 }}>
          <span style={{ fontSize: 11, color: 'var(--text-muted)' }}>共 {total} 项</span>
          <div style={{ display: 'flex', gap: 8 }}>
            <button onClick={doCancel} disabled={saving} style={{ ...cancelBtn, opacity: saving ? 0.5 : 1, cursor: saving ? 'not-allowed' : 'pointer' }}>取消</button>
            <button onClick={() => onConfirm(sel)} disabled={saving} style={{ ...okBtn, opacity: saving ? 0.6 : 1 }}>
              {saving ? '保存中…' : '确认关联'}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
};

const modalStyle: React.CSSProperties = {
  backgroundColor: 'var(--surface-2)', border: '1px solid var(--border-light)', borderRadius: 8,
  padding: '16px 18px', width: 'min(640px, 94vw)', maxWidth: '92%', maxHeight: '84vh',
  overflowY: 'auto', boxShadow: '0 8px 30px rgba(0,0,0,0.3)', display: 'flex', flexDirection: 'column',
};
const cancelBtn: React.CSSProperties = { padding: '5px 12px', borderRadius: 5, border: '1px solid var(--text-muted)', backgroundColor: 'transparent', color: 'var(--text-secondary)', cursor: 'pointer', fontSize: 12 };
const okBtn: React.CSSProperties = { padding: '5px 12px', borderRadius: 5, border: 'none', backgroundColor: 'var(--accent-blue)', color: '#fff', cursor: 'pointer', fontSize: 12 };

export default ManualAssocDialog;
