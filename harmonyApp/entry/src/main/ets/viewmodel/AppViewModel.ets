import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import http from '@ohos.net.http';
import {
  UiState, ChatMessage, MessageRole, SessionUi, LiveItem,
  PendingQuestion, PendingQuestionItem, PendingOption, BgJobUi, LogLineUi,
} from '../model/UiModels';
import { LocalEngine, RoundEvent } from '../service/LocalEngine';
import { HarnessNative } from '../service/HarnessNative';
import {
  ChatOutcome, ToolCallEntry, TodoSnapshotItem,
  AnswerQuestionItem,
} from '../service/HarnessNative';
import { ConfigService, ProviderConfig } from '../service/ConfigService';
import { SessionStore, SessionRecord, StoredMessage } from '../service/SessionStore';
import { PROVIDER_META, EFFORT_OPTIONS, ReasoningEfforts } from '../common/Constants';

const TAG = 'AppViewModel';
const DOMAIN = 0x0305;

/** k5 提问回答项（UI 收集：选中选项 label 列表 + 可选自定义文本） */
export interface QuestionPick {
  selected: string[];
  custom?: string;
}

/**
 * 应用 ViewModel（本地内核 v2 + k 系列）。
 *
 * 模型选择语义：
 *  - 会话粒度：SessionRecord.provider/model/effort 保存，切换会话自动恢复
 *  - 消息粒度：StoredMessage.provider/model 记录每条消息实际使用的模型
 *  - 记住最后选择：ConfigService.setLastSelection 三元组 — 新会话默认值
 *
 * k 系列：
 *  - k2 title 事件 → LLM 自动改名
 *  - k3 compactNow 手动压缩；k3b 会话事件日志（fork/重放数据源）
 *  - k4 消息排队（busy 入队 · 回合结束自动续发 · 停止清空）+ steer 转向
 *  - k5 提问卡（question 事件 asked/answered/cancelled）
 *  - k6 Plan 模式开关；k7e 后台任务镜像 + killJob
 */
@Observed
export class AppViewModel {
  state: UiState = new UiState();
  private engine: LocalEngine = new LocalEngine();
  private context: common.Context | null = null;
  private store: SessionStore = SessionStore.get();
  /** k6 停止标志（本轮发送 finally 中检查 — 决定清空队列还是续发） */
  private stopped: boolean = false;
  // 思考/回复节流（150ms，窗口须严格小于内核 200ms 心跳防相位锁死）：万字累积全量高频
  // 覆盖会触发 liveItems 整组替换重渲染卡 UI，暂存丢帧由回合收尾 flushPendingLive 补偿
  private thinkThrottleAt: number = 0;
  private thinkPendingText: string | null = null;
  private thinkPendingTurn: number = 0;
  private thinkPendingStep: number = 0;
  private answerThrottleAt: number = 0;
  private answerPendingText: string | null = null;
  private answerPendingTurn: number = 0;
  private answerPendingStep: number = 0;
  /** A1 工具计时兜底：callId → tool-start 到达时刻（tool-end 事件缺 durationMs 时用差值计算，用毕删除） */
  private toolStartAt: Map<string, number> = new Map();
  /** A2 回合耗时跳动器：doSend 期间每秒更新 state.busySec（busy 行拼「阶段 · 字数 · m:ss」） */
  private busyTickerId: number = -1;
  private busyStartAt: number = 0;
  /** A4 运行日志行序号（全局递增，环形缓冲 splice 后仍可作 ForEach 稳定键） */
  private logSeq: number = 0;
  /** 脚本沙箱 engineId（App 级复用，-1 = 未创建；惰性初始化于首次 runScript） */
  private scriptEngineId: number = -1;

