/**
 * HarnessApp 全局常量与 Provider 预设
 *
 * 本地内核（deepseek-harness QuickJS）使用 DeepSeekAdapter（OpenAI 兼容协议），
 * 因此仅收录 OpenAI 兼容端点的服务商；Gemini/Anthropic 原生协议暂不支持。
 */

export class AppConstants {
  static readonly APP_DIR: string = 'HarnessApp';
  static readonly FILE_API_CONFIG: string = 'api_config.json';
  static readonly FILE_SESSIONS: string = 'sessions.json';
  static readonly FILE_PREFS: string = 'preferences.json';
  static readonly DIR_SESSIONS: string = 'sessions';
}

/** k 系列：思考强度选项（value=null 表示跟随服务端默认，不传 reasoningEffort） */
export interface EffortOption {
  value: string | null;
  label: string;
  hint: string;
}

/** k1/k19 思考模式面板选项（对齐 Android 蓝本文案） */
export const EFFORT_OPTIONS: EffortOption[] = [
  { value: null, label: '默认', hint: '跟随服务端默认设置' },
  { value: 'off', label: '关闭', hint: '不输出思考过程，速度最快' },
  { value: 'high', label: '标准', hint: '标准思考模式' },
  { value: 'max', label: '最高', hint: '最高强度思考，耗时更长' }
];

/** k1：reasoningEffort 合法值校验（持久化前过滤脏数据） */
export class ReasoningEfforts {
  static readonly ALL: string[] = ['off', 'high', 'max'];

  static isValid(v: string | null | undefined): boolean {
    return v !== null && v !== undefined && v.length > 0 && ReasoningEfforts.ALL.indexOf(v) >= 0;
  }
}

/** Provider 标识（与引擎 profiles 表键对齐） */
export enum AiProvider {
  DEEPSEEK = 'deepseek',
  QWEN = 'qwen',
  DOUBAO = 'doubao',
  ZHIPU = 'zhipu',
  ZHIPU_CODING = 'zhipu_coding',
  MOONSHOT = 'moonshot',
  OPENAI = 'openai',
  GEMINI = 'gemini',
  CUSTOM = 'custom'
}

export interface ProviderMeta {
  provider: string;
  label: string;
  baseUrl: string;
  defaultModel: string;
  models: string[];
  /** 预设官网/控制台地址（设置页「获取 Key」入口） */
  keyUrl: string;
}

/** OpenAI 兼容服务商预设（模型列表 2025-2026） */
export const PROVIDER_META: Record<string, ProviderMeta> = {
  [AiProvider.DEEPSEEK]: {
    provider: AiProvider.DEEPSEEK,
    label: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com',
    defaultModel: 'deepseek-chat',
    models: ['deepseek-chat', 'deepseek-reasoner'],
    keyUrl: 'https://platform.deepseek.com/api_keys'
  },
  [AiProvider.QWEN]: {
    provider: AiProvider.QWEN,
    label: '千问 Qwen',
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    defaultModel: 'qwen-plus',
    models: ['qwen3-max', 'qwen-plus', 'qwen-flash', 'qwen-turbo', 'qwen3-coder-plus', 'qwq-plus'],
    keyUrl: 'https://bailian.console.aliyun.com/'
  },
  [AiProvider.DOUBAO]: {
    provider: AiProvider.DOUBAO,
    label: '豆包 Doubao',
    baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
    defaultModel: 'doubao-seed-1.6-251015',
    models: [
      'doubao-seed-1.6-251015', 'doubao-seed-1.6-lite-251015', 'doubao-seed-1-6-250615',
      'doubao-1.5-pro-32k-250115', 'doubao-1.5-thinking-pro-250415'
    ],
    keyUrl: 'https://console.volcengine.com/ark'
  },
  [AiProvider.ZHIPU]: {
    provider: AiProvider.ZHIPU,
    label: '智谱 按量付费',
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    defaultModel: 'glm-4.6',
    models: ['glm-5.2', 'glm-5.1', 'glm-5', 'glm-5-turbo', 'glm-4.7', 'glm-4.6', 'glm-4.5', 'glm-4.5-air'],
    keyUrl: 'https://open.bigmodel.cn/'
  },
  [AiProvider.ZHIPU_CODING]: {
    provider: AiProvider.ZHIPU_CODING,
    label: '智谱 Coding Plan',
    baseUrl: 'https://open.bigmodel.cn/api/coding/paas/v4',
    defaultModel: 'glm-4.7',
    models: ['glm-5.2', 'glm-5.1', 'glm-5', 'glm-5-turbo', 'glm-4.7', 'glm-4.6', 'glm-4.5'],
    keyUrl: 'https://open.bigmodel.cn/'
  },
  [AiProvider.MOONSHOT]: {
    provider: AiProvider.MOONSHOT,
    label: 'Kimi 月之暗面',
    baseUrl: 'https://api.moonshot.cn/v1',
    defaultModel: 'kimi-k2-0905-preview',
    models: ['kimi-k2-0905-preview', 'kimi-k2-turbo-preview', 'kimi-latest'],
    keyUrl: 'https://platform.moonshot.cn/'
  },
  [AiProvider.OPENAI]: {
    provider: AiProvider.OPENAI,
    label: 'OpenAI',
    baseUrl: 'https://api.openai.com/v1',
    defaultModel: 'gpt-4.1-mini',
    models: ['gpt-4.1', 'gpt-4.1-mini', 'gpt-4.1-nano', 'o3', 'o3-mini', 'o4-mini'],
    keyUrl: 'https://platform.openai.com/api-keys'
  },
  [AiProvider.GEMINI]: {
    provider: AiProvider.GEMINI,
    label: 'Gemini',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
    defaultModel: 'gemini-3.7-flash',
    models: ['gemini-3.7-flash', 'gemini-3.6-flash', 'gemini-flash-latest', 'gemini-pro-latest'],
    keyUrl: 'https://aistudio.google.com/apikey'
  },
  [AiProvider.CUSTOM]: {
    provider: AiProvider.CUSTOM,
    label: '自定义（OpenAI 兼容）',
    baseUrl: '',
    defaultModel: '',
    models: [],
    keyUrl: ''
  }
};

export const ALL_PROVIDERS: string[] = [
  AiProvider.DEEPSEEK,
  AiProvider.QWEN,
  AiProvider.DOUBAO,
  AiProvider.ZHIPU,
  AiProvider.ZHIPU_CODING,
  AiProvider.MOONSHOT,
  AiProvider.OPENAI,
  AiProvider.GEMINI,
  AiProvider.CUSTOM
];

/**
 * 导入时的 provider 别名映射（外部应用导出标识 → 本项目标识）。
 * - chatgpt：EyeMouthMind 导出的 OpenAI 条目
 * - kimi：外部应用若以 kimi 标识月之暗面
 */
export const IMPORT_ALIAS: Record<string, string> = {
  'chatgpt': AiProvider.OPENAI,
  'kimi': AiProvider.MOONSHOT
};

/** 导入时协议不兼容、直接跳过的 provider（Anthropic 原生协议，内核仅支持 OpenAI 兼容） */
export const IMPORT_UNSUPPORTED: string[] = ['claude'];
