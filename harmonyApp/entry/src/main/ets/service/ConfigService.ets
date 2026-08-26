import { hilog } from '@kit.PerformanceAnalysisKit';
import { StorageService } from './StorageService';
import { AiProvider, PROVIDER_META, ALL_PROVIDERS, IMPORT_ALIAS, IMPORT_UNSUPPORTED, LEGACY_PRESET_MODELS, ReasoningEfforts } from '../common/Constants';
import { ProviderProfileInput, EngineConfig, ModelInput } from './HarnessNative';

const TAG = 'ConfigService';
const DOMAIN = 0x0302;

/** 单个服务商的用户配置 */
export interface ProviderConfig {
  provider: string;
  apiKey: string;
  baseUrl: string;
  models: string[];
  defaultModel: string;
  enabled: boolean;
  /** 每请求最大输出 tokens（含深度思考）；未配置走内核默认（reasoner 65536 / 其他 8192） */
  maxTokens?: number;
}

/** 配置文件结构（含「记住最后一次模型选择」） */
export interface AiConfig {
  version: number;
  configs: Record<string, ProviderConfig>;
  lastProvider: string;
  lastModel: string;
  lastEffort?: string;
  /** 预设刷新迁移标记（如 '2026-08b'），防重复迁移 */
  presetMigration?: string;
}

/** 导出格式 */
interface ExportConfigData {
  version: number;
  type: string;
  exportTime: number;
  configs: Record<string, Object>[];
}

/** 导入结果：导入条数 + 跳过的 provider（协议不兼容等） */
export interface ImportOutcome {
  imported: number;
  skipped: string[];
  error: boolean;
}

/**
 * AI 配置服务（单例，EMM 式）。
 * - provider 预设 + 用户 apiKey/baseUrl/模型列表持久化
 * - lastProvider/lastModel 记住最后一次模型选择（新会话默认值）
 * - buildEngineConfig() 生成内核 EngineConfig（仅含已配 key 的 provider）
 */
export class ConfigService {
  private config: AiConfig | null = null;
  private static instance: ConfigService | null = null;

  static get(): ConfigService {
    if (ConfigService.instance === null) {
      ConfigService.instance = new ConfigService();
    }
    return ConfigService.instance;
  }

  load(): AiConfig {
    if (this.config !== null) {
      return this.config;
    }
    const read = StorageService.get().readJson<AiConfig>(StorageService.get().pathApiConfig());
    if (read !== null && read.configs !== undefined) {
      if (read.presetMigration !== '2026-08b') {
        // 存量配置一次性升级：旧预设模型列表换为官方现役列表（定制过的补齐缺失项）
        this.migratePresets(read);
        read.presetMigration = '2026-08b';
        this.config = read;
        this.save();
        hilog.info(DOMAIN, TAG, 'config migrated to 2026-08b presets');
        return this.config;
      }
      this.config = read;
      return this.config;
    }
    // 初始化默认结构（全部未填写 key，未启用）
    const configs: Record<string, ProviderConfig> = {};
    for (const p of ALL_PROVIDERS) {
      const meta = PROVIDER_META[p];
      configs[p] = {
        provider: p,
        apiKey: '',
        baseUrl: meta.baseUrl,
        models: meta.models.slice(),
        defaultModel: meta.defaultModel,
        enabled: false
      };
    }
    this.config = {
      version: 1,
      configs: configs,
      lastProvider: AiProvider.DEEPSEEK,
      lastModel: PROVIDER_META[AiProvider.DEEPSEEK].defaultModel
    };
    this.save();
    hilog.info(DOMAIN, TAG, 'config initialized with defaults');
    return this.config;
  }

  save(): void {
    if (this.config !== null) {
      StorageService.get().writeJson(StorageService.get().pathApiConfig(), this.config);
    }
  }

