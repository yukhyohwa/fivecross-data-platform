import React, { useRef, useEffect, useState, useCallback } from 'react';
import type { OnMount } from '@monaco-editor/react';
import Editor from '@monaco-editor/react';
import { useStore } from '../stores/useStore';
import { useTheme } from './ThemeProvider';

interface Suggestion {
  label: string;
  detail?: string;
  insertText: string;
  kind?: number;
  sortText?: string;
}

/* ---------- static SQL completions ---------- */

const SQL_FUNCTIONS: Suggestion[] = [
  // Aggregate
  { label: 'COUNT', detail: 'COUNT(expr)', insertText: 'COUNT(${1:expr})', kind: 2, sortText: '1' },
  { label: 'SUM', detail: 'SUM(expr)', insertText: 'SUM(${1:expr})', kind: 2, sortText: '1' },
  { label: 'AVG', detail: 'AVG(expr)', insertText: 'AVG(${1:expr})', kind: 2, sortText: '1' },
  { label: 'MIN', detail: 'MIN(expr)', insertText: 'MIN(${1:expr})', kind: 2, sortText: '1' },
  { label: 'MAX', detail: 'MAX(expr)', insertText: 'MAX(${1:expr})', kind: 2, sortText: '1' },
  { label: 'GROUP_CONCAT', detail: 'GROUP_CONCAT(expr)', insertText: 'GROUP_CONCAT(${1:expr})', kind: 2, sortText: '1' },
  // String
  { label: 'CONCAT', detail: 'CONCAT(str1, str2)', insertText: 'CONCAT(${1:str1}, ${2:str2})', kind: 2, sortText: '1' },
  { label: 'SUBSTRING', detail: 'SUBSTRING(str, pos)', insertText: 'SUBSTRING(${1:str}, ${2:pos})', kind: 2, sortText: '1' },
  { label: 'UPPER', detail: 'UPPER(str)', insertText: 'UPPER(${1:str})', kind: 2, sortText: '1' },
  { label: 'LOWER', detail: 'LOWER(str)', insertText: 'LOWER(${1:str})', kind: 2, sortText: '1' },
  { label: 'TRIM', detail: 'TRIM(str)', insertText: 'TRIM(${1:str})', kind: 2, sortText: '1' },
  { label: 'REPLACE', detail: 'REPLACE(str, from, to)', insertText: 'REPLACE(${1:str}, ${2:from}, ${3:to})', kind: 2, sortText: '1' },
  { label: 'LENGTH', detail: 'LENGTH(str)', insertText: 'LENGTH(${1:str})', kind: 2, sortText: '1' },
  { label: 'LOCATE', detail: 'LOCATE(substr, str)', insertText: 'LOCATE(${1:substr}, ${2:str})', kind: 2, sortText: '1' },
  // Date
  { label: 'NOW', detail: 'NOW()', insertText: 'NOW()', kind: 2, sortText: '1' },
  { label: 'CURDATE', detail: 'CURDATE()', insertText: 'CURDATE()', kind: 2, sortText: '1' },
  { label: 'DATE_FORMAT', detail: 'DATE_FORMAT(date, fmt)', insertText: 'DATE_FORMAT(${1:date}, ${2:fmt})', kind: 2, sortText: '1' },
  { label: 'DATE_ADD', detail: 'DATE_ADD(date, INTERVAL expr unit)', insertText: 'DATE_ADD(${1:date}, INTERVAL ${2:expr} ${3:unit})', kind: 2, sortText: '1' },
  { label: 'DATEDIFF', detail: 'DATEDIFF(d1, d2)', insertText: 'DATEDIFF(${1:d1}, ${2:d2})', kind: 2, sortText: '1' },
  { label: 'YEAR', detail: 'YEAR(date)', insertText: 'YEAR(${1:date})', kind: 2, sortText: '1' },
  { label: 'MONTH', detail: 'MONTH(date)', insertText: 'MONTH(${1:date})', kind: 2, sortText: '1' },
  { label: 'DAY', detail: 'DAY(date)', insertText: 'DAY(${1:date})', kind: 2, sortText: '1' },
  // Numeric
  { label: 'ROUND', detail: 'ROUND(num, decimals)', insertText: 'ROUND(${1:num}, ${2:decimals})', kind: 2, sortText: '1' },
  { label: 'FLOOR', detail: 'FLOOR(num)', insertText: 'FLOOR(${1:num})', kind: 2, sortText: '1' },
  { label: 'CEIL', detail: 'CEIL(num)', insertText: 'CEIL(${1:num})', kind: 2, sortText: '1' },
  { label: 'ABS', detail: 'ABS(num)', insertText: 'ABS(${1:num})', kind: 2, sortText: '1' },
  // Conditional
  { label: 'COALESCE', detail: 'COALESCE(v1, v2, ...)', insertText: 'COALESCE(${1:v1}, ${2:v2})', kind: 2, sortText: '1' },
  { label: 'IFNULL', detail: 'IFNULL(expr, alt)', insertText: 'IFNULL(${1:expr}, ${2:alt})', kind: 2, sortText: '1' },
  { label: 'NULLIF', detail: 'NULLIF(expr1, expr2)', insertText: 'NULLIF(${1:expr1}, ${2:expr2})', kind: 2, sortText: '1' },
  { label: 'CAST', detail: 'CAST(expr AS type)', insertText: 'CAST(${1:expr} AS ${2:type})', kind: 2, sortText: '1' },
  // JSON
  { label: 'JSON_EXTRACT', detail: 'JSON_EXTRACT(json, path)', insertText: 'JSON_EXTRACT(${1:json}, ${2:path})', kind: 2, sortText: '1' },
];

