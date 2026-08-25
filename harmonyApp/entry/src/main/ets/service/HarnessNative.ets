/**
 * HarnessNative.ets — libharness_napi.so 的 ArkTS 封装（v2 异步驱动）
 *
 * 职责：
 *   1. 从 rawfile 加载 harness.js → native init（带 onFetch/onCallSettled 回调）
 *   2. callFunc 的 Promise 化（callId → onCallSettled 结算；含同步 settle 早到缓冲）
 *   3. HttpBridge 装配（QuickJS fetch → ohos http 流式执行）
 *   4. DeviceBridge 装配（QuickJS __harnessDeviceCall → 通讯录/日历/剪贴板/文件/相册/邮件/拨号/相机/录音/应用）
 *   5. 引擎高层 API：engineInit / createSession / chat / setModel / listProviders ...
 */
import harness from 'libharness_napi.so';
import { common } from '@kit.AbilityKit';
import util from '@ohos.util';
import { HttpBridge } from './HttpBridge';
import { DeviceBridge } from './DeviceBridge';

// ── 与 harness-entry.ts 对齐的类型 ──────────────────────────

export interface ModelInput {
  id: string;
  name?: string;
}

export interface ProviderProfileInput {
  provider: string;
  baseUrl: string;
  apiKey: string;
  models: ModelInput[];
  maxTokens?: number;
  contextWindow?: number;
}

export interface EngineConfig {
  cwd?: string;
  providers: ProviderProfileInput[];
  defaultProvider: string;
  defaultModel: string;
}

export interface ChatOutcome {
  sessionId: string;
  text: string;
  reason?: ChatReason;
  details?: TurnDetails;
}

/** 单次工具调用（tool/call + tool/result 配对） */
export interface ToolCallEntry {
  seq: number;
  callId: string;
  name: string;
  args: string;
  status: string;
  result?: string;
}

/** todo 快照项 */
export interface TodoSnapshotItem {
  content: string;
  status: string;
}

/** 子代理/workflow 成员 */
export interface SubagentEntry {
  label: string;
  phase?: string;
  outcome?: string;
}

export interface TurnUsage {
  inputTokens: number;
  outputTokens: number;
}

/** 回合执行细节（内联工具气泡 + 轨迹视图数据源） */
export interface TurnDetails {
  toolCalls: ToolCallEntry[];
  todos: TodoSnapshotItem[] | null;
  subagents: SubagentEntry[];
  planActive: boolean;
  usage: TurnUsage | null;
}

export interface ChatReason {
  kind?: string;
  error?: ChatError;
}

export interface ChatError {
  code?: string;
  message?: string;
}

export interface ModelSelection {
  provider: string;
  model: string;
}

export interface CreateSessionOpts {
  sessionId: string;
  /** k3b：种子事件流（.jsonl 全文 — 内核重放历史；缺省=全新会话） */
  seedJson?: string;
}

export interface ChatOpts {
  text: string;
}

/** k4 转向结果：steered=false 表示引擎空闲未注入（UI 降级提示） */
export interface SteerOutcome {
  steered: boolean;
}

/** k3 手动压缩结果 */
export interface CompactOutcome {
  /** 'ok' | 'noop' */
  status: string;
  shadowedCount: number;
  shadowedTokens: number;
}

/** k5 提问回答项 */
export interface AnswerQuestionItem {
  id: number;
  selected: string[];
  custom?: string;
}

export interface AnswerQuestionOpts {
  qid: number;
  answers: AnswerQuestionItem[];
}

export interface SetPlanModeOpts {
  active: boolean;
}

/** k7e 后台任务 */
export interface KernelJob {
  id: string;
  label: string;
  /** 'running' | 'stopping' | 'done' … */
  status: string;
}

export class NoArgs {
}

export interface KillJobOpts {
  id: string;
}

/** k1 setModel 参数（effort 非空才带 reasoningEffort，空=跟随服务端默认） */
export interface SetModelInput {
  provider: string;
  model: string;
  reasoningEffort?: string;
}

export interface ProviderCatalogEntry {
  provider: string;
  baseUrl: string;
  hasKey: boolean;
  models: string[];
}

// ── 内部类型 ────────────────────────────────────────────────

interface CallEnvelope {
  async: boolean;
  callId?: number;
  result?: object | string | null;
}

interface PendingCall {
  resolve: (v: object | string | null) => void;
  reject: (e: Error) => void;
}

interface EarlySettle {
  ok: boolean;
  json: string;
}

interface NativeCallbacks {
  onLog: (stream: string, chunk: string) => void;
  onEvent: (eventJson: string) => void;
  onFetch: (fetchId: number, requestJson: string) => void;
  onCallSettled: (callId: number, ok: boolean, json: string) => void;
  onDevice: (deviceId: number, requestJson: string) => void;
}

