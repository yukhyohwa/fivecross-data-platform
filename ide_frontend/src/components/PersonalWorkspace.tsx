import React, { useCallback, useEffect, useState } from 'react';
import { useStore } from '../stores/useStore';
import { api } from '../services/api';
import { useToast } from './Toast';
import { SqlWorkspace } from './SqlWorkspace';
import { SkillWorkspace } from './SkillWorkspace';
import { KnowledgeWorkspace } from './KnowledgeWorkspace';
import { MemoryPage } from './Memory/MemoryPage';
import { Bell, Trash2, RefreshCw, FileCode, Target, BookOpen } from 'lucide-react';
import { overlayStyle, dialogStyle, saveCancelBtn, dangerBtn } from './wsCommon';
import { useDialog } from '../lib/useDialog';

interface Sub {
  id: string;
  name: string;
  skill: string | null;
  sqls: string[];
  docs: string[];
  created_at: string;
  source: string;
  game: string | null;
}

const TABS: { key: string; label: string }[] = [
  { key: 'reports', label: '订阅报告' },
  { key: 'sql', label: '个人SQL' },
  { key: 'skill', label: '个人专项' },
  { key: 'kb', label: '个人知识库（习惯记忆）' },
  { key: 'memory', label: '个人记忆' },
  { key: 'history', label: '聊天记录' },
];

// P1-14：scopeLevel 是全局 store 状态（列表过滤 + 新建/保存落个人都读它），不能做实例本地状态；
// 多实例并存时用模块级引用计数，只有最后一个卸载的实例才把「个人」上下文清 null，互不踩踏。
let personalScopeRefs = 0;

/** 个人定制页（替换原「聊天记录」导航项）：订阅报告（可取消订阅）+ 个人SQL/专项/知识库（复用工作台，强制个人层级）+ 个人记忆（记忆增强 2026-10-21：唯一入口）+ 聊天记录（iframe 复用 /app/chat-history.html）。
 *  六个 tab 内容常驻（display:none 不卸载），编辑器草稿/窗口在切换间不丢，与 iframe 保活同思路。 */
export const PersonalWorkspace: React.FC = () => {
  const setScopeLevel = useStore((s) => s.setScopeLevel);
  const [tab, setTab] = useState('reports');

  // 个人定制上下文：挂载期间强制「个人」层级（列表过滤 + 新建/保存落个人）
  useEffect(() => {
    personalScopeRefs += 1;
    setScopeLevel('个人');
    return () => {
      personalScopeRefs = Math.max(0, personalScopeRefs - 1);
      if (personalScopeRefs === 0) setScopeLevel(null);
    };
  }, [setScopeLevel]);

  return (
    <div className="h-full flex flex-col" style={{ minHeight: 0 }}>
      <div style={{ display: 'flex', gap: 0, padding: '0 12px', borderBottom: '1px solid var(--border-light)', backgroundColor: 'var(--surface-1)', flexShrink: 0, overflowX: 'auto' }}>
        {TABS.map((t) => (
          <button key={t.key} onClick={() => setTab(t.key)}
            role="tab" aria-selected={tab === t.key}
            style={{
              padding: '8px 16px', border: 'none', borderBottom: tab === t.key ? '2px solid var(--accent-blue)' : '2px solid transparent',
              backgroundColor: 'transparent', color: tab === t.key ? 'var(--accent-blue)' : 'var(--text-secondary)',
              cursor: 'pointer', fontSize: 13, fontWeight: tab === t.key ? 600 : 400, whiteSpace: 'nowrap', flexShrink: 0,
            }}>
            {t.label}
          </button>
        ))}
      </div>

      <div style={{ flex: 1, minHeight: 0, position: 'relative' }}>
        <div style={{ position: 'absolute', inset: 0, display: tab === 'reports' ? 'flex' : 'none', flexDirection: 'column' }}>
          <SubscriptionsTab />
        </div>
        <div style={{ position: 'absolute', inset: 0, display: tab === 'sql' ? 'flex' : 'none', flexDirection: 'column' }}>
          <SqlWorkspace />
        </div>
        <div style={{ position: 'absolute', inset: 0, display: tab === 'skill' ? 'flex' : 'none', flexDirection: 'column' }}>
          <SkillWorkspace />
        </div>
        <div style={{ position: 'absolute', inset: 0, display: tab === 'kb' ? 'flex' : 'none', flexDirection: 'column' }}>
          <KnowledgeWorkspace />
        </div>
        <div style={{ position: 'absolute', inset: 0, display: tab === 'memory' ? 'flex' : 'none', flexDirection: 'column' }}>
          {/* 个人记忆（记忆增强 2026-10-21：AI配置入口已移除，此为唯一入口）。
              对抗验证 2026-10-21：六 tab 常驻（display:none）不重挂载，内部 tab 状态不变——
              传 active 让 MemoryPage 在外层切回时重新加载（同会话 agent 沉淀的新记忆可见） */}
          <MemoryPage active={tab === 'memory'} />
        </div>
        <div style={{ position: 'absolute', inset: 0, display: tab === 'history' ? 'flex' : 'none', flexDirection: 'column' }}>
          {/* 聊天记录（P0-11）：复用 vanilla 页 /app/chat-history.html，iframe 内嵌 */}
          <iframe src="/app/chat-history.html" title="聊天记录"
            style={{ width: '100%', height: '100%', border: 'none', backgroundColor: 'var(--surface-1)' }} />
        </div>
      </div>
    </div>
  );
};

