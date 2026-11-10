import React, { useCallback, useEffect, useRef, useState } from 'react';
import { useStore } from '../stores/useStore';
import { useToast } from './Toast';
import { api } from '../services/api';
import { useDialog } from '../lib/useDialog';
import { History, RotateCcw, X, GitCompareArrows } from 'lucide-react';
import { overlayStyle, saveCancelBtn, dangerBtn, fmtBytes } from './wsCommon';

interface VersionRow {
  file: string;
  size: number;
  mtime: number;
  mtime_str: string;
}

const KIND_LABEL: Record<string, string> = { sql: 'SQL 文件', skill: '专项', doc: '文档', model: '模型' };

/** 版本历史弹窗（P1-16）：列出 /api/admin/versions 时间倒序快照；「回滚」二次确认，
 * 「对比」展示「版本 vs 当前」统一 diff（P1-16 增补）；成功后 toast 并回调 onRestored。 */
export const VersionHistoryDialog: React.FC<{ kind: string; name: string; onClose: () => void; onRestored: () => void }> = ({ kind, name, onClose, onRestored }) => {
  const { success, error: toastError } = useToast();
  const myPermissions = useStore((s) => s.myPermissions);
  const canRestore = myPermissions === null || myPermissions.includes('analysis_edit');
  const [versions, setVersions] = useState<VersionRow[] | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [confirmTarget, setConfirmTarget] = useState<string | null>(null);
  // P1-16 diff：对比面板（- 行 = 历史版本，+ 行 = 当前）
  const [diffFile, setDiffFile] = useState<string | null>(null);
  const [diffText, setDiffText] = useState('');
  const [diffBusy, setDiffBusy] = useState(false);

  // 审计 P2-12：弹窗接入 useDialog（Escape 关闭 + 打开聚焦 + 关闭还原焦点）；本组件仅在打开时挂载
  const dialogRef = useDialog(true, onClose);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const r = await api.listVersions(kind, name);
      setVersions(r.versions || []);
    } catch (e: any) {
      toastError(e.message || '加载版本历史失败');
      setVersions([]);
    } finally {
      setLoading(false);
    }
  }, [kind, name, toastError]);

  useEffect(() => { load(); }, [load]);

  const confirmRestore = async () => {
    if (!confirmTarget || busy) return;
    setBusy(true);
    try {
      await api.restoreVersion({ kind, name, version_file: confirmTarget });
      success(`已回滚到版本 ${confirmTarget}`);
      onRestored();
      onClose();
    } catch (e: any) {
      toastError(e.message || '回滚失败');
      setBusy(false);
    }
  };

  // 对抗审查 LOW：连续点击「对比」时，慢请求的过期结果不能覆盖新请求（序号守卫）
  const diffSeq = useRef(0);

  const showDiff = async (vfile: string) => {
    const seq = ++diffSeq.current;
    setDiffFile(vfile);
    setDiffBusy(true);
    setDiffText('');
    try {
      const r = await api.diffVersion(kind, name, vfile);
      if (seq !== diffSeq.current) return; // 已发起更新的对比请求，丢弃过期结果
      setDiffText(r.diff || '');
    } catch (e: any) {
      if (seq !== diffSeq.current) return;
      setDiffText(`对比失败：${e.message || '未知错误'}`);
    } finally {
      if (seq === diffSeq.current) setDiffBusy(false);
    }
  };

  return (
    <div onClick={onClose} style={overlayStyle}>
      {/* 审计 P2-12：role/aria-modal/tabIndex 弹窗语义；宽度 min() 化（列表内部已滚动，只改宽） */}
      <div ref={dialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={{ ...dialogStyle, width: 'min(440px,94vw)', display: 'flex', flexDirection: 'column', maxHeight: '72vh' }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <p style={{ margin: 0, fontSize: 13, color: 'var(--text-primary)', display: 'flex', alignItems: 'center', gap: 6 }}>
            <History size={14} style={{ color: 'var(--accent-blue)' }} /> 版本历史：{name}
          </p>
          <button onClick={onClose} aria-label="关闭" style={{ ...saveCancelBtn, display: 'flex', alignItems: 'center', padding: 2, border: 'none' }} title="关闭">
            <X size={14} />
          </button>
        </div>
        <p style={{ margin: '4px 0 0', fontSize: 11, color: 'var(--text-muted)' }}>{KIND_LABEL[kind] || '工件'} · 回滚前会自动备份当前版本</p>

        {diffFile && (
          <div style={{ marginTop: 10, border: '1px solid var(--border-light)', borderRadius: 6, backgroundColor: 'var(--surface-1)', display: 'flex', flexDirection: 'column', maxHeight: '34vh' }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '6px 10px', borderBottom: '1px solid var(--border-light)' }}>
              <span style={{ fontSize: 11, color: 'var(--text-secondary)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                对比：<strong>{diffFile}</strong> → 当前
              </span>
              <button onClick={() => setDiffFile(null)} aria-label="关闭对比" style={{ ...saveCancelBtn, display: 'flex', alignItems: 'center', padding: 2, border: 'none' }} title="关闭对比">
                <X size={12} />
              </button>
            </div>
            <div style={{ flex: 1, minHeight: 0, overflow: 'auto', padding: '6px 0' }}>
              {diffBusy ? (
                <p style={{ textAlign: 'center', color: 'var(--text-inactive)', fontSize: 12, margin: '12px 0' }}>生成对比中...</p>
              ) : (
                <pre style={{ margin: 0, fontFamily: 'var(--font-mono, ui-monospace, Consolas, monospace)', fontSize: 11, lineHeight: 1.55, whiteSpace: 'pre', overflowX: 'auto' }}>
                  {diffText.split('\n').map((line, i) => (
                    <div key={i} style={{
                      backgroundColor: line.startsWith('+') && !line.startsWith('+++') ? 'var(--tint-green-bg, rgba(46,160,67,0.12))'
                        : line.startsWith('-') && !line.startsWith('---') ? 'var(--tint-red-bg, rgba(248,81,73,0.12))' : 'transparent',
                      color: line.startsWith('+') && !line.startsWith('+++') ? 'var(--success-text, #2ea043)'
                        : line.startsWith('-') && !line.startsWith('---') ? 'var(--error-text, #f85149)'
                          : (line.startsWith('---') || line.startsWith('+++')) ? 'var(--text-inactive)' : 'var(--text-primary)',
                      padding: '0 10px', minHeight: '1.55em',
                    }}>{line || ' '}</div>
                  ))}
                </pre>
              )}
            </div>
          </div>
        )}

        <div style={{ marginTop: 10, flex: 1, minHeight: 0, overflowY: 'auto', display: 'flex', flexDirection: 'column', gap: 4 }}>
          {loading ? (
            <p style={{ textAlign: 'center', color: 'var(--text-inactive)', fontSize: 12, margin: '16px 0' }}>加载中...</p>
          ) : versions && versions.length === 0 ? (
            <p style={{ textAlign: 'center', color: 'var(--text-inactive)', fontSize: 12, margin: '16px 0' }}>暂无历史版本</p>
          ) : (versions || []).map((v) => (
            <div key={v.file} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 8px', borderRadius: 5, border: '1px solid var(--border-light)', backgroundColor: 'var(--surface-1)' }}>
              <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 2 }}>
                <span style={{ fontSize: 12, color: 'var(--text-primary)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }} title={v.file}>
                  {v.file}
                </span>
                <span style={{ fontSize: 10, color: 'var(--text-inactive)' }}>
                  {v.mtime_str || ''}{v.size ? ` · ${fmtBytes(v.size)}` : ''}
                </span>
              </div>
              {confirmTarget === v.file ? (
                <>
                  <button onClick={confirmRestore} disabled={busy} style={{ ...dangerBtn, fontSize: 11, padding: '3px 10px' }}>
                    {busy ? '回滚中…' : '确认回滚'}
                  </button>
                  <button onClick={() => setConfirmTarget(null)} disabled={busy} style={{ ...saveCancelBtn, fontSize: 11, padding: '3px 10px' }}>取消</button>
                </>
              ) : (
                <>
                  <button onClick={() => showDiff(v.file)} disabled={busy}
                    title="对比该版本与当前内容"
                    style={{ display: 'flex', alignItems: 'center', gap: 4, fontSize: 11, padding: '3px 10px', borderRadius: 5, border: '1px solid var(--text-muted)', backgroundColor: 'transparent', color: 'var(--text-secondary)', cursor: 'pointer' }}>
                    <GitCompareArrows size={11} /> 对比
                  </button>
                  <button onClick={() => setConfirmTarget(v.file)} disabled={!canRestore || busy} title={canRestore ? '回滚到该版本' : '仅可查看（无新增/修改权限）'}
                    style={{ display: 'flex', alignItems: 'center', gap: 4, fontSize: 11, padding: '3px 10px', borderRadius: 5, border: '1px solid var(--text-muted)', backgroundColor: 'transparent', color: 'var(--text-secondary)', cursor: canRestore ? 'pointer' : 'not-allowed', opacity: canRestore ? 1 : 0.4 }}>
                    <RotateCcw size={11} /> 回滚
                  </button>
                </>
              )}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
};

const dialogStyle: React.CSSProperties = { backgroundColor: 'var(--surface-2)', border: '1px solid var(--border-light)', borderRadius: 8, padding: '16px 18px', maxWidth: '90%', boxShadow: '0 8px 30px rgba(0,0,0,0.3)' };

export default VersionHistoryDialog;
