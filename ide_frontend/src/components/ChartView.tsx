import React, { useMemo, useState } from 'react';
import ReactECharts from 'echarts-for-react';
import { BarChart3 } from 'lucide-react';
import { BRAND_PALETTE as PALETTE } from '../lib/palette';

interface ChartViewProps {
  columns: string[];
  rows: Record<string, unknown>[];
}

const CHART_TYPES = [
  { key: 'bar', label: '柱状图' },
  { key: 'line', label: '趋势图' },
  { key: 'stacked-bar', label: '堆叠图' },
  { key: 'combo', label: '柱叠图' },
  { key: 'donut', label: '环形分布图' },
] as const;

type ChartType = typeof CHART_TYPES[number]['key'];

/* ---- helpers ---- */

function isNumericCol(rows: Record<string, unknown>[], col: string): boolean {
  const sample = rows.slice(0, 10);
  if (sample.length === 0) return false;
  let numeric = 0;
  for (const r of sample) {
    const v = r[col];
    if (v === null || v === undefined || v === '') continue;
    if (!isNaN(Number(v))) numeric++;
  }
  return numeric >= sample.length * 0.5;
}

function distinctVals(rows: Record<string, unknown>[], col: string): string[] {
  const seen = new Set<string>();
  for (const r of rows) {
    const v = r[col];
    seen.add(v === null || v === undefined ? 'NULL' : String(v));
  }
  return [...seen];
}

function smartDefaultX(columns: string[], rows: Record<string, unknown>[]): string {
  const datePattern = /date|time|日期|时间|月|年|day|month|year|dt/i;
  const match = columns.find((c) => datePattern.test(c));
  return match || columns[0] || '';
}

function smartDefaultY(columns: string[], rows: Record<string, unknown>[]): string[] {
  const numeric = columns.filter((c) => isNumericCol(rows, c));
  return numeric.length > 0 ? [numeric[0]] : columns.slice(1, 2);
}

function smartDefaultGroup(columns: string[], rows: Record<string, unknown>[]): string {
  const groupPattern = /region|地区|category|类别|type|类型|group|分组|status|状态|channel|渠道/i;
  const candidate = columns.find((c) => groupPattern.test(c) && !isNumericCol(rows, c));
  return candidate && candidate !== smartDefaultX(columns, rows) ? candidate : '';
}

function smartDefaultChart(columns: string[], rows: Record<string, unknown>[], groupCol: string): ChartType {
  if (groupCol) return 'stacked-bar';
  if (columns.length <= 2) return 'bar';
  return 'bar';
}

/* ---- component ---- */