  /**
   * 预设刷新迁移（2026-08）：官方模型 ID 大面积退役后，存量配置里
   * 全部落在旧预设内的模型列表整体替换为新预设；定制过的列表保留用户条目，
   * 仅把缺失的现役预设补入（保证 kimi-k3 等新 ID 始终可选）；
   * defaultModel/lastModel 若已退役一并纠正。
   */
  private migratePresets(cfg: AiConfig): void {
    for (const p of ALL_PROVIDERS) {
      const item = cfg.configs[p];
      const legacy = LEGACY_PRESET_MODELS[p];
      const meta = PROVIDER_META[p];
      if (item === undefined || legacy === undefined || meta === undefined) {
        continue;
      }
      const untouched = item.models.every((m: string) => legacy.indexOf(m) >= 0);
      if (untouched) {
        item.models = meta.models.slice();
      } else {
        for (const m of meta.models) {
          if (item.models.indexOf(m) < 0) {
            item.models.push(m);
          }
        }
      }
      if (legacy.indexOf(item.defaultModel) >= 0) {
        item.defaultModel = meta.defaultModel;
      }
    }
    const legacyLast = LEGACY_PRESET_MODELS[cfg.lastProvider];
    const metaLast = PROVIDER_META[cfg.lastProvider];
    if (legacyLast !== undefined && metaLast !== undefined && legacyLast.indexOf(cfg.lastModel) >= 0) {
      cfg.lastModel = metaLast.defaultModel;
    }
  }

  getConfig(provider: string): ProviderConfig {
    const c = this.load();
    const item = c.configs[provider];
    if (item !== undefined) {
      return item;
    }
    const meta = PROVIDER_META[provider];
    return {
      provider: provider,
      apiKey: '',
      baseUrl: meta !== undefined ? meta.baseUrl : '',
      models: meta !== undefined ? meta.models.slice() : [],
      defaultModel: meta !== undefined ? meta.defaultModel : '',
      enabled: false
    };
  }

  /** 更新服务商配置并保存（apiKey 非空即视为启用） */
  setConfig(cfg: ProviderConfig): void {
    const c = this.load();
    cfg.enabled = cfg.apiKey.trim().length > 0;
    c.configs[cfg.provider] = cfg;
    this.save();
  }

  /** 记住最后一次模型选择（发送消息/切换模型时调用；effort 合法才写，否则清除） */
  setLastSelection(provider: string, model: string, effort?: string): void {
    const c = this.load();
    c.lastProvider = provider;
    c.lastModel = model;
    if (ReasoningEfforts.isValid(effort)) {
      c.lastEffort = effort;
    } else {
      c.lastEffort = undefined;
    }
    this.save();
  }

  getLastSelection(): ModelSelectionPersist {
    const c = this.load();
    const sel: ModelSelectionPersist = { provider: c.lastProvider, model: c.lastModel };
    if (ReasoningEfforts.isValid(c.lastEffort)) {
      sel.effort = c.lastEffort;
    }
    return sel;
  }

  /** 任意可用配置是否存在 */
  hasUsableConfig(): boolean {
    const c = this.load();
    for (const p of ALL_PROVIDERS) {
      const item = c.configs[p];
      if (item !== undefined && item.apiKey.trim().length > 0) {
        return true;
      }
    }
    return false;
  }

  /** 已启用的 provider 列表 */
  listUsableProviders(): ProviderConfig[] {
    const c = this.load();
    const out: ProviderConfig[] = [];
    for (const p of ALL_PROVIDERS) {
      const item = c.configs[p];
      if (item !== undefined && item.apiKey.trim().length > 0) {
        out.push(item);
      }
    }
    return out;
  }

