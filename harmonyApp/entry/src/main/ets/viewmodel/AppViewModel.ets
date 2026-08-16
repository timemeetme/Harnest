/**
 * AppViewModel — 持有 UI 状态 + 所有业务动作。
 * 对应 shared/src/commonMain/kotlin/com/harnessapp/shared/ui/AppViewModel.kt。
 *
 * ArkTS 下没有 Kotlin 的 data class copy()，所以 state 更新采用：
 *   1) 直接修改 state 的子对象属性（AppState 内部的 plain class），或
 *   2) 用 Object.assign 做浅拷贝
 *
 * 两种方式都能触发 @ObjectLink 驱动的 UI 刷新（ArkUI Proxy 深度拦截）。
 */

import { DshWebSocketClient } from '../service/DshClient';
import {
  UiState, SessionUi, ChatMessage, MessageRole, ConnectionStatus,
  DetailsTab, WindowWidthClass, computeWidthClass,
  SubagentUi, SubagentStatus, TodoItemUi, PlanItemUi, PlanStatus,
  ToolCallUi, ToolStatus, GoalState, KernelConnectionState,
} from '../model/UiModels';

@Observed
export class AppViewModel {
  state: UiState = new UiState();
  client: DshWebSocketClient = new DshWebSocketClient();
  private unsubscribe: (() => void) | null = null;

  constructor() {
    this.client.setErrorHandler((err: Error) => {
      console.error('[DshClient] error:', err.message);
    });
    this.client.setCloseHandler(() => {
      this.state.connection.status = ConnectionStatus.Disconnected;
      this.state.isStreaming = false;
    });
    this.unsubscribe = this.client.subscribe((method, params) => {
      this.handleNotification(method, params);
    });
  }

  dispose(): void {
    this.unsubscribe?.();
    this.unsubscribe = null;
    try { this.client.disconnect(); } catch (_) { /* ignore */ }
  }

  onWindowSizeChanged(widthPx: number): void {
    const cls = computeWidthClass(widthPx);
    this.state.widthClass = cls;
    if (cls === WindowWidthClass.Compact) {
      this.state.detailsOpen = false;
    }
  }

  toggleSidebar(): void {
    this.state.sidebarOpen = !this.state.sidebarOpen;
  }

  toggleDetails(): void {
    this.state.detailsOpen = !this.state.detailsOpen;
  }

  selectDetailsTab(tab: DetailsTab): void {
    this.state.detailsTab = tab;
    this.state.detailsOpen = true;
  }

  updateInput(text: string): void {
    this.state.inputText = text;
  }

  setGoal(text: string): void {
    this.state.goal.text = text;
    this.state.goal.active = text.trim().length > 0;
  }

  selectSession(sessionId: string): void {
    this.state.activeSessionId = sessionId;
    this.state.messages = [];
  }

  newSession(): string {
    const id = 'session-' + Date.now();
    const session = new SessionUi();
    session.id = id;
    session.title = '新会话';
    session.updatedAt = Date.now();
    session.messageCount = 0;
    this.state.sessions = [session].concat(this.state.sessions);
    this.state.activeSessionId = id;
    this.state.messages = [];
    return id;
  }

  deleteSession(sessionId: string): void {
    const list = this.state.sessions.filter((s) => s.id !== sessionId);
    this.state.sessions = list;
    if (this.state.activeSessionId === sessionId) {
      this.state.activeSessionId = list.length > 0 ? list[0].id : null;
      this.state.messages = [];
    }
  }

  async connectKernel(
    host: string, port: number, useTls: boolean,
    provider: string, model: string, cwd: string = '/tmp',
  ): Promise<void> {
    this.state.connection.host = host;
    this.state.connection.port = port;
    this.state.connection.useTls = useTls;
    this.state.connection.provider = provider;
    this.state.connection.model = model;
    this.state.connection.status = ConnectionStatus.Connecting;
    this.state.workspace.path = cwd;
    try {
      const scheme = useTls ? 'wss' : 'ws';
      const url = scheme + '://' + host + ':' + port;
      await this.client.connect(url);
      const info = await this.client.initialize({ cwd, provider, model });
      this.state.connection.status = ConnectionStatus.Connected;
      this.state.connection.serverName = info.name;
      this.state.connection.serverVersion = info.version;
      if (this.state.sessions.length === 0) {
        this.newSession();
      }
    } catch (e) {
      this.state.connection.status = ConnectionStatus.Error;
      console.error('[AppViewModel] connect failed:', (e as Error).message);
    }
  }

  async disconnectKernel(): Promise<void> {
    try { await this.client.disconnect(); } catch (_) { /* ignore */ }
    this.state.connection.status = ConnectionStatus.Disconnected;
    this.state.isStreaming = false;
    for (const s of this.state.sessions) s.isRunning = false;
  }