export const ChartView: React.FC<ChartViewProps> = ({ columns, rows }) => {
  const [chartType, setChartType] = useState<ChartType>(() => smartDefaultChart(columns, rows, smartDefaultGroup(columns, rows)));
  const [xColumn, setXColumn] = useState(() => smartDefaultX(columns, rows));
  const [yColumns, setYColumns] = useState<string[]>(() => smartDefaultY(columns, rows));
  const [groupColumn, setGroupColumn] = useState(() => smartDefaultGroup(columns, rows));

  const showGroup = chartType !== 'donut';

  /* ---- ECharts option ---- */
  const option = useMemo(() => {
    if (columns.length === 0 || rows.length === 0) return null;
    if (!xColumn || yColumns.length === 0) return null;

    const baseOption: any = {
      backgroundColor: 'transparent',
      textStyle: { color: 'var(--text-muted)' },
      tooltip: { trigger: chartType === 'donut' ? 'item' : 'axis' },
      legend: { textStyle: { color: 'var(--text-muted)' }, top: 0, type: 'scroll' },
      color: PALETTE,
    };

    /* ---- donut ---- */
    if (chartType === 'donut') {
      const yCol = yColumns[0];
      const data = rows.map((r) => ({
        name: String(r[xColumn] ?? 'NULL'),
        value: Number(r[yCol]) || 0,
      }));
      return {
        ...baseOption,
        series: [{
          type: 'pie',
          radius: ['40%', '70%'],
          center: ['50%', '55%'],
          data,
          label: { color: 'var(--text-secondary)', fontSize: 12 },
          emphasis: { label: { fontSize: 14, fontWeight: 'bold' } },
        }],
      };
    }

    /* ---- cartesian charts ---- */
    const xVals = distinctVals(rows, xColumn);
    const groups = groupColumn && showGroup ? distinctVals(rows, groupColumn) : null;

    const buildSeriesData = (yCol: string): number[] => {
      if (groups) {
        // Grouped: each group builds a series
        return []; // handled per-group below
      }
      return xVals.map((xv) => {
        const row = rows.find((r) => String(r[xColumn] ?? 'NULL') === xv);
        return row ? (Number(row[yCol]) || 0) : 0;
      });
    };

    let series: any[];
    if (groups) {
      series = groups.map((g, gi) => {
        const data = xVals.map((xv) => {
          const row = rows.find(
            (r) => String(r[xColumn] ?? 'NULL') === xv && String(r[groupColumn] ?? 'NULL') === g
          );
          return row ? (Number(row[yColumns[0]]) || 0) : 0;
        });
        const base: any = { name: g, data };
        if (chartType === 'stacked-bar') {
          base.type = 'bar';
          base.stack = 'total';
        } else if (chartType === 'combo') {
          base.type = gi === 0 ? 'bar' : 'line';
          if (gi > 0) base.smooth = true;
        } else if (chartType === 'line') {
          base.type = 'line';
          base.smooth = true;
        } else {
          base.type = 'bar';
        }
        return base;
      });
    } else {
      series = yColumns.map((yc, yi) => {
        const data = xVals.map((xv) => {
          const row = rows.find((r) => String(r[xColumn] ?? 'NULL') === xv);
          return row ? (Number(row[yc]) || 0) : 0;
        });
        const base: any = { name: yc, data };
        if (chartType === 'stacked-bar') {
          base.type = 'bar';
          base.stack = 'total';
        } else if (chartType === 'combo') {
          base.type = yi === 0 ? 'bar' : 'line';
          if (yi > 0) base.smooth = true;
        } else if (chartType === 'line') {
          base.type = 'line';
          base.smooth = true;
        } else {
          base.type = 'bar';
        }
        return base;
      });
    }

    return {
      ...baseOption,
      grid: { top: 40, right: 16, bottom: 32, left: 50 },
      xAxis: { type: 'category', data: xVals, axisLabel: { color: 'var(--text-muted)', rotate: xVals.length > 8 ? 30 : 0 } },
      yAxis: { type: 'value', axisLabel: { color: 'var(--text-muted)' }, splitLine: { lineStyle: { color: 'var(--border-light)' } } },
      series,
    };
  }, [columns, rows, chartType, xColumn, yColumns, groupColumn, showGroup]);

  if (columns.length === 0 || rows.length === 0) {
    return <div style={emptyStyle}>没有可用于图表的数据</div>;
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%', minHeight: 300 }}>
      {/* Config bar */}
      <div style={configBarStyle}>
        {/* Chart type（审计 P2-12：原生控件补 aria-label） */}
        <select value={chartType} onChange={(e) => setChartType(e.target.value as ChartType)} aria-label="图表类型" style={selStyle}>
          {CHART_TYPES.map((t) => <option key={t.key} value={t.key}>{t.label}</option>)}
        </select>

        {/* X column */}
        <div style={fieldStyle}>
          <span style={lblStyle}>{chartType === 'donut' ? '标签列' : 'X 轴'}</span>
          <select value={xColumn} onChange={(e) => setXColumn(e.target.value)} aria-label={chartType === 'donut' ? '标签列' : 'X 轴'} style={selStyle}>
            {columns.map((c) => <option key={c} value={c}>{c}</option>)}
          </select>
        </div>

        {/* Y columns (multi) */}
        <div style={fieldStyle}>
          <span style={lblStyle}>Y 轴</span>
          <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap', maxWidth: 260 }}>
            {columns.filter((c) => chartType !== 'donut' || c !== xColumn).map((c) => {
              const active = yColumns.includes(c);
              return (
                <button
                  key={c}
                  onClick={() => {
                    if (chartType === 'donut') {
                      setYColumns([c]); // single Y for donut
                    } else {
                      setYColumns((prev) =>
                        prev.includes(c) ? prev.filter((yc) => yc !== c) : [...prev, c]
                      );
                    }
                  }}
                  aria-pressed={active}
                  style={{
                    padding: '1px 7px', borderRadius: 3, border: `1px solid ${active ? '#4caf50' : 'var(--text-muted)'}`,
                    background: active ? 'var(--tint-green-bg)' : 'transparent', color: active ? '#4caf50' : 'var(--text-muted)',
                    cursor: 'pointer', fontSize: 10, whiteSpace: 'nowrap',
                  }}
                >{c}</button>
              );
            })}
          </div>
        </div>

        {/* Group column */}
        {showGroup && (
          <div style={fieldStyle}>
            <span style={lblStyle}>分组</span>
            <select value={groupColumn} onChange={(e) => setGroupColumn(e.target.value)} aria-label="分组" style={selStyle}>
              <option value="">无</option>
              {columns.filter((c) => c !== xColumn).map((c) => <option key={c} value={c}>{c}</option>)}
            </select>
          </div>
        )}
      </div>

      {/* Chart */}
      <div style={{ flex: 1, minHeight: 0 }}>
        {option ? (
          <ReactECharts
            option={option}
            style={{ height: '100%', width: '100%' }}
            opts={{ renderer: 'canvas' }}
            notMerge={true}
          />
        ) : (
          <div style={emptyStyle}>
            <BarChart3 size={32} style={{ marginBottom: 8, color: 'var(--text-inactive)' }} />
            <span>请配置列映射以生成图表</span>
          </div>
        )}
      </div>
    </div>
  );
};

const configBarStyle: React.CSSProperties = {
  display: 'flex', alignItems: 'center', gap: 8, padding: '6px 8px',
  borderBottom: '1px solid var(--border-light)', flexShrink: 0, flexWrap: 'wrap',
  fontSize: 11, backgroundColor: 'var(--surface-1)',
};
const selStyle: React.CSSProperties = {
  padding: '2px 4px', borderRadius: 3, border: '1px solid var(--text-muted)',
  background: 'var(--surface-0)', color: 'var(--text-primary)', fontSize: 11, outline: 'none', cursor: 'pointer',
};
const fieldStyle: React.CSSProperties = { display: 'flex', alignItems: 'center', gap: 4 };
const lblStyle: React.CSSProperties = { color: 'var(--text-muted)', fontSize: 10, whiteSpace: 'nowrap' };
const emptyStyle: React.CSSProperties = {
  display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center',
  height: '100%', color: 'var(--text-inactive)', fontSize: 12,
};
