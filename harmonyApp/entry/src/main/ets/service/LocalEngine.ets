import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HarnessNative, ChatOutcome, ProviderCatalogEntry, ModelInput } from './HarnessNative';
import { ConfigService } from './ConfigService';
import { SessionRecord, SessionStore } from './SessionStore';

const TAG = 'LocalEngine';
const DOMAIN = 0x0304;

/**
 * 本地内核引擎（deepseek-harness QuickJS，开箱即用）。
 * 包装 HarnessNative：引擎生命周期、会话映射、模型切换、配置热更新。
 */
export class LocalEngine {
  private native: HarnessNative = HarnessNative.getInstance();
  private started: boolean = false;
  private starting: Promise<void> | null = null;
  /** 当前挂载到内核的会话 id（内核侧 this.agent — 同一时刻一个） */
  private mountedSessionId: string | null = null;

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
   */
  async mountSession(record: SessionRecord): Promise<void> {
    if (!this.isReady()) {
      throw new Error('engine not started');
    }
    this.native.setModel(record.provider, record.model);
    if (this.mountedSessionId === record.id) {
      return;
    }
    await this.native.createSession({ sessionId: record.id });
    this.mountedSessionId = record.id;
  }

  /** 发送消息（当前挂载会话 + 当前模型选择） */
  async send(text: string): Promise<ChatOutcome> {
    if (!this.isReady()) {
      throw new Error('engine not started');
    }
    return await this.native.chat(text);
  }

  /** 切换当前会话的模型（下一条消息生效） */
  applyModel(provider: string, model: string): void {
    if (!this.isReady()) {
      return;
    }
    this.native.setModel(provider, model);
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
