import React from 'react';
import { useStore } from '../stores/useStore';
import { useToast } from './Toast';
import { api } from '../services/api';
import { marked } from 'marked';
import { sanitizeHtml } from '../lib/sanitizeHtml';
import { DraftAgentPanel } from './DraftAgentPanel';

/** 追加笔记去重：若目标内容已含完全相同文本则跳过，否则以空行分隔追加。 */
function dedupAppend(cur: string, addition: string): string {
  const clean = addition.trim();
  if (!clean) return (cur || '').trim();
  const curTrim = (cur || '').trim();
  if (!curTrim) return clean;
  if (curTrim.includes(clean)) return curTrim;
  return curTrim + '\n\n' + clean;
}

/** AI源生：对话式生成/调整专项 + 深度分析。
 * 生成 = 对话本身（单次 LLM 请求，AI 出方法说明草稿 → 「应用到编辑器」），不再单独设「生成专项」按钮；
 * 专项笔记 = 生成/调整专项时由 LLM 顺带提炼口径/经验/已知数据坑，后端自动追加到笔记槽
 * （右下「内嵌快照」区的「专项笔记」组查看/编辑，报告生成时随方法说明注入），不再单独设「专项笔记」按钮；
 * 深度分析 = 与 SQL 管理同源的 agent 流（头部开关），结论按自动/确认模式追加到方法说明。 */
export const SkillAgentPanel: React.FC<{ onClose?: () => void }> = ({ onClose }) => {
  const { setSkillDraft, setSelectedSkill, bumpSkillFiles } = useStore();
  const skillDraft = useStore((s) => s.skillDraft);
  const scopeLevel = useStore((s) => s.scopeLevel);
  const agentMode = useStore((s) => s.agentMode);
  const { success } = useToast();

  // 笔记沉淀目标 = 当前编辑器草稿的专项名：调整既有专项（已选中/已保存）时非空；
  // 新建/未落盘草稿名空 → 不沉淀。不用 selectedSkill 兜底：选中专项 A 却对话生成全新专项 B 时，
  // 会把为 B 提炼的口径错配进 A 的笔记槽（B 名字未知，草稿未应用时 name 为空）。
  const noteTargetName = (skillDraft?.name || '').trim();

  const applyDraft = (draft: any) => {
    if (!draft) return;
    // 无活动窗口时先新建一个，再回填草稿（草稿随活动窗口保存）
    const st = useStore.getState();
    if (!st.activeSkillWindowId) {
      st.newSkillWindow({ name: '', level: scopeLevel ?? '通用', content: '', sqls: [], docs: [], forecast: null });
    }
    setSkillDraft({
      name: draft.title || '',
      content: draft.content || '',
      sqls: draft.sqls || [],
      docs: draft.docs || [],
      forecast: draft.forecast || null,
      level: scopeLevel ?? '通用',
    });
    setSelectedSkill(null); // 草稿未落盘态
    bumpSkillFiles();
    success('草稿已放入编辑器，改后点「保存」入库');
  };

  /** 深度分析（与 SQL 管理同源 agent 循环）：结论追加到方法说明（自动模式生成完直接追加） */
  const deepApply = (answer: string) => {
    const st = useStore.getState();
    if (!st.activeSkillWindowId) {
      st.newSkillWindow({ name: '', level: scopeLevel ?? '通用', content: '', sqls: [], docs: [], forecast: null });
    }
    const cur = (useStore.getState().skillDraft?.content || '').trim();
    const next = dedupAppend(cur, answer);
    setSkillDraft({ content: next });
    success('深度分析结论已追加到方法说明');
  };

  return (
    <DraftAgentPanel
      sessionKey="sql-ide-skill-agent-msgs"
      emptyHint={(mode) => (
        mode === 'deep'
          ? '切到「深度分析」后，输入分析问题，AI 多轮取数/检索并输出结论（自动模式直接追加到方法说明）。'
          : '输入专项描述，AI 生成方法说明并建议关联 SQL/文档；对话中提炼的口径/经验会自动记入「专项笔记」（右下内嵌快照区，随报告注入）。'
      )}
      placeholder={(model, mode) => mode === 'deep'
        ? `输入分析问题（${agentMode === 'auto' ? '⚡自动模式' : '🔒确认模式'}，${model || '默认模型'}）...（Enter 发送，Shift+Enter 换行）`
        : `描述专项 / 补充口径与经验（${model || '默认模型'}）...（Enter 发送，Shift+Enter 换行）`}
      loadingText={(mode) => (mode === 'deep' ? 'AI 深度分析中...' : 'AI 生成专项中...')}
      errorPrefix={() => '生成失败：'}
      send={async (text, model, _activeModel) => {
        const existing = skillDraft?.content || '';
        const noteTarget = noteTargetName; // 已选中/已保存的专项 → 生成时自动沉淀笔记到该专项
        const r = await api.generateSkill(text, model ?? undefined, existing, noteTarget || undefined);
        if (r.note) {
          bumpSkillFiles(); // 笔记已变，刷新右下「内嵌快照」区（专项笔记组）
          success('口径/经验已自动记入专项笔记');
        }
        return {
          content: r.note
            ? (r.title ? `已生成专项草稿「${r.title}」（口径/经验已自动记入专项笔记）` : '已生成专项草稿（口径/经验已自动记入专项笔记）')
            : (r.title ? `已生成专项草稿「${r.title}」` : '已生成专项草稿'),
          draft: { title: r.title || '', content: r.draft || '', sqls: r.sqls || [], docs: r.docs || [], forecast: r.forecast || null },
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
      deepApplyLabel="追加到方法说明"
      externalGap
      onClose={onClose}
    />
  );
};

export default SkillAgentPanel;
