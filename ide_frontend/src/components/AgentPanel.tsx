import React, { useState, useRef, useEffect, useCallback } from 'react';
import { useStore } from '../stores/useStore';
import { useToast } from './Toast';
import { api } from '../services/api';
import { marked } from 'marked';
import { sanitizeHtml } from '../lib/sanitizeHtml';
import { stripOptionLines } from './wsCommon';
import { Sparkles, Send, X, Loader2, Copy, Trash2, FileCode, ChevronDown, ChevronRight, Search, Zap, Lock, Check, CheckCircle2, XCircle, Square } from 'lucide-react';

interface Step { id: string; label: string; status: 'running' | 'done' | 'error'; summary?: string; }
interface Msg {
  role: 'user' | 'assistant';
  content: string;
  sql?: string;
  steps?: Step[];
  elapsed_s?: number;
  /** 深度分析以提问收口（ask_user）：消息带可点选项卡片 */
  asked?: boolean;
  options?: string[];
}

const SESSION_KEY = 'sql-ide-agent-msgs-v2';

function loadMsgs(): Msg[] {
  try {
    const raw = sessionStorage.getItem(SESSION_KEY);
    return raw ? JSON.parse(raw) : [];
  } catch { return []; }
}

function saveMsgs(msgs: Msg[]) {
  try { sessionStorage.setItem(SESSION_KEY, JSON.stringify(msgs.slice(-100))); } catch {}
}

/** 生成一个新的 AI 会话 id（历史记录侧栏按它拉取 SQL 执行历史）。 */
function genSessionId(): string {
  return 'sess-' + Math.random().toString(36).slice(2, 10);
}

/**
 * AI源生：深度分析单一 agent 循环（/api/agent/chat/stream）+ 模型切换 + 「生成SQL」快路径。
 * 生成的 SQL 写入「🤖 AI Agent」编辑器页，可应用执行。
 */
