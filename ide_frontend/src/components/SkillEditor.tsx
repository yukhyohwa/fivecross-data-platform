import React from 'react';
import { useStore } from '../stores/useStore';
import { MarkdownEditor } from './MarkdownEditor';

/** 专项方法说明编辑器：Monaco markdown（无 SQL 补全、无 Ctrl+Enter，与 SQLEditor 区分）。 */
export const SkillEditor: React.FC = () => {
  const content = useStore((s) => s.skillDraft?.content || '');
  const setSkillDraft = useStore((s) => s.setSkillDraft);
  const myPermissions = useStore((s) => s.myPermissions);
  const canEdit = myPermissions === null || myPermissions.includes('analysis_edit');

  return <MarkdownEditor value={content} onChange={(v) => setSkillDraft({ content: v })} readOnly={!canEdit} />;
};

export default SkillEditor;
