import React, { useEffect, useRef, useState } from 'react';
import { api } from '../services/api';
import { useStore } from '../stores/useStore';
import { marked } from 'marked';
import { sanitizeHtml } from '../lib/sanitizeHtml';
import { stripOptionLines } from './wsCommon';
import { SkillGapCard, type SkillGapCardData } from './SkillGapCard';
import { Sparkles, Send, Trash2, X, Loader2, Check, Zap, Lock, Square, CheckCircle2, XCircle, Search } from 'lucide-react';

interface Msg {
  role: 'user' | 'assistant';
  content: string;
  draft?: any;
  /** 深度分析流消息（markdown 答复 + 工具步骤），不走 draftPreview/applyDraft */
  deep?: boolean;
  steps?: Step[];
  elapsed_s?: number;
  /** 深度分析是否成功（false 时错误文案不得自动/手动应用进编辑器） */
  success?: boolean;
  /** 是否已应用到编辑器（按消息记录，不随 agentMode 切换误判） */
  applied?: boolean;
  /** 深度分析以提问收口（ask_user）：消息带可点选项卡片；提问文本不得应用进编辑器 */
  asked?: boolean;
  options?: string[];
  /** 报告缺口与补数建议卡片（专项执行完成后自动触发，仅专项 AI源生面板） */
  gapCard?: SkillGapCardData;
  gapSeq?: number;
}

interface Step { id: string; label: string; status: 'running' | 'done' | 'error'; summary?: string; }

export interface DraftAgentPanelProps {
  sessionKey: string;
  /** 空对话提示（随 mode 变化；返回完整展示节点以便各工作台定制样式） */
  emptyHint: (mode: string | null) => React.ReactNode;
  placeholder: (model: string, mode: string | null) => string;
  loadingText: (mode: string | null) => string;
  /** 发送逻辑（父组件闭包内绑定端点与副作用）；返回 assistant 消息内容与可选草稿；抛错按 errorPrefix 组装失败消息 */
  send: (text: string, model: string | null, activeModel: string, mode: string | null) => Promise<{ content: string; draft?: any }>;
  errorPrefix?: (mode: string | null) => string;
  /** 草稿展示（markdown 渲染 / 代码预览 / 预检问题等），随各工作台定制 */
  draftPreview: (draft: any) => React.ReactNode;
  applyDraft: (draft: any) => void;
  applyLabel?: string;
  /** 深度分析流（复用 SQL 管理的 /api/agent/chat/stream 单一 agent 循环）；缺省则该面板无深度分析开关 */
  deepSend?: (text: string, model: string | null, history: { role: string; content: string }[], signal: AbortSignal) => AsyncGenerator<any>;
  /** 深度分析答复是否可应用（如模型面板无 Python 代码块时返回 false：不显示应用按钮、不自动应用） */
  deepApplicable?: (answer: string) => boolean;
  /** 深度分析答复应用方式（自动模式结束直接应用；确认模式给「应用到编辑器」按钮） */
  deepApply?: (answer: string) => void;
  deepApplyLabel?: string;
  /** 订阅报告缺口与补数建议卡片（专项执行完成自动触发，渲染进对话；仅专项 AI源生面板开启） */
  externalGap?: boolean;
  onClose?: () => void;
}

function loadMsgs(sessionKey: string): Msg[] {
  try {
    const raw = sessionStorage.getItem(sessionKey);
    return raw ? JSON.parse(raw) : [];
  } catch { return []; }
}

/**
 * 草稿生成 Agent 面板骨架（P1-12 收敛）：对话列表 + 模型切换 + 清空/关闭 + 加载指示 +
 * 草稿预览 + 「应用到编辑器」。Skill / Knowledge / Models 三个 AgentPanel 共用，
 * 端点与草稿落盘由 send / applyDraft 参数化。
 * P2-16：对齐 SQL 管理的 AI源生 面板——新增「深度分析」流（deepSend 流式 agent 循环，
 * 工具步骤/计划文本/耗时展示）与「自动/确认」切换（全局 agentMode 与 SQL 面板共享；
 * 自动=生成/分析完直接应用到编辑器，确认=手动点应用按钮）。
 * 模式收敛：对话本身即「生成」（单次 LLM 请求），不再单独设「生成专项/知识/算法」按钮；
 * 头部只保留「深度分析」开关（再点一次切回普通生成）。专项笔记改由后端在生成时自动提炼沉淀。
 */
