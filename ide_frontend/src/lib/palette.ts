/**
 * 品牌调色板（审计 P1-23 ④：全站图表唯一色源）。
 * - ide_frontend：ChartView.tsx、panel/utils/reportTransform.ts 均从此 import；
 * - vanilla frontend/charts.js 无构建，palette() 内 base 数组与此保持同源（改色需双改，见注释）。
 * 设计约束：品牌蓝开头，全部颜色在白底对比度 ≥3:1（明暗主题均可读），无低对比亮黄。
 */
export const BRAND_PALETTE: string[] = [
  '#4f7cff', // 品牌蓝
  '#e8546b', // 红
  '#9a6bff', // 紫
  '#b8860b', // 暗金
  '#2f9e5f', // 绿
  '#0d97a5', // 青
  '#d95f2e', // 橙
];