export type EngineEventListener = (type: string, data: object) => void;

export class HarnessNative {
  private static _instance: HarnessNative | null = null;

  static getInstance(): HarnessNative {
    if (!HarnessNative._instance) {
      HarnessNative._instance = new HarnessNative();
    }
    return HarnessNative._instance;
  }

  private http: HttpBridge = new HttpBridge((_id: number, _k: string, _a: string, _b: string) => {});
  private device: DeviceBridge = new DeviceBridge((_id: number, _ok: boolean, _j: string) => {});
  private pending: Map<number, PendingCall> = new Map();
  private early: Map<number, EarlySettle> = new Map();
  private initialized: boolean = false;
  private listener: EngineEventListener | null = null;
  /** A4 诊断日志行 tap（[stream]/[event] 镜像）→ 运行日志查看器 */
  private logLineListener: ((line: string) => void) | null = null;

  private constructor() {
    this.http = new HttpBridge((fetchId: number, kind: string, a: string, b: string) => {
      harness.fetchEvent(fetchId, kind, a, b);
    });
    this.device = new DeviceBridge((deviceId: number, ok: boolean, resultJson: string) => {
      try {
        harness.deviceResult(deviceId, ok, resultJson);
      } catch (e) {
        console.error('[HarnessNative] deviceResult failed: ' + JSON.stringify(e));
      }
    });
  }

  /** 设备能力桥访问器（自测页可直接调用 dispatch，不经 QuickJS） */
  deviceBridge(): DeviceBridge {
    return this.device;
  }

  setEventListener(l: EngineEventListener): void {
    this.listener = l;
  }

  /** A4 注册诊断日志行监听（引擎启动前调用亦可；回调在 cbs.onLog / dispatchEvent 发射） */
  setLogLineListener(l: (line: string) => void): void {
    this.logLineListener = l;
  }

  isReady(): boolean {
    return this.initialized && harness.isReady();
  }

  /** 加载 rawfile harness.js 并初始化 QuickJS 引擎 */
  async init(context: common.Context, opts: EngineConfig): Promise<void> {
    if (this.isReady()) return;

    const jsCode = await this.loadHarnessJs(context);
    if (!jsCode) {
      throw new Error('Failed to load harness.js from rawfile');
    }

    const cwd = opts.cwd ?? (context.filesDir + '/harness');
    const env: Record<string, string> = {};

    const cbs: NativeCallbacks = {
      onLog: (stream: string, chunk: string) => {
        console.info('[harness:' + stream + '] ' + chunk);
        if (this.logLineListener !== null) {
          this.logLineListener('[' + stream + '] ' + chunk);
        }
      },
      onEvent: (eventJson: string) => {
        this.dispatchEvent(eventJson);
      },
      onFetch: (fetchId: number, requestJson: string) => {
        this.http.start(fetchId, requestJson);
      },
      onCallSettled: (callId: number, ok: boolean, json: string) => {
        this.settle(callId, ok, json);
      },
      onDevice: (deviceId: number, requestJson: string) => {
        this.device.dispatch(deviceId, requestJson);
      },
    };

    harness.init(jsCode, cwd, env, cbs);
    this.device.setContext(context);
    this.initialized = true;

    // 引擎内核初始化（Context + 插件 + provider adapter 注册）
    await this.call<object>('init', opts as object);
  }

  /** callFunc 的 Promise 化 */
  call<T>(funcName: string, args?: object): Promise<T> {
    return new Promise<T>((resolve: (v: T) => void, reject: (e: Error) => void) => {
      let envelopeRaw: string;
      try {
        envelopeRaw = harness.callFunc(funcName, args ? JSON.stringify(args) : '');
      } catch (e) {
        const msg = e instanceof Error ? e.message : JSON.stringify(e);
        reject(new Error(funcName + ': ' + msg));
        return;
      }
      const envelope = JSON.parse(envelopeRaw) as CallEnvelope;
      if (!envelope.async) {
        resolve(envelope.result as T);
        return;
      }
      const callId = envelope.callId ?? -1;
      // 同步 settle 早到（callFunc 内 pump 已完成）→ 直接结算
      const earlySettle = this.early.get(callId);
      if (earlySettle) {
        this.early.delete(callId);
        if (earlySettle.ok) {
          resolve(JSON.parse(earlySettle.json) as T);
        } else {
          reject(new Error(funcName + ': ' + earlySettle.json));
        }
        return;
      }
      this.pending.set(callId, {
        resolve: (v: object | string | null) => { resolve(v as T); },
        reject: reject,
      });
    });
  }

  // ── 引擎高层 API（对象参数 — 与 harness-entry.ts 对齐） ──

  async engineInit(config: EngineConfig): Promise<void> {
    await this.call<object>('init', config as object);
  }

