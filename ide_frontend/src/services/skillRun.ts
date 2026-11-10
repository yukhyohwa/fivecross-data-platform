/** 专项执行（本窗口）流驱动：POST /api/chat preset 模式，SSE 事件累积进 useStore.skillRun。
 *  流在模块级 async 循环里跑（不随组件卸载中断），切走导航再切回结果仍在——与聊天 iframe 保活同思路。
 *  seq 由 beginSkillRun 分配，每个事件先比对 seq，旧流（新一轮执行/清空后仍在到达的事件）一律丢弃。 */
import { api } from './api';
import { useStore } from '../stores/useStore';

let activeController: AbortController | null = null;
let gapController: AbortController | null = null;

/** 启动专项执行流（beginSkillRun 之后调用）；再次调用会先中止上一流。
 *  deepThinking：报告三模型开「深度思考」（推理），随 preset 请求下发给后端。 */
export function startSkillStream(name: string, seq: number, deepThinking = false): void {
  abortSkillStream();
  abortSkillGaps(); // 新一轮执行：上一轮可能仍在跑的缺口分析一并作废
  const ctrl = new AbortController();
  activeController = ctrl;
  (async () => {
    try {
      for await (const ev of api.chatStream(
        { model: '', message: '', mode: 'preset', preset_skill: name, chart_type: 'auto', docs: [], context_report: null, history: [], deep_thinking: deepThinking },
        ctrl.signal,
      )) {
        if (useStore.getState().skillRun?.seq !== seq) break; // 已被新一轮/清空取代
        applyEvent(ev);
      }
    } catch (e: any) {
      if (useStore.getState().skillRun?.seq !== seq) return;
      if (e && (e.name === 'AbortError' || e.name === 'DOMException')) {
        // 用户点「停止」：状态行由面板改，这里只收口
        useStore.getState().updateSkillRun({ running: false });
        return;
      }
      useStore.getState().updateSkillRun({ running: false, status: '出错', error: e.message || String(e) });
    } finally {
      if (activeController === ctrl) activeController = null;
    }
  })();
}

/** 中止当前执行流（面板「停止」/「清空」/新一轮执行共用） */
export function abortSkillStream(): void {
  if (activeController) {
    try { activeController.abort(); } catch { /* noop */ }
    activeController = null;
  }
}

/** 手动触发「提炼修改建议」（报告缺口与补数建议）：结果写入 useStore.skillGapCard，
 *  由「AI源生」面板（SkillAgentPanel → DraftAgentPanel externalGap）按 seq 消费渲染。
 *  同时把 seq 写回 skillRun.gapSeq，执行结果面板据此提示「建议已生成，查看 AI源生」。
 *  缺口修复/调整按专项自身绑定游戏执行（readSkill.meta.game），不走右上角选中游戏——
 *  通用级专项跨游戏执行时口径才一致（2026-10-26 与聊天窗口 to-C 摘除同批）。
 *  进度经 useStore.skillGapStatus 暴露（running=分析中、error=失败），供面板画进度条 + 中断；
 *  成功写卡、失败不写卡（面板就地给「重试」，不再向 AI源生推 error 卡）。
 *  2026-10-29：由执行完成自动触发改为手动触发（用户要求按钮 + 进度条 + 中断）。 */
export function requestSkillGaps(skill: string, answer: string, seq: number): void {
  abortSkillGaps();
  const ctrl = new AbortController();
  gapController = ctrl;
  const st = useStore.getState();
  st.setSkillGapStatus({ running: true, error: null });
  (async () => {
    // 绑定游戏非必需：readSkill 失败（权限/不存在）时回落默认头（右上角选中游戏），
    // 与旧聊天窗口行为一致——缺口分析本身（chat/gaps）按专项元数据口径，不受影响
    let boundGame: string | null = null;
    try {
      boundGame = (await api.readSkill(skill))?.game || null;
    } catch { /* 回落默认行为 */ }
    try {
      const r = await api.chatGaps(skill || null, answer, ctrl.signal);
      if (useStore.getState().skillRun?.seq !== seq) return; // 新一轮执行已开始，丢弃旧建议
      const cardSeq = Date.now();
      useStore.getState().updateSkillRun({ gapSeq: cardSeq });
      useStore.getState().setSkillGapCard({
        skill: skill || '', reportMd: answer, game: boundGame,
        gaps: r.gaps || [], whitelist: r.whitelist || [], seq: cardSeq,
      });
      useStore.getState().setSkillGapStatus({ running: false, error: null });
    } catch (e: any) {
      if (e && (e.name === 'AbortError' || e.name === 'DOMException')) {
        // 用户中断（或新一轮执行作废）：不写卡，进度收口即可
        useStore.getState().setSkillGapStatus({ running: false, error: null });
        return;
      }
      if (useStore.getState().skillRun?.seq !== seq) return;
      useStore.getState().setSkillGapStatus({ running: false, error: e.message || '缺口分析失败' });
    } finally {
      if (gapController === ctrl) gapController = null;
    }
  })();
}

/** 中止正在进行的缺口分析（面板「中断」/ 新一轮执行共用） */
export function abortSkillGaps(): void {
  if (gapController) {
    try { gapController.abort(); } catch { /* noop */ }
    gapController = null;
  }
}

/** 单事件 → skillRun 状态（与 vanilla app.js handleEvent 同一协议；progress 心跳只更新状态行） */
function applyEvent(ev: any): void {
  const st = useStore.getState();
  const run = st.skillRun;
  if (!run) return;
  const upd = st.updateSkillRun;
  switch (ev.type) {
    case 'stage':
      upd({ status: ev.message || '', steps: [...run.steps, ev.message || ''] });
      break;
    case 'progress':
      upd({ status: ev.message || '' });
      break;
    case 'meta':
      upd({ meta: { source: ev.source || '', skill: ev.skill || undefined } });
      break;
    case 'sql':
      upd({ sqls: [...run.sqls, { name: ev.name || null, sql: ev.sql || '', explain: ev.explain || null }] });
      break;
    case 'data': {
      // currentSql 语义（同 app.js）：紧邻本次 data 之前的 sql 事件值，供导出全量
      const lastSql = run.sqls.length ? run.sqls[run.sqls.length - 1].sql : null;
      upd({ tables: [...run.tables, { name: ev.name || null, table: ev.table || { columns: [], rows: [] }, sql: lastSql }] });
      break;
    }
    case 'charts':
      upd({ charts: ev.charts || [] });
      break;
    case 'answer':
      upd({ answer: ev.markdown || '' });
      break;
    case 'usage':
      upd({ usage: ev });
      break;
    case 'error':
      upd({ error: ev.message || '未知错误', status: '出错', running: false });
      break;
    case 'done':
      // 出错后后端仍会补发 done（看门狗收口）：错误已记则状态保持「出错」
      upd({ running: false, status: run.error ? '出错' : '完成', elapsed: ev.elapsed ?? null });
      // 报告缺口与补数建议（2026-10-29 起改为手动触发）：执行成功后由面板「提炼修改建议」
      // 按钮显式调用 requestSkillGaps（不再自动触发；卡片渲染进「AI源生」对话）。
      break;
    case 'confirm': case 'game_confirm': case 'forecast_confirm':
    case 'candidates': case 'ai_report_confirm': case 'rewrite_confirm': case 'generate_confirm':
      // preset 模式按名直跑不会出交互确认（探查已验证）；防御性提示
      upd({ steps: [...run.steps, `⚠️ 出现交互确认（${ev.type}）——请到聊天窗口完成该步骤`] });
      break;
    default:
      break;
  }
}
