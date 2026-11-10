import React from 'react';
import { useStore } from '../stores/useStore';
import { useToast } from './Toast';
import { api } from '../services/api';
import { marked } from 'marked';
import { sanitizeHtml } from '../lib/sanitizeHtml';
import { DraftAgentPanel } from './DraftAgentPanel';

/** AI源生：对话式「生成知识草稿」（/api/admin/knowledge/summarize），结果放入编辑器草稿。
 * 对话本身即生成，不再单独设「生成知识」按钮；头部只保留「深度分析」开关。
 * 上传文档汇总已移到知识库工作台右上角「上传文档汇总」按钮（弹窗形式）。 */
export const KnowledgeAgentPanel: React.FC<{ onClose?: () => void }> = ({ onClose }) => {
  const { setKbDraft, setSelectedKb, bumpKbFiles } = useStore();
  const kbDraft = useStore((s) => s.kbDraft);
  const scopeLevel = useStore((s) => s.scopeLevel);
  const agentMode = useStore((s) => s.agentMode);
  const { success } = useToast();

  const applyDraft = (draft: any) => {
    if (!draft) return;
    // 无活动窗口时先新建一个，再回填草稿（草稿随活动窗口保存）
    const st = useStore.getState();
    if (!st.activeKbWindowId) {
      st.newKbWindow({ name: '', level: scopeLevel ?? '通用', content: '' });
    }
    setKbDraft({ name: draft.title || '', level: scopeLevel ?? '通用', content: draft.content || '' });
    setSelectedKb(null); // 草稿未落盘态
    bumpKbFiles();
    success('草稿已放入编辑器，改后点「保存」入库');
  };

  /** 深度分析（与 SQL 管理同源 agent 循环）：结论追加到文档（自动模式生成完直接追加） */
  const deepApply = (answer: string) => {
    const st = useStore.getState();
    if (!st.activeKbWindowId) {
      st.newKbWindow({ name: '', level: scopeLevel ?? '通用', content: '' });
    }
    const cur = (useStore.getState().kbDraft?.content || '').trim();
    const clean = answer.trim();
    const next = cur ? (cur.includes(clean) ? cur : cur + '\n\n' + clean) : clean;
    setKbDraft({ content: next });
    success('深度分析结论已追加到文档');
  };

  return (
    <DraftAgentPanel
      sessionKey="sql-ide-kb-agent-msgs"
      emptyHint={(mode) => (mode === 'deep'
        ? '切到「深度分析」后，输入分析问题，AI 多轮取数/检索并输出结论（自动模式直接追加到文档）。'
        : '输入知识描述，AI 汇总生成知识文档草稿；上传文件批量汇总请点右上角「上传文档汇总」按钮。')}
      placeholder={(model, mode) => mode === 'deep'
        ? `输入分析问题（${agentMode === 'auto' ? '⚡自动模式' : '🔒确认模式'}，${model || '默认模型'}）...（Enter 发送，Shift+Enter 换行）`
        : `描述要沉淀的知识（${model || '默认模型'}）...（Enter 发送，Shift+Enter 换行）`}
      loadingText={(mode) => (mode === 'deep' ? 'AI 深度分析中...' : 'AI 生成知识草稿中...')}
      send={async (text, _model, activeModel) => {
        // 若正在编辑已有文档，带上现有内容作为合并基线
        const existing = kbDraft?.content || '';
        const r = await api.summarizeKnowledge(activeModel, [{ name: '需求描述', content: text }], '', existing);
        return {
          content: r.title ? `已生成知识草稿「${r.title}」` : '已生成知识草稿',
          draft: { title: r.title || '', content: r.draft || '' },
        };
      }}
      draftPreview={(draft) => (draft.content ? (
        <div className="agent-reply" style={{ lineHeight: 1.7, maxHeight: 180, overflowY: 'auto', fontSize: 11, color: 'var(--text-secondary)' }}
          dangerouslySetInnerHTML={{ __html: sanitizeHtml(marked.parse(draft.content) as string) }} />
      ) : null)}
      applyDraft={applyDraft}
      deepSend={(text, model, history, signal) => api.deepAgentChatStream(text, history, model ?? undefined, signal)}
      deepApplicable={(answer) => answer.trim().length > 0}
      deepApply={deepApply}
      deepApplyLabel="追加到文档"
      onClose={onClose}
    />
  );
};

export default KnowledgeAgentPanel;
