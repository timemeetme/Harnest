import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  UiState, ChatMessage, MessageRole, SessionUi,
} from '../model/UiModels';
import { LocalEngine } from '../service/LocalEngine';
import { ChatOutcome, ToolCallEntry, TodoSnapshotItem } from '../service/HarnessNative';
import { ConfigService, ProviderConfig } from '../service/ConfigService';
import { SessionStore, SessionRecord, StoredMessage } from '../service/SessionStore';
import { PROVIDER_META } from '../common/Constants';

const TAG = 'AppViewModel';
const DOMAIN = 0x0305;

/**
 * 应用 ViewModel（本地内核 v2）。
 *
 * 模型选择语义：
 *  - 会话粒度：SessionRecord.provider/model 保存，切换会话自动恢复
 *  - 消息粒度：StoredMessage.provider/model 记录每条消息实际使用的模型
 *  - 记住最后选择：ConfigService.setLastSelection — 新会话默认值
 */
@Observed
export class AppViewModel {
  state: UiState = new UiState();
  private engine: LocalEngine = new LocalEngine();
  private context: common.Context | null = null;
  private store: SessionStore = SessionStore.get();

  /** Index 启动时调用 */
  init(context: common.Context): void {
    this.context = context;
    this.refreshNeedsConfig();

    const records = this.store.loadAll();
    const sessions: SessionUi[] = records.map((r: SessionRecord) => this.toSessionUi(r));
    if (sessions.length > 0) {
      this.state.sessions = sessions;
      this.state.activeSessionId = sessions[0].id;
      this.loadMessages(sessions[0].id);
    } else {
      this.createDraftSession();
    }
    this.state.engineStatus = this.engine.isReady() ? '内核就绪' : '内核待命';
  }

  // ── 会话管理 ────────────────────────────────────────────────

  newSession(): void {
    this.createDraftSession();
  }

  private createDraftSession(): void {
    const def = ConfigService.get().getDefaultSelection();
    const id = SessionStore.newId();
    const record: SessionRecord = {
      id: id,
      title: '新会话',
      provider: def.provider,
      model: def.model,
      createdAt: Date.now(),
      updatedAt: Date.now(),
      messages: []
    };
    this.store.upsert(record);
    this.state.sessions = [this.toSessionUi(record)].concat(this.state.sessions);
    this.state.activeSessionId = id;
    this.state.messages = [];
  }

  selectSession(id: string): void {
    if (this.state.activeSessionId === id) {
      return;
    }
    this.state.activeSessionId = id;
    this.loadMessages(id);
  }

  deleteSession(id: string): void {
    this.store.delete(id);
    this.engine.unmountIfMounted(id);
    const rest = this.state.sessions.filter((s: SessionUi) => s.id !== id);
    this.state.sessions = rest;
    if (this.state.activeSessionId === id) {
      if (rest.length > 0) {
        this.state.activeSessionId = rest[0].id;
        this.loadMessages(rest[0].id);
      } else {
        this.createDraftSession();
      }
    }
  }

  // ── 模型选择（会话粒度 + 记住最后选择） ──────────────────────

  /** 设置页保存后刷新引擎 profiles 与 needsConfig */
  onConfigChanged(): void {
    this.refreshNeedsConfig();
    this.engine.refreshProfiles();
  }

  /** 当前会话切换模型（下一条消息生效） */
  setSessionModel(provider: string, model: string): void {
    const id = this.state.activeSessionId;
    if (!id) {
      return;
    }
    const record = this.store.get(id);
    if (record === null) {
      return;
    }
    record.provider = provider;
    record.model = model;
    record.updatedAt = Date.now();
    this.store.upsert(record);

    const sessions = this.state.sessions.slice();
    for (let i = 0; i < sessions.length; i++) {
      if (sessions[i].id === id) {
        const s = sessions[i];
        s.provider = provider;
        s.model = model;
        sessions[i] = s;
        break;
      }
    }
    this.state.sessions = sessions;
    ConfigService.get().setLastSelection(provider, model);
    this.engine.applyModel(provider, model);
  }

  /** 模型选择器数据源（已配置 key 的 provider 列表） */
  usableProviders(): ProviderConfig[] {
    return ConfigService.get().listUsableProviders();
  }

  providerLabel(provider: string): string {
    const meta = PROVIDER_META[provider];
    return meta !== undefined ? meta.label : provider;
  }

  refreshNeedsConfig(): void {
    this.state.needsConfig = !ConfigService.get().hasUsableConfig();
  }

  // ── 发送消息 ────────────────────────────────────────────────

  async sendMessage(text: string): Promise<void> {
    const trimmed = text.trim();
    if (trimmed.length === 0 || this.state.isSending) {
      return;
    }
    if (!this.context) {
      return;
    }
    if (this.state.needsConfig) {
      this.pushLocalError('请先在「设置」中配置大模型 API');
      return;
    }

    const sessionId = this.state.activeSessionId ?? '';
    const record = this.store.get(sessionId);
    if (record === null) {
      return;
    }

    this.state.isSending = true;
    try {
      // 1. 引擎启动（幂等）+ 会话挂载（应用会话模型选择）
      await this.engine.ensureStarted(this.context);
      await this.engine.mountSession(record);
      this.state.engineStatus = '内核就绪';

      // 2. 用户消息（记录使用的模型）
      const userMsg = this.makeMessage(MessageRole.User, trimmed, record.provider, record.model);
      this.appendMessage(userMsg);

      // 3. 等待内核回合结束
      const outcome = await this.engine.send(trimmed);

      // 3.5 工具消息（时间序：工具调用先于 assistant 回复插入消息流）
      const todosJson = this.todosToJson(outcome);
      if (outcome.details !== undefined && outcome.details !== null) {
        for (const call of outcome.details.toolCalls) {
          this.appendMessage(this.makeToolMessage(call, todosJson));
        }
      }

      // 4. assistant 回复（记录实际模型）
      const reply = outcome.text.length > 0 ? outcome.text : this.describeReason(outcome);
      const assistantMsg = this.makeMessage(MessageRole.Assistant, reply, record.provider, record.model);
      this.appendMessage(assistantMsg);

      // 5. 持久化会话（首条消息更新标题）
      this.persistSession(record, trimmed);
    } catch (e) {
      const msg = e instanceof Error ? e.message : JSON.stringify(e);
      hilog.error(DOMAIN, TAG, 'send failed: %{public}s', msg);
      this.appendMessage(this.makeMessage(MessageRole.Assistant, '发送失败：' + msg, null, null, true));
      // 会话状态仍持久化（含用户消息）
      this.persistSession(record, trimmed);
    } finally {
      this.state.isSending = false;
    }
  }

