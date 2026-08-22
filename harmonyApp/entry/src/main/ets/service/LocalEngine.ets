import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HarnessNative, ChatOutcome, ProviderCatalogEntry, ModelInput, TodoSnapshotItem,
  CreateSessionOpts, SteerOutcome, CompactOutcome, AnswerQuestionItem, KernelJob } from './HarnessNative';
import { ConfigService } from './ConfigService';
import { SessionRecord, SessionStore } from './SessionStore';

const TAG = 'LocalEngine';
const DOMAIN = 0x0304;

/**
 * 本地内核引擎（deepseek-harness QuickJS，开箱即用）。
 * 包装 HarnessNative：引擎生命周期、会话映射、模型切换、配置热更新。
 */
/** 内核 round 事件（实时执行轨迹）：kind = thinking | tool-start | tool-end | todos | agent-start | agent-end */
export interface RoundEvent {
  kind: string;
  seq: number;
  text?: string;
  callId?: string;
  name?: string;
  args?: string;
  status?: string;
  result?: string;
  todos?: TodoSnapshotItem[];
  /** k 子代理：agent-start/agent-end 的成员标签 */
  label?: string;
  /** 子代理阶段（running/done…） */
  phase?: string;
  /** 子代理执行结果 */
  outcome?: string;
}

export class LocalEngine {
  private native: HarnessNative = HarnessNative.getInstance();
  private started: boolean = false;
  private starting: Promise<void> | null = null;
  /** 当前挂载到内核的会话 id（内核侧 this.agent — 同一时刻一个） */
  private mountedSessionId: string | null = null;
  private roundListener: ((evt: RoundEvent) => void) | null = null;
  /** k2：LLM 自动命名（title 事件 → 会话标题） */
  private titleListener: ((data: object) => void) | null = null;
  /** k3b：会话事件日志（type=log 追加 / type=log-reset 全量重写） */
  private logListener: ((data: object) => void) | null = null;
  /** k5：内核提问（kind=asked/answered/cancelled） */
  private questionListener: ((data: object) => void) | null = null;
  /** k7e：后台任务镜像（jobs 列表变更） */
  private jobsListener: ((data: object) => void) | null = null;

  /** 注册实时回合事件监听（思考段/工具起止/待办快照），在引擎启动前调用亦可 */
  setRoundListener(l: (evt: RoundEvent) => void): void {
    this.roundListener = l;
  }

  setTitleListener(l: (data: object) => void): void {
    this.titleListener = l;
  }

  setLogListener(l: (data: object) => void): void {
    this.logListener = l;
  }

  setQuestionListener(l: (data: object) => void): void {
    this.questionListener = l;
  }

  setJobsListener(l: (data: object) => void): void {
    this.jobsListener = l;
  }

  isReady(): boolean {
    return this.started && this.native.isReady();
  }

  /**
   * 启动引擎（幂等，并发安全）。
   * 无可用 provider 配置时抛错 — UI 引导去设置页。
   */
  async ensureStarted(context: common.Context): Promise<void> {
    if (this.started && this.native.isReady()) {
      return;
    }
    if (this.starting !== null) {
      await this.starting;
      return;
    }
    const job = this.doStart(context);
    this.starting = job;
    try {
      await job;
    } finally {
      this.starting = null;
    }
  }

  private async doStart(context: common.Context): Promise<void> {
    const engineConfig = ConfigService.get().buildEngineConfig(context.filesDir + '/harness');
    if (engineConfig === null) {
      throw new Error('未配置任何大模型 API — 请在设置中添加');
    }
    await this.native.init(context, engineConfig);
    this.native.setEventListener((type: string, data: object) => {
      if (type === 'round' && this.roundListener !== null) {
        this.roundListener(data as RoundEvent);
      }
    });
    this.started = true;
    hilog.info(DOMAIN, TAG, 'local engine started');
  }