const SQL_KEYWORDS: Suggestion[] = `
SELECT FROM WHERE AND OR NOT IN EXISTS BETWEEN LIKE IS NULL
GROUP BY ORDER BY ASC DESC HAVING LIMIT OFFSET
JOIN LEFT JOIN RIGHT JOIN INNER JOIN OUTER JOIN ON
INSERT INTO VALUES UPDATE SET DELETE
CREATE TABLE ALTER DROP INDEX UNIQUE PRIMARY KEY
DISTINCT AS UNION ALL CASE WHEN THEN ELSE END
`.trim().split(/\s+/).map((kw) => ({
  label: kw,
  insertText: kw,
  kind: 14,
  sortText: '2',
}));

/* ---------- utility ---------- */

/** Extract table names/aliases referenced in FROM/JOIN clauses */
function extractTableRefs(sql: string): Set<string> {
  const refs = new Set<string>();
  // Match FROM|JOIN followed by optional db.table or table [alias]
  const re = /\b(FROM|JOIN)\s+`?(\w+)`?(?:\s+AS\s+)?\s*`?(\w+)`?/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(sql)) !== null) {
    refs.add(m[2].toLowerCase()); // table name
    if (m[3]) refs.add(m[3].toLowerCase()); // alias (if present)
  }
  return refs;
}

/* ---------- component ---------- */

/** Module-level reference for external use */
export let monacoEditorRef: any = null;
export function setMonacoCursor(line: number, column: number) {
  if (!monacoEditorRef) return;
  monacoEditorRef.setPosition({ lineNumber: line, column });
  monacoEditorRef.revealLineInCenter(line);
  monacoEditorRef.focus();
}

interface SchemaTable {
  name: string;
  alias: string;
  columns: { name: string; type: string; comment: string }[];
}

/** 从 store 的 schema 缓存（SchemaSidebar 拉取游戏库 schema）构建编辑器补全用的表/列清单。 */
function getSchema(): SchemaTable[] {
  const st = useStore.getState();
  const out: SchemaTable[] = [];
  const tables = st.schemaTables || {};
  const cols = st.schemaCols || {};
  for (const db of Object.keys(tables)) {
    for (const t of (tables[db] || []) as any[]) {
      const name = t?.name;
      if (!name) continue;
      const columns = (cols[`${db}.${name}`] || []).map((c: any) => ({
        name: c.name,
        type: c.type,
        comment: c.comment || '',
      }));
      out.push({ name, alias: name, columns });
    }
  }
  return out;
}