  /** 默认 provider/model/effort：优先最后选择，否则第一个可用 */
  getDefaultSelection(): ModelSelectionPersist {
    const c = this.load();
    const effort = ReasoningEfforts.isValid(c.lastEffort) ? c.lastEffort : undefined;
    if (c.lastProvider.length > 0) {
      const item = c.configs[c.lastProvider];
      if (item !== undefined && item.enabled) {
        const model = c.lastModel.length > 0 && item.models.indexOf(c.lastModel) >= 0
          ? c.lastModel : item.defaultModel;
        const sel: ModelSelectionPersist = { provider: c.lastProvider, model: model };
        if (effort !== undefined) {
          sel.effort = effort;
        }
        return sel;
      }
    }
    const usable = this.listUsableProviders();
    if (usable.length > 0) {
      const sel: ModelSelectionPersist = { provider: usable[0].provider, model: usable[0].defaultModel };
      if (effort !== undefined) {
        sel.effort = effort;
      }
      return sel;
    }
    const sel: ModelSelectionPersist = { provider: AiProvider.DEEPSEEK, model: PROVIDER_META[AiProvider.DEEPSEEK].defaultModel };
    if (effort !== undefined) {
      sel.effort = effort;
    }
    return sel;
  }

  /** 生成内核 EngineConfig（仅含已配 key 的 provider；无可用时返回 null） */
  buildEngineConfig(cwd: string): EngineConfig | null {
    const usable = this.listUsableProviders();
    if (usable.length === 0) {
      return null;
    }
    const def = this.getDefaultSelection();
    const profiles: ProviderProfileInput[] = [];
    for (const item of usable) {
      const models = item.models.length > 0 ? item.models : [item.defaultModel];
      const modelInputs: ModelInput[] = [];
      for (const m of models) {
        const input: ModelInput = { id: m };
        modelInputs.push(input);
      }
      const profile: ProviderProfileInput = {
        provider: item.provider,
        baseUrl: item.baseUrl,
        apiKey: item.apiKey,
        models: modelInputs
      };
      if (item.maxTokens !== undefined && item.maxTokens > 0) {
        profile.maxTokens = item.maxTokens;
      }
      profiles.push(profile);
    }
    const cfg: EngineConfig = {
      cwd: cwd,
      providers: profiles,
      defaultProvider: def.provider,
      defaultModel: def.model
    };
    return cfg;
  }

  /** 导出模型配置（EMM 兼容格式 — EyeMouthMind 可直接导入；仅导出已配 key 的条目） */
  exportConfigJson(): string {
    const c = this.load();
    const configs: Record<string, Object>[] = [];
    for (const p of ALL_PROVIDERS) {
      const item = c.configs[p];
      if (item !== undefined && item.apiKey.trim().length > 0) {
        const obj: Record<string, Object> = {};
        obj['provider'] = item.provider;
        obj['apiKey'] = item.apiKey;
        obj['model'] = item.defaultModel;
        obj['baseUrl'] = item.baseUrl;
        obj['models'] = item.models;
        obj['defaultModel'] = item.defaultModel;
        if (item.maxTokens !== undefined && item.maxTokens > 0) {
          obj['maxTokens'] = item.maxTokens;
        }
        configs.push(obj);
      }
    }
    const data: ExportConfigData = {
      version: 1,
      type: 'emm_model_config',
      exportTime: Date.now(),
      configs: configs
    };
    return JSON.stringify(data, null, 2);
  }