export const AgentPanel: React.FC<{ onClose?: () => void }> = ({ onClose }) => {
  const {
    agentMode, toggleAgentMode,
    getOrCreateAgentEditorTab, setEditorTabSql, switchEditorTab,
    setSqlSessionId,
  } = useStore();
  const { success, error: toastError } = useToast();

  const [msgs, setMsgs] = useState<Msg[]>(loadMsgs);
  // 发送逻辑用最新消息镜像（选项点选在 setMsgs 后立即发送，状态值可能还是旧的）
  const msgsRef = useRef<Msg[]>(msgs);
  useEffect(() => { msgsRef.current = msgs; }, [msgs]);
  const [input, setInput] = useState('');
  const [loading, setLoading] = useState(false);
  const [mode, setMode] = useState<'chat' | 'generate'>('chat');
  const [models, setModels] = useState<string[]>([]);
  const [defaultModel, setDefaultModel] = useState('');
  const [model, setModel] = useState<string | null>(null); // null = 默认
  const [liveSteps, setLiveSteps] = useState<Step[]>([]);
  const [planText, setPlanText] = useState('');
  const [liveElapsed, setLiveElapsed] = useState(0);
  const elapsedTimerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const abortRef = useRef<AbortController | null>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const isAtBottomRef = useRef(true);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());

  // 模型列表 + 新会话 id
  useEffect(() => {
    api.getModels().then((r) => {
      setModels(r.models || []);
      setDefaultModel(r.default || '');
    }).catch(() => {});
    setSqlSessionId(genSessionId());
  }, [setSqlSessionId]);

  // 滚动到底 + 持久化
  useEffect(() => {
    if (isAtBottomRef.current) listRef.current?.scrollTo({ top: listRef.current.scrollHeight, behavior: 'smooth' });
    saveMsgs(msgs);
  }, [msgs]);

  const startTimer = () => {
    if (elapsedTimerRef.current) clearInterval(elapsedTimerRef.current);
    setLiveElapsed(0);
    const t0 = Date.now();
    elapsedTimerRef.current = setInterval(() => setLiveElapsed(Math.round((Date.now() - t0) / 1000)), 500);
  };
  const stopTimer = () => {
    if (elapsedTimerRef.current) { clearInterval(elapsedTimerRef.current); elapsedTimerRef.current = null; }
  };

  const handleScroll = useCallback(() => {
    const el = listRef.current;
    if (!el) return;
    isAtBottomRef.current = el.scrollHeight - el.scrollTop - el.clientHeight < 60;
  }, []);

  const toggleExpanded = (key: string) => setExpanded((prev) => {
    const next = new Set(prev);
    if (next.has(key)) next.delete(key); else next.add(key);
    return next;
  });

  const pushSqlToEditor = (sqlText: string, replace: boolean) => {
    const tabId = getOrCreateAgentEditorTab();
    const cur = useStore.getState().editorTabs.find((t) => t.id === tabId)?.sql || '';
    const next = replace
      ? sqlText
      : (cur.trim() ? cur + '\n\n-- ---- AI 生成 ----\n' + sqlText : sqlText);
    setEditorTabSql(tabId, next);
    switchEditorTab(tabId);
    success('SQL 已写入「🤖 AI Agent」查询窗口');
  };

  const applySql = async (sqlText: string) => {
    const tabId = getOrCreateAgentEditorTab();
    setEditorTabSql(tabId, sqlText);
    switchEditorTab(tabId);
    useStore.getState().setSelectedSql(null);
    await useStore.getState().executeSql(true);
  };

  const copyToClipboard = (text: string) => {
    navigator.clipboard.writeText(text).then(() => success('已复制到剪贴板')).catch(() => toastError('复制失败'));
  };

  const clearContext = () => {
    // 流进行中禁清空：final/error 事件用发送时捕获的 newMsgs 落盘，会把已清空的对话整段复活
    if (loading) return;
    setMsgs([]);
    sessionStorage.removeItem(SESSION_KEY);
    setExpanded(new Set());
    const { agentEditorTabId } = useStore.getState();
    if (agentEditorTabId) useStore.getState().setEditorTabSql(agentEditorTabId, '');
    setSqlSessionId(genSessionId());
  };

  /** 统一发送入口：baseMsgs 用于选项点选（已先清掉被点消息的选项）等场景覆盖消息基线；
   *  forceDeep：ask_user 选项续聊时强制走深度分析流，不受当前模式切换（生成SQL/深度）影响 */
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

    // ── 生成 SQL 快路径（/api/admin/sqls/generate） ──
    if (mode === 'generate' && !forceDeep) {
      try {
        const r = await api.generateSql(text, model ?? undefined);
        const sqlText = r.sql || '';
        setMsgs([...newMsgs, { role: 'assistant', content: '已根据描述生成 SQL：', sql: sqlText }]);
        if (sqlText) pushSqlToEditor(sqlText, true);
      } catch (e: any) {
        setMsgs([...newMsgs, { role: 'assistant', content: '生成失败: ' + (e.message || '未知错误') }]);
      } finally {
        setLoading(false);
        stopTimer();
      }
      return;
    }

    // ── 深度分析流（单一 agent 循环） ──
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
      const stream = api.deepAgentChatStream(text, history, model ?? undefined, controller.signal);
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
          // ask_user 提问收口：final 时挂到消息上渲染可点选项卡片
          pendingQuestion = { question: ev.question || '', options: (ev.options || []).filter((o: any) => typeof o === 'string') };
        } else if (ev.type === 'final') {
          if (ev.reply) replyText = ev.reply;
          if (!replyText && ev.error) replyText = ev.error;
          const sqls: string[] = ev.sqls || [];
          setMsgs([...newMsgs, {
            role: 'assistant',
            content: replyText || (ev.success ? '（无回复）' : '分析失败'),
            steps: [...steps],
            elapsed_s: Math.round((Date.now() - startedAt) / 1000),
            asked: !!pendingQuestion,
            options: pendingQuestion ? pendingQuestion.options : undefined,
          }]);
          if (sqls.length && !pendingQuestion) pushSqlToEditor(sqls.join('\n\n'), agentMode === 'auto');
        } else if (ev.type === 'error') {
          setMsgs([...newMsgs, { role: 'assistant', content: '出错: ' + (ev.message || '未知错误'), steps: [...steps] }]);
        }
      }
    } catch (e: any) {
      if (e?.name === 'AbortError') {
        setMsgs([...newMsgs, { role: 'assistant', content: '⏹ 已停止', steps: [...steps] }]);
      } else {
        setMsgs([...newMsgs, { role: 'assistant', content: e.message || '网络错误', steps: [...steps] }]);
      }
    } finally {
      setLoading(false);
      stopTimer();
      setLiveSteps([]);
      abortRef.current = null;
    }
  };

  const handleSend = () => {
    const text = input.trim();
    if (!text || loading) return;
    setInput('');
    doSend(text);
  };

  /** ask_user 选项卡片点击：先清掉该消息的选项（防止重复点选），再以「我选第 N 项：…」继续对话；
   *  forceDeep：无论当前模式（深度/生成SQL）如何切换，续聊必须回到深度分析流 */
  const handlePickOption = (m: Msg, opt: string, idx: number) => {
    if (loading) return;
    const text = `我选第 ${idx + 1} 项：${opt}`;
    const base = msgsRef.current.map((x) => (x === m ? { ...x, options: undefined } : x));
    doSend(text, base, true);
  };

  const handleStop = () => {
    if (abortRef.current) abortRef.current.abort();
  };

  const activeModel = model ?? defaultModel;

  return (
    <div style={{ width: '100%', height: '100%', position: 'relative', borderRight: '1px solid var(--border-light)', display: 'flex', flexDirection: 'column', backgroundColor: 'var(--surface-1)', flexShrink: 0, minHeight: 0 }}>
      {/* Header */}
      <div style={{ display: 'flex', alignItems: 'center', padding: '10px 12px', borderBottom: '1px solid var(--border-light)', gap: 6, minWidth: 0 }}>
        <h3 style={{ margin: 0, fontSize: 14, color: 'var(--text-primary)', display: 'flex', alignItems: 'center', gap: 6, flexShrink: 0 }}>
          <Sparkles size={14} style={{ color: 'var(--accent-amber)' }} /> AI源生
        </h3>
        <div style={{ display: 'flex', gap: 4, alignItems: 'center', flex: '1 1 auto', minWidth: 0, justifyContent: 'flex-end', flexWrap: 'nowrap' }}>
          {/* 模型切换（审计 P2-12：补 aria-label） */}
          {models.length > 0 && (
            <select
              value={activeModel}
              onChange={(e) => setModel(e.target.value || null)}
              title="切换 LLM 模型"
              aria-label="切换 LLM 模型"
              style={{ fontSize: 11, padding: '2px 6px', borderRadius: 3, cursor: 'pointer', backgroundColor: 'var(--surface-2)', color: 'var(--text-secondary)', border: '1px solid var(--text-muted)', flex: '1 1 auto', minWidth: 40, maxWidth: 200 }}
            >
              {models.map((m) => <option key={m} value={m}>{m}{m === defaultModel ? '（默认）' : ''}</option>)}
            </select>
          )}
          {/* 模式：深度分析 / 生成SQL（字号/内距对齐专项/知识库/算法的 ModeBtn，四工作台统一） */}
          <button
            onClick={() => setMode((m) => (m === 'chat' ? 'generate' : 'chat'))}
            title={mode === 'chat' ? '当前：深度分析（多轮 agent）——点击切到生成SQL' : '当前：生成SQL（单次）——点击切到深度分析'}
            style={{
              fontSize: 11, padding: '3px 9px', borderRadius: 4, cursor: 'pointer', whiteSpace: 'nowrap', flexShrink: 0,
              display: 'inline-flex', alignItems: 'center', gap: 4,
              fontWeight: mode === 'generate' ? 600 : 400,
              backgroundColor: mode === 'generate' ? 'var(--tint-blue-bg)' : 'transparent',
              color: mode === 'generate' ? 'var(--accent-blue)' : 'var(--text-secondary)',
              border: '1px solid var(--text-muted)',
            }}
          >
            {mode === 'chat'
              ? <><Search size={11} />深度分析</>
              : <><Zap size={11} />生成SQL</>}
          </button>
          {/* 自动/确认（字号对齐其它工作台） */}
          <button
            onClick={toggleAgentMode}
            title={agentMode === 'auto' ? '自动模式（点击切换为确认模式）' : '确认模式（点击切换为自动模式）'}
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
          <button onClick={clearContext} disabled={loading} style={{ ...iconBtn, opacity: loading ? 0.4 : 1, cursor: loading ? 'not-allowed' : 'pointer' }} title="新建对话" aria-label="新建对话"><Trash2 size={14} /></button>
          {onClose && <button onClick={onClose} style={iconBtn} title="关闭" aria-label="关闭"><X size={14} /></button>}
        </div>
      </div>

      {/* Messages */}
      <div ref={listRef} onScroll={handleScroll} style={{ flex: 1, overflowY: 'auto', padding: 8, display: 'flex', flexDirection: 'column', gap: 8 }}>
        {msgs.length === 0 && (
          <p style={{ textAlign: 'center', color: 'var(--text-inactive)', fontSize: 12, marginTop: 20 }}>
            {mode === 'generate' ? '输入取数需求，AI 生成一条 SQL' : '输入需求，AI 将自动取数并生成 SQL'}
          </p>
        )}
        {msgs.map((m, i) => (
          <div key={i} style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
            {m.role === 'user' ? (
              <div style={{ alignSelf: 'flex-end', backgroundColor: 'var(--accent-blue-faint)', padding: '6px 10px', borderRadius: 8, fontSize: 12, color: 'var(--text-primary)', maxWidth: '90%', whiteSpace: 'pre-wrap' }}>
                {m.content}
              </div>
            ) : (
              <div style={{ backgroundColor: 'var(--surface-2)', padding: '6px 10px', borderRadius: 8, fontSize: m.sql ? 11 : 12, color: 'var(--text-primary)', maxWidth: '100%', whiteSpace: 'pre-wrap' }}>
                {m.elapsed_s !== undefined && (
                  <div style={{ display: 'flex', justifyContent: 'flex-end', marginBottom: m.steps?.length ? 4 : 0 }}>
                    <span style={{ fontSize: 10, color: 'var(--text-muted)' }}>⏱ {m.elapsed_s}s</span>
                  </div>
                )}
                {m.steps && m.steps.length > 0 && (
                  <div style={{ marginBottom: 8, display: 'flex', flexDirection: 'column', gap: 3 }}>
                    {m.steps.map((s, si) => {
                      const key = `${i}-${si}`;
                      const isExpanded = expanded.has(key);
                      return (
                        <div key={si} style={{
                          fontSize: 11, borderRadius: 4, overflow: 'hidden',
                          backgroundColor: s.status === 'done' ? 'var(--tint-green-bg)' : s.status === 'error' ? 'var(--tint-red-bg)' : 'var(--tint-amber-bg)',
                          border: '1px solid',
                          borderColor: s.status === 'done' ? 'var(--tint-green-border)' : s.status === 'error' ? 'var(--tint-red-border)' : 'var(--tint-amber-bg)',
                        }}>
                          {/* 审计 P2-12：展开行 div → role=button 键盘可达 */}
                          <div onClick={() => toggleExpanded(key)} role="button" tabIndex={0} aria-expanded={isExpanded}
                            onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggleExpanded(key); } }}
                            style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '4px 8px', cursor: 'pointer', userSelect: 'none' }}>
                            <span style={{ flexShrink: 0, display: 'inline-flex', alignItems: 'center' }}>
                              {s.status === 'done'
                                ? <CheckCircle2 size={12} style={{ color: '#4caf50' }} />
                                : s.status === 'error'
                                  ? <XCircle size={12} style={{ color: '#e74c3c' }} />
                                  : <Loader2 size={12} style={{ animation: 'spin 1s linear infinite' }} />}
                            </span>
                            <span style={{ color: 'var(--accent-amber)', fontWeight: 600, fontSize: 10, flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{s.label}</span>
                            {s.summary && <span style={{ color: 'var(--text-muted)', fontSize: 10 }}>{s.summary}</span>}
                            {isExpanded ? <ChevronDown size={12} style={{ color: 'var(--text-muted)', flexShrink: 0 }} /> : <ChevronRight size={12} style={{ color: 'var(--text-muted)', flexShrink: 0 }} />}
                          </div>
                        </div>
                      );
                    })}
                  </div>
                )}
                {m.sql ? (
                  <code style={{ color: '#5a8', whiteSpace: 'pre-wrap', wordBreak: 'break-word' }}>{m.content}{'\n\n'}{m.sql}</code>
                ) : (
                  <div className="agent-reply" style={{ lineHeight: 1.7 }} dangerouslySetInnerHTML={{ __html: sanitizeHtml(marked.parse(stripOptionLines(m.content, m.options)) as string) }} />
                )}
                {/* ask_user 提问收口：可点选项卡片（点击即以「我选第 N 项：…」继续对话） */}
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
                {m.sql && (
                  <div style={{ display: 'flex', gap: 6, marginTop: 6, flexWrap: 'wrap' }}>
                    <button onClick={() => applySql(m.sql!)} disabled={loading}
                      style={{ padding: '3px 10px', borderRadius: 4, border: 'none', backgroundColor: 'var(--accent-blue)', color: '#fff', cursor: 'pointer', fontSize: 11, opacity: loading ? 0.5 : 1 }}>
                      应用并执行
                    </button>
                    <button onClick={() => pushSqlToEditor(m.sql!, false)}
                      style={{ display: 'flex', alignItems: 'center', gap: 3, padding: '3px 8px', borderRadius: 4, border: '1px solid var(--text-inactive)', backgroundColor: 'transparent', color: 'var(--text-secondary)', cursor: 'pointer', fontSize: 11 }}>
                      <FileCode size={10} /> 发到编辑器
                    </button>
                    <button onClick={() => copyToClipboard(m.sql!)}
                      style={{ display: 'flex', alignItems: 'center', gap: 3, padding: '3px 8px', borderRadius: 4, border: '1px solid var(--text-muted)', backgroundColor: 'transparent', color: 'var(--text-secondary)', cursor: 'pointer', fontSize: 11 }}>
                      <Copy size={10} /> 复制
                    </button>
                  </div>
                )}
              </div>
            )}
          </div>
        ))}
        {loading && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 6, padding: '8px 10px', backgroundColor: 'var(--tint-green-bg)', border: '1px solid var(--tint-green-border)', borderRadius: 8 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <Loader2 size={13} style={{ color: '#5a5', animation: 'spin 1s linear infinite', flexShrink: 0 }} />
              <span style={{ fontSize: 12, color: '#6a6', fontWeight: 600, flex: 1 }}>{mode === 'generate' ? '生成 SQL 中...' : 'AI 分析中...'}</span>
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
                        ? <Check size={10} style={{ color: '#4caf50' }} />
                        : s.status === 'error'
                          ? <X size={10} style={{ color: '#e74c3c' }} />
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
      <div style={{ padding: '8px 10px' }}>
        <div style={{ display: 'flex', gap: 6 }}>
          <textarea value={input} onChange={(e) => setInput(e.target.value)}
            aria-label="输入需求"
            onKeyDown={(e) => {
              if (e.key === 'Enter' && !e.shiftKey) {
                e.preventDefault();
                handleSend();
              }
            }}
            placeholder={mode === 'generate'
              ? `描述取数需求，生成 SQL（${activeModel || '默认模型'}）...（Enter 发送，Shift+Enter 换行）`
              : `输入需求（${agentMode === 'confirm' ? '🔒确认模式' : '⚡自动模式'}，${activeModel || '默认模型'}）...（Enter 发送，Shift+Enter 换行）`}
            rows={3}
            style={{ flex: 1, padding: '6px 10px', borderRadius: 6, border: '1px solid var(--text-muted)', backgroundColor: 'var(--surface-1)', color: 'var(--text-on-accent)', fontSize: 12, outline: 'none', resize: 'none', fontFamily: 'inherit', userSelect: 'text' }}
          />
          <button onClick={handleSend} disabled={loading || !input.trim()} aria-label="发送"
            style={{ width: 30, height: 30, display: 'flex', alignItems: 'center', justifyContent: 'center', borderRadius: 6, border: 'none', backgroundColor: 'var(--accent-blue)', color: '#fff', cursor: 'pointer', opacity: loading || !input.trim() ? 0.4 : 1, flexShrink: 0 }}>
            <Send size={13} />
          </button>
          {loading && (
            <button onClick={handleStop} aria-label="停止生成"
              style={{ width: 30, height: 30, display: 'flex', alignItems: 'center', justifyContent: 'center', borderRadius: 6, border: '1px solid #e74c3c', backgroundColor: 'transparent', color: '#e74c3c', cursor: 'pointer', fontSize: 16, lineHeight: 1, flexShrink: 0 }}>
              <Square size={13} fill="currentColor" />
            </button>
          )}
        </div>
      </div>
    </div>
  );
};

const iconBtn: React.CSSProperties = { background: 'none', border: 'none', color: 'var(--text-muted)', cursor: 'pointer', padding: 4, display: 'flex', alignItems: 'center', borderRadius: 3, flexShrink: 0 };
