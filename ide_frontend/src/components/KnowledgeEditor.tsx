import React from 'react';
import { useStore } from '../stores/useStore';
import { MarkdownEditor } from './MarkdownEditor';

/** 知识库文档编辑器：Monaco markdown（无 SQL 补全，与 SkillEditor 区分）。 */
export const KnowledgeEditor: React.FC = () => {
  const content = useStore((s) => s.kbDraft?.content || '');
  const setKbDraft = useStore((s) => s.setKbDraft);
  const myPermissions = useStore((s) => s.myPermissions);
  const canEdit = myPermissions === null || myPermissions.includes('analysis_edit');

  return <MarkdownEditor value={content} onChange={(v) => setKbDraft({ content: v })} readOnly={!canEdit} ariaLabel="知识库文档编辑器（Markdown）" />;
};

export default KnowledgeEditor;
