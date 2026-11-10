import React, { useState } from 'react';
import { api } from '../services/api';
import { Loader2 } from 'lucide-react';

/** 报告缺口与补数建议卡片（2026-10-26 to-B 化）：专项管理内执行专项成功后自动触发，
 *  渲染在「AI源生」对话里（SkillAgentPanel）。从聊天窗口 vanilla 版（app.js gap 块）
 *  整体移植：缺口列表 + 自动修复/生成 SQL/检查知识库 + 确认流（diff 预览）+ 白名单 +
 *  文本说明调整，全部走 /api/chat/gap-* 端点族。 */

const GAP_TYPE_LABELS: Record<string, string> = { sql: '🗄️ SQL', skill: '🎯 专项', kb: '📚 知识库', model: '🧮 算法模型' };
const GAP_TYPE_LINKS: Record<string, string> = { sql: '/#/analysis/sql', skill: '/#/analysis/skill', kb: '/#/analysis/knowledge', model: '/#/analysis/models' };
const GAP_SEV_LABELS: Record<string, string> = { high: '高', medium: '中', low: '低' };
const GAP_SEV_COLORS: Record<string, string> = { high: '#d9534f', medium: '#f0ad4e', low: '#8a8a8a' };

export interface SkillGapCardData {
  skill: string;
  reportMd: string;
  gaps: any[];
  whitelist: any[];
  seq: number;
  game?: string | null;
  error?: string;
}

const smBtn: React.CSSProperties = {
  display: 'inline-flex', alignItems: 'center', gap: 4, padding: '2px 9px', fontSize: 11,
  borderRadius: 4, border: '1px solid var(--text-muted)', background: 'var(--surface-1)',
  color: 'var(--text-secondary)', cursor: 'pointer', whiteSpace: 'nowrap',
};
const box: React.CSSProperties = {
  border: '1px solid var(--border-light)', borderRadius: 6, padding: '8px 10px',
  marginTop: 6, backgroundColor: 'var(--surface-0)', display: 'flex', flexDirection: 'column', gap: 6,
};

function gapActionFor(g: any): string | null {
  if (g.remedy_type === 'kb') return '🔍 检查知识库';
  if (g.remedy_type === 'sql' && g.remedy_action === 'modify') return '🛠 自动修复';
  if (g.remedy_type === 'sql' && g.remedy_action === 'create') return '🛠 生成 SQL';
  return null;
}

function gapAnswerKindLabel(draft: any): string {
  const map: Record<string, string> = { sql: 'SQL', kb: '知识库文档', skill: '专项', model: '预测模型' };
  return map[draft.kind] || draft.kind;
}