  /** Index 启动时调用 */
  init(context: common.Context): void {
    this.context = context;
    this.refreshNeedsConfig();
    this.engine.setRoundListener((evt: RoundEvent) => {
      this.applyRoundEvent(evt);
    });
    // k2：LLM 自动命名
    this.engine.setTitleListener((data: object) => {
      this.applyTitleEvent(data);
    });
    // k3b：会话事件日志 → .jsonl（按内核当前挂载会话落盘）
    this.engine.setLogListener((data: object) => {
      const mountedId = this.engine.currentMountedId();
      if (mountedId !== null) {
        this.store.onKernelLogEvent(mountedId, data);
      }
    });
    // k5：内核提问
    this.engine.setQuestionListener((data: object) => {
      this.applyQuestionEvent(data);
    });
    // k7e：后台任务镜像
    this.engine.setJobsListener((data: object) => {
      this.applyJobsEvent(data);
    });
    // A4 运行日志：桥接 onLog/[event] 镜像 → UiState 环形缓冲（最近 300 行；@Observed 数组
    // 整体替换触发重渲染，仅 LogsOverlay 读取，聊天面板不受影响）
    this.engine.setLogLineListener((line: string) => {
      const entry = new LogLineUi();
      entry.seq = ++this.logSeq;
      entry.text = line;
      const lines = this.state.logLines.slice(0);
      lines.push(entry);
      if (lines.length > 300) {
        lines.splice(0, lines.length - 300);
      }
      this.state.logLines = lines;
    });

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

  // ── 脚本沙箱（device runScript — per-instance QuickJS，App 级引擎复用） ──

  /** 惰性初始化：首次 runScript 时创建沙箱引擎 + 注册 fetch handler + 注入 DeviceBridge */
  private ensureScriptEngine(): void {
    if (this.scriptEngineId >= 0) {
      return;
    }
    if (this.context === null) {
      throw new Error('runScript: context not ready');
    }
    const native = HarnessNative.getInstance();
    const id = native.scriptEngineCreate(this.context.filesDir + '/scripts');
    if (id <= 0) {
      throw new Error('runScript: script engine create failed');
    }
    this.scriptEngineId = id;
    native.scriptEngineSetFetchHandler(id, this.scriptFetchHandler);
    native.deviceBridge().setRunScriptExecutor(
      (source: string, timeoutMs: number): Promise<Record<string, Object>> => this.runScript(source, timeoutMs));
    hilog.info(DOMAIN, TAG, 'script engine %{public}d ready', id);
  }

  /** 沙箱 fetch 上行执行（@ohos.net.http，60s 超时；完成即 fetchDone 下行结算） */
  private scriptFetchHandler = (fetchId: number, url: string, optionsJson: string): void => {
    let method: http.RequestMethod = http.RequestMethod.GET;
    let headerRecord: Record<string, string> = {};
    let bodyStr: string = '';
    try {
      const opts = JSON.parse(optionsJson) as Record<string, Object>;
      const m = opts['method'];
      if (m === 'POST') {
        method = http.RequestMethod.POST;
      } else if (m === 'PUT') {
        method = http.RequestMethod.PUT;
      } else if (m === 'DELETE') {
        method = http.RequestMethod.DELETE;
      } else if (m === 'HEAD') {
        method = http.RequestMethod.HEAD;
      }
      const h = opts['headers'];
      if (h !== undefined && h !== null) {
        headerRecord = h as Record<string, string>;
      }
      const b = opts['body'];
      if (typeof b === 'string') {
        bodyStr = b;
      }
    } catch (e) {
      // 解析失败按 GET 默认执行
    }
    const native = HarnessNative.getInstance();
    const client = http.createHttp();
    client.request(url, {
      method: method,
      header: headerRecord,
      extraData: bodyStr.length > 0 ? bodyStr : undefined,
      connectTimeout: 60000,
      readTimeout: 60000,
      expectDataType: http.HttpDataType.STRING,
    }).then((resp: http.HttpResponse) => {
      client.destroy();
      const bodyText = typeof resp.result === 'string' ? resp.result : JSON.stringify(resp.result);
      native.scriptEngineFetchDone(this.scriptEngineId, fetchId,
        resp.responseCode >= 200 && resp.responseCode < 300, bodyText);
    }).catch((e: Error) => {
      client.destroy();
      native.scriptEngineFetchDone(this.scriptEngineId, fetchId, false,
        e.message.length > 0 ? e.message : 'network error');
    });
  };

  /** 执行沙箱脚本：envelope JSON → Record（ok/value/error/durationMs/logs） */
  private async runScript(source: string, timeoutMs: number): Promise<Record<string, Object>> {
    this.ensureScriptEngine();
    const envelopeRaw = await HarnessNative.getInstance().scriptEngineRun(this.scriptEngineId, source, timeoutMs);
    return JSON.parse(envelopeRaw) as Record<string, Object>;
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
      messages: [],
      effort: def.effort ?? ''
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

  // ── 模型选择（会话粒度 + 记住最后选择，含 k19 effort） ──────

  /** 设置页保存后刷新引擎 profiles 与 needsConfig */
  onConfigChanged(): void {
    this.refreshNeedsConfig();
    this.engine.refreshProfiles();
  }

  /** 当前会话切换模型+思考强度（下一条消息生效；effort 空串=跟随服务端默认） */
  setSessionModel(provider: string, model: string, effort?: string): void {
    const id = this.state.activeSessionId;
    if (!id) {
      return;
    }
    const record = this.store.get(id);
    if (record === null) {
      return;
    }
    const cleanEffort = ReasoningEfforts.isValid(effort) ? effort as string : '';
    record.provider = provider;
    record.model = model;
    record.effort = cleanEffort;
    record.updatedAt = Date.now();
    this.store.upsert(record);

    const sessions = this.state.sessions.slice();
    for (let i = 0; i < sessions.length; i++) {
      if (sessions[i].id === id) {
        const s = sessions[i];
        s.provider = provider;
        s.model = model;
        s.effort = cleanEffort;
        sessions[i] = s;
        break;
      }
    }
    this.state.sessions = sessions;
    ConfigService.get().setLastSelection(provider, model, cleanEffort);
    this.engine.applyModel(provider, model, cleanEffort);
    // 【5】换模型后 contextWindow 变化 → 重刷水位条
    this.refreshUsageStats();
  }

  /** 当前激活会话（无会话或不匹配时 null） */
  currentSession(): SessionUi | null {
    const id = this.state.activeSessionId;
    if (id === null) {
      return null;
    }
    for (const s of this.state.sessions) {
      if (s.id === id) {
        return s;
      }
    }
    return null;
  }

  /** 模型选择器数据源（已配置 key 的 provider 列表） */
  usableProviders(): ProviderConfig[] {
    return ConfigService.get().listUsableProviders();
  }

  providerLabel(provider: string): string {
    const meta = PROVIDER_META[provider];
    return meta !== undefined ? meta.label : provider;
  }

  /** k1 思考模式选项（选择器钻取第二级数据源） */
  effortOptions() {
    return EFFORT_OPTIONS;
  }

  /** effort 值 → 显示标签（''/未知 → 默认） */
  effortLabel(effort: string): string {
    for (const opt of EFFORT_OPTIONS) {
      if (opt.value === null && effort.length === 0) {
        return opt.label;
      }
      if (opt.value === effort) {
        return opt.label;
      }
    }
    return '默认';
  }

  refreshNeedsConfig(): void {
    this.state.needsConfig = !ConfigService.get().hasUsableConfig();
  }

  // ── 发送消息（k4 排队 + k6 停止） ───────────────────────────

  async sendMessage(text: string): Promise<void> {
    const trimmed = text.trim();
    if (trimmed.length === 0) {
      return;
    }
    if (this.state.isSending) {
      // k4：busy → 入队（本轮结束自动续发）
      this.state.queuedMessages = this.state.queuedMessages.concat([trimmed]);
      this.state.toast = '⏳ 已排队（第 ' + this.state.queuedMessages.length + ' 条）';
      return;
    }
    if (!this.context) {
      return;
    }
    if (this.state.needsConfig) {
      this.pushLocalError('请先在「设置」中配置大模型 API');
      return;
    }
    await this.doSend(trimmed);
  }

  private async doSend(text: string): Promise<void> {
    const sessionId = this.state.activeSessionId ?? '';
    const record = this.store.get(sessionId);
    if (record === null) {
      return;
    }
    const ctx = this.context;
    if (ctx === null) {
      return;
    }
    this.stopped = false;
    this.state.isSending = true;
    this.state.liveItems = [];
    this.state.busyHint = '思考中…';
    this.startBusyTicker();
    const roundStart = Date.now();
    try {
      // 旧会话的 provider 可能已无可用 key（清空 API/换设备后重开历史会话）：
      // 未注册 adapter 的 provider 发消息会报 no adapter registered — 回落默认可用选择
      const cfgSvc = ConfigService.get();
      if (cfgSvc.getConfig(record.provider).apiKey.trim().length === 0) {
        const def = cfgSvc.getDefaultSelection();
        record.provider = def.provider;
        record.model = def.model;
        record.effort = def.effort;
        this.store.upsert(record);
      }
      // 1. 引擎启动（幂等）+ 会话挂载（应用会话模型选择；k3b 带日志种子重放）
      await this.engine.ensureStarted(ctx);
      await this.engine.mountSession(record);
      this.state.engineStatus = '内核就绪';

      // 2. 用户消息（记录使用的模型）
      const userMsg = this.makeMessage(MessageRole.User, text, record.provider, record.model);
      this.appendMessage(userMsg);

      // 3. 等待内核回合结束
      const outcome = await this.engine.send(text);

      // 3.5 planActive 同步（k8）
      if (outcome.details !== undefined && outcome.details !== null) {
        this.state.planActive = outcome.details.planActive;
      }

      // 3.6 工具消息（实时面板已展示时不重复插入消息流）
      const todosJson = this.todosToJson(outcome);
      if (this.state.liveItems.length === 0
        && outcome.details !== undefined && outcome.details !== null) {
        for (const call of outcome.details.toolCalls) {
          this.appendMessage(this.makeToolMessage(call, todosJson));
        }
      }

      // 4. assistant 回复（记录实际模型与执行轨迹）
      // 错误判定：reason.error / max-tokens 截断 / 空回复兜底 → isError（错误色 + 重试入口，不入评分）
      let failed = false;
      let reply = outcome.text;
      const reason = outcome.reason;
      if (reason !== undefined && reason !== null) {
        if (reason.error !== undefined && reason.error !== null) {
          failed = true;
        }
        if (reason.kind === 'max-tokens') {
          failed = true;
        }
      }
      if (reply.length === 0) {
        reply = this.describeReason(outcome);
        failed = true;
      }
      // token 用量 surfaced：内核 extractDetails 的 details.usage（无 = 0 不展示）
      const usage = outcome.details !== undefined && outcome.details !== null ? outcome.details.usage : null;
      const assistantMsg = this.makeMessage(MessageRole.Assistant, reply, record.provider, record.model, failed);
      assistantMsg.durationMs = Date.now() - roundStart;
      if (usage !== null && usage !== undefined) {
        assistantMsg.inTok = usage.inputTokens;
        assistantMsg.outTok = usage.outputTokens;
      }
      assistantMsg.traceJson = this.traceJson();
      this.appendMessage(assistantMsg);

      // 5. 持久化会话（首条消息更新标题）
      this.persistSession(record, text);
    } catch (e) {
      const msg = e instanceof Error ? e.message : JSON.stringify(e);
      hilog.error(DOMAIN, TAG, 'send failed: %{public}s', msg);
      // k6：主动停止不算错误（落一条中性提示）
      const errMsg = this.stopped
        ? '已停止本轮'
        : '发送失败：' + msg;
      const m = this.makeMessage(MessageRole.Assistant, errMsg, null, null, !this.stopped);
      m.durationMs = Date.now() - roundStart;
      m.traceJson = this.traceJson();
      this.appendMessage(m);
      // 会话状态仍持久化（含用户消息）
      this.persistSession(record, text);
    } finally {
      this.flushPendingLive();
      this.state.isSending = false;
      this.state.busyHint = '';
      this.stopBusyTicker();
      // 【5】回合结束刷新 token 水位（fire-and-forget，不阻塞排队续发）
      this.refreshUsageStats();
      if (this.stopped) {
        // k6：停止 → 清空排队
        const n = this.state.queuedMessages.length;
        this.state.queuedMessages = [];
        this.state.toast = n > 0 ? '已停止本轮（清空 ' + n + ' 条排队）' : '已停止本轮';
      } else if (this.state.queuedMessages.length > 0) {
        // k4：自然结束 → 自动续发队首
        const next = this.state.queuedMessages[0];
        this.state.queuedMessages = this.state.queuedMessages.slice(1);
        this.doSend(next);
      }
    }
  }

  // ── k 系列动作 ──────────────────────────────────────────────

  /** 【5】刷新 token 水位条（回合结束/换模型后调；失败静默不干扰主流程） */
  private async refreshUsageStats(): Promise<void> {
    try {
      const s = await this.engine.usageStats();
      if (s === null || s.ok !== true) {
        return;
      }
      this.state.usageRatio = s.usageRatio;
      this.state.usageText = this.fmtTokens(s.totalTokens) + '/' + this.fmtTokens(s.contextWindow);
      this.state.usageCold = s.baseline === 'none';
    } catch (e) {
      // 冷启动前（引擎未 boot/无会话）查询失败属正常，保持现值
    }
  }

  /** 【5】1024 进制用量文本：1023 → "1023"；12615 → "12.3k"；65536 → "64k" */
  private fmtTokens(v: number): string {
    if (v < 1024) {
      return String(v);
    }
    const k = v / 1024;
    const s = k >= 100 ? String(Math.round(k)) : k.toFixed(1).replace('.0', '');
    return s + 'k';
  }

  /** k4 转向：进行中的回合注入补充指令（下一 step 边界生效） */
  async steerMessage(text: string): Promise<void> {
    const trimmed = text.trim();
    if (trimmed.length === 0) {
      return;
    }
    if (!this.state.isSending || !this.engine.isReady()) {
      this.state.toast = '当前无进行中的回合 — 请直接发送';
      return;
    }
    try {
      const res = await this.engine.steer(trimmed);
      if (res.steered) {
        const userMsg = this.makeMessage(MessageRole.User, trimmed, null, null);
        userMsg.steered = true;
        this.appendMessage(userMsg);
        const item = new LiveItem();
        item.kind = 'steer';
        item.text = trimmed;
        this.state.liveItems = this.state.liveItems.concat([item]);
        this.state.toast = '⚡ 已转向 · 下一 step 注入';
        // 持久化（steered 标记落盘）
        const id = this.state.activeSessionId;
        if (id) {
          const rec = this.store.get(id);
          if (rec !== null) {
            this.persistSession(rec, '');
          }
        }
      } else {
        this.state.toast = '内核空闲 — 转向未生效，请直接发送';
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : JSON.stringify(e);
      hilog.error(DOMAIN, TAG, 'steer failed: %{public}s', msg);
      this.state.toast = '转向失败';
    }
  }

  /** k6 停止当前回合（内核 abortActive + 在途 HTTP 取消 + 清空排队） */
  stopRound(): void {
    if (!this.state.isSending) {
      return;
    }
    this.stopped = true;
    this.engine.abortActiveRound();
  }

  /** k3 手动压缩当前会话历史 */
  async runCompact(): Promise<void> {
    if (this.state.isSending) {
      this.state.toast = '请等待当前回合结束';
      return;
    }
    if (!this.engine.isReady()) {
      this.state.toast = '内核未启动 — 发送一条消息后再压缩';
      return;
    }
    try {
      const res = await this.engine.compactNow();
      if (res.status === 'ok') {
        this.state.toast = '已压缩 ' + res.shadowedCount + ' 个事件 · 约省 ' + res.shadowedTokens + ' tokens';
      } else {
        this.state.toast = '暂无可压缩的历史';
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : JSON.stringify(e);
      hilog.error(DOMAIN, TAG, 'compact failed: %{public}s', msg);
      this.state.toast = '压缩失败';
    }
  }

  /** k8 Plan 模式开关（与内核 setPlanMode 同步） */
  async togglePlan(): Promise<void> {
    if (!this.engine.isReady()) {
      this.state.toast = '内核未启动 — 发送一条消息后再切换';
      return;
    }
    const next = !this.state.planActive;
    try {
      await this.engine.setPlanMode(next);
      this.state.planActive = next;
      this.state.toast = next ? '🧭 计划模式已开启' : '🧭 计划模式已关闭';
    } catch (e) {
      const msg = e instanceof Error ? e.message : JSON.stringify(e);
      hilog.error(DOMAIN, TAG, 'setPlanMode failed: %{public}s', msg);
      this.state.toast = '计划模式切换失败';
    }
  }

  /** 【6】/plan on|off 显式设定（k8 同款守卫与反馈） */
  async setPlan(active: boolean): Promise<void> {
    if (!this.engine.isReady()) {
      this.state.toast = '内核未启动 — 发送一条消息后再切换';
      return;
    }
    try {
      await this.engine.setPlanMode(active);
      this.state.planActive = active;
      this.state.toast = active ? '🧭 计划模式已开启' : '🧭 计划模式已关闭';
    } catch (e) {
      const msg = e instanceof Error ? e.message : JSON.stringify(e);
      hilog.error(DOMAIN, TAG, 'setPlanMode failed: %{public}s', msg);
      this.state.toast = '计划模式切换失败';
    }
  }

  /** k5 提交提问回答（qid 对应当前 pendingQuestion） */
  async answerPendingQuestion(picks: Record<string, QuestionPick>): Promise<void> {
    const pq = this.state.pendingQuestion;
    if (pq === null) {
      return;
    }
    const answers: AnswerQuestionItem[] = [];
    for (const q of pq.questions) {
      const pick = picks[q.id.toString()];
      const item: AnswerQuestionItem = {
        id: q.id,
        selected: pick !== undefined ? pick.selected : []
      };
      if (pick !== undefined && pick.custom !== undefined && pick.custom.length > 0) {
        item.custom = pick.custom;
      }
      answers.push(item);
    }
    this.state.pendingQuestion = null;
    this.state.busyHint = '';
    try {
      await this.engine.answerQuestion(pq.qid, answers);
      this.state.toast = '已提交回答';
    } catch (e) {
      const msg = e instanceof Error ? e.message : JSON.stringify(e);
      hilog.error(DOMAIN, TAG, 'answerQuestion failed: %{public}s', msg);
      this.state.toast = '回答提交失败';
    }
  }

  /** 会话手动重命名（标题不再只等 LLM 命名） */
  renameSession(id: string, title: string): void {
    const clean = title.trim();
    if (clean.length === 0) {
      return;
    }
    const record = this.store.get(id);
    if (record === null) {
      return;
    }
    record.title = clean;
    this.store.upsert(record);
    const sessions = this.state.sessions.slice();
    for (let i = 0; i < sessions.length; i++) {
      if (sessions[i].id === id) {
        sessions[i] = this.toSessionUi(record);
        break;
      }
    }
    this.state.sessions = sessions;
    this.state.toast = '已重命名';
  }

  /** 错误重试：重发该错误消息之前最近一条 user 消息（重新问一遍，历史保留）。 */
  retryFromMessage(messageId: string): void {
    if (this.state.isSending) {
      return;
    }
    const idx = this.state.messages.findIndex((m: ChatMessage) => m.id === messageId);
    if (idx < 0) {
      return;
    }
    let text = '';
    for (let i = idx - 1; i >= 0; i--) {
      if (this.state.messages[i].role === MessageRole.User) {
        text = this.state.messages[i].content;
        break;
      }
    }
    if (text.trim().length === 0) {
      this.state.toast = '未找到可重试的提问';
      return;
    }
    this.sendMessage(text);
  }

  /** k5 跳过提问：全空 selected 提交（等价"不选直接交卷"，内核按空答案继续）。 */
  async skipPendingQuestion(): Promise<void> {
    await this.answerPendingQuestion({});
  }

  /** 清空当前会话消息（保留会话壳与 provider 选择，重新开始）。 */
  clearCurrentMessages(): void {
    const sessionId = this.state.activeSessionId ?? '';
    const record = this.store.get(sessionId);
    if (record === null || record.messages.length === 0) {
      return;
    }
    record.messages = [];
    this.store.upsert(record);
    this.state.messages = [];
    const sessions = this.state.sessions.slice();
    for (let i = 0; i < sessions.length; i++) {
      if (sessions[i].id === sessionId) {
        sessions[i].messageCount = 0;
        break;
      }
    }
    this.state.sessions = sessions;
    this.state.toast = '已清空';
  }

  /** k7e 终止后台任务 */
  async killBgJob(id: string): Promise<void> {
    try {
      await this.engine.killJob(id);
      this.state.toast = '已请求终止后台任务';
    } catch (e) {
      const msg = e instanceof Error ? e.message : JSON.stringify(e);
      hilog.error(DOMAIN, TAG, 'killJob failed: %{public}s', msg);
      this.state.toast = '终止失败';
    }
  }

  /** k6 fork：从指定消息分叉新会话（日志截断重放，无日志降级为仅消息视图） */
  forkFromMessage(messageId: string): void {
    const sessionId = this.state.activeSessionId ?? '';
    const record = this.store.get(sessionId);
    if (record === null) {
      return;
    }
    const idx = this.state.messages.findIndex((m: ChatMessage) => m.id === messageId);
    if (idx < 0) {
      return;
    }
    // 目标 user 回合序号：截止该消息（含）的 user 消息数
    let userTurn = 0;
    for (let i = 0; i <= idx; i++) {
      if (this.state.messages[i].role === MessageRole.User) {
        userTurn++;
      }
    }
    const newId = SessionStore.newId();
    let replayed = false;
    if (userTurn > 0) {
      const seed = this.store.truncateLogAtUserTurn(sessionId, userTurn);
      if (seed !== null) {
        replayed = this.store.writeSeedText(newId, seed);
      }
    }
    if (!replayed && idx === this.state.messages.length - 1) {
      // 末尾消息 fork：直接全量复制日志
      replayed = this.store.copyLogTo(sessionId, newId);
    }
    const kept = this.state.messages.slice(0, idx + 1);
    const storedList: StoredMessage[] = [];
    for (const m of kept) {
      storedList.push(this.toStoredMessage(m));
    }
    const newRecord: SessionRecord = {
      id: newId,
      title: record.title + ' ⑂',
      provider: record.provider,
      model: record.model,
      createdAt: Date.now(),
      updatedAt: Date.now(),
      messages: storedList,
      effort: record.effort
    };
    this.store.upsert(newRecord);
    this.state.sessions = [this.toSessionUi(newRecord)].concat(this.state.sessions);
    this.state.activeSessionId = newId;
    this.state.messages = kept;
    this.state.toast = replayed
      ? '已分支（内核上下文已复刻）'
      : '已分支（仅消息视图 · 该会话无事件日志，内核上下文无法复刻）';
  }

  /** k6 消息评分（同值再点取消；1 赞 / -1 踩 / 0 无） */
  setRating(messageId: string, value: number): void {
    const msgs = this.state.messages.slice();
    let changed = false;
    for (let i = 0; i < msgs.length; i++) {
      if (msgs[i].id === messageId) {
        const m = msgs[i];
        m.rating = m.rating === value ? 0 : value;
        msgs[i] = m;
        changed = true;
        break;
      }
    }
    if (!changed) {
      return;
    }
    this.state.messages = msgs;
    const id = this.state.activeSessionId;
    if (id) {
      const rec = this.store.get(id);
      if (rec !== null) {
        rec.messages = this.state.messages.map((m: ChatMessage) => this.toStoredMessage(m));
        rec.updatedAt = Date.now();
        this.store.upsert(rec);
      }
    }
  }

  // ── 内核事件处理 ────────────────────────────────────────────

  /** k2：title 事件 → 会话自动改名（LLM 命名优先于首条消息截断） */
  private applyTitleEvent(data: object): void {
    const o = data as Record<string, Object>;
    const title = String(o['title'] ?? '').trim();
    if (title.length === 0) {
      return;
    }
    const id = this.state.activeSessionId;
    if (!id) {
      return;
    }
    const record = this.store.get(id);
    if (record === null) {
      return;
    }
    record.title = title;
    record.updatedAt = Date.now();
    this.store.upsert(record);
    const sessions = this.state.sessions.slice();
    for (let i = 0; i < sessions.length; i++) {
      if (sessions[i].id === id) {
        const s = sessions[i];
        s.title = title;
        sessions[i] = s;
        break;
      }
    }
    this.state.sessions = sessions;
  }

  /** k5：question 事件 → 提问卡（kind=asked 弹出 / answered|cancelled 收起） */
  private applyQuestionEvent(data: object): void {
    const o = data as Record<string, Object>;
    const kind = String(o['kind'] ?? '');
    if (kind !== 'asked') {
      this.state.pendingQuestion = null;
      this.state.busyHint = '';
      return;
    }
    const pq = new PendingQuestion();
    pq.qid = Number(o['qid'] ?? 0);
    let planReview = false;
    const rawQs = o['questions'];
    if (Array.isArray(rawQs)) {
      for (const raw of rawQs as Object[]) {
        const q = raw as Record<string, Object>;
        const item = new PendingQuestionItem();
        item.id = Number(q['id'] ?? 0);
        item.question = String(q['question'] ?? '');
        item.detail = String(q['detail'] ?? '');
        item.header = String(q['header'] ?? '');
        item.multiSelect = q['multiSelect'] === true;
        const rawOpts = q['options'];
        if (Array.isArray(rawOpts)) {
          for (const rawOpt of rawOpts as Object[]) {
            const optRec = rawOpt as Record<string, Object>;
            const po = new PendingOption();
            po.label = String(optRec['label'] ?? '');
            po.description = String(optRec['description'] ?? '');
            const intentRaw = optRec['intent'];
            if (intentRaw !== null && intentRaw !== undefined) {
              const intent = intentRaw as Record<string, Object>;
              if (intent['approve'] === true || String(intent['kind'] ?? '') === 'plan-review') {
                po.isApprove = true;
                planReview = true;
              }
            }
            item.options.push(po);
          }
        }
        if (item.options.length > 0) {
          pq.questions.push(item);
        }
      }
    }
    if (pq.questions.length === 0) {
      return;
    }
    pq.planReview = planReview;
    this.state.pendingQuestion = pq;
    this.state.busyHint = '等待你的回答…';
  }

  /** k7e：jobs 事件 → 后台任务镜像（只保留 running/stopping） */
  private applyJobsEvent(data: object): void {
    const o = data as Record<string, Object>;
    const raw = o['jobs'];
    const jobs: BgJobUi[] = [];
    if (Array.isArray(raw)) {
      for (const item of raw as Object[]) {
        const j = item as Record<string, Object>;
        const status = String(j['status'] ?? '');
        if (status === 'running' || status === 'stopping') {
          const ui = new BgJobUi();
          ui.id = String(j['id'] ?? '');
          ui.label = String(j['label'] ?? '');
          ui.status = status;
          jobs.push(ui);
        }
      }
    }
    this.state.bgJobs = jobs;
  }

  /** 把内核 round 事件归并进实时活动列表（思考段/工具行/待办快照/转向/子代理），驱动实时面板。 */
  private applyRoundEvent(evt: RoundEvent): void {
    if (!this.state.isSending) {
      return;
    }
    const items = this.state.liveItems.slice();
    if (evt.kind === 'thinking') {
      // 内核 emit 段内累积全量（64 字/200ms 节流）：同 (turn,step) 幂等覆盖，跨键开新段。
      // 倒序查找而非只看尾元素——assistant/message 兜底发来时段后可能已有工具行；
      // 宿主 150ms 节流（窗口严格小于内核心跳，防相位锁死），丢帧由 flushPendingLive 补偿
      const text = evt.text ?? '';
      const turn = evt.turn ?? 0;
      const step = evt.step ?? 0;
      if (text.length === 0) {
        return;
      }
      const now = Date.now();
      if (now - this.thinkThrottleAt < 150) {
        this.thinkPendingText = text;
        this.thinkPendingTurn = turn;
        this.thinkPendingStep = step;
        return;
      }
      this.thinkThrottleAt = now;
      let idx = -1;
      for (let i = items.length - 1; i >= 0; i--) {
        if (items[i].kind === 'think' && items[i].turn === turn && items[i].step === step) {
          idx = i;
          break;
        }
      }
      if (idx >= 0) {
        if (text.length >= items[idx].text.length) {
          const updated = this.cloneItem(items[idx]);
          updated.text = text;
          items[idx] = updated;
        }
      } else {
        const item = new LiveItem();
        item.kind = 'think';
        item.seq = evt.seq;
        item.turn = turn;
        item.step = step;
        item.text = text;
        items.push(item);
      }
      this.state.busyHint = '思考中 · ' + this.liveChars(items, 'think') + ' 字';
    } else if (evt.kind === 'answer') {
      // 流式答案正文：与思考同构按 (turn,step) 分段累积覆盖 + 150ms 节流（Answer 不入
      // trace，最终 assistant 正文即完整形态）
      const text = evt.text ?? '';
      const turn = evt.turn ?? 0;
      const step = evt.step ?? 0;
      if (text.length === 0) {
        return;
      }
      const now = Date.now();
      if (now - this.answerThrottleAt < 150) {
        this.answerPendingText = text;
        this.answerPendingTurn = turn;
        this.answerPendingStep = step;
        return;
      }
      this.answerThrottleAt = now;
      let idx = -1;
      for (let i = items.length - 1; i >= 0; i--) {
        if (items[i].kind === 'answer' && items[i].turn === turn && items[i].step === step) {
          idx = i;
          break;
        }
      }
      if (idx >= 0) {
        if (text.length >= items[idx].text.length) {
          const updated = this.cloneItem(items[idx]);
          updated.text = text;
          items[idx] = updated;
        }
      } else {
        const item = new LiveItem();
        item.kind = 'answer';
        item.seq = evt.seq;
        item.turn = turn;
        item.step = step;
        item.text = text;
        items.push(item);
      }
      this.state.busyHint = '撰写回复 · ' + this.liveChars(items, 'answer') + ' 字';
    } else if (evt.kind === 'tool-start') {
      const item = new LiveItem();
      item.kind = 'tool';
      item.callId = evt.callId ?? '';
      item.name = evt.name ?? 'tool';
      item.args = evt.args ?? '';
      item.status = 'running';
      if (item.callId !== '') {
        this.toolStartAt.set(item.callId, Date.now());
      }
      items.push(item);
      this.state.busyHint = '执行 ' + item.name + '…';
    } else if (evt.kind === 'tool-end') {
      const callId = evt.callId ?? '';
      let merged = false;
      for (let i = items.length - 1; i >= 0; i--) {
        if (items[i].kind === 'tool' && items[i].callId === callId) {
          const updated = this.cloneItem(items[i]);
          updated.status = evt.status ?? 'ok';
          updated.result = evt.result ?? '';
          updated.durationMs = this.resolveToolDuration(callId, evt.durationMs);
          items[i] = updated;
          merged = true;
          break;
        }
      }
      if (!merged && callId === '') {
        // 兜底：事件缺 callId 时归并到最后一个运行中的工具（顺序执行场景等价）
        for (let i = items.length - 1; i >= 0; i--) {
          if (items[i].kind === 'tool' && items[i].status === 'running') {
            const updated = this.cloneItem(items[i]);
            updated.status = evt.status ?? 'ok';
            updated.result = evt.result ?? '';
            updated.durationMs = this.resolveToolDuration(items[i].callId, evt.durationMs);
            items[i] = updated;
            break;
          }
        }
      }
    } else if (evt.kind === 'todos') {
      const item = new LiveItem();
      item.kind = 'todos';
      item.todos = (evt.todos ?? []).slice();
      let replaced = false;
      for (let i = items.length - 1; i >= 0; i--) {
        if (items[i].kind === 'todos') {
          items[i] = item;
          replaced = true;
          break;
        }
      }
      if (!replaced) {
        items.push(item);
      }
    } else if (evt.kind === 'agent-start') {
      // k 子代理开始（🤖 缩进行）
      const item = new LiveItem();
      item.kind = 'subagent';
      item.name = evt.label ?? '子代理';
      item.status = evt.phase ?? 'running';
      items.push(item);
      this.state.busyHint = '子代理 ' + item.name + '…';
    } else if (evt.kind === 'agent-end') {
      // k 子代理结束（按 label 匹配最后一个 subagent 更新 phase/outcome）
      const label = evt.label ?? '';
      for (let i = items.length - 1; i >= 0; i--) {
        if (items[i].kind === 'subagent' && (label === '' || items[i].name === label)) {
          const updated = this.cloneItem(items[i]);
          updated.status = evt.phase ?? 'done';
          updated.result = evt.outcome ?? '';
          items[i] = updated;
          break;
        }
      }
    }
    this.state.liveItems = items;
  }

  /** 节流丢帧补偿：把 150ms 窗口内暂存的思考/回复文本落进实时面板（回合收尾保证最终完整）。 */
  private flushPendingLive(): void {
    const tText = this.thinkPendingText;
    if (tText !== null) {
      this.thinkPendingText = null;
      this.upsertLiveItem('think', tText, this.thinkPendingTurn, this.thinkPendingStep, 0);
    }
    const aText = this.answerPendingText;
    if (aText !== null) {
      this.answerPendingText = null;
      this.upsertLiveItem('answer', aText, this.answerPendingTurn, this.answerPendingStep, 0);
    }
  }

  /** 按 (turn,step) 幂等 upsert 思考/回复段（内核事件携带段内累积全量，同键且更长时覆盖）。 */
  private upsertLiveItem(kind: string, text: string, turn: number, step: number, seq: number): void {
    const items = this.state.liveItems.slice();
    let idx = -1;
    for (let i = items.length - 1; i >= 0; i--) {
      if (items[i].kind === kind && items[i].turn === turn && items[i].step === step) {
        idx = i;
        break;
      }
    }
    if (idx >= 0) {
      if (text.length >= items[idx].text.length) {
        const updated = this.cloneItem(items[idx]);
        updated.text = text;
        items[idx] = updated;
        this.state.liveItems = items;
      }
    } else {
      const item = new LiveItem();
      item.kind = kind;
      item.seq = seq;
      item.turn = turn;
      item.step = step;
      item.text = text;
      items.push(item);
      this.state.liveItems = items;
    }
  }

  /** A1 工具耗时：优先事件 durationMs（内核上报），缺省用 tool-start 时刻差值兜底；用毕清理防泄漏 */
  private resolveToolDuration(callId: string, evtMs?: number): number {
    const started = this.toolStartAt.get(callId);
    this.toolStartAt.delete(callId);
    if (evtMs !== undefined && evtMs > 0) {
      return evtMs;
    }
    return started !== undefined ? Date.now() - started : 0;
  }

  /** A2 实时字数统计（think/answer 各段文本长度求和，驱动「思考中 · N 字」阶段文案） */
  private liveChars(items: LiveItem[], kind: string): number {
    let n = 0;
    for (const it of items) {
      if (it.kind === kind) {
        n += it.text.length;
      }
    }
    return n;
  }

  /** A2 回合耗时跳动器：doSend 开始启动（幂等）；finally 停止，排队续发按新回合重新计秒 */
  private startBusyTicker(): void {
    if (this.busyTickerId >= 0) {
      return;
    }
    this.state.busySec = 0;
    this.busyStartAt = Date.now();
    this.busyTickerId = setInterval(() => {
      this.state.busySec = Math.floor((Date.now() - this.busyStartAt) / 1000);
    }, 1000);
  }

  private stopBusyTicker(): void {
    if (this.busyTickerId >= 0) {
      clearInterval(this.busyTickerId);
      this.busyTickerId = -1;
    }
    this.state.busySec = 0;
  }

  /** A4 清空运行日志查看器缓冲（内核仍继续产出新行） */
  clearLogs(): void {
    this.state.logLines = [];
  }

  private cloneItem(src: LiveItem): LiveItem {
    const item = new LiveItem();
    item.kind = src.kind;
    item.seq = src.seq;
    item.text = src.text;
    item.callId = src.callId;
    item.name = src.name;
    item.args = src.args;
    item.status = src.status;
    item.result = src.result;
    item.durationMs = src.durationMs;
    item.todos = src.todos.slice();
    return item;
  }

  /** 序列化实时活动列表为轨迹 JSON（与 Android 端 parseTrace 同格式）。 */
  private traceJson(): string {
    this.flushPendingLive();
    const items = this.state.liveItems;
    if (items.length === 0) {
      return '';
    }
    const arr: Record<string, Object>[] = [];
    for (const it of items) {
      if (it.kind === 'think') {
        arr.push({ 'k': 'think', 't': it.text, 's': it.step, 'u': it.turn });
      } else if (it.kind === 'tool') {
        arr.push({ 'k': 'tool', 'n': it.name, 'a': it.args, 's': it.status, 'r': it.result, 'ms': it.durationMs });
      } else if (it.kind === 'steer') {
        arr.push({ 'k': 'steer', 't': it.text });
      } else if (it.kind === 'subagent') {
        arr.push({ 'k': 'subagent', 'l': it.name, 'p': it.status, 'o': it.result });
      } else if (it.kind === 'answer') {
        // 流式答案正文已随最终 assistant 消息持久化，轨迹不重复记录
        continue;
      } else {
        const l: string[][] = [];
        for (const t of it.todos) {
          l.push([t.content, t.status]);
        }
        arr.push({ 'k': 'todos', 'l': l });
      }
    }
    return JSON.stringify(arr);
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

  /** ChatMessage → StoredMessage（含 k4 steered / k6 rating） */
  private toStoredMessage(m: ChatMessage): StoredMessage {
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
    if (m.role === MessageRole.Assistant && m.durationMs > 0) {
      sm.durationMs = m.durationMs;
    }
    if (m.role === MessageRole.Assistant && m.traceJson.length > 0) {
      sm.traceJson = m.traceJson;
    }
    if (m.role === MessageRole.Assistant && m.isError) {
      sm.isError = 1;
    }
    if (m.role === MessageRole.Assistant && m.inTok > 0) {
      sm.inTok = m.inTok;
    }
    if (m.role === MessageRole.Assistant && m.outTok > 0) {
      sm.outTok = m.outTok;
    }
    if (m.role === MessageRole.User && m.steered) {
      sm.steered = 1;
    }
    if (m.rating !== 0) {
      sm.rating = m.rating;
    }
    return sm;
  }

  private persistSession(record: SessionRecord, firstUserText: string): void {
    record.messages = this.state.messages.map((m: ChatMessage) => this.toStoredMessage(m));
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
      if (m.role === MessageRole.Assistant) {
        m.durationMs = sm.durationMs ?? 0;
        m.traceJson = sm.traceJson ?? '';
        m.isError = (sm.isError ?? 0) === 1;
        m.inTok = sm.inTok ?? 0;
        m.outTok = sm.outTok ?? 0;
      }
      m.steered = (sm.steered ?? 0) === 1;
      m.rating = sm.rating ?? 0;
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
    s.effort = r.effort ?? '';
    return s;
  }

  private describeReason(outcome: ChatOutcome): string {
    const reason = outcome.reason;
    if (reason && reason.error && reason.error.message) {
      return reason.error.message;
    }
    if (reason && reason.kind === 'max-tokens') {
      return '（模型输出达到长度上限被截断：深度思考占满了输出额度。可简化问题、降低思考强度，或换用输出额度更大的模型后重试）';
    }
    return '（模型未返回内容）';
  }
}
