import React from 'react';
import Editor from '@monaco-editor/react';
import { useStore } from '../stores/useStore';
import { useTheme } from './ThemeProvider';

/** 算法模型代码编辑器：Monaco python（无 SQL 补全、无 Ctrl+Enter，与 SQLEditor 区分）。
 * 审计 P2-12：外层容器补 role=region + aria-label（Monaco 内部无需改）。 */
export const ModelsEditor: React.FC<{ readOnly?: boolean }> = ({ readOnly: readOnlyProp }) => {
  const { theme } = useTheme();
  const code = useStore((s) => s.modelDraft?.code || '');
  const builtin = useStore((s) => s.modelDraft?.builtin || false);
  const setModelDraft = useStore((s) => s.setModelDraft);
  const myPermissions = useStore((s) => s.myPermissions);
  const canEdit = myPermissions === null || myPermissions.includes('analysis_edit');
  // 审计 P2-12 核验：锁定态（工作台传入 readOnly=true）下 Monaco 必须只读，否则「编辑」解锁前就能改代码且保存钮禁用，改动会静默丢失
  const readOnly = readOnlyProp ?? (builtin || !canEdit);

  return (
    <div role="region" aria-label="模型代码编辑器（Python）" style={{ width: '100%', height: '100%', position: 'relative' }}>
      <Editor
        height="100%"
        width="100%"
        defaultLanguage="python"
        theme={theme === 'dark' ? 'vs-dark' : 'vs'}
        value={code}
        onChange={(v) => setModelDraft({ code: v ?? '' })}
        options={{
          fontSize: 13,
          fontFamily: "'Microsoft YaHei', '微软雅黑', Consolas, monospace",
          minimap: { enabled: false },
          scrollBeyondLastLine: false,
          lineNumbers: 'on',
          renderLineHighlight: 'line',
          automaticLayout: true,
          tabSize: 4,
          wordWrap: 'off',
          readOnly,
          padding: { top: 12, bottom: 12 },
        }}
      />
    </div>
  );
};

export default ModelsEditor;