  // ── 内部 ────────────────────────────────────────────────────

  private makeMessage(role: MessageRole, content: string,
    provider: string | null, model: string | null, isError: boolean = false): ChatMessage {
    const m = new ChatMessage();
    m.id = 'm_' + Date.now() + '_' + Math.floor(Math.random() * 1e6).toString(36);
    m.role = role;
    m.content = content;
    m.createdAt = Date.now();
    m.provider = provider;
    m.model = model;
    m.isError = isError;
    return m;
  }

  /** 工具调用 → 消息流节点（todo_write 携带整表快照） */
  private makeToolMessage(call: ToolCallEntry, todosJson: string): ChatMessage {
    const m = new ChatMessage();
    m.id = 't_' + call.seq + '_' + call.callId;
    m.role = MessageRole.Tool;
    m.content = '';
    m.createdAt = Date.now();
    m.toolName = call.name;
    m.toolStatus = call.status;
    m.toolResult = call.result ?? '';
    m.todosJson = call.name === 'todo_write' ? todosJson : '';
    return m;
  }

  /** details.todos → JSON 字符串（无快照返回空串） */
  private todosToJson(outcome: ChatOutcome): string {
    if (outcome.details === undefined || outcome.details === null) {
      return '';
    }
    const todos = outcome.details.todos;
    if (todos === null || todos === undefined) {
      return '';
    }
    const items: TodoSnapshotItem[] = [];
    for (const t of todos) {
      items.push(t);
    }
    return JSON.stringify(items);
  }

  private appendMessage(m: ChatMessage): void {
    this.state.messages = this.state.messages.concat([m]);
    const id = this.state.activeSessionId;
    if (id) {
      const sessions = this.state.sessions.slice();
      for (let i = 0; i < sessions.length; i++) {
        if (sessions[i].id === id) {
          sessions[i].messageCount = this.state.messages.length;
          break;
        }
      }
      this.state.sessions = sessions;
    }
  }

  private pushLocalError(text: string): void {
    this.appendMessage(this.makeMessage(MessageRole.Assistant, text, null, null, true));
  }

  private persistSession(record: SessionRecord, firstUserText: string): void {
    const msgs: StoredMessage[] = this.state.messages.map((m: ChatMessage) => {
      const sm: StoredMessage = {
        id: m.id,
        role: m.role === MessageRole.User ? 'user' : (m.role === MessageRole.Tool ? 'tool' : 'assistant'),
        content: m.content,
        createdAt: m.createdAt
      };
      if (m.provider !== null) {
        sm.provider = m.provider;
      }
      if (m.model !== null) {
        sm.model = m.model;
      }
      if (m.role === MessageRole.Tool) {
        sm.toolName = m.toolName;
        sm.toolStatus = m.toolStatus;
        sm.toolResult = m.toolResult;
        sm.todosJson = m.todosJson;
      }
      return sm;
    });
    record.messages = msgs;
    record.updatedAt = Date.now();
    if (record.title === '新会话' && firstUserText.length > 0) {
      record.title = SessionStore.titleFrom(firstUserText);
    }
    this.store.upsert(record);

    const sessions = this.state.sessions.slice();
    for (let i = 0; i < sessions.length; i++) {
      if (sessions[i].id === record.id) {
        sessions[i] = this.toSessionUi(record);
        break;
      }
    }
    this.state.sessions = sessions;
  }

  private loadMessages(sessionId: string): void {
    const record = this.store.get(sessionId);
    if (record === null) {
      this.state.messages = [];
      return;
    }
    this.state.messages = record.messages.map((sm: StoredMessage) => {
      const m = new ChatMessage();
      m.id = sm.id;
      m.role = sm.role === 'user' ? MessageRole.User : (sm.role === 'tool' ? MessageRole.Tool : MessageRole.Assistant);
      m.content = sm.content;
      m.createdAt = sm.createdAt;
      m.provider = sm.provider ?? null;
      m.model = sm.model ?? null;
      if (m.role === MessageRole.Tool) {
        m.toolName = sm.toolName ?? '';
        m.toolStatus = sm.toolStatus ?? 'ok';
        m.toolResult = sm.toolResult ?? '';
        m.todosJson = sm.todosJson ?? '';
      }
      return m;
    });
  }

  private toSessionUi(r: SessionRecord): SessionUi {
    const s = new SessionUi();
    s.id = r.id;
    s.title = r.title;
    s.provider = r.provider;
    s.model = r.model;
    s.createdAt = r.createdAt;
    s.updatedAt = r.updatedAt;
    s.messageCount = r.messages.length;
    return s;
  }

  private describeReason(outcome: ChatOutcome): string {
    const reason = outcome.reason;
    if (reason && reason.error && reason.error.message) {
      return reason.error.message;
    }
    return '（模型未返回内容）';
  }
}