/** 报告缺口与补数建议卡片（含白名单区） */
export const SkillGapCard: React.FC<{ card: SkillGapCardData }> = ({ card }) => {
  const [gaps, setGaps] = useState<any[]>(card.gaps || []);
  const [whitelist, setWhitelist] = useState<any[]>(card.whitelist || []);
  const [error, setError] = useState<string | undefined>(card.error);
  const [retrying, setRetrying] = useState(false);
  const skill = card.skill || null;

  const retry = async () => {
    setRetrying(true);
    setError(undefined);
    try {
      const r = await api.chatGaps(skill, card.reportMd);
      setGaps(r.gaps || []);
      setWhitelist(r.whitelist || []);
    } catch (e: any) {
      setError(e.message || '缺口分析失败');
    } finally {
      setRetrying(false);
    }
  };

  const ignoreGap = async (g: any) => {
    try {
      await api.gapWhitelistAdd(skill, g);
      setGaps((prev) => prev.filter((x) => x !== g));
      try { setWhitelist((await api.gapWhitelistList(skill)).whitelist || []); } catch { /* 静默 */ }
    } catch (e: any) {
      window.alert('加入白名单失败：' + (e.message || '请求失败'));
    }
  };

  const restoreWhitelist = async (w: any) => {
    if (!window.confirm('移出白名单后，下次运行该缺口可能再次出现。确认恢复？')) return;
    try {
      await api.gapWhitelistRemove(w.sig, skill);
      setWhitelist((prev) => prev.filter((x) => x !== w));
    } catch (e: any) {
      window.alert('恢复失败：' + (e.message || '请求失败'));
    }
  };

  return (
    <div style={box}>
      <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--text-primary)' }}>
        🔍 报告缺口与补数建议（{gaps.length} 条）
      </div>
      {error && (
        <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
          <span style={{ fontSize: 11, color: 'var(--danger)' }}>⚠️ {error}</span>
          <button onClick={retry} disabled={retrying} style={smBtn}>
            {retrying && <Loader2 size={10} style={{ animation: 'spin 1s linear infinite' }} />} 重试
          </button>
        </div>
      )}
      {!error && !gaps.length && (
        <div style={{ fontSize: 11, color: 'var(--text-muted)' }}>未发现明显的数据/口径/方法缺口。</div>
      )}
      {gaps.map((g, i) => (
        <GapItem key={i} gap={g} skill={skill} game={card.game ?? null}
          onFixed={() => setGaps((prev) => prev.map((x) => (x === g ? { ...x, status: 'fixed' } : x)))}
          onIgnore={() => ignoreGap(g)} />
      ))}
      {whitelist.length > 0 && (
        <div style={{ marginTop: 4, borderTop: '1px solid var(--border-light)', paddingTop: 6 }}>
          <div style={{ fontSize: 11, color: 'var(--text-secondary)', marginBottom: 4 }}>
            🗂 白名单（已忽略，不再出现）· {whitelist.length} 条
          </div>
          {whitelist.map((w, i) => (
            <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '2px 0' }}>
              <div style={{ flex: 1, fontSize: 11, color: 'var(--text-muted)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }} title={w.detail || ''}>
                {w.issue || w.sig || ''}
              </div>
              <button onClick={() => restoreWhitelist(w)} style={smBtn} title="移出白名单：下次运行该缺口可能再次出现">恢复</button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
};

/** 单条缺口：严重度/问题/引文/补救建议 + 操作（修复/忽略/文本说明调整） */
const GapItem: React.FC<{
  gap: any; skill: string | null; game: string | null;
  onFixed: () => void; onIgnore: () => void;
}> = ({ gap: g, skill, game, onFixed, onIgnore }) => {
  const [busy, setBusy] = useState<string | null>(null); // fix | answer
  const [note, setNote] = useState<string | null>(null);
  const [noteErr, setNoteErr] = useState(false);
  const [fixDraft, setFixDraft] = useState<any>(null); // action=draft 的草稿编辑器
  const [confirm, setConfirm] = useState<any>(null);   // action=confirm 的确认流
  const [answerText, setAnswerText] = useState('');
  const [answerDraft, setAnswerDraft] = useState<any>(null);
  const fixed = g.status && g.status !== 'new';

  const setFixNote = (text: string, isErr = false) => {
    setNote(text); setNoteErr(isErr);
    setFixDraft(null); setConfirm(null); setAnswerDraft(null);
  };

  const requestFix = async () => {
    setBusy('fix');
    setNote(null); setFixDraft(null); setConfirm(null);
    try {
      const data = await api.gapFix(skill, g, game);
      if (data.action === 'applied') {
        setNote('✅ ' + (data.message || '已处理'));
        onFixed();
      } else if (data.action === 'confirm' && data.draft) {
        setConfirm({ data, err: null });
      } else if (data.action === 'draft' && data.draft) {
        setFixDraft(data.draft);
      } else {
        setNote('💡 ' + (data.message || '请手动处理。'));
      }
    } catch (e: any) {
      setFixNote('修复失败：' + (e.message || '请求失败'), true);
    } finally {
      setBusy(null);
    }
  };

  const applyFixDraft = async (draft: any) => {
    try {
      const data = await api.gapFixApply(skill, draft, game);
      if (data.ok) {
        setFixNote('✅ ' + (data.message || '已保存'));
        onFixed();
      } else {
        setFixNote('❌ ' + (data.message || '保存失败'), true);
      }
    } catch (e: any) {
      setFixNote('❌ 保存失败：' + (e.message || '请求失败'), true);
    }
  };

  const applyConfirm = async (draft: any) => {
    try {
      const data = await api.gapFixApply(skill, draft, game);
      if (data.ok) {
        setFixNote('✅ ' + (data.message || '已保存'));
        onFixed();
      } else {
        setConfirm((prev: any) => (prev ? { ...prev, err: data.message || '保存失败' } : prev));
      }
    } catch (e: any) {
      setConfirm((prev: any) => (prev ? { ...prev, err: '保存失败：' + (e.message || '请求失败') } : prev));
    }
  };

  const requestAnswer = async () => {
    const txt = answerText.trim();
    if (!txt) return;
    setBusy('answer');
    setNote(null); setAnswerDraft(null);
    try {
      const data = await api.gapAnswer(skill, g, txt, game);
      if (data.action === 'draft' && data.draft) {
        setAnswerDraft(data.draft);
      } else {
        setNote('💡 ' + (data.message || '请手动处理。'));
      }
    } catch (e: any) {
      setFixNote('调整失败：' + (e.message || '请求失败'), true);
    } finally {
      setBusy(null);
    }
  };

  const applyAnswerDraft = async (draft: any) => {
    try {
      const data = await api.gapAnswerApply(skill, draft, g, game);
      if (data.ok) {
        setFixNote('✅ ' + (data.message || '已保存'));
        onFixed();
      } else {
        setFixNote('❌ ' + (data.message || '保存失败'), true);
      }
    } catch (e: any) {
      setFixNote('❌ 保存失败：' + (e.message || '请求失败'), true);
    }
  };

  const actionLabel = gapActionFor(g);
  const sevColor = GAP_SEV_COLORS[g.severity] || '#8a8a8a';
  const sevLabel = GAP_SEV_LABELS[g.severity] || g.severity;

  return (
    <div style={{ padding: '6px 0', borderTop: '1px dashed var(--border-light)', opacity: fixed ? 0.65 : 1 }}>
      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 6 }}>
        <span style={{ flexShrink: 0, padding: '1px 6px', borderRadius: 3, fontSize: 10, fontWeight: 600, color: '#fff', background: sevColor, marginTop: 1 }}>{sevLabel}</span>
        <div style={{ flex: 1, fontSize: 12, color: 'var(--text-primary)', lineHeight: 1.5 }}>{g.issue}</div>
        {fixed && (
          <span style={{ flexShrink: 0, fontSize: 11, color: '#5a5' }}>
            {g.status === 'fixed' ? '✅ 已修复' : '👁 已登记'}
          </span>
        )}
      </div>
      {g.quote && (
        <div style={{ fontSize: 11, color: 'var(--text-muted)', fontStyle: 'italic', margin: '3px 0 0 2px' }}>“{g.quote}”</div>
      )}
      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 6, marginTop: 4 }}>
        <span style={{ flexShrink: 0, fontSize: 10, padding: '1px 6px', borderRadius: 3, background: 'var(--tint-blue-bg)', color: 'var(--accent-blue)', whiteSpace: 'nowrap' }}>
          {GAP_TYPE_LABELS[g.remedy_type] || g.remedy_type}
        </span>
        <div style={{ flex: 1, fontSize: 11, color: 'var(--text-secondary)', lineHeight: 1.5 }}>{g.remedy_detail || ''}</div>
      </div>

      {!fixed && (
        <>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginTop: 6, flexWrap: 'wrap' }}>
            {actionLabel && (
              <button onClick={requestFix} disabled={busy !== null} style={smBtn}>
                {busy === 'fix' ? <Loader2 size={10} style={{ animation: 'spin 1s linear infinite' }} /> : null} {actionLabel}
              </button>
            )}
            {g.remedy_type && GAP_TYPE_LINKS[g.remedy_type] && (
              <a href={GAP_TYPE_LINKS[g.remedy_type]} style={{ fontSize: 11, color: 'var(--accent-blue)' }}>去处理 →</a>
            )}
            <button onClick={onIgnore} disabled={busy !== null} style={smBtn} title="加入白名单：这条建议后续不再出现">🚫 忽略</button>
          </div>
          <div style={{ display: 'flex', gap: 6, marginTop: 6 }}>
            <textarea
              value={answerText}
              onChange={(e) => setAnswerText(e.target.value)}
              disabled={busy !== null}
              rows={2}
              placeholder="补充说明：这个缺口该怎么补 / 为什么这么改（AI 会据此调整 SQL / 知识库 / 专项 / 模型）"
              style={{ flex: 1, padding: '4px 8px', borderRadius: 4, border: '1px solid var(--text-muted)', background: 'var(--surface-1)', color: 'var(--text-primary)', fontSize: 11, resize: 'vertical', fontFamily: 'inherit' }}
            />
            <button onClick={requestAnswer} disabled={busy !== null || !answerText.trim()} style={{ ...smBtn, flexShrink: 0, alignSelf: 'flex-start' }}>
              {busy === 'answer' ? <Loader2 size={10} style={{ animation: 'spin 1s linear infinite' }} /> : null} 📝 按说明调整
            </button>
          </div>
        </>
      )}

      {note && (
        <div style={{ marginTop: 6, fontSize: 11, color: noteErr ? 'var(--danger)' : '#5a5' }}>{note}</div>
      )}
      {confirm && (
        <GapConfirmBox
          data={confirm.data} err={confirm.err}
          onApply={(d) => applyConfirm(d)}
          onCancel={() => setConfirm(null)} />
      )}
      {fixDraft && (
        <FixDraftBox draft={fixDraft}
          onSave={(d) => applyFixDraft(d)}
          onCancel={() => setFixDraft(null)} />
      )}
      {answerDraft && (
        <AnswerDraftBox draft={answerDraft}
          onSave={(d) => applyAnswerDraft(d)}
          onCancel={() => setAnswerDraft(null)} />
      )}
    </div>
  );
};

