import React from 'react';
import Editor from '@monaco-editor/react';
import { useTheme } from './ThemeProvider';

/** 通用 markdown Monaco 编辑器（专项方法说明 / 知识库文档共用，P1-12 收敛）：
 * 无 SQL 补全、无 Ctrl+Enter，与 SQLEditor 区分。
 * 审计 P2-12：外层容器补 role=region + aria-label（Monaco 内部无需改）。 */
export const MarkdownEditor: React.FC<{ value: string; onChange: (v: string) => void; readOnly?: boolean; ariaLabel?: string }> = ({ value, onChange, readOnly, ariaLabel = 'Markdown 编辑器' }) => {
  const { theme } = useTheme();

  return (
    <div role="region" aria-label={ariaLabel} style={{ width: '100%', height: '100%', position: 'relative' }}>
      <Editor
        height="100%"
        width="100%"
        defaultLanguage="markdown"
        theme={theme === 'dark' ? 'vs-dark' : 'vs'}
        value={value}
        onChange={(v) => onChange(v ?? '')}
        options={{
          fontSize: 14,
          fontFamily: "'Microsoft YaHei', '微软雅黑', sans-serif",
          minimap: { enabled: false },
          scrollBeyondLastLine: false,
          lineNumbers: 'on',
          renderLineHighlight: 'line',
          automaticLayout: true,
          tabSize: 2,
          wordWrap: 'on',
          readOnly: !!readOnly,
          padding: { top: 12, bottom: 12 },
        }}
      />
    </div>
  );
};

export default MarkdownEditor;
