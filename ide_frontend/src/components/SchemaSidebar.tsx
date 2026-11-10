import React, { useState, useEffect, useCallback, useRef } from 'react';
import { useStore } from '../stores/useStore';
import { useToast } from './Toast';
import { api } from '../services/api';
import {
  Database, Table2, Columns3, ChevronRight, ChevronDown, RotateCw, Search, X,
} from 'lucide-react';

interface Col { name: string; type: string; comment: string; }
interface Tbl { name: string; }
interface SourceContract { engine: string; region: string; project_id: string; event_table: string; status: string; }

/** 模块级记忆：上次加载的 game key。游戏切换后强制重拉 schema（游戏库 schema 随 X-Game 变）。 */
let _loadedGame: string | null = null;
function currentGame(): string {
  try { return localStorage.getItem('chatbi.game') || ''; } catch { return ''; }
}

/** 数据库侧栏：游戏库 schema（/api/schema + /api/schema/{db}/{table}），不绑用户连接。 */
export const SchemaSidebar: React.FC<{ onClose?: () => void }> = ({ onClose }) => {
  const {
    setSql,
    schemaDbs, setSchemaDbs, schemaTables, setSchemaTables, schemaCols, setSchemaCols,
    schemaExpandedDbs, setSchemaExpandedDbs, schemaExpandedTbls, setSchemaExpandedTbls,
    schemaCurrentDb, setSchemaCurrentDb,
  } = useStore();
  const { error: toastError } = useToast();

  const [dbs, setDbs] = useState<string[]>([]);
  const [currentDb, setCurrentDb] = useState('');
  const [expandedDbs, setExpandedDbs] = useState<Set<string>>(new Set());
  const [tables, setTables] = useState<Record<string, Tbl[]>>({});
  const [loadingDbs, setLoadingDbs] = useState(false);
  const [loadingTbls, setLoadingTbls] = useState<Set<string>>(new Set());
  const [expandedTbls, setExpandedTbls] = useState<Set<string>>(new Set());
  const [cols, setCols] = useState<Record<string, Col[]>>({});
  const [sources, setSources] = useState<SourceContract[]>([]);
  const [loadingCols, setLoadingCols] = useState<Set<string>>(new Set());
  const [search, setSearch] = useState('');
  const scrollRef = useRef<HTMLDivElement>(null);

  const loadSchema = useCallback(async () => {
    setLoadingDbs(true);
    try {
      const r = await api.getGameSchema();
      const dbList: string[] = r.databases || [];
      setSources((r as any).sources || []);
      const def = r.default_db || dbList[0] || '';
      const tblList: Tbl[] = (r.tables || []).map((t: string) => ({ name: t }));
      setDbs(dbList);
      setSchemaDbs(dbList);
      const tblMap: Record<string, Tbl[]> = def ? { [def]: tblList } : {};
      setTables(tblMap);
      setSchemaTables(tblMap);
      setCurrentDb(def);
      setSchemaCurrentDb(def);
      setExpandedDbs(new Set(def ? [def] : []));
      setSchemaExpandedDbs(def ? [def] : []);
      setExpandedTbls(new Set());
      setSchemaExpandedTbls([]);
      _loadedGame = currentGame();
    } catch (e: any) {
      toastError(e.message || '加载 schema 失败');
    } finally {
      setLoadingDbs(false);
    }
  }, [setSchemaDbs, setSchemaTables, setSchemaCurrentDb, setSchemaExpandedDbs, setSchemaExpandedTbls, toastError]);

  useEffect(() => {
    const st = useStore.getState();
    if (st.schemaDbs.length > 0 && st.schemaCurrentDb && _loadedGame === currentGame()) {
      // 同 game 的缓存恢复
      setDbs(st.schemaDbs);
      setTables(st.schemaTables);
      setCols(st.schemaCols);
      setCurrentDb(st.schemaCurrentDb);
      setExpandedDbs(new Set(st.schemaExpandedDbs));
      setExpandedTbls(new Set(st.schemaExpandedTbls));
    } else {
      loadSchema();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const switchAndExpandDb = async (db: string) => {
    const willExpand = !expandedDbs.has(db);
    if (db !== currentDb) {
      setCurrentDb(db);
      setSchemaCurrentDb(db);
      setExpandedTbls(new Set());
      setSchemaExpandedTbls([]);
    }
    if (willExpand) {
      const next = new Set(expandedDbs).add(db);
      setExpandedDbs(next);
      setSchemaExpandedDbs([...next]);
      if (!tables[db]) {
        setLoadingTbls((p) => new Set(p).add(db));
        try {
          const data = await api.getGameTables(db);
          const tblList: Tbl[] = (data.tables || []).map((t: string) => ({ name: t }));
          const updated = { ...tables, [db]: tblList };
          setTables(updated);
          setSchemaTables(updated);
        } catch (e) { console.error(e); } finally {
          setLoadingTbls((p) => { const n = new Set(p); n.delete(db); return n; });
        }
      }
    } else {
      const next = new Set(expandedDbs);
      next.delete(db);
      setExpandedDbs(next);
      setSchemaExpandedDbs([...next]);
    }
  };

  const toggleTbl = async (db: string, tbl: string) => {
    const key = `${db}.${tbl}`;
    const next = new Set(expandedTbls);
    if (next.has(key)) {
      next.delete(key);
      setExpandedTbls(next);
      setSchemaExpandedTbls([...next]);
      return;
    }
    next.add(key);
    setExpandedTbls(next);
    setSchemaExpandedTbls([...next]);
    if (!cols[key]) {
      setLoadingCols((p) => new Set(p).add(key));
      try {
        const data = await api.getGameColumns(db, tbl);
        const colList: Col[] = data.columns || [];
        const updated = { ...cols, [key]: colList };
        setCols(updated);
        setSchemaCols(updated);
      } catch (e) { console.error(e); } finally {
        setLoadingCols((p) => { const n = new Set(p); n.delete(key); return n; });
      }
    }
  };

  const insertSelect = (tbl: string) => setSql(`SELECT * FROM \`${tbl}\`\nLIMIT 100;`);

  // --- search ---
  const lowerSearch = search.toLowerCase();
  const searchMatch = (tbl: Tbl) => lowerSearch ? tbl.name.toLowerCase().includes(lowerSearch) : true;
  const colSearchMatch = (col: Col) => lowerSearch ? col.name.toLowerCase().includes(lowerSearch) || (col.comment || '').toLowerCase().includes(lowerSearch) : true;

  return (
    <div style={{ width: '100%', height: '100%', borderRight: '1px solid var(--border-light)', display: 'flex', flexDirection: 'column', backgroundColor: 'var(--surface-1)', flexShrink: 0, minHeight: 0 }}>
      {/* Header（审计 P2-12：窄屏可换行，宽屏不溢出则不生效；图标钮补 aria-label） */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '10px 12px', borderBottom: '1px solid var(--border-light)', flexWrap: 'wrap', gap: 4 }}>
        <h3 style={{ margin: 0, fontSize: 14, color: 'var(--text-primary)', display: 'flex', alignItems: 'center', gap: 6 }}><Database size={14} /> 数据源</h3>
        <div style={{ display: 'flex', gap: 2 }}>
          <button onClick={loadSchema} style={iconBtn} title="刷新 schema" aria-label="刷新 schema"><RotateCw size={14} /></button>
          {onClose && <button onClick={onClose} style={iconBtn} title="关闭" aria-label="关闭"><X size={14} /></button>}
        </div>
      </div>

      {/* Search */}
      <div style={{ padding: '6px 8px', borderBottom: '1px solid var(--surface-heavy)' }}>
        <input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="搜索数据库/表/字段..." aria-label="搜索数据库/表/字段" style={searchInput} />
      </div>

      {currentDb ? (
        <div style={{ padding: '4px 12px', fontSize: 11, color: '#4caf50', borderBottom: '1px solid var(--surface-heavy)', display: 'flex', alignItems: 'center', gap: 6 }}>
          <span style={{ width: 6, height: 6, borderRadius: '50%', backgroundColor: '#4caf50', display: 'inline-block' }} /> {currentDb}
        </div>
      ) : (
        <div style={{ padding: '5px 12px', fontSize: 11, color: 'var(--text-muted)', borderBottom: '1px solid var(--surface-heavy)' }}>未选择真实数据源</div>
      )}

      <div ref={scrollRef} style={{ flex: 1, overflowY: 'auto', padding: 4 }}>
        {loadingDbs ? (
          <div style={{ padding: 12 }}>{[1, 2, 3].map((i) => <div key={i} style={{ height: 16, marginBottom: 10, borderRadius: 4, backgroundColor: 'var(--surface-heavy)', width: `${50 + i * 15}%`, animation: 'skeleton-pulse 1.5s ease-in-out infinite' }} />)}</div>
        ) : search ? (
          /* ---- Search results (interactive tree) ---- */
          <div>
            {(() => {
              const dbNameMatch = (db: string) => db.toLowerCase().includes(lowerSearch);
              const resultDbs = dbs.filter((db) => dbNameMatch(db) || (tables[db] || []).some(searchMatch));
              if (resultDbs.length === 0) return <p style={{ textAlign: 'center', color: 'var(--text-inactive)', fontSize: 12, marginTop: 20 }}>无匹配结果</p>;
              return resultDbs.map((db) => {
                const isCurrent = db === currentDb;
                const dbExpanded = expandedDbs.has(db);
                const visibleTbls = dbNameMatch(db) ? (tables[db] || []) : (tables[db] || []).filter(searchMatch);
                const loadingTbl = loadingTbls.has(db);
                return (
                  <div key={db} style={{ marginBottom: 1 }}>
                    {/* 审计 P2-12：树节点 div → role=button 键盘可达 */}
                    <div data-db={db} onClick={() => switchAndExpandDb(db)} role="button" tabIndex={0} aria-expanded={dbExpanded}
                      onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); switchAndExpandDb(db); } }}
                      style={{ ...rowStyle, backgroundColor: isCurrent ? 'var(--tint-green-bg)' : 'transparent', borderLeft: isCurrent ? '3px solid #4caf50' : '3px solid transparent' }}>
                      <span style={{ color: 'var(--text-muted)', display: 'flex', flexShrink: 0 }}>{dbExpanded ? <ChevronDown size={14} /> : <ChevronRight size={14} />}</span>
                      <Database size={14} style={{ color: isCurrent ? '#4caf50' : 'var(--accent-amber)', flexShrink: 0 }} />
                      <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', color: isCurrent ? '#4caf50' : 'var(--text-primary)', fontWeight: isCurrent ? 600 : 400 }}>{db}</span>
                    </div>
                    {dbExpanded && (
                      <div style={{ marginLeft: 12 }}>
                        {loadingTbl ? <p style={{ padding: '4px 12px', fontSize: 11, color: 'var(--text-inactive)' }}>加载中...</p>
                          : visibleTbls.length === 0 && tables[db] ? <p style={{ padding: '4px 12px', fontSize: 11, color: 'var(--text-inactive)' }}>无匹配表</p>
                            : visibleTbls.map((tbl) => {
                              const key = `${db}.${tbl.name}`;
                              const tblExpanded = expandedTbls.has(key);
                              const colList = cols[key];
                              const loadingCol = loadingCols.has(key);
                              const colMatch = colList ? (lowerSearch ? colList.filter(colSearchMatch) : colList) : [];
                              return (
                                <div key={tbl.name} style={{ marginBottom: 1 }}>
                                  {/* 审计 P2-12：树节点 div → role=button 键盘可达 */}
                                  <div onClick={() => toggleTbl(db, tbl.name)} onDoubleClick={() => insertSelect(tbl.name)} role="button" tabIndex={0} aria-expanded={tblExpanded}
                                    onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggleTbl(db, tbl.name); } }}
                                    style={rowStyle} title="双击 SELECT">
                                    <span style={{ color: 'var(--text-muted)', display: 'flex', flexShrink: 0 }}>{tblExpanded ? <ChevronDown size={13} /> : <ChevronRight size={13} />}</span>
                                    <Table2 size={13} style={{ color: 'var(--accent-amber)', flexShrink: 0 }} />
                                    <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', fontSize: 12 }}>{tbl.name}</span>
                                  </div>
                                  {tblExpanded && (
                                    <div style={{ marginLeft: 14 }}>
                                      {loadingCol ? <p style={{ padding: '2px 8px', fontSize: 11, color: 'var(--text-inactive)' }}>加载中...</p>
                                        : colList ? (colMatch.length > 0 ? colMatch : colList).map((col) => (
                                          <div key={col.name} style={{ display: 'flex', alignItems: 'center', gap: 4, padding: '2px 8px 2px 18px', borderRadius: 3, fontSize: 11, color: 'var(--text-muted)', cursor: 'default' }}
                                            title={`${col.name}  ${col.type}${col.comment ? `\n${col.comment}` : ''}`}
                                            onMouseEnter={e => { (e.currentTarget as HTMLElement).style.backgroundColor = 'var(--surface-heavy)'; }}
                                            onMouseLeave={e => { (e.currentTarget as HTMLElement).style.backgroundColor = ''; }}>
                                            <Columns3 size={10} style={{ color: '#5a8', flexShrink: 0 }} />
                                            <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', flex: 1, minWidth: 0 }}>{col.name}</span>
                                            <span style={{ color: 'var(--text-inactive)', fontSize: 10, flexShrink: 0 }}>{col.type}</span>
                                          </div>
                                        )) : <p style={{ padding: '2px 12px', fontSize: 11, color: 'var(--text-inactive)' }}>点击展开加载字段</p>}
                                    </div>
                                  )}
                                </div>
                              );
                            })}
                      </div>
                    )}
                  </div>
                );
              });
            })()}
          </div>
        ) : (
          /* ---- Normal tree ---- */
          dbs.length === 0 ? (
            <div style={{ padding: 8 }}>
              {sources.length === 0 ? <p style={{ color: 'var(--text-muted)', fontSize: 11 }}>当前项目未配置可验证的数据源契约。</p> : sources.map((s, i) => (
                <div key={`${s.engine}-${s.project_id}-${i}`} style={{ padding: 8, marginBottom: 6, border: '1px solid var(--border-light)', borderRadius: 5, fontSize: 11 }}>
                  <div style={{ color: s.status === 'configured' ? '#4caf50' : '#e67e22', fontWeight: 600 }}>{s.status === 'configured' ? '已配置数据源' : '未配置数据源'}</div>
                  <div>engine: {s.engine || '—'} · region: {s.region || '—'}</div>
                  <div>project: {s.project_id || '—'}</div>
                  <div>event table: {s.event_table || '—'}</div>
                </div>
              ))}
            </div>
          ) : dbs.map((db) => {
            const isCurrent = db === currentDb;
            const dbExpanded = expandedDbs.has(db);
            const tblList = tables[db];
            const loadingTbl = loadingTbls.has(db);
            return (
              <div key={db} style={{ marginBottom: 1 }}>
                {/* 审计 P2-12：树节点 div → role=button 键盘可达 */}
                <div data-db={db} onClick={() => switchAndExpandDb(db)} role="button" tabIndex={0} aria-expanded={dbExpanded}
                  onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); switchAndExpandDb(db); } }}
                  style={{ ...rowStyle, backgroundColor: isCurrent ? 'var(--tint-green-bg)' : 'transparent', borderLeft: isCurrent ? '3px solid #4caf50' : '3px solid transparent' }}>
                  <span style={{ color: 'var(--text-muted)', display: 'flex', flexShrink: 0 }}>{dbExpanded ? <ChevronDown size={14} /> : <ChevronRight size={14} />}</span>
                  <Database size={14} style={{ color: isCurrent ? '#4caf50' : 'var(--accent-amber)', flexShrink: 0 }} />
                  <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', color: isCurrent ? '#4caf50' : 'var(--text-primary)', fontWeight: isCurrent ? 600 : 400 }}>{db}</span>
                </div>
                {dbExpanded && (
                  <div style={{ marginLeft: 12 }}>
                    {loadingTbl ? <p style={{ padding: '4px 12px', fontSize: 11, color: 'var(--text-inactive)' }}>加载中...</p>
                      : tblList ? tblList.map((tbl) => {
                        const key = `${db}.${tbl.name}`;
                        const tblExpanded = expandedTbls.has(key);
                        const colList = cols[key];
                        const loadingCol = loadingCols.has(key);
                        return (
                          <div key={tbl.name} style={{ marginBottom: 1 }}>
                            {/* 审计 P2-12：树节点 div → role=button 键盘可达 */}
                            <div onClick={() => toggleTbl(db, tbl.name)} onDoubleClick={() => insertSelect(tbl.name)} role="button" tabIndex={0} aria-expanded={tblExpanded}
                              onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggleTbl(db, tbl.name); } }}
                              style={rowStyle} title="双击 SELECT">
                              <span style={{ color: 'var(--text-muted)', display: 'flex', flexShrink: 0 }}>{tblExpanded ? <ChevronDown size={13} /> : <ChevronRight size={13} />}</span>
                              <Table2 size={13} style={{ color: 'var(--accent-amber)', flexShrink: 0 }} />
                              <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', fontSize: 12 }}>{tbl.name}</span>
                            </div>
                            {tblExpanded && (
                              <div style={{ marginLeft: 8 }}>
                                {loadingCol ? <p style={{ padding: '2px 12px', fontSize: 11, color: 'var(--text-inactive)' }}>加载中...</p>
                                  : colList ? colList.map((col) => (
                                    <div key={col.name} style={{ display: 'flex', alignItems: 'center', gap: 4, padding: '2px 8px 2px 18px', borderRadius: 3, fontSize: 11, color: 'var(--text-muted)', cursor: 'default' }}
                                      title={`${col.name}  ${col.type}${col.comment ? `\n${col.comment}` : ''}`}>
                                      <Columns3 size={10} style={{ color: '#5a8', flexShrink: 0 }} />
                                      <span style={{ color: 'var(--text-heading)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', flex: 1, minWidth: 0 }}>{col.name}</span>
                                      <span style={{ color: 'var(--text-muted)', fontSize: 10, flexShrink: 0, marginLeft: 2 }}>{col.type.length > 14 ? col.type.slice(0, 12) + '…' : col.type}</span>
                                    </div>
                                  )) : null}
                              </div>
                            )}
                          </div>
                        );
                      }) : null}
                  </div>
                )}
              </div>
            );
          })
        )}
      </div>
    </div>
  );
};

const rowStyle: React.CSSProperties = { display: 'flex', alignItems: 'center', gap: 5, padding: '5px 8px', borderRadius: 4, cursor: 'pointer', fontSize: 13, color: 'var(--text-primary)', userSelect: 'none' };
const iconBtn: React.CSSProperties = { background: 'none', border: 'none', color: 'var(--text-muted)', cursor: 'pointer', padding: 4, display: 'flex', alignItems: 'center', borderRadius: 4 };
const searchInput: React.CSSProperties = { width: '100%', padding: '4px 8px', borderRadius: 4, border: '1px solid var(--text-muted)', backgroundColor: 'var(--surface-1)', color: 'var(--text-on-accent)', fontSize: 12, outline: 'none', boxSizing: 'border-box' };