/** 确认流（自动改写/绑定知识库先预览 diff，一键确认才落盘——审计 P2-1 语义） */
const GapConfirmBox: React.FC<{ data: any; err: string | null; onApply: (d: any) => void; onCancel: () => void }> = ({ data, err, onApply, onCancel }) => {
  const [busy, setBusy] = useState(false);
  const draft = data.draft;
  return (
    <div style={box}>
      {err && <div style={{ fontSize: 11, color: 'var(--danger)' }}>❌ {err}</div>}
      <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--text-primary)' }}>
        {(draft.kind === 'kb_bind_confirm' ? '📚 ' : '🛠 ') + (data.message || '请预览后确认应用')}
      </div>
      {draft.kind === 'sql_modify_confirm' && <SqlDiff beforeText={draft.before_sql || ''} afterText={draft.sql || ''} />}
      <div style={{ display: 'flex', gap: 6 }}>
        <button
          onClick={async () => { setBusy(true); await onApply(draft); setBusy(false); }}
          disabled={busy} style={smBtn}>
          {busy ? <Loader2 size={10} style={{ animation: 'spin 1s linear infinite' }} /> : null} ✔ 确认应用
        </button>
        <button onClick={onCancel} disabled={busy} style={smBtn}>放弃</button>
      </div>
    </div>
  );
};

