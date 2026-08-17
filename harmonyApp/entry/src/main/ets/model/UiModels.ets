/**
 * HarmonyOS 侧的 UI 状态模型（本地内核 v2）。
 * @Observed 类仅追踪顶层属性 — 数组变更通过整体替换触发。
 */

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
}

export class SessionUi {
  id: string = '';
  title: string = '新会话';
  provider: string = 'deepseek';
  model: string = 'deepseek-chat';
  createdAt: number = 0;
  updatedAt: number = 0;
  messageCount: number = 0;
}

@Observed
export class UiState {
  sessions: SessionUi[] = [];
  activeSessionId: string | null = null;
  messages: ChatMessage[] = [];
  /** 发送中（等待内核回合结束） */
  isSending: boolean = false;
  /** 尚未配置任何大模型 API */
  needsConfig: boolean = true;
  /** 引擎状态文本（状态条显示） */
  engineStatus: string = '内核未启动';
  widthClass: WindowWidthClass = WindowWidthClass.Compact;
}

export function computeWidthClass(widthVp: number): WindowWidthClass {
  if (widthVp < 600) return WindowWidthClass.Compact;
  if (widthVp <= 840) return WindowWidthClass.Medium;
  return WindowWidthClass.Expanded;
}