  /**
   * 导入模型配置（兼容 EyeMouthMind 导出格式 emm_model_config）。
   * - provider 别名映射（chatgpt→openai、kimi→moonshot）
   * - gemini 原生端点自动替换为 OpenAI 兼容端点
   * - 协议不兼容 provider（claude）跳过并记录
   */
  importConfigJson(jsonStr: string): ImportOutcome {
    const fail: ImportOutcome = { imported: 0, skipped: [], error: true };
    if (jsonStr.length > 1024 * 1024) {
      hilog.error(DOMAIN, TAG, 'import fail: too large %{public}d', jsonStr.length);
      return fail;
    }
    let parsed: Record<string, Object>;
    try {
      parsed = JSON.parse(jsonStr) as Record<string, Object>;
    } catch (e) {
      const msg = e instanceof Error ? e.message : JSON.stringify(e);
      hilog.error(DOMAIN, TAG, 'import fail: parse error %{public}s len=%{public}d head=%{public}s',
        msg, jsonStr.length, jsonStr.substring(0, 60));
      return fail;
    }
    if (parsed === null || parsed === undefined) {
      return fail;
    }
    const typeVal = parsed['type'];
    if (typeof typeVal !== 'string' || (typeVal !== 'harness_model_config' && typeVal !== 'emm_model_config')) {
      hilog.error(DOMAIN, TAG, 'import fail: bad type=%{public}s', String(typeVal));
      return fail;
    }
    const cfgArr = parsed['configs'];
    if (!Array.isArray(cfgArr)) {
      hilog.error(DOMAIN, TAG, 'import fail: configs not array');
      return fail;
    }
    const c = this.load();
    let imported = 0;
    const skipped: string[] = [];
    for (const raw of cfgArr as Object[]) {
      const obj = raw as Record<string, Object>;
      const providerRaw = obj['provider'];
      const apiKeyStr = obj['apiKey'];
      if (typeof providerRaw !== 'string' || typeof apiKeyStr !== 'string') {
        continue;
      }
      const providerStr = IMPORT_ALIAS[providerRaw] ?? providerRaw;
      // 协议不兼容（Anthropic 原生协议 — 内核仅支持 OpenAI 兼容）
      if (IMPORT_UNSUPPORTED.indexOf(providerStr) >= 0) {
        if (skipped.indexOf(providerStr) < 0) {
          skipped.push(providerStr);
        }
        continue;
      }
      const meta = PROVIDER_META[providerStr];
      if (meta === undefined) {
        continue;
      }
      const apiKey = (apiKeyStr as string).trim();
      if (apiKey.length === 0 || apiKey.length > 500) {
        continue;
      }
      const baseUrlStr = obj['baseUrl'];
      const modelStr = obj['defaultModel'] ?? obj['model'];
      const modelsVal = obj['models'];
      let models: string[] = meta.models.slice();
      if (Array.isArray(modelsVal)) {
        const custom = (modelsVal as Object[]).filter((m: Object) => typeof m === 'string').map((m: Object) => m as string);
        if (custom.length > 0) {
          models = custom;
        }
      }
      let defaultModel = typeof modelStr === 'string' && (modelStr as string).length > 0
        ? modelStr as string : meta.defaultModel;
      if (models.indexOf(defaultModel) < 0) {
        models.push(defaultModel);
      }
      // gemini：EMM 导出的原生协议端点 → 本项目 OpenAI 兼容端点
      let baseUrl = typeof baseUrlStr === 'string' && (baseUrlStr as string).length > 0
        ? baseUrlStr as string : meta.baseUrl;
      if (providerStr === AiProvider.GEMINI && baseUrl.indexOf('/openai') < 0) {
        baseUrl = meta.baseUrl;
      }
      const cfg: ProviderConfig = {
        provider: providerStr,
        apiKey: apiKey,
        baseUrl: baseUrl,
        models: models,
        defaultModel: defaultModel,
        enabled: true
      };
      const maxTokensVal = obj['maxTokens'];
      if (typeof maxTokensVal === 'number' && maxTokensVal > 0) {
        cfg.maxTokens = maxTokensVal;
      }
      const existing = c.configs[providerStr];
      if (existing !== undefined && existing.apiKey === cfg.apiKey && existing.defaultModel === cfg.defaultModel) {
        continue;
      }
      c.configs[providerStr] = cfg;
      imported++;
    }
    if (imported > 0) {
      this.save();
    }
    return { imported: imported, skipped: skipped, error: false };
  }
}

export interface ModelSelectionPersist {
  provider: string;
  model: string;
  /** k19：思考强度（合法值 off/high/max；缺省=跟随服务端默认） */
  effort?: string;
}
