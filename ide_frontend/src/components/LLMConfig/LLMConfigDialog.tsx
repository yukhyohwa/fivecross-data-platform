import React, { useEffect, useState } from 'react';
import { useToast } from '../Toast';
import { api } from '../../services/api';
import { useDialog } from '../../lib/useDialog';
import { overlayStyle } from '../wsCommon';
import { Loader2, CheckCircle, XCircle, X } from 'lucide-react';

// 网关模型（对齐 analysis/ai_client.py 的 MODELS）。per-user model 只覆盖主对话 / 深度分析模型；
// 全站系统级选型（指标拆分/报告三模型等 13 个槽位）统一在「系统管理 → 模型管理」调整（2026-10-26）。
const MODEL_GROUPS: { vendor: string; models: { id: string; label: string }[] }[] = [
  { vendor: 'Anthropic', models: [{ id: 'claude-opus-4-6', label: '旗舰' }, { id: 'claude-haiku-4-5', label: '快速' }] },
  { vendor: 'OpenAI', models: [{ id: 'gpt-5-5', label: '旗舰' }, { id: 'gpt-5-mini', label: '快速' }] },
  { vendor: 'Google', models: [{ id: 'gemini-3.1-pro', label: '旗舰' }, { id: 'gemini-3-6-flash', label: '快速' }] },
  { vendor: 'DeepSeek', models: [{ id: 'deepseek-v4-pro', label: '旗舰' }, { id: 'deepseek-v4-flash', label: '快速' }] },
  { vendor: '智谱', models: [{ id: 'glm-5-2', label: '旗舰' }, { id: 'glm-flash-latest', label: '快速' }] },
];

// legacy 直连哨兵值：建表默认（deepseek 直连），后端视作「未配置」回落全局，前端归一为空
const LEGACY_MODEL = 'deepseek-chat';
const LEGACY_BASE = 'https://api.deepseek.com/v1';

// 审计 P2-6：保存/测试遇 401/403（Key 失效或权限不足）时，错误提示补一句个人 Key 检查提示
const KEY_EXPIRED_HINT = '个人 Key 可能失效，请检查 Key 是否有效';
const isAuthErrorMsg = (msg: string) => /401|403|无效|未登录|unauthorized|forbidden/i.test(msg || '');
const withKeyHint = (msg: string) => (isAuthErrorMsg(msg) ? `${msg}。${KEY_EXPIRED_HINT}` : msg);