/** 修复草稿编辑器（sql_create 带名称/步骤/必做字段；modify 仅 SQL 文本） */
const FixDraftBox: React.FC<{ draft: any; onSave: (d: any) => void; onCancel: () => void }> = ({ draft, onSave, onCancel }) => {
  const [sql, setSql] = useState(draft.sql || '');
  const [name, setName] = useState(draft.name || '');
  const [step, setStep] = useState(draft.step || '');
  const [required, setRequired] = useState(!!draft.required);
  const [busy, setBusy] = useState(false);
  const isCreate = draft.kind === 'sql_create';
  return (
    <div style={box}>
      <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--text-primary)' }}>
        {isCreate ? '🧩 生成的 SQL 草稿（保存后写入全局并绑定到专项）' : '🧩 改写草稿（保存后同步全局与专项快照）'}
      </div>
      {isCreate && (
        <div style={{ display: 'flex', gap: 6 }}>
          <input value={name} onChange={(e) => setName(e.target.value)} placeholder="SQL 文件名（含 .sql）"
            style={{ flex: 1, padding: '3px 8px', borderRadius: 4, border: '1px solid var(--text-muted)', background: 'var(--surface-1)', color: 'var(--text-primary)', fontSize: 11 }} />
          <input value={step} onChange={(e) => setStep(e.target.value)} placeholder="步骤名（图表名）"
            style={{ flex: 1, padding: '3px 8px', borderRadius: 4, border: '1px solid var(--text-muted)', background: 'var(--surface-1)', color: 'var(--text-primary)', fontSize: 11 }} />
          <label style={{ display: 'flex', alignItems: 'center', gap: 4, fontSize: 11, color: 'var(--text-secondary)', whiteSpace: 'nowrap' }}>
            <input type="checkbox" checked={required} onChange={(e) => setRequired(e.target.checked)} /> 必做步骤
          </label>
        </div>
      )}
      <textarea value={sql} onChange={(e) => setSql(e.target.value)} spellCheck={false} rows={6}
        style={{ padding: '6px 8px', borderRadius: 4, border: '1px solid var(--text-muted)', background: 'var(--surface-1)', color: 'var(--text-primary)', fontSize: 11, resize: 'vertical', fontFamily: 'ui-monospace, Consolas, monospace', lineHeight: 1.5 }} />
      {draft.violations && draft.violations.length > 0 && (
        <div style={{ fontSize: 11, color: 'var(--accent-amber-text)' }}>⚠️ 护栏提示：{draft.violations.join('；')}</div>
      )}
      <div style={{ display: 'flex', gap: 6 }}>
        <button
          onClick={async () => {
            setBusy(true);
            await onSave({ ...draft, sql, ...(isCreate ? { name: name.trim(), step: step.trim(), required } : {}) });
            setBusy(false);
          }}
          disabled={busy} style={smBtn}>
          {busy ? <Loader2 size={10} style={{ animation: 'spin 1s linear infinite' }} /> : null} ✅ 确认保存
        </button>
        <button onClick={onCancel} disabled={busy} style={smBtn}>取消</button>
      </div>
    </div>
  );
};