export const SQLEditor: React.FC = () => {
  const { sql, setSql } = useStore();
  const myPermissions = useStore((s) => s.myPermissions);
  const canEdit = myPermissions === null || myPermissions.includes('analysis_edit');
  const { theme } = useTheme();
  const containerRef = useRef<HTMLDivElement>(null);
  const [size, setSize] = useState({ width: 0, height: 0 });
  const providerRef = useRef<any>(null);

  // ResizeObserver
  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const ro = new ResizeObserver((entries) => {
      for (const entry of entries) {
        const { width, height } = entry.contentRect;
        if (width > 0 && height > 0) setSize({ width, height });
      }
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const handleEditorDidMount: OnMount = useCallback((editor, monaco) => {
    if (!monaco) return;

    monacoEditorRef = editor;

    // Ctrl+Enter execute
    editor.addCommand(
      monaco.KeyMod.CtrlCmd | monaco.KeyCode.Enter,
      () => { useStore.getState().executeSql(); }
    );

    // Track selection for partial execution
    editor.onDidChangeCursorSelection((e) => {
      const model = editor.getModel();
      if (!model) return;
      const text = model.getValueInRange(e.selection);
      const hasSelection =
        e.selection.endLineNumber !== e.selection.startLineNumber ||
        e.selection.endColumn !== e.selection.startColumn;
      useStore.getState().setSelectedSql(hasSelection ? text : null);
    });

    // Register completion provider
    const provider = monaco.languages.registerCompletionItemProvider('sql', {
      triggerCharacters: ['.', ' ', '(', ','],

      provideCompletionItems: (model: any, position: any) => {
        const word = model.getWordUntilPosition(position);
        const range = {
          startLineNumber: position.lineNumber,
          endLineNumber: position.lineNumber,
          startColumn: Math.max(1, word.startColumn),
          endColumn: word.endColumn,
        };

        const textBefore = model.getValueInRange({
          startLineNumber: position.lineNumber,
          startColumn: 1,
          endLineNumber: position.lineNumber,
          endColumn: position.column,
        });

        const schema = getSchema();
        const suggestions: any[] = [];

        // Extract table references from entire SQL for context-aware column suggestions
        const fullText = model.getValue();
        const tableRefs = extractTableRefs(fullText);

        // --- dot completion: alias_or_table . column ---
        const dotMatch = textBefore.match(/(\w+)\.\s*$/);
        if (dotMatch) {
          const prefix = dotMatch[1].toLowerCase();
          // Find table by name or alias
          for (const table of schema) {
            if (table.name.toLowerCase() === prefix || table.alias.toLowerCase() === prefix) {
              for (const col of table.columns) {
                suggestions.push({
                  label: col.name,
                  detail: `${table.name}.${col.name}  (${col.type})`,
                  insertText: col.name,
                  kind: 4,
                  range,
                  sortText: '1',
                });
              }
              break;
            }
          }
          return { suggestions: suggestions as any };
        }

        // --- after FROM / JOIN / INTO / UPDATE → suggest tables with alias snippet ---
        const ctxMatch = textBefore.match(
          /\b(FROM|JOIN|INNER\s+JOIN|LEFT\s+JOIN|RIGHT\s+JOIN|INTO|UPDATE|TABLE)\s+$/i
        );
        if (ctxMatch) {
          for (const table of schema) {
            suggestions.push({
              label: table.name,
              detail: `${table.name}  (${table.alias})`,
              insertText: `${table.name} ${table.alias}`,
              kind: 1,
              range,
              sortText: '1',
            });
          }
          return { suggestions };
        }

        // --- after ON → suggest columns from joined tables ---
        const onMatch = textBefore.match(/\bON\s+$/i);
        if (onMatch) {
          const refTables = schema.filter((t: any) =>
            tableRefs.has(t.name.toLowerCase()) || tableRefs.has(t.alias.toLowerCase())
          );
          const pool = refTables.length > 0 ? refTables : schema;
          for (const table of pool) {
            for (const col of table.columns) {
              suggestions.push({
                label: `${table.alias}.${col.name}`,
                detail: `${table.name}.${col.name}  (${col.type})`,
                insertText: `${table.alias}.${col.name}`,
                kind: 4,
                range,
                sortText: '2',
              });
            }
          }
          return { suggestions };
        }

        // --- after WHERE / AND / OR / SET / comma → suggest columns from referenced tables ---
        const colCtx = textBefore.match(
          /\b(WHERE|AND|OR|SET|ON|VALUES)\s+$/i
        );
        if (colCtx) {
          const refTables = schema.filter((t: any) =>
            tableRefs.has(t.name.toLowerCase()) || tableRefs.has(t.alias.toLowerCase())
          );
          const pool = refTables.length > 0 ? refTables : schema; // fallback to all if no refs found
          for (const table of pool) {
            for (const col of table.columns) {
              suggestions.push({
                label: col.name,
                detail: `${table.name}.${col.name}  (${col.type})`,
                insertText: col.name,
                kind: 4,
                range,
                sortText: '1',
              });
            }
          }
          return { suggestions };
        }

        // --- default: functions + keywords + table names ---
        for (const fn of SQL_FUNCTIONS) {
          suggestions.push({ ...fn, range });
        }
        for (const kw of SQL_KEYWORDS) {
          suggestions.push({ ...kw, range });
        }
        for (const table of schema) {
          suggestions.push({
            label: table.name,
            detail: `${table.name}  (alias: ${table.alias})`,
            insertText: table.name,
            kind: 1,
            range,
            sortText: '3',
          });
          // Also suggest alias
          suggestions.push({
            label: table.alias,
            detail: `alias for ${table.name}`,
            insertText: table.alias,
            kind: 13,
            range,
            sortText: '4',
          });
        }

        return { suggestions };
      },
    });

    providerRef.current = provider;
  }, []);

  // Cleanup provider on unmount
  useEffect(() => {
    return () => {
      providerRef.current?.dispose();
    };
  }, []);

  return (
    <div ref={containerRef} style={{ width: '100%', height: '100%', position: 'relative' }}>
      {size.width > 0 && size.height > 0 && (
        <Editor
          height={size.height}
          width={size.width}
          defaultLanguage="sql"
          theme={theme === 'dark' ? 'vs-dark' : 'vs'}
          value={sql}
          onChange={(value) => setSql(value ?? '')}
          onMount={handleEditorDidMount}
          options={{
            fontSize: 14,
            fontFamily: "Consolas, 'Courier New', monospace",
            minimap: { enabled: false },
            scrollBeyondLastLine: false,
            lineNumbers: 'on',
            renderLineHighlight: 'line',
            automaticLayout: true,
            tabSize: 2,
            wordWrap: 'off',
            scrollbar: {
              horizontal: 'visible',
              horizontalScrollbarSize: 8,
            },
            padding: { top: 12, bottom: 12 },
            readOnly: !canEdit,
            suggestOnTriggerCharacters: true,
            quickSuggestions: { other: true, comments: false, strings: false },
          }}
        />
      )}
    </div>
  );
};