/** 订阅报告：个人订阅列表 + 取消订阅（删除）。订阅在聊天窗口/订阅报告页创建，这里只管查看与取消。 */
const SubscriptionsTab: React.FC = () => {
  const { success, error: toastError } = useToast();
  const [subs, setSubs] = useState<Sub[]>([]);
  const [loading, setLoading] = useState(false);
  const [deleteTarget, setDeleteTarget] = useState<Sub | null>(null);

  // 审计 P2-12：删除确认弹窗接入 useDialog（Escape 关闭 + 打开聚焦 + 关闭还原焦点）
  const deleteDialogRef = useDialog(deleteTarget !== null, () => setDeleteTarget(null));

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const r = await api.listSubscriptions();
      setSubs(r.subscriptions || []);
    } catch (e: any) {
      toastError(e.message || '加载订阅失败');
    } finally {
      setLoading(false);
    }
  }, [toastError]);

  useEffect(() => { load(); }, [load]);

  const confirmDelete = async () => {
    if (!deleteTarget) return;
    const t = deleteTarget;
    setDeleteTarget(null);
    try {
      await api.deleteSubscription(t.id);
      success(`已取消订阅「${t.name}」`);
      await load();
    } catch (e: any) {
      toastError(e.message || '取消订阅失败');
    }
  };

  return (
    <div style={{ flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '10px 14px', borderBottom: '1px solid var(--border-light)' }}>
        <h3 style={{ margin: 0, fontSize: 14, color: 'var(--text-primary)', display: 'flex', alignItems: 'center', gap: 6 }}><Bell size={14} /> 我的订阅报告</h3>
        <button onClick={load} style={iconBtn} title="刷新" aria-label="刷新"><RefreshCw size={14} /></button>
      </div>

      <div style={{ flex: 1, overflowY: 'auto', padding: 12 }}>
        {loading ? (
          <p style={{ textAlign: 'center', color: 'var(--text-inactive)', fontSize: 12, marginTop: 20 }}>加载中...</p>
        ) : subs.length === 0 ? (
          <p style={{ textAlign: 'center', color: 'var(--text-inactive)', fontSize: 12, marginTop: 20, lineHeight: 1.8 }}>
            暂无订阅报告。
            <br />可在「聊天窗口」运行专项后保存为订阅报告。
          </p>
        ) : (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
            {subs.map((s) => (
              <div key={s.id} style={{ padding: '10px 12px', borderRadius: 6, border: '1px solid var(--border-light)', backgroundColor: 'var(--surface-1)' }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--text-primary)', flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{s.name}</span>
                  <button onClick={() => setDeleteTarget(s)} title="取消订阅（删除）" aria-label="取消订阅（删除）"
                    style={{ ...iconBtn, color: '#e74c3c' }}>
                    <Trash2 size={14} />
                  </button>
                </div>
                <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', marginTop: 6, fontSize: 11, color: 'var(--text-secondary)' }}>
                  {s.skill && (
                    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 3 }}><Target size={11} style={{ color: 'var(--accent-amber)' }} />{s.skill}</span>
                  )}
                  {s.sqls?.length > 0 && (
                    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 3 }}><FileCode size={11} style={{ color: 'var(--accent-blue)' }} />{s.sqls.length} SQL</span>
                  )}
                  {s.docs?.length > 0 && (
                    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 3 }}><BookOpen size={11} style={{ color: '#5a8' }} />{s.docs.length} 文档</span>
                  )}
                  {s.created_at && <span>{s.created_at}</span>}
                </div>
              </div>
            ))}
          </div>
        )}
      </div>

      {deleteTarget && (
        <div onClick={() => setDeleteTarget(null)} style={overlayStyle}>
          {/* 审计 P2-12：role/aria-modal/tabIndex 弹窗语义 */}
          <div ref={deleteDialogRef} tabIndex={-1} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={dialogStyle}>
            <p style={{ margin: 0, fontSize: 13, color: 'var(--text-primary)' }}>确认取消订阅「{deleteTarget.name}」？</p>
            <p style={{ margin: '6px 0 0', fontSize: 11, color: 'var(--text-muted)' }}>取消后该订阅将被删除，不可恢复。</p>
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end', marginTop: 14 }}>
              <button onClick={() => setDeleteTarget(null)} style={saveCancelBtn}>取消</button>
              <button onClick={confirmDelete} style={dangerBtn}>取消订阅</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};

const iconBtn: React.CSSProperties = { background: 'none', border: 'none', color: 'var(--text-muted)', cursor: 'pointer', padding: 4, display: 'flex', alignItems: 'center', borderRadius: 4 };

export default PersonalWorkspace;