/** 右上角用户菜单弹出的 LLM 配置弹窗（原「个人配置 → LLM 配置」页，移到用户菜单）。 */
export const LLMConfigDialog: React.FC<{ onClose: () => void }> = ({ onClose }) => {
  const { success: toastSuccess, error: toastError } = useToast();
  const [apiKey, setApiKey] = useState('');
  const [model, setModel] = useState('');
  const [apiBase, setApiBase] = useState('');
  const [saving, setSaving] = useState(false);
  const [testing, setTesting] = useState(false);
  const [testResult, setTestResult] = useState<{ success: boolean; message: string } | null>(null);
  const [isAdmin, setIsAdmin] = useState(false);

  // 审计 P2-12：弹窗接入 useDialog（Escape 关闭 + 打开聚焦 + 关闭还原焦点）；本组件仅在打开时挂载
  const dialogRef = useDialog(true, onClose);

  useEffect(() => {
    api.getAgentConfig().then((c) => {
      const k = c.api_key || '';
      const m = (c.model && c.model !== LEGACY_MODEL) ? c.model : '';
      const b = (c.api_base && c.api_base !== LEGACY_BASE) ? c.api_base : '';
      setApiKey(k); setModel(m); setApiBase(b);
    }).catch(() => {});
    api.getMe().then((u) => {
      setIsAdmin(u.llm_access === 'admin' || (u.permissions || []).includes('system'));
    }).catch(() => {});
  }, []);

  const saveConfig = async () => {
    setSaving(true);
    try {
      await api.saveAgentConfig({ api_key: apiKey, model, api_base: apiBase });
      toastSuccess('配置已保存');
    } catch (e: any) {
      // 审计 P2-6：401/403 时提示个人 Key 可能失效
      toastError(withKeyHint(e.message || '保存失败'));
    } finally {
      setSaving(false);
    }
  };

  const testConnection = async () => {
    if (!apiKey.trim()) {
      toastError('请先填写 API Key');
      return;
    }
    setTesting(true);
    setTestResult(null);
    try {
      const res = await api.testLLMConnection({ api_key: apiKey, model, api_base: apiBase });
      if (res.success) {
        setTestResult({ success: true, message: res.message || '连接成功' });
        toastSuccess('连通性测试通过');
      } else {
        // 审计 P2-6：Key 无效/401/403 时提示个人 Key 可能失效
        const msg = withKeyHint(res.message || '连接失败');
        setTestResult({ success: false, message: msg });
        toastError(msg);
      }
    } catch (e: any) {
      // 审计 P2-6：401/403 时提示个人 Key 可能失效
      const msg = withKeyHint(e.message || '连接失败');
      setTestResult({ success: false, message: msg });
      toastError(msg);
    } finally {
      setTesting(false);
    }
  };

  return (
    // 审计 P2-12：遮罩点击关闭；卡片 role/aria-modal/tabIndex 弹窗语义
    <div onClick={onClose} style={overlayStyle}>
      <div ref={dialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={modalStyle}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 6 }}>
          <h2 style={{ margin: 0, fontSize: 16, color: 'var(--text-heading)' }}>LLM 配置</h2>
          <button onClick={onClose} aria-label="关闭" style={{ background: 'none', border: 'none', color: 'var(--text-muted)', cursor: 'pointer', padding: 4 }}><X size={18} /></button>
        </div>
        {isAdmin ? (
          <p style={{ margin: '0 0 12px', fontSize: 12, color: 'var(--text-muted)', lineHeight: 1.6 }}>
            你是<strong>管理员</strong>：API Key / 模型 / 地址留空即回落系统默认 LLM（<code>.env</code> 的 LITELLM 配置）。
          </p>
        ) : (
          <div style={{ margin: '0 0 16px', padding: '10px 12px', borderRadius: 6, fontSize: 12, lineHeight: 1.6, backgroundColor: 'var(--tint-amber-bg, var(--surface-2))', color: 'var(--accent-amber, #c9a227)', border: '1px solid var(--accent-amber, #c9a227)' }}>
            非管理员身份<strong>必须手填 API Key</strong>才能使用任何 AI 功能（主对话 / 深度分析 / 报告 / 指标拆分等）。
            未配置时后端会直接拦截。
          </div>
        )}
        <p style={{ margin: '0 0 20px', fontSize: 12, color: 'var(--text-muted)', lineHeight: 1.6 }}>
          模型只覆盖<strong>主对话 / 深度分析</strong>；指标拆分、报告三模型仍走系统选型。
        </p>

        {/* Model */}
        <div style={fieldStyle}>
          <label style={lab}>模型（留空走系统默认）</label>
          <input value={model} onChange={(e) => setModel(e.target.value)} style={inp} placeholder="未配置，使用系统默认" aria-label="模型（留空走系统默认）" />
          <div style={{ display: 'flex', flexDirection: 'column', gap: 4, marginTop: 6 }}>
            {MODEL_GROUPS.map((g) => (
              <div key={g.vendor} style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                <span style={{ width: 68, fontSize: 11, color: 'var(--text-muted)', flexShrink: 0 }}>{g.vendor}</span>
                <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap' }}>
                  {g.models.map((m) => (
                    <button key={m.id} onClick={() => setModel(m.id)}
                      title={m.label}
                      style={{
                        padding: '2px 8px', borderRadius: 3, border: '1px solid var(--text-muted)', fontSize: 11, cursor: 'pointer',
                        backgroundColor: model === m.id ? 'var(--accent-blue)' : 'transparent',
                        color: model === m.id ? '#fff' : 'var(--text-muted)',
                      }}>{m.id}</button>
                  ))}
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* API Key */}
        <div style={fieldStyle}>
          <label style={lab}>API Key {!isAdmin && <span style={{ color: '#e74c3c' }}>*</span>}</label>
          <input type="password" value={apiKey} onChange={(e) => setApiKey(e.target.value)} style={inp} placeholder={isAdmin ? '留空走全局 .env 的 Key' : '必填：否则无法使用 AI 功能'} aria-label="API Key" />
        </div>

        {/* API Base */}
        <div style={fieldStyle}>
          <label style={lab}>API 地址</label>
          <input value={apiBase} onChange={(e) => setApiBase(e.target.value)} style={inp} placeholder="留空走全局 LiteLLM 网关" aria-label="API 地址" />
        </div>

        {/* Actions */}
        <div style={{ display: 'flex', gap: 8, marginTop: 16 }}>
          <button onClick={saveConfig} disabled={saving}
            style={{
              padding: '6px 20px', borderRadius: 6, border: 'none', cursor: 'pointer', fontSize: 13,
              backgroundColor: 'var(--accent-blue)', color: '#fff', opacity: saving ? 0.6 : 1,
            }}>{saving ? '保存中...' : '保存配置'}</button>
          <button onClick={testConnection} disabled={testing || !apiKey.trim()}
            style={{
              padding: '6px 20px', borderRadius: 6, border: '1px solid var(--text-muted)', cursor: 'pointer', fontSize: 13,
              backgroundColor: testing ? 'var(--surface-heavy)' : 'transparent', color: testing ? 'var(--text-muted)' : 'var(--text-primary)',
              opacity: apiKey.trim() ? 1 : 0.4,
              display: 'flex', alignItems: 'center', gap: 6,
            }}>
            {testing ? <Loader2 size={14} style={{ animation: 'spin 1s linear infinite' }} /> : null}
            {testing ? '测试中...' : '连通性测试'}
          </button>
        </div>

        {/* Test result */}
        {testResult && (
          <div style={{
            marginTop: 12, padding: '8px 12px', borderRadius: 6,
            display: 'flex', alignItems: 'center', gap: 8, fontSize: 13,
            backgroundColor: testResult.success ? 'var(--tint-green-bg)' : 'var(--tint-red-bg)',
            border: `1px solid ${testResult.success ? 'var(--tint-green-border)' : 'var(--tint-red-border)'}`,
            color: testResult.success ? 'var(--success-text)' : 'var(--error-text)',
          }}>
            {testResult.success ? <CheckCircle size={16} /> : <XCircle size={16} />}
            {testResult.message}
          </div>
        )}
      </div>
    </div>
  );
};

// 审计 P2-12 核验：遮罩统一复用 wsCommon.overlayStyle（rgba 0.45 + padding:12，窄屏卡片不贴边；zIndex 4000 与全站弹窗层一致），删除本地重复定义
const modalStyle: React.CSSProperties = {
  backgroundColor: 'var(--surface-1)', color: 'var(--text-primary)',
  borderRadius: 10, padding: 20, width: 'min(560px,94vw)', maxWidth: 'calc(100vw - 32px)', maxHeight: 'calc(100vh - 64px)', overflow: 'auto',
  boxShadow: '0 8px 32px rgba(0,0,0,0.24)',
};
const fieldStyle: React.CSSProperties = { marginBottom: 14 };
const lab: React.CSSProperties = { display: 'block', color: 'var(--text-secondary)', marginBottom: 4, fontSize: 12, fontWeight: 500 };
const inp: React.CSSProperties = { width: '100%', padding: '7px 10px', borderRadius: 6, border: '1px solid var(--text-muted)', backgroundColor: 'var(--surface-heavy)', color: 'var(--text-on-accent)', fontSize: 13, outline: 'none', boxSizing: 'border-box' };