/** 文本说明调整草稿编辑器（create 带名称/步骤字段；skill/model 展示绑定信息） */
const AnswerDraftBox: React.FC<{ draft: any; onSave: (d: any) => void; onCancel: () => void }> = ({ draft, onSave, onCancel }) => {
  const [text, setText] = useState(draft.kind === 'sql' ? (draft.sql || '') : (draft.content || ''));
  const [name, setName] = useState(draft.name || '');
  const [step, setStep] = useState(draft.step || '');
  const [busy, setBusy] = useState(false);
  const isCreate = draft.action === 'create';
  const isSql = draft.kind === 'sql';
  return (
    <div style={box}>
      <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--text-primary)' }}>
        🧩 {isCreate ? '新建' : '改写'}{gapAnswerKindLabel(draft)}草稿（确认后落盘并留痕）
      </div>
      {isCreate && (
        <div style={{ display: 'flex', gap: 6 }}>
          <input value={name} onChange={(e) => setName(e.target.value)} placeholder={isSql ? 'SQL 文件名（含 .sql）' : '名称'}
            style={{ flex: 1, padding: '3px 8px', borderRadius: 4, border: '1px solid var(--text-muted)', background: 'var(--surface-1)', color: 'var(--text-primary)', fontSize: 11 }} />
          {isSql && (
            <input value={step} onChange={(e) => setStep(e.target.value)} placeholder="步骤名（图表名）"
              style={{ flex: 1, padding: '3px 8px', borderRadius: 4, border: '1px solid var(--text-muted)', background: 'var(--surface-1)', color: 'var(--text-primary)', fontSize: 11 }} />
          )}
        </div>
      )}
      <textarea value={text} onChange={(e) => setText(e.target.value)} spellCheck={false} rows={6}
        style={{ padding: '6px 8px', borderRadius: 4, border: '1px solid var(--text-muted)', background: 'var(--surface-1)', color: 'var(--text-primary)', fontSize: 11, resize: 'vertical', fontFamily: isSql ? 'ui-monospace, Consolas, monospace' : 'inherit', lineHeight: 1.5 }} />
      {draft.kind === 'skill' && draft.meta && (
        <div style={{ fontSize: 11, color: 'var(--text-muted)' }}>
          绑定：{(draft.meta.sqls || []).length} 条 SQL · {(draft.meta.docs || []).length} 篇文档{draft.meta.forecast ? ` · 预测能力 ${draft.meta.forecast}` : ''}
        </div>
      )}
      {draft.kind === 'model' && draft.meta && (
        <div style={{ fontSize: 11, color: 'var(--text-muted)' }}>绑定 SQL：{draft.meta.sql || '（无）'}</div>
      )}
      {draft.violations && draft.violations.length > 0 && (
        <div style={{ fontSize: 11, color: 'var(--accent-amber-text)' }}>⚠️ 护栏提示：{draft.violations.join('；')}</div>
      )}
      <div style={{ display: 'flex', gap: 6 }}>
        <button
          onClick={async () => {
            setBusy(true);
            const next: any = { ...draft };
            if (isSql) { next.sql = text; if (name) next.name = name.trim(); if (isCreate) next.step = step.trim(); }
            else { next.content = text; if (name) next.name = name.trim(); }
            await onSave(next);
            setBusy(false);
          }}
          disabled={busy} style={smBtn}>
          {busy ? <Loader2 size={10} style={{ animation: 'spin 1s linear infinite' }} /> : null} ✅ 确认保存
        </button>
        <button onClick={onCancel} disabled={busy} style={smBtn}>取消</button>
      </div>
    </div>
  );
};

