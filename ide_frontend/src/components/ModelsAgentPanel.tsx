import React from 'react';
import { useStore } from '../stores/useStore';
import { useToast } from './Toast';
import { api } from '../services/api';
import { DraftAgentPanel } from './DraftAgentPanel';
import { AlertTriangle } from 'lucide-react';

/** AI源生：对话式「生成模型代码」（/api/admin/models/generate），结果放入编辑器草稿。
 * 对话本身即生成，不再单独设「生成模型」按钮；头部只保留「深度分析」开关。 */
export const ModelsAgentPanel: React.FC<{ onClose?: () => void }> = ({ onClose }) => {
  const { setModelDraft, setSelectedModel, bumpModelFiles } = useStore();
  const modelDraft = useStore((s) => s.modelDraft);
  const agentMode = useStore((s) => s.agentMode);
  const { success } = useToast();

  const applyDraft = (draft: any) => {
    if (!draft) return;
    setModelDraft({
      code: draft.code || '',
      problems: draft.problems || [],
      sources: draft.sources || [],
      transformed_sqls: draft.transformed_sqls || {},
    });
    setSelectedModel(null); // 草稿未落盘态
    bumpModelFiles();
    success('代码草稿已放入编辑器，补全名称/参数后点「保存」入库');
  };

  /** 深度分析（与 SQL 管理同源 agent 循环）：仅当结论含 Python 代码块时才可应用（提取代码放入编辑器草稿） */
  const extractCode = (answer: string): string[] => {
    const blocks: string[] = [];
    const re = /```(?:python)?\s*\n?([\s\S]*?)```/g;
    let m: RegExpExecArray | null;
    while ((m = re.exec(answer)) !== null) {
      const b = m[1].trim();
      if (b) blocks.push(b);
    }
    return blocks;
  };
  const deepApplicable = (answer: string) => extractCode(answer).length > 0;
  const deepApply = (answer: string) => {
    const blocks = extractCode(answer);
    if (!blocks.length) return;
    const st = useStore.getState();
    const cur = (st.modelDraft?.code || '').trim();
    // 去重（与 Skill/Knowledge 面板 dedupAppend 同语义）：重复点击「提取代码到编辑器」/
    // 自动应用后再点击，不会把同一段代码重复追加进编辑器
    const fresh = blocks.filter((b) => !cur.includes(b));
    if (!fresh.length) return;
    setModelDraft({ code: cur ? cur + '\n\n' + fresh.join('\n\n') : fresh.join('\n\n') });
    setSelectedModel(null); // 代码已变，视为草稿未落盘态
    bumpModelFiles();
    success(`已提取 ${fresh.length} 段 Python 代码放入编辑器`);
  };

  return (
    <DraftAgentPanel
      sessionKey="sql-ide-model-agent-msgs"
      emptyHint={(mode) => (
        mode === 'deep'
          ? <span style={{ lineHeight: 1.8 }}>切到「深度分析」后，输入算法模型/分析问题，AI 多轮取数分析输出结论；结论含 Python 代码块时可应用到编辑器。</span>
          : <span style={{ lineHeight: 1.8 }}>输入算法模型需求描述，AI 生成可执行的 Python 预测/算法代码（只读、纯计算，固定签名 def run(df_hist, pred_end, **params)）。</span>
      )}
      placeholder={(model, mode) => mode === 'deep'
        ? `输入算法模型/分析问题（${agentMode === 'auto' ? '⚡自动模式' : '🔒确认模式'}，${model || '默认模型'}）...（Enter 发送，Shift+Enter 换行）`
        : `描述要生成的算法模型（${model || '默认模型'}）...（Enter 发送，Shift+Enter 换行）`}
      loadingText={(mode) => (mode === 'deep' ? 'AI 深度分析中...' : 'AI 生成模型代码中...')}
      send={async (text, model) => {
        // 已关联 SQL 时带上其名（AI 依据其头部注释列生成输入列），已有代码作为合并基线
        const boundSqls = modelDraft?.sql ? [modelDraft.sql] : [];
        const existing = modelDraft?.code || '';
        const r = await api.generateModel(text, model ?? undefined, boundSqls, existing);
        return {
          content: '已生成模型代码草稿',
          draft: {
            code: r.code || '',
            problems: r.problems || [],
            sources: r.sources || [],
            transformed_sqls: r.transformed_sqls || {},
          },
        };
      }}
      draftPreview={(draft) => (
        <>
          {draft.problems?.length ? (
            <div style={{ display: 'flex', alignItems: 'center', gap: 4, marginBottom: 4, fontSize: 11, color: '#f90' }}>
              <AlertTriangle size={11} /> {draft.problems.length} 项安全预检问题（保存前需修复）
            </div>
          ) : null}
          {draft.code && (
            <pre style={{ margin: 0, lineHeight: 1.5, maxHeight: 180, overflowY: 'auto', fontSize: 11, color: 'var(--text-secondary)', whiteSpace: 'pre-wrap', wordBreak: 'break-word' }}>
              {draft.code}
            </pre>
          )}
        </>
      )}
      applyDraft={applyDraft}
      deepSend={(text, model, history, signal) => api.deepAgentChatStream(text, history, model ?? undefined, signal)}
      deepApplicable={deepApplicable}
      deepApply={deepApply}
      deepApplyLabel="提取代码到编辑器"
      onClose={onClose}
    />
  );
};

export default ModelsAgentPanel;