  /** 设置页保存后热更新 provider profiles（无需重启引擎） */
  refreshProfiles(): void {
    if (!this.isReady()) {
      return;
    }
    const usable = ConfigService.get().listUsableProviders();
    for (const item of usable) {
      const models = item.models.length > 0 ? item.models : [item.defaultModel];
      const modelInputs: ModelInput[] = [];
      for (const m of models) {
        const input: ModelInput = { id: m };
        modelInputs.push(input);
      }
      this.native.setProviderProfile({
        provider: item.provider,
        baseUrl: item.baseUrl,
        apiKey: item.apiKey,
        models: modelInputs
      });
    }
  }

  /** provider 目录（模型选择器数据源） */
  catalog(): ProviderCatalogEntry[] {
    if (!this.isReady()) {
      return [];
    }
    return this.native.listProviders();
  }

  /**
   * 挂载会话到内核：首次发送/切换会话时调用。
   * 每次挂载都会应用会话记录的模型选择（对话粒度保存 → 恢复）。
   * k3b：进程重启后以日志种子重建内核上下文（createSession seedJson 重放）。
   */
  async mountSession(record: SessionRecord): Promise<void> {
    if (!this.isReady()) {
      throw new Error('engine not started');
    }
    this.native.setModel(record.provider, record.model, record.effort ?? '');
    if (this.mountedSessionId === record.id) {
      return;
    }
    const opts: CreateSessionOpts = { sessionId: record.id };
    const seed = SessionStore.get().readSeedJson(record.id);
    if (seed !== null && seed.length > 0) {
      opts.seedJson = seed;
    }
    await this.native.createSession(opts);
    this.mountedSessionId = record.id;
  }

  /** 发送消息（当前挂载会话 + 当前模型选择） */
  async send(text: string): Promise<ChatOutcome> {
    if (!this.isReady()) {
      throw new Error('engine not started');
    }
    return await this.native.chat(text);
  }

  /** 切换当前会话的模型+思考强度（下一条消息生效；effort 空串/undefined=跟随服务端默认） */
  applyModel(provider: string, model: string, effort?: string): void {
    if (!this.isReady()) {
      return;
    }
    this.native.setModel(provider, model, effort);
  }

  // ── k 系列内核 API 透传（busy 状态由 ViewModel 判断） ──

  /** k4 转向：进行中的回合注入补充指令；steered=false 表示引擎空闲需降级 */
  async steer(text: string): Promise<SteerOutcome> {
    if (!this.isReady()) {
      throw new Error('engine not started');
    }
    return await this.native.steer(text);
  }

  /** k3 手动压缩当前会话历史 */
  async compactNow(): Promise<CompactOutcome> {
    if (!this.isReady()) {
      throw new Error('engine not started');
    }
    return await this.native.compactNow();
  }

  /** k5 回答内核提问（qid 对应当前 pendingQuestion） */
  async answerQuestion(qid: number, answers: AnswerQuestionItem[]): Promise<void> {
    if (!this.isReady()) {
      throw new Error('engine not started');
    }
    await this.native.answerQuestion(qid, answers);
  }

  /** k6 Plan 模式开关 */
  async setPlanMode(active: boolean): Promise<void> {
    if (!this.isReady()) {
      throw new Error('engine not started');
    }
    await this.native.setPlanMode(active);
  }

  /** k7e 查询后台任务列表（UI 镜像对账） */
  async listJobs(): Promise<KernelJob[]> {
    if (!this.isReady()) {
      return [];
    }
    return await this.native.listJobs();
  }

  /** k7e 终止后台任务 */
  async killJob(id: string): Promise<void> {
    if (!this.isReady()) {
      throw new Error('engine not started');
    }
    await this.native.killJob(id);
  }

  /** k 停止当前回合（内核 abortActive + 取消在途 HTTP） */
  abortActiveRound(): void {
    this.native.abortActiveRound();
  }

  /** 当前挂载会话 id（k3b 日志路由用；null=未挂载） */
  currentMountedId(): string | null {
    return this.mountedSessionId;
  }

  /** 会话被删除时卸载（若挂载中） */
  unmountIfMounted(sessionId: string): void {
    if (this.mountedSessionId === sessionId) {
      this.mountedSessionId = null;
    }
  }

  dispose(): void {
    this.native.dispose();
    this.started = false;
    this.mountedSessionId = null;
  }
}