export const DraftAgentPanel: React.FC<DraftAgentPanelProps> = ({
  sessionKey, emptyHint, placeholder, loadingText, send, errorPrefix,
  draftPreview, applyDraft, applyLabel = '应用到编辑器',
  deepSend, deepApplicable, deepApply, deepApplyLabel, externalGap, onClose,
}) => {
  const [mode, setMode] = useState<string | null>(null);
  const [msgs, setMsgs] = useState<Msg[]>(() => loadMsgs(sessionKey));
  // 卸载清理用最新消息镜像（cleanup 闭包若直接读 msgs 会拿到过期值）
  const msgsRef = useRef<Msg[]>(msgs);
  useEffect(() => { msgsRef.current = msgs; }, [msgs]);
  const [input, setInput] = useState('');
  const [loading, setLoading] = useState(false);
  const [models, setModels] = useState<string[]>([]);
  const [defaultModel, setDefaultModel] = useState('');
  const [model, setModel] = useState<string | null>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const isAtBottomRef = useRef(true);
  const abortRef = useRef<AbortController | null>(null);
  const [liveSteps, setLiveSteps] = useState<Step[]>([]);
  const [planText, setPlanText] = useState('');
  const [liveElapsed, setLiveElapsed] = useState(0);
  const elapsedTimerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  // 自动/确认：全局 store agentMode（与 SQL 管理 AI源生 共享同一开关）
  const agentMode = useStore((s) => s.agentMode);
  const toggleAgentMode = useStore((s) => s.toggleAgentMode);

  useEffect(() => {
    api.getModels().then((r) => {
      setModels(r.models || []);
      setDefaultModel(r.default || '');
    }).catch(() => {});
  }, []);

  // 报告缺口与补数建议卡片（externalGap，仅专项 AI源生面板）：执行完成后 skillRun.ts
  // 把卡片写进 store，这里按 seq 消费追加成一条 assistant 消息。面板关闭时卡片先落 store，
  // 下次挂载（读 sessionStorage 后）补挂——消息本身随 sessionStorage 持久化，回放不丢。
  const skillGapCard = useStore((s) => s.skillGapCard);
  const gapSeqRef = useRef(0);
  useEffect(() => {
    if (!externalGap || !skillGapCard || skillGapCard.seq <= gapSeqRef.current) return;
    gapSeqRef.current = skillGapCard.seq;
    setMsgs((prev) => {
      if (prev.some((m) => m.gapSeq === skillGapCard.seq)) return prev;
      return [...prev, { role: 'assistant' as const, content: '', gapCard: skillGapCard, gapSeq: skillGapCard.seq }];
    });
  }, [externalGap, skillGapCard]);

  useEffect(() => {
    if (isAtBottomRef.current) listRef.current?.scrollTo({ top: listRef.current.scrollHeight, behavior: 'smooth' });
    try { sessionStorage.setItem(sessionKey, JSON.stringify(msgs.slice(-60))); } catch {}
  }, [msgs, liveSteps, planText, sessionKey]);

  const startTimer = () => {
    if (elapsedTimerRef.current) clearInterval(elapsedTimerRef.current);
    setLiveElapsed(0);
    const t0 = Date.now();
    elapsedTimerRef.current = setInterval(() => setLiveElapsed(Math.round((Date.now() - t0) / 1000)), 500);
  };
  const stopTimer = () => {
    if (elapsedTimerRef.current) { clearInterval(elapsedTimerRef.current); elapsedTimerRef.current = null; }
  };
  // 卸载兜底（对抗审查 correctness 轮）：隐藏 AI 栏等卸载路径若撞上流进行中——
  // abort 止损 + 按 msgsRef 把最新消息落回 sessionStorage，避免答复静默丢失；
  // 重挂后新实例从 sessionStorage 读回，对话不丢。
  useEffect(() => () => {
    if (abortRef.current) abortRef.current.abort();
    stopTimer();
    try { sessionStorage.setItem(sessionKey, JSON.stringify(msgsRef.current.slice(-60))); } catch {}
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionKey]);

  const handleScroll = () => {
    const el = listRef.current;
    if (!el) return;
    isAtBottomRef.current = el.scrollHeight - el.scrollTop - el.clientHeight < 60;
  };

  const activeModel = model ?? defaultModel;
  const disabled = loading || !input.trim();
  const isDeep = mode === 'deep';

  /** 统一发送入口：baseMsgs 用于选项点选（已先清掉被点消息的选项）等场景覆盖消息基线；
   *  forceDeep：ask_user 选项续聊时强制走深度分析流，不受深度开关被切回的影响 */
  const doSend = async (text: string, baseMsgs?: Msg[], forceDeep?: boolean) => {
    if (!text || loading) return;
    isAtBottomRef.current = true;
    const base = baseMsgs || msgsRef.current;
    const userMsg: Msg = { role: 'user', content: text };
    const newMsgs = [...base, userMsg];
    setMsgs(newMsgs);
    setLoading(true);
    setLiveSteps([]);
    setPlanText('');
    startTimer();

    // ── 深度分析流（单一 agent 循环，与 SQL 管理一致） ──
    if ((isDeep || forceDeep) && deepSend) {
      const controller = new AbortController();
      abortRef.current = controller;
      const steps: Step[] = [];
      let stepCounter = 0;
      let replyText = '';
      let pendingQuestion: { question: string; options: string[] } | null = null;
      // 历史不含刚追加的用户消息：后端 routers/agent.py 会 append body.message，
      // 一并传入会把同一条用户消息喂两遍（对抗审查修复）
      const history = base.map((m) => ({ role: m.role, content: m.content }));
      const startedAt = Date.now();
      try {
        const stream = deepSend(text, model ?? null, history, controller.signal);
        for await (const ev of stream) {
          if (ev.type === 'agent_start') {
            setPlanText('');
          } else if (ev.type === 'plan_text') {
            setPlanText(ev.text || '');
          } else if (ev.type === 'tool_start') {
            const id = 't' + (++stepCounter);
            steps.push({ id, label: ev.name || '工具', status: 'running' });
            setLiveSteps([...steps]);
          } else if (ev.type === 'tool_done') {
            const idx = [...steps].reverse().findIndex((s) => s.label === (ev.name || '') && s.status === 'running');
            if (idx >= 0) {
              const realIdx = steps.length - 1 - idx;
              steps[realIdx] = { ...steps[realIdx], status: ev.ok ? 'done' : 'error', summary: ev.summary || '' };
            }
            setLiveSteps([...steps]);
          } else if (ev.type === 'answer') {
            replyText += ev.text || '';
          } else if (ev.type === 'question') {
            // ask_user 提问收口：记下问题与选项，final 时挂到消息上渲染可点选项卡片
            pendingQuestion = { question: ev.question || '', options: (ev.options || []).filter((o: any) => typeof o === 'string') };
          } else if (ev.type === 'final') {
            if (ev.reply) replyText = ev.reply;
            if (!replyText && ev.error) replyText = ev.error;
            const ok = ev.success !== false;
            // 自动模式只在成功时应用：失败终态（超轮数/超时/LLMNotConfigured）的
            // 错误文案不得被追加进方法说明/知识文档草稿；ask_user 提问收口的消息同样不得应用
            const applied = ok && !pendingQuestion && !!replyText && agentMode === 'auto' && !!deepApply && (!deepApplicable || deepApplicable(replyText));
            if (applied) deepApply(replyText);
            setMsgs([...newMsgs, {
              role: 'assistant',
              content: replyText || (ok ? '（无回复）' : '分析失败'),
              deep: true,
              steps: [...steps],
              elapsed_s: Math.round((Date.now() - startedAt) / 1000),
              success: ok,
              applied,
              asked: !!pendingQuestion,
              options: pendingQuestion ? pendingQuestion.options : undefined,
            }]);
          } else if (ev.type === 'error') {
            setMsgs([...newMsgs, { role: 'assistant', content: '出错: ' + (ev.message || '未知错误'), deep: true, steps: [...steps], success: false }]);
          }
        }
      } catch (e: any) {
        if (e?.name === 'AbortError') {
          setMsgs([...newMsgs, { role: 'assistant', content: '⏹ 已停止', deep: true, steps: [...steps], success: false }]);
        } else {
          setMsgs([...newMsgs, { role: 'assistant', content: e.message || '网络错误', deep: true, steps: [...steps], success: false }]);
        }
      } finally {
        setLoading(false);
        stopTimer();
        setLiveSteps([]);
        setPlanText('');
        abortRef.current = null;
      }
      return;
    }

    // ── 生成模式（单次请求） ──
    try {
      const r = await send(text, model ?? null, activeModel, mode);
      // 自动模式：生成完直接应用到编辑器，无需再点「应用到编辑器」（按消息记录 applied）
      const applied = !!r.draft && agentMode === 'auto';
      if (applied) applyDraft(r.draft);
      setMsgs([...newMsgs, { role: 'assistant', content: r.content, draft: r.draft, applied }]);
    } catch (e: any) {
      const prefix = errorPrefix ? errorPrefix(mode) : '生成失败：';
      setMsgs([...newMsgs, { role: 'assistant', content: prefix + (e.message || '未知错误') }]);
    } finally {
      setLoading(false);
      stopTimer();
    }
  };

  const handleSend = () => {
    const text = input.trim();
    if (!text || loading) return;
    setInput('');
    doSend(text);
  };

  /** ask_user 选项卡片点击：先清掉该消息的选项（防止重复点选），再以「我选第 N 项：…」继续对话；
   *  forceDeep：无论深度开关是否被切回，续聊必须回到深度分析流 */
  const handlePickOption = (m: Msg, opt: string, idx: number) => {
    if (loading) return;
    const text = `我选第 ${idx + 1} 项：${opt}`;
    const base = msgsRef.current.map((x) => (x === m ? { ...x, options: undefined } : x));
    doSend(text, base, true);
  };

  const handleStop = () => {
    if (abortRef.current) abortRef.current.abort();
  };

  const clearContext = () => {
    // 流进行中禁清空：final/error 事件用发送时捕获的 newMsgs 落盘，会把已清空的对话整段复活
    if (loading) return;
    setMsgs([]);
    try { sessionStorage.removeItem(sessionKey); } catch {}
  };

  return (
    <div style={{ width: '100%', height: '100%', minHeight: 0, borderRight: '1px solid var(--border-light)', display: 'flex', flexDirection: 'column', backgroundColor: 'var(--surface-1)' }}>
      {/* Header */}
      <div style={{ display: 'flex', alignItems: 'center', padding: '10px 12px', borderBottom: '1px solid var(--border-light)', gap: 6, minWidth: 0 }}>
        <h3 style={{ margin: 0, fontSize: 14, color: 'var(--text-primary)', display: 'flex', alignItems: 'center', gap: 6, flexShrink: 0 }}>
          <Sparkles size={14} style={{ color: 'var(--accent-amber)' }} /> AI源生
        </h3>
        <div style={{ display: 'flex', gap: 4, alignItems: 'center', flex: '1 1 auto', minWidth: 0, justifyContent: 'flex-end', flexWrap: 'nowrap' }}>
          {models.length > 0 && (
            <select
              value={activeModel}
              onChange={(e) => setModel(e.target.value || null)}
              title="切换 LLM 模型"
              aria-label="切换 LLM 模型"
              style={{ fontSize: 11, padding: '2px 6px', borderRadius: 3, cursor: 'pointer', backgroundColor: 'var(--surface-2)', color: 'var(--text-secondary)', border: '1px solid var(--text-muted)', flex: '1 1 auto', minWidth: 40, maxWidth: 200 }}>
              {models.map((m) => <option key={m} value={m}>{m}{m === defaultModel ? '（默认）' : ''}</option>)}
            </select>
          )}
          {/* 深度分析开关（与 SQL 管理 AI源生 头部同款式；对话本身即生成，不再单独设「生成」按钮，再点一次切回普通生成）。
              流进行中禁用：切回会让停止按钮消失、流不可中止 */}
          {deepSend && (
            <ModeBtn active={isDeep} disabled={loading} onClick={() => setMode(isDeep ? null : 'deep')} icon={<Search size={11} />} label="深度分析" />
          )}
          {/* 自动/确认（全局 agentMode，与 SQL 管理 AI源生 共享；字号四工作台统一 11） */}
          <button
            onClick={toggleAgentMode}
            title={agentMode === 'auto' ? '自动模式（生成/分析完直接应用到编辑器；点击切换为确认模式）' : '确认模式（生成/分析完先预览，手动点应用；点击切换为自动模式）'}
            style={{
              fontSize: 11, padding: '2px 6px', borderRadius: 3, cursor: 'pointer', whiteSpace: 'nowrap', flexShrink: 0,
              display: 'inline-flex', alignItems: 'center', gap: 3,
              backgroundColor: agentMode === 'auto' ? 'var(--tint-green-bg)' : 'var(--tint-amber-bg)',
              color: agentMode === 'auto' ? '#5a5' : '#f90',
              border: `1px solid ${agentMode === 'auto' ? 'var(--tint-green-border)' : 'var(--tint-amber-border)'}`,
            }}
          >
            {agentMode === 'auto' ? <><Zap size={11} />自动</> : <><Lock size={11} />确认</>}
          </button>
          {/* 审计 P2-12：图标按钮补 aria-label（原仅 title 或无 label） */}
          <button onClick={clearContext} disabled={loading} style={{ ...iconBtn, opacity: loading ? 0.4 : 1, cursor: loading ? 'not-allowed' : 'pointer' }} title="清空对话" aria-label="清空对话"><Trash2 size={14} /></button>
          {onClose && <button onClick={onClose} style={iconBtn} title="关闭" aria-label="关闭"><X size={14} /></button>}
        </div>
      </div>

      {/* Messages */}
      <div ref={listRef} onScroll={handleScroll} style={{ flex: 1, overflowY: 'auto', padding: 8, display: 'flex', flexDirection: 'column', gap: 8 }}>
        {msgs.length === 0 && (
          <p style={{ textAlign: 'center', color: 'var(--text-inactive)', fontSize: 12, marginTop: 20 }}>
            {emptyHint(mode)}
          </p>
        )}
        {msgs.map((m, i) => (
          <div key={i} style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
            {m.role === 'user' ? (
              <div style={{ alignSelf: 'flex-end', backgroundColor: 'var(--accent-blue-faint)', padding: '6px 10px', borderRadius: 8, fontSize: 12, color: 'var(--text-primary)', maxWidth: '90%', whiteSpace: 'pre-wrap' }}>
                {m.content}
              </div>
            ) : (
              <div style={{ backgroundColor: 'var(--surface-2)', padding: '6px 10px', borderRadius: 8, fontSize: 12, color: 'var(--text-primary)', maxWidth: '100%', whiteSpace: 'pre-wrap' }}>
                {m.elapsed_s !== undefined && (
                  <div style={{ display: 'flex', justifyContent: 'flex-end', marginBottom: m.steps?.length ? 4 : 0 }}>
                    <span style={{ fontSize: 10, color: 'var(--text-muted)' }}>⏱ {m.elapsed_s}s</span>
                  </div>
                )}
                {m.steps && m.steps.length > 0 && <StepsBlock steps={m.steps} />}
                {m.gapCard && <SkillGapCard card={m.gapCard} />}
                {!m.gapCard && (m.deep ? (
                  <div className="agent-reply" style={{ lineHeight: 1.7 }} dangerouslySetInnerHTML={{ __html: sanitizeHtml(marked.parse(stripOptionLines(m.content, m.options)) as string) }} />
                ) : (
                  <>
                    {/* 旧会话/生成态消息同样走 markdown 渲染（旧 note 模式消息含 LLM 提炼的 markdown，纯文本展示会露出 #/` 语法） */}
                    <div className="agent-reply" style={{ fontWeight: 600, marginBottom: 4, lineHeight: 1.7 }} dangerouslySetInnerHTML={{ __html: sanitizeHtml(marked.parse(m.content) as string) }} />
                    {m.draft && draftPreview(m.draft)}
                  </>
                ))}
                {/* ask_user 提问收口：可点选项卡片（点击即以「我选第 N 项：…」继续对话，与 sql-ide ask_user 同款体验） */}
                {m.options && m.options.length > 0 && (
                  <div style={{ display: 'flex', flexDirection: 'column', gap: 6, marginTop: 8 }}>
                    <div style={{ fontSize: 10, color: 'var(--text-muted)' }}>💬 点击选项回复（将按所选继续执行）：</div>
                    {m.options.map((o, oi) => (
                      <button key={oi} disabled={loading} onClick={() => handlePickOption(m, o, oi)}
                        title={loading ? '请等待当前任务结束' : '点击选择该项并继续'}
                        style={{
                          display: 'flex', alignItems: 'center', gap: 6, padding: '5px 10px', borderRadius: 5,
                          border: '1px solid var(--accent-blue)', backgroundColor: 'var(--accent-blue-faint)',
                          color: 'var(--text-primary)', cursor: loading ? 'not-allowed' : 'pointer', fontSize: 12,
                          textAlign: 'left', opacity: loading ? 0.5 : 1,
                        }}>
                        <span style={{ fontSize: 10, fontWeight: 600, color: 'var(--accent-blue)', flexShrink: 0 }}>{oi + 1}</span>
                        <span>{o}</span>
                      </button>
                    ))}
                  </div>
                )}
                {/* 应用按钮/标记按「该消息是否已应用」判定（不随 agentMode 切换误判）；深度分析仅成功消息可应用；提问收口消息不应用 */}
                {!m.applied && agentMode === 'confirm' && !m.deep && m.draft && (
                  <button onClick={() => { applyDraft(m.draft); setMsgs((prev) => prev.map((x) => x === m ? { ...x, applied: true } : x)); }}
                    style={{ display: 'flex', alignItems: 'center', gap: 4, marginTop: 6, padding: '3px 10px', borderRadius: 4, border: 'none', backgroundColor: 'var(--accent-blue)', color: '#fff', cursor: 'pointer', fontSize: 11 }}>
                    <Check size={11} /> {applyLabel}
                  </button>
                )}
                {!m.applied && !m.asked && agentMode === 'confirm' && m.deep && m.success !== false && deepApply && (!deepApplicable || deepApplicable(m.content)) && (
                  <button onClick={() => { deepApply(m.content); setMsgs((prev) => prev.map((x) => x === m ? { ...x, applied: true } : x)); }}
                    style={{ display: 'flex', alignItems: 'center', gap: 4, marginTop: 6, padding: '3px 10px', borderRadius: 4, border: 'none', backgroundColor: 'var(--accent-blue)', color: '#fff', cursor: 'pointer', fontSize: 11 }}>
                    <Check size={11} /> {deepApplyLabel || '应用到编辑器'}
                  </button>
                )}
                {m.applied && (
                  <div style={{ marginTop: 6, fontSize: 10, color: '#5a5' }}>⚡ 已应用到编辑器</div>
                )}
              </div>
            )}
          </div>
        ))}
        {loading && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 6, padding: '8px 10px', backgroundColor: 'var(--tint-green-bg)', border: '1px solid var(--tint-green-border)', borderRadius: 8 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <Loader2 size={13} style={{ color: '#5a5', animation: 'spin 1s linear infinite', flexShrink: 0 }} />
              <span style={{ fontSize: 12, color: '#6a6', fontWeight: 600, flex: 1 }}>{loadingText(mode)}</span>
              {liveElapsed > 0 && <span style={{ fontSize: 11, color: '#5a7', fontVariantNumeric: 'tabular-nums', flexShrink: 0 }}>{liveElapsed}s</span>}
            </div>
            {planText && (
              <pre style={{ margin: 0, fontSize: 10, color: 'var(--text-secondary)', whiteSpace: 'pre-wrap', wordBreak: 'break-word', lineHeight: 1.5 }}>{planText}</pre>
            )}
            {liveSteps.length > 0 && (
              <div style={{ display: 'flex', flexDirection: 'column', gap: 2, maxHeight: 200, overflowY: 'auto' }}>
                {liveSteps.map((s) => (
                  <div key={s.id} style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                    <span style={{ fontSize: 11, flexShrink: 0, width: 14, textAlign: 'center', display: 'inline-flex', alignItems: 'center', justifyContent: 'center' }}>
                      {s.status === 'done'
                        ? <CheckCircle2 size={10} style={{ color: '#4caf50' }} />
                        : s.status === 'error'
                          ? <XCircle size={10} style={{ color: '#e74c3c' }} />
                          : <Loader2 size={10} style={{ animation: 'spin 1s linear infinite' }} />}
                    </span>
                    <span style={{ fontSize: 11, color: s.status === 'running' ? '#8c8' : 'var(--text-muted)', flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{s.label}</span>
                    {s.summary && <span style={{ fontSize: 10, color: 'var(--text-muted)', flexShrink: 0 }}>{s.summary}</span>}
                  </div>
                ))}
              </div>
            )}
          </div>
        )}
      </div>

      {/* Input */}
      <div style={{ padding: '8px 10px', borderTop: '1px solid var(--border-light)' }}>
        <div style={{ display: 'flex', gap: 6 }}>
          <textarea value={input} onChange={(e) => setInput(e.target.value)}
            onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); handleSend(); } }}
            placeholder={placeholder(activeModel, mode)}
            rows={2}
            style={{ flex: 1, padding: '6px 10px', borderRadius: 6, border: '1px solid var(--text-muted)', backgroundColor: 'var(--surface-1)', color: 'var(--text-on-accent)', fontSize: 12, outline: 'none', resize: 'none', fontFamily: 'inherit' }} />
          <button onClick={handleSend} disabled={disabled} aria-label="发送"
            style={{ width: 30, height: 30, display: 'flex', alignItems: 'center', justifyContent: 'center', borderRadius: 6, border: 'none', backgroundColor: 'var(--accent-blue)', color: '#fff', cursor: 'pointer', opacity: disabled ? 0.4 : 1, flexShrink: 0 }}>
            <Send size={13} />
          </button>
          {loading && isDeep && (
            <button onClick={handleStop} aria-label="停止生成"
              style={{ width: 30, height: 30, display: 'flex', alignItems: 'center', justifyContent: 'center', borderRadius: 6, border: '1px solid #e74c3c', backgroundColor: 'transparent', color: '#e74c3c', cursor: 'pointer', flexShrink: 0 }}>
              <Square size={13} fill="currentColor" />
            </button>
          )}
        </div>
      </div>
    </div>
  );
};