  sendMessage(content: string): void {
    const trimmed = content.trim();
    if (!trimmed) return;
    const sessionId = this.state.activeSessionId ?? this.newSession();

    const userMsg = new ChatMessage();
    userMsg.id = 'msg-' + Date.now();
    userMsg.role = MessageRole.User;
    userMsg.content = trimmed;
    userMsg.createdAt = Date.now();

    this.state.messages = this.state.messages.concat([userMsg]);
    this.state.inputText = '';
    this.state.isStreaming = true;

    for (let i = 0; i < this.state.sessions.length; i++) {
      const s = this.state.sessions[i];
      if (s.id === sessionId) {
        s.messageCount += 1;
        s.updatedAt = Date.now();
        s.isRunning = true;
      }
    }

    if (!this.client.isConnected) {
      this.state.isStreaming = false;
      this.appendAssistantError('未连接 DSH 内核');
      return;
    }

    this.client.prompt(sessionId, []).then(() => {
      // 入队成功，实际流式内容走 session.event 通知
    }).catch((err: Error) => {
      this.appendAssistantError('发送失败: ' + err.message);
    });
  }

  addTodo(content: string): void {
    const t = new TodoItemUi();
    t.id = 'todo-' + Date.now();
    t.content = content;
    t.done = false;
    t.order = this.state.todos.length;
    this.state.todos = this.state.todos.concat([t]);
  }

  toggleTodo(id: string): void {
    for (const t of this.state.todos) {
      if (t.id === id) t.done = !t.done;
    }
  }

  deleteTodo(id: string): void {
    this.state.todos = this.state.todos.filter((t) => t.id !== id);
  }

  private appendAssistantError(text: string): void {
    const m = new ChatMessage();
    m.id = 'msg-err-' + Date.now();
    m.role = MessageRole.Assistant;
    m.content = text;
    m.createdAt = Date.now();
    this.state.messages = this.state.messages.concat([m]);
    this.state.isStreaming = false;
  }

  private handleNotification(method: string, params: Record<string, Object>): void {
    switch (method) {
      case 'session.event': this.onSessionEvent(params); break;
      case 'session.status': this.onSessionStatus(params); break;
      case 'subagent.started': this.onSubagentStarted(params); break;
      case 'subagent.finished': this.onSubagentFinished(params); break;
      default:
        console.info('[DSH] unknown notification:', method);
        break;
    }
  }

  private onSessionEvent(params: Record<string, Object>): void {
    const sessionId = String(params['sessionId'] ?? '');
    const event = params['event'] ?? {};
    const eventObj = event as Record<string, Object>;
    const type = String(eventObj['type'] ?? eventObj['event'] ?? '');
    const action = String(eventObj['action'] ?? '');

    for (const s of this.state.sessions) {
      if (s.id === sessionId) s.updatedAt = Date.now();
    }

    if (type === 'message' || action === 'append' || 'message' in eventObj) {
      this.tryAppendAssistantDelta(eventObj);
    }
  }

  private onSessionStatus(params: Record<string, Object>): void {
    const sessionId = String(params['sessionId'] ?? '');
    const raw = String((params['status'] as Record<string, Object>)['name'] ?? params['status'] ?? '');
    const running = raw === 'running';
    for (const s of this.state.sessions) {
      if (s.id === sessionId) s.isRunning = running;
    }
    if (!running) {
      this.state.isStreaming = false;
    }
  }

  private onSubagentStarted(params: Record<string, Object>): void {
    const child = String(params['childSessionId'] ?? '');
    const parent = String(params['parentSessionId'] ?? '');
    const sub = new SubagentUi();
    sub.id = child;
    sub.name = '子代理 ' + child.slice(-8);
    sub.parentSessionId = parent;
    sub.status = SubagentStatus.Running;
    this.state.subagents = this.state.subagents.concat([sub]);
  }

  private onSubagentFinished(params: Record<string, Object>): void {
    const child = String(params['childSessionId'] ?? '');
    this.state.subagents = this.state.subagents.filter((s) => s.id !== child);
  }

  private tryAppendAssistantDelta(eventObj: Record<string, Object>): void {
    const content = String(
      eventObj['content'] ?? eventObj['text'] ?? eventObj['delta'] ?? '',
    );
    if (!content) return;

    const last = this.state.messages.length > 0
      ? this.state.messages[this.state.messages.length - 1]
      : null;

    if (last && last.role === MessageRole.Assistant) {
      last.content = last.content + content;
      last.isStreaming = true;
    } else {
      const m = new ChatMessage();
      m.id = 'msg-a-' + Date.now() + '-' + Math.random().toString(36).slice(2, 6);
      m.role = MessageRole.Assistant;
      m.content = content;
      m.createdAt = Date.now();
      m.isStreaming = true;
      this.state.messages = this.state.messages.concat([m]);
    }
    this.state.isStreaming = true;
  }
}
