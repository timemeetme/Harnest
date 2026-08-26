/**
 * HarmonyOS 侧的 UI 状态模型（本地内核 v2）。
 * @Observed 类仅追踪顶层属性 — 数组变更通过整体替换触发。
 */

import { TodoSnapshotItem } from '../service/HarnessNative';

export enum MessageRole {
  User = 'user',
  Assistant = 'assistant',
  Tool = 'tool',
  System = 'system',
}

export enum WindowWidthClass {
  Compact = 0,
  Medium = 1,
  Expanded = 2,
}

export class ChatMessage {
  id: string = '';
  role: MessageRole = MessageRole.User;
  content: string = '';
  createdAt: number = 0;
  /** 该消息使用的模型（assistant 消息记录实际应答模型） */
  provider: string | null = null;
  model: string | null = null;
  isError: boolean = false;
  /** 工具消息（role=Tool）：工具名 */
  toolName: string = '';
  /** 工具消息状态：running | ok | error */
  toolStatus: string = '';
  /** 工具结果预览（截断后的文本） */
  toolResult: string = '';
  /** todo_write 消息携带的整表快照（JSON 数组，空串=无） */
  todosJson: string = '';
  /** assistant 消息：本轮响应耗时（毫秒，0=未记录） */
  durationMs: number = 0;
  /** assistant 消息：回合 token 用量（内核 details.usage surfaced；0=未上报） */
  inTok: number = 0;
  outTok: number = 0;
  /** assistant 消息：执行轨迹 JSON（思考/工具/待办/转向/子代理，空串=无） */
  traceJson: string = '';
  /** k4：用户消息为 ⚡ 转向注入（下一 step 边界生效） */
  steered: boolean = false;
  /** k6：消息评分 1 赞 / -1 踩 / 0 无 */
  rating: number = 0;
}

/**
 * 实时回合活动条目（内核 round 事件归并而来）。
 * kind='think'：seq/text 有效；kind='tool'：callId/name/args/status/result 有效；
 * kind='todos'：todos 有效（整表快照）；
 * kind='steer'（k4 转向注入预告）：text 有效；
 * kind='subagent'（子代理）：name=label、status=phase（running…）、result=outcome。
 */
export class LiveItem {
  kind: string = 'think';
  seq: number = 0;
  /** (turn,step) 双键定位段：内核事件自带，跨 turn 同 step 序号不串段（trace 持久化 "u"/"s"） */
  turn: number = 0;
  step: number = 0;
  text: string = '';
  callId: string = '';
  name: string = '';
  args: string = '';
  status: string = '';
  result: string = '';
  /** A1 工具执行耗时（毫秒，0=未记录；事件 durationMs 直读，缺省用 tool-start 时刻差值兜底） */
  durationMs: number = 0;
  todos: TodoSnapshotItem[] = [];
}

/** k5 提问选项 */
export class PendingOption {
  label: string = '';
  description: string = '';
  /** plan-review 变体：该选项为「批准」动作（点选即批准计划，显示批准徽标） */
  isApprove: boolean = false;
}

/** k5 单个提问 */
export class PendingQuestionItem {
  id: number = 0;
  question: string = '';
  detail: string = '';
  header: string = '';
  multiSelect: boolean = false;
  options: PendingOption[] = [];
}

/** k5 提问卡（当前等待用户回答的一组问题；qid 对应内核 answerQuestion） */
export class PendingQuestion {
  qid: number = 0;
  questions: PendingQuestionItem[] = [];
  /** plan-review 变体（任一选项带批准意图）— 标题变「🧭 计划待审批」 */
  planReview: boolean = false;
}

/** k7e 后台任务镜像（只保留 running/stopping） */
export class BgJobUi {
  id: string = '';
  label: string = '';
  status: string = 'running';
}

export class SessionUi {
  id: string = '';
  title: string = '新会话';
  provider: string = 'deepseek';
  model: string = 'deepseek-v4-flash';
  createdAt: number = 0;
  updatedAt: number = 0;
  messageCount: number = 0;
  /** k19：思考强度（空串=跟随服务端默认；按会话保存） */
  effort: string = '';
}

@Observed
export class UiState {
  sessions: SessionUi[] = [];
  activeSessionId: string | null = null;
  messages: ChatMessage[] = [];
  /** 发送中（等待内核回合结束） */
  isSending: boolean = false;
  /** 本轮实时活动条目（思考/工具/待办/转向/子代理，回合结束后随 assistant 消息落盘） */
  liveItems: LiveItem[] = [];
  /** 尚未配置任何大模型 API */
  needsConfig: boolean = true;
  /** 引擎状态文本（状态条显示） */
  engineStatus: string = '内核未启动';
  /** k4：排队待发消息（busy 时入队，本轮结束自动续发；停止清空） */
  queuedMessages: string[] = [];
  /** k5：当前待回答提问卡（null=无；busyHint 同步「等待你的回答…」） */
  pendingQuestion: PendingQuestion | null = null;
  /** k6：Plan 模式开关态（与内核 setPlanMode 同步） */
  planActive: boolean = false;
  /** k7e：后台任务镜像（只留 running/stopping） */
  bgJobs: BgJobUi[] = [];
  /** 忙时提示条（等待回答/压缩中等；空串=隐藏） */
  busyHint: string = '';
  /** A2 回合已进行秒数（doSend 期间跳动器每秒更新；busy 行拼「阶段 · 字数 · m:ss」） */
  busySec: number = 0;
  /** A4 运行日志环形缓冲（[stream]/[event] 镜像，最近 300 行；LogLineUi.seq 供 ForEach 稳定键） */
  logLines: LogLineUi[] = [];
  /** 【5】token 水位条（usageRatio 0~1，0=不渲染；回合结束 refreshUsageStats 刷新） */
  usageRatio: number = 0;
  /** 【5】用量文本（如 "12.3k/64k" = totalTokens/contextWindow，1024 进制） */
  usageText: string = '';
  /** 【5】内核 baseline=='none'（无请求样本冷启动）→ 水位条半透明 */
  usageCold: boolean = false;
  /** 一次性提示（ChatView 渲染 toast 条后由 UI 定时清空） */
  toast: string = '';
  widthClass: WindowWidthClass = WindowWidthClass.Compact;
}

/** A4 运行日志行（seq 全局递增，环形缓冲 splice 后仍可作 ForEach 稳定键防全列表重渲染） */
export class LogLineUi {
  seq: number = 0;
  text: string = '';
}

export function computeWidthClass(widthVp: number): WindowWidthClass {
  if (widthVp < 600) return WindowWidthClass.Compact;
  if (widthVp <= 840) return WindowWidthClass.Medium;
  return WindowWidthClass.Expanded;
}