/** SQL diff（LCS 对齐 + 改动上下文窗口，与聊天窗口 vanilla 版同口径） */
const SqlDiff: React.FC<{ beforeText: string; afterText: string }> = ({ beforeText, afterText }) => {
  const a = String(beforeText || '').split('\n');
  const b = String(afterText || '').split('\n');
  const MAX = 500;
  if (a.length > MAX || b.length > MAX) {
    return (
      <div>
        <div style={{ fontSize: 10, color: 'var(--text-muted)' }}>改动过大，未做逐行对齐，仅并排展示原文与改写全文。</div>
        <div style={{ display: 'flex', gap: 8, marginTop: 4 }}>
          <pre style={preStyle}>{a.slice(0, 200).join('\n')}{a.length > 200 ? '\n…' : ''}</pre>
          <pre style={preStyle}>{b.slice(0, 200).join('\n')}{b.length > 200 ? '\n…' : ''}</pre>
        </div>
      </div>
    );
  }
  const n = a.length, m = b.length, stride = m + 1;
  const dp = new Uint32Array((n + 1) * stride);
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      dp[i * stride + j] = a[i] === b[j]
        ? dp[(i + 1) * stride + j + 1] + 1
        : Math.max(dp[(i + 1) * stride + j], dp[i * stride + j + 1]);
    }
  }
  const ops: Array<[string, string]> = [];
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) { ops.push(['ctx', a[i]]); i++; j++; }
    else if (dp[(i + 1) * stride + j] >= dp[i * stride + j + 1]) { ops.push(['del', a[i]]); i++; }
    else { ops.push(['add', b[j]]); j++; }
  }
  while (i < n) ops.push(['del', a[i++]]);
  while (j < m) ops.push(['add', b[j++]]);

  const CTX = 3;
  const keep = new Uint8Array(ops.length);
  ops.forEach((op, k) => {
    if (op[0] !== 'ctx') {
      for (let t = Math.max(0, k - CTX); t <= Math.min(ops.length - 1, k + CTX); t++) keep[t] = 1;
    }
  });

  const rows: React.ReactNode[] = [];
  let skipping = false;
  ops.forEach((op, k) => {
    if (op[0] === 'ctx' && !keep[k]) {
      if (!skipping) {
        rows.push(<div key={'s' + k} style={{ color: 'var(--text-muted)', fontSize: 10 }}>⋯</div>);
        skipping = true;
      }
      return;
    }
    skipping = false;
    const color = op[0] === 'del' ? 'var(--danger)' : op[0] === 'add' ? '#27ae60' : 'var(--text-secondary)';
    rows.push(
      <div key={k} style={{ color, fontSize: 10, fontFamily: 'ui-monospace, Consolas, monospace', whiteSpace: 'pre-wrap', wordBreak: 'break-all' }}>
        {(op[0] === 'del' ? '- ' : op[0] === 'add' ? '+ ' : '  ') + op[1]}
      </div>,
    );
  });

  return (
    <div style={{ maxHeight: 220, overflowY: 'auto' }}>
      <div style={{ fontSize: 10, color: 'var(--text-muted)' }}>红=原文删除  绿=改写新增</div>
      {rows}
    </div>
  );
};

const preStyle: React.CSSProperties = {
  flex: 1, margin: 0, fontSize: 10, fontFamily: 'ui-monospace, Consolas, monospace',
  whiteSpace: 'pre-wrap', wordBreak: 'break-all', color: 'var(--text-secondary)',
  background: 'var(--surface-1)', padding: 6, borderRadius: 4, overflow: 'auto', maxHeight: 160,
};

export default SkillGapCard;