/** 已完成的深度分析消息内的工具步骤块（状态着色 + 摘要） */
const StepsBlock: React.FC<{ steps: Step[] }> = ({ steps }) => (
  <div style={{ marginBottom: 8, display: 'flex', flexDirection: 'column', gap: 3 }}>
    {steps.map((s, i) => (
      <div key={i} style={{
        display: 'flex', alignItems: 'center', gap: 6, padding: '3px 8px', borderRadius: 4, fontSize: 11,
        backgroundColor: s.status === 'done' ? 'var(--tint-green-bg)' : s.status === 'error' ? 'var(--tint-red-bg)' : 'var(--tint-amber-bg)',
        border: '1px solid',
        borderColor: s.status === 'done' ? 'var(--tint-green-border)' : s.status === 'error' ? 'var(--tint-red-border)' : 'var(--tint-amber-bg)',
      }}>
        <span style={{ flexShrink: 0, display: 'inline-flex', alignItems: 'center' }}>
          {s.status === 'done'
            ? <CheckCircle2 size={12} style={{ color: '#4caf50' }} />
            : s.status === 'error'
              ? <XCircle size={12} style={{ color: '#e74c3c' }} />
              : <Loader2 size={12} style={{ animation: 'spin 1s linear infinite' }} />}
        </span>
        <span style={{ color: 'var(--accent-amber)', fontWeight: 600, fontSize: 10, flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{s.label}</span>
        {s.summary && <span style={{ color: 'var(--text-muted)', fontSize: 10 }}>{s.summary}</span>}
      </div>
    ))}
  </div>
);

const ModeBtn: React.FC<{ active: boolean; disabled?: boolean; onClick: () => void; icon: React.ReactNode; label: string }> = ({ active, disabled, onClick, icon, label }) => (
  <button onClick={() => { if (!disabled) onClick(); }} aria-disabled={disabled}
    style={{
      display: 'flex', alignItems: 'center', gap: 4, padding: '3px 9px', borderRadius: 4, border: '1px solid var(--text-muted)', whiteSpace: 'nowrap', flexShrink: 0,
      backgroundColor: active ? 'var(--tint-blue-bg)' : 'transparent', color: active ? 'var(--accent-blue)' : 'var(--text-secondary)',
      cursor: disabled ? 'not-allowed' : 'pointer', fontSize: 11, fontWeight: active ? 600 : 400, opacity: disabled ? 0.5 : 1,
    }}>
    {icon}{label}
  </button>
);

const iconBtn: React.CSSProperties = { background: 'none', border: 'none', color: 'var(--text-muted)', cursor: 'pointer', padding: 4, display: 'flex', alignItems: 'center', borderRadius: 3, flexShrink: 0 };
