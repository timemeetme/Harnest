/**
 * HarmonyOS 侧的 UI 状态模型。
 * 一一对应 shared/src/commonMain/kotlin/com/harnessapp/shared/ui/UiState.kt。
 *
 * 说明：
 *  - ArkTS 不支持 Kotlin/Native 的 KMP 产物，所以这里手动镜像一份。
 *  - 所有 class 使用纯数据 + 默认值，便于在 @Observed 类里持有引用。
 *  - 所有字段必须可序列化（ArkTS 的 JSON 能力），方便从 JSON-RPC 通知反序列化。
 */

export enum MessageRole {
  User = 'user',
  Assistant = 'assistant',
  System = 'system',
  Tool = 'tool',
}

export enum ToolStatus {
  Pending = 'pending',
  Running = 'running',
  Success = 'success',
  Error = 'error',
}

export enum PlanStatus {
  Pending = 'pending',
  InProgress = 'in_progress',
  Done = 'done',
  Blocked = 'blocked',
}

export enum SubagentStatus {
  Running = 'running',
  Done = 'done',
  Error = 'error',
}

export enum ConnectionStatus {
  Disconnected = 'disconnected',
  Connecting = 'connecting',
  Connected = 'connected',
  Error = 'error',
}

export enum DetailsTab {
  Tools = 'tools',
  Plan = 'plan',
  Todo = 'todo',
  Subagents = 'subagents',
  Settings = 'settings',
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
  reasoning: string | null = null;
  toolCalls: ToolCallUi[] = [];
  isStreaming: boolean = false;
}

export class ToolCallUi {
  id: string = '';
  name: string = '';
  args: string = '';
  result: string | null = null;
  status: ToolStatus = ToolStatus.Pending;
}

export class SessionUi {
  id: string = '';
  title: string = '';
  updatedAt: number = 0;
  messageCount: number = 0;
  isRunning: boolean = false;
}

export class TodoItemUi {
  id: string = '';
  content: string = '';
  done: boolean = false;
  order: number = 0;
}

export class PlanItemUi {
  id: string = '';
  title: string = '';
  description: string | null = null;
  status: PlanStatus = PlanStatus.Pending;
  children: PlanItemUi[] = [];
}

export class ApprovalRequestUi {
  id: string = '';
  title: string = '';
  description: string | null = null;
  toolName: string | null = null;
  createdAt: number = 0;
}

export class SubagentUi {
  id: string = '';
  name: string = '';
  status: SubagentStatus = SubagentStatus.Running;
  parentSessionId: string | null = null;
}

export class GoalState {
  text: string = '';
  active: boolean = false;
}

export class KernelConnectionState {
  host: string = 'localhost';
  port: number = 3080;
  useTls: boolean = false;
  provider: string = 'deepseek';
  model: string = 'deepseek-chat';
  status: ConnectionStatus = ConnectionStatus.Disconnected;
  serverName: string | null = null;
  serverVersion: string | null = null;
}

export class WorkspaceUi {
  path: string = '';
  name: string = '';
}

export class SettingsUi {
  provider: string = 'deepseek';
  model: string = 'deepseek-chat';
  maxTokens: number = 8192;
  autoApprove: boolean = false;
  theme: string = 'system';
  language: string = 'zh-CN';
}

export class UiState {
  sessions: SessionUi[] = [];
  activeSessionId: string | null = null;
  messages: ChatMessage[] = [];
  todos: TodoItemUi[] = [];
  plan: PlanItemUi[] = [];
  approvals: ApprovalRequestUi[] = [];
  subagents: SubagentUi[] = [];
  goal: GoalState = new GoalState();
  connection: KernelConnectionState = new KernelConnectionState();
  workspace: WorkspaceUi = new WorkspaceUi();
  settings: SettingsUi = new SettingsUi();
  inputText: string = '';
  isStreaming: boolean = false;
  sidebarOpen: boolean = true;
  detailsOpen: boolean = false;
  detailsTab: DetailsTab = DetailsTab.Tools;
  widthClass: WindowWidthClass = WindowWidthClass.Compact;
}

export function computeWidthClass(widthPx: number): WindowWidthClass {
  if (widthPx < 600) return WindowWidthClass.Compact;
  if (widthPx <= 840) return WindowWidthClass.Medium;
  return WindowWidthClass.Expanded;
}

export function sidebarWidthFor(cls: WindowWidthClass): number {
  switch (cls) {
    case WindowWidthClass.Compact: return 0;
    case WindowWidthClass.Medium: return 240;
    case WindowWidthClass.Expanded: return 300;
  }
}

export function detailsWidthFor(cls: WindowWidthClass): number {
  switch (cls) {
    case WindowWidthClass.Compact: return 0;
    case WindowWidthClass.Medium: return 0;
    case WindowWidthClass.Expanded: return 360;
  }
}