  async createSession(opts: CreateSessionOpts): Promise<string> {
    return await this.call<string>('createSession', opts);
  }

  async chat(text: string): Promise<ChatOutcome> {
    const opts: ChatOpts = { text: text };
    return await this.call<ChatOutcome>('chat', opts);
  }

  /** k1：设置当前会话模型 + 思考强度（effort 非空才写 reasoningEffort，空=跟随服务端默认） */
  setModel(provider: string, model: string, effort?: string): void {
    const args: SetModelInput = { provider: provider, model: model };
    if (effort !== undefined && effort !== null && effort.length > 0) {
      args.reasoningEffort = effort;
    }
    harness.callFunc('setModel', JSON.stringify(args));
  }

  getModel(): ModelSelection {
    const raw: string = harness.callFunc('getModel', '');
    const envelope = JSON.parse(raw) as CallEnvelope;
    return envelope.result as ModelSelection;
  }

  setProviderProfile(profile: ProviderProfileInput): void {
    harness.callFunc('setProviderProfile', JSON.stringify(profile));
  }

  listProviders(): ProviderCatalogEntry[] {
    const raw: string = harness.callFunc('listProviders', '');
    const envelope = JSON.parse(raw) as CallEnvelope;
    return envelope.result as ProviderCatalogEntry[];
  }

  // ── k 系列内核 API（callFunc 通用透传 — C++ 桥无需改动） ──

  /** k4 转向：进行中的回合注入补充指令 */
  async steer(text: string): Promise<SteerOutcome> {
    const opts: ChatOpts = { text: text };
    return await this.call<SteerOutcome>('steer', opts);
  }

  /** k3 手动压缩当前会话历史 */
  async compactNow(): Promise<CompactOutcome> {
    return await this.call<CompactOutcome>('compactNow', new NoArgs());
  }

  /** k5 回答内核提问 */
  async answerQuestion(qid: number, answers: AnswerQuestionItem[]): Promise<void> {
    const opts: AnswerQuestionOpts = { qid: qid, answers: answers };
    await this.call<object>('answerQuestion', opts);
  }

  /** k6 Plan 模式开关 */
  async setPlanMode(active: boolean): Promise<void> {
    const opts: SetPlanModeOpts = { active: active };
    await this.call<object>('setPlanMode', opts);
  }

  /** k7e 查询后台任务列表 */
  async listJobs(): Promise<KernelJob[]> {
    return await this.call<KernelJob[]>('listJobs', new NoArgs());
  }

  /** k7e 终止后台任务 */
  async killJob(id: string): Promise<void> {
    const opts: KillJobOpts = { id: id };
    await this.call<object>('killJob', opts);
  }

  /** k 停止当前回合（内核 abortActive + 取消全部在途 HTTP） */
  abortActiveRound(): void {
    try {
      harness.callFunc('abortActive', '');
    } catch (e) {
      console.error('[HarnessNative] abortActive failed: ' + JSON.stringify(e));
    }
    this.http.abortAll();
  }

  dispose(): void {
    this.device.dispose();
    this.http.abortAll();
    this.pending.forEach((p: PendingCall) => {
      p.reject(new Error('engine disposed'));
    });
    this.pending.clear();
    this.early.clear();
    harness.dispose();
    this.initialized = false;
  }

  // ── 内部 ──────────────────────────────────────────────────

  private settle(callId: number, ok: boolean, json: string): void {
    const p = this.pending.get(callId);
    if (p) {
      this.pending.delete(callId);
      if (ok) {
        p.resolve(json.length > 0 ? JSON.parse(json) : null);
      } else {
        p.reject(new Error(json));
      }
      return;
    }
    // 早到（callFunc 尚未返回 callId）— 缓冲
    this.early.set(callId, { ok: ok, json: json });
  }

  private dispatchEvent(eventJson: string): void {
    if (this.logLineListener !== null) {
      this.logLineListener('[event] ' + eventJson);
    }
    if (!this.listener) return;
    try {
      const evt = JSON.parse(eventJson) as Record<string, Object>;
      const type = evt['type'] as string;
      if (typeof type === 'string') {
        this.listener(type, evt as object);
      }
    } catch (e) {
      console.error('[HarnessNative] event parse failed: ' + JSON.stringify(e));
    }
  }

  private async loadHarnessJs(context: common.Context): Promise<string> {
    try {
      const buf = await context.resourceManager.getRawFileContent('harness.js');
      if (buf && buf.length > 0) {
        const decoder = util.TextDecoder.create('utf-8');
        return decoder.decodeWithStream(buf, { stream: false });
      }
    } catch (e) {
      console.error('[HarnessNative] load rawfile failed: ' + JSON.stringify(e));
    }
    return '';
  }
}
