import { useEffect, useRef } from 'react';

/**
 * 弹窗无障碍收口（审计 P2-12）：Escape 关闭、打开时聚焦容器、关闭后焦点还原到触发元素。
 * 用法：
 *   const dialogRef = useDialog(open, () => setOpen(false));
 *   <div ref={dialogRef} tabIndex={-1} role="dialog" aria-modal="true" style={dialogStyle}>
 *
 * 分层语义：模块级弹窗栈保证 Escape 只关「最上层」（后打开的）弹窗——
 * window 监听按注册顺序触发，先注册者先收到事件，仅靠 stopImmediatePropagation 会关错层（核验 G6 指出）。
 */

/** 打开中的弹窗栈（每个 useDialog 实例一个 id，后开者在栈顶） */
const dialogStack: symbol[] = [];

export function useDialog(open: boolean, onClose: () => void) {
  const ref = useRef<HTMLDivElement>(null);
  const closeRef = useRef(onClose);
  closeRef.current = onClose;
  useEffect(() => {
    if (!open) return;
    const id = Symbol('dialog');
    dialogStack.push(id);
    const previous = document.activeElement as HTMLElement | null;
    const node = ref.current;
    // 不抢已落在弹窗内控件的焦点（autoFocus 输入框等），否则提交阶段聚焦会被覆盖
    if (node && !node.contains(document.activeElement)) node.focus({ preventScroll: true });
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && dialogStack[dialogStack.length - 1] === id) {
        e.stopImmediatePropagation();
        closeRef.current();
      }
    };
    window.addEventListener('keydown', onKey);
    return () => {
      window.removeEventListener('keydown', onKey);
      const at = dialogStack.indexOf(id);
      if (at !== -1) dialogStack.splice(at, 1);
      previous?.focus?.({ preventScroll: true });
    };
  }, [open]);
  return ref;
}
