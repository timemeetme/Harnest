/**
 * harness-entry.ts — Harnest App 的内核入口点（v2：多 provider HostAdapter）
 *
 * 职责:
 *   1. 显式 import 所有 dsh-* 运行时包（触发 esbuild bundle）
 *   2. 为每个 provider（OpenAI 兼容）注册独立的 DeepSeekAdapter 实例，
 *      options()/resolveApiKey() 为活闭包 — 每次请求从 profile 表读取最新配置
 *   3. 提供 HarnessEngine 类：会话式 chat API + 动态模型切换 + 运行时改配置
 *
 * 宿主桥（QuickJS 环境，host-bridge.js 注入）：
 *   fetch()（__harnessFetchStart）/ fs（__harnessFsCall）/ __harnessEmit
 */

// ── Vendor 基础层 ──────────────────────────────────────────
import { Context } from '@deepseek-ai/cordis'

// ── Core Services ──────────────────────────────────────────
import AgentRegistry, { Inbox, installModelSelection } from '@deepseek-ai/dsh-agent'
import AgentDefaultModelConfig from '@deepseek-ai/dsh-agent-default-model'
import SessionStore, { SessionId } from '@deepseek-ai/dsh-session'
import SystemPrompt from '../../core/system-prompt/src/index.ts'
import ToolRuntime from '../../core/tools/src/index.ts'
import { defineTool } from '@deepseek-ai/dsh-tools'
import AgentLoop from '../../core/agent-loop/src/index.ts'
// 会话标题：SessionTitleService（session/title 事件 + 本地 fallback）+ 首条消息 LLM 标题插件
import { SessionTitleService } from '../../session/session-title/src/index.ts'
import * as SessionTitleFirstPrompt from '../../session/session-title-first-prompt-llm/src/index.ts'
// 上下文压缩：TokenMeter（会话 token 用量计量）+ BasicCompactionEngine（步间压力/溢出自动压缩 + 手动 compactNow）
import { TokenMeter } from '../../llm/token-meter/src/index.ts'
import { BasicCompactionEngine } from '../../compaction/compaction-basic/src/index.ts'
// k7e 后台任务：进程内 JobRegistry（list/kill/onJobsChanged — 后台 bash/subagent 任务的注册与终止）
import LocalJobRegistry from '../../jobs/jobs-local/src/index.ts'
// 工具层：todo_write（整表快照事件 todo/write — 消息流/详情页渲染数据源）
import * as ToolTodo from '../../todo/tool-todo/src/index.ts'
// 工具层：device_*（设备能力 — 通讯录/日历/剪贴板/文件/相册/邮件/拨号/相机/录音/应用）
// 构建时与 harness-entry.ts 一同拷入 headless（见 build.mjs），故用同目录相对导入
import { DeviceToolsPlugin } from './device-tools'

// ── LLM 层 ─────────────────────────────────────────────────
import LlmRuntime, { createUserMessage, resolveRetryPolicy, LlmError } from '@deepseek-ai/dsh-llm'
// 注意：headless 包的 node_modules 未链接 dsh-llm-deepseek / dsh-credentials，
// 用相对路径直达源码（构建时 harness-entry.ts 位于 packages/bundle/headless/）
import { DeepSeekAdapter } from '../../llm/llm-deepseek/src/adapter.ts'
import type { DeepSeekConnectionOptions } from '../../llm/llm-deepseek/src/adapter.ts'
import { credentialRef } from '../../credentials/credentials/src/index.ts'
import type { AnonymousUserId } from '../../identity/anonymous-user-id/src/index.ts'

// k5 交互控制：agent 提问（user-questions 服务 + ask_user_question 工具）与 Plan 审批
// （plan-mode 插件：plan/mode 事件 + exit_plan_mode 工具，审批问题复用 user-questions 通道）
import UserQuestionService from '../../interaction/user-questions/src/index.ts'
import type { AskUserQuestionAnswer, AskUserQuestionRequest } from '../../interaction/user-questions/src/index.ts'
import * as ToolAskUser from '../../interaction/tool-ask-user/src/index.ts'
import PlanModeController from '../../plan/plan-mode/src/index.ts'

// ── 类型 ────────────────────────────────────────────────────

/** UI 侧传入的 provider 模型目录项 */
export interface ProviderModelInput {
  id: string
  name?: string
  contextWindow?: number
  maxTokens?: number
}

/** UI 侧传入的 provider 连接配置 */
export interface ProviderProfileInput {
  provider: string
  baseUrl: string
  apiKey: string
  models: ProviderModelInput[]
  maxTokens?: number
  contextWindow?: number
}

export interface HarnessConfig {
  cwd?: string
  providers: ProviderProfileInput[]
  defaultProvider: string
  defaultModel: string
}

/** 单次工具调用（tool/call + tool/result 配对，callId 关联） */
export interface ToolCallEntry {
  seq: number
  callId: string
  name: string
  args: string
  status: 'running' | 'ok' | 'error'
  result?: string
}

/** todo_write 的整表快照项 */
export interface TodoSnapshotItem {
  content: string
  status: string
}

/** 子代理/workflow 成员（tool-workflow/agent-start/-end 配对） */
export interface SubagentEntry {
  label: string
  phase?: string
  outcome?: string
}

export interface TurnUsage {
  inputTokens: number
  outputTokens: number
}

/** 回合执行细节（消息流内联工具气泡 + 详情页轨迹的数据源） */
export interface TurnDetails {
  toolCalls: ToolCallEntry[]
  todos?: TodoSnapshotItem[]
  subagents: SubagentEntry[]
  planActive: boolean
  usage?: TurnUsage
}

export interface ChatOutcome {
  sessionId: string
  text: string
  reason?: { kind?: string; error?: { code?: string; message?: string } }
  details?: TurnDetails
}

interface ModelSelection {
  provider: string
  model: string
  reasoningEffort?: string
}

interface SessionEvent {
  seq: number
  type: string
  data?: Record<string, unknown>
}

/** 从 session events 增量提取 assistant 文本（对齐 dsh-headless 的 summarize） */
function summarizeEvents(events: SessionEvent[], firstSeq: number): { text: string; reason?: ChatOutcome['reason'] } {
  let started = false
  let text = ''
  let reason: ChatOutcome['reason'] | undefined
  for (const event of events) {
    if (event.seq < firstSeq) continue
    if (event.type === 'turn/start') { started = true; continue }
    if (!started) continue
    if (event.type === 'assistant/message') {
      const message = (event.data && event.data.message) as { content?: Array<{ type: string; text?: string }> } | undefined
      const joined = (message && message.content || [])
        .filter((block) => block.type === 'text')
        .map((block) => block.text || '')
        .join('')
      if (joined !== '') text = joined
    }
    if (event.type === 'turn/end') {
      reason = (event.data && event.data.reason) as ChatOutcome['reason']
    }
  }
  return { text, reason }
}

/**
 * 从 session events 提取回合执行细节（详情页轨迹 + 消息流内联工具气泡的数据源）。
 * - tool/call + tool/result 按 callId 配对（result 未到 = running）
 * - todo/write 整表快照（last-write-wins）
 * - plan/mode 折叠为 planActive
 * - tool-workflow/agent-start/-end 按 runId:seq 配对为子代理条目
 * - assistant/message.usage 取最后一次
 */
function extractDetails(events: SessionEvent[], firstSeq: number): TurnDetails {
  const toolCalls: ToolCallEntry[] = []
  const byId = new Map<string, ToolCallEntry>()
  // undefined（而非 null）：JSON.stringify 自动省略 undefined 字段，
  // 纯对话回合不会输出 "todos":null（宿主端 NSNull 曾致 iOS 崩溃，见 encodeString 守卫）
  let todos: TodoSnapshotItem[] | undefined = undefined
  let planActive = false
  let usage: TurnUsage | undefined = undefined
  const subagents: SubagentEntry[] = []
  const wfPending = new Map<string, SubagentEntry>()

  for (const event of events) {
    if (event.seq < firstSeq) continue
    const d = (event.data || {}) as Record<string, unknown>

    if (event.type === 'tool/call') {
      const entry: ToolCallEntry = {
        seq: event.seq,
        callId: String(d.callId ?? ''),
        name: String(d.name ?? 'unknown'),
        args: String(d.arguments ?? ''),
        status: 'running',
      }
      toolCalls.push(entry)
      byId.set(entry.callId, entry)
      continue
    }

    if (event.type === 'tool/result') {
      // callId 兜底链：createToolResultMessage 把 callId 放在 content[0].toolCallId
      // 和 message.source.callId，顶层 message.callId 不存在 — 单读必空导致配对失败
      const message = d.message as
        | {
            callId?: unknown
            source?: { callId?: unknown }
            isError?: boolean
            content?: Array<{ type?: string; text?: string; toolCallId?: unknown; isError?: boolean; content?: Array<{ type?: string; text?: string }> }>
          }
        | undefined
      const trBlock = message && Array.isArray(message.content)
        ? message.content.find((block) => block && block.type === 'tool-result')
        : undefined
      const callId = String(
        (trBlock && trBlock.toolCallId) ??
        (message && message.source && message.source.callId) ??
        (message && message.callId) ??
        d.callId ??
        '',
      )
      const entry = byId.get(callId) ?? (callId === '' ? findLastRunning(toolCalls) : undefined)
      if (!entry) continue
      let text = ((message && message.content) || [])
        .filter((block) => block.type === 'text')
        .map((block) => block.text || '')
        .join('')
      if (!text && trBlock && Array.isArray(trBlock.content)) {
        text = trBlock.content.filter((block) => block && block.type === 'text').map((block) => block.text || '').join('')
      }
      const isError = (trBlock && trBlock.isError) || (message && message.isError) || d.error !== undefined
      entry.status = isError ? 'error' : 'ok'
      entry.result = text.length > 0 ? text.slice(0, 2000) : JSON.stringify(d.error ?? '')
      continue
    }

    if (event.type === 'todo/write') {
      const raw = d.todos
      if (Array.isArray(raw)) {
        todos = raw.map((t) => {
          const item = t as Record<string, unknown>
          return { content: String(item.content ?? ''), status: String(item.status ?? 'pending') }
        })
      }
      continue
    }

    if (event.type === 'plan/mode') {
      planActive = d.active === true
      continue
    }

    if (event.type === 'tool-workflow/agent-start') {
      const key = `${String(d.runId)}:${String(d.seq)}`
      const entry: SubagentEntry = {
        label: String(d.label ?? 'subagent'),
        ...(d.phase !== undefined ? { phase: String(d.phase) } : {}),
      }
      subagents.push(entry)
      wfPending.set(key, entry)
      continue
    }

    if (event.type === 'tool-workflow/agent-end') {
      const key = `${String(d.runId)}:${String(d.seq)}`
      const entry = wfPending.get(key)
      if (entry && d.outcome !== undefined) entry.outcome = String(d.outcome)
      continue
    }

    if (event.type === 'assistant/message') {
      const u = d.usage as { inputTokens?: unknown; outputTokens?: unknown } | undefined
      if (u) usage = { inputTokens: Number(u.inputTokens ?? 0), outputTokens: Number(u.outputTokens ?? 0) }
    }
  }

  return { toolCalls, todos, subagents, planActive, usage }
}

function randomId(): string {
  const g = globalThis as { crypto?: { randomUUID?: () => string } }
  if (g.crypto && typeof g.crypto.randomUUID === 'function') return g.crypto.randomUUID()
  return `s-${Date.now()}-${Math.floor(Math.random() * 1e9).toString(36)}`
}

/** 兜底：事件缺 callId 时归并到最后一个运行中的工具（顺序执行场景等价） */
function findLastRunning(toolCalls: ToolCallEntry[]): ToolCallEntry | undefined {
  for (let i = toolCalls.length - 1; i >= 0; i--) {
    if (toolCalls[i].status === 'running') return toolCalls[i]
  }
  return undefined
}

/** 截取平衡前缀：止于最后一个闭合的 turn/step 边界。
 *  崩溃残留的开放 turn / 悬挂 tool call 尾部弃置，满足 seed 校验
 *  （contiguous from seq 0, no open turn/step, no dangling tool call）。 */
function balancedSeedPrefix(events: SessionEvent[]): SessionEvent[] {
  let depth = 0
  let lastBalanced = -1
  for (let i = 0; i < events.length; i++) {
    const t = events[i].type
    if (t === 'turn/start' || t === 'step/start') depth++
    else if (t === 'turn/end' || t === 'step/end') depth = Math.max(0, depth - 1)
    if (depth === 0) lastBalanced = i
  }
  return lastBalanced >= 0 ? events.slice(0, lastBalanced + 1) : []
}

/** 解析宿主 .jsonl 事件日志 → 平衡前缀 seed（seq 必须从 0 连续；首条损坏行即截断）。 */
function parseSeedJson(seedJson: unknown): SessionEvent[] | undefined {
  if (typeof seedJson !== 'string' || seedJson.trim() === '') return undefined
  const parsed: SessionEvent[] = []
  for (const raw of seedJson.split('\n')) {
    const line = raw.trim()
    if (!line) continue
    let o: { seq?: unknown; type?: unknown; time?: unknown; data?: unknown; surfaceOp?: unknown; sourceEventSeqs?: unknown; ignorable?: unknown }
    try { o = JSON.parse(line) } catch { break }
    const seq = Number(o.seq)
    const time = Number(o.time)
    // envelope 校验：seq 0 基连续 + time 必填 safe integer（断行即止 — 宿主文件尾
    // 可能有半写入行，保留已解析前缀）；surface 元数据字段原样透传
    if (!Number.isSafeInteger(seq) || seq !== parsed.length) break
    if (!Number.isSafeInteger(time)) break
    if (typeof o.type !== 'string' || o.type === '') break
    parsed.push({
      seq,
      type: o.type,
      time,
      data: o.data === undefined ? {} : o.data as Record<string, unknown>,
      ...(o.surfaceOp !== undefined ? { surfaceOp: o.surfaceOp } : {}),
      ...(o.sourceEventSeqs !== undefined ? { sourceEventSeqs: o.sourceEventSeqs } : {}),
      ...(o.ignorable !== undefined ? { ignorable: o.ignorable } : {}),
    })
  }
  const balanced = balancedSeedPrefix(parsed)
  return balanced.length > 0 ? balanced : undefined
}

// ── HarnessEngine ───────────────────────────────────────────

export class HarnessEngine {
  private ctx: Context | null = null
  private llm: { registerAdapter: (providers: string[], adapter: unknown) => unknown } | null = null
  private agent: { session: { id: unknown; seq: number; events: SessionEvent[] }; followup: (m: unknown) => void; whenIdle: () => Promise<void> } | null = null
  /** 动态模型选择：每次 agent/request 读取 current（installModelSelection 拦截） */
  private selectionRef: { current: ModelSelection; assembled?: ModelSelection } = {
    current: { provider: 'deepseek', model: 'deepseek-chat' },
  }
  /** provider 连接配置表（活数据源 — options()/resolveApiKey() 每次请求读取） */
  private profiles = new Map<string, ProviderProfileInput>()
  private anonymousUserId: string = randomId()
  /** 已下行转发的最大事件 seq（跨回合去重，防 followup 重放旧事件） */
  private lastRoundSeq: number = 0
  /** 当前挂载会话 id（日志镜像下行时标注归属） */
  private sessionId: string = ''
  /** 已镜像下发持久化的最大事件 seq（会话日志 append-only 游标） */
  private lastLoggedSeq: number = -1
  private thinkAccKey: string = ''
  private thinkAccText: string = ''
  private thinkEmitAt: number = 0
  private thinkEmitLen: number = 0
  private ansAccKey: string = ''
  private ansAccText: string = ''
  private ansEmitAt: number = 0
  private ansEmitLen: number = 0
  /** k7e：进程内后台任务注册表（init 时装载 LocalJobRegistry 后非空） */
  private jobs: {
    list: (caller?: unknown) => Array<Record<string, unknown>>
    kill: (id: unknown, caller?: unknown, reason?: string) => string
    onJobsChanged: (listener: (owner: unknown) => void) => () => void
  } | null = null
  /** k5：待回答的 agent 提问（provider ask() 的挂起 resolver；qid 供宿主回填答案） */
  private questionSeq: number = 0
  private pendingQuestion: {
    qid: number
    questions: AskUserQuestionRequest['questions']
    resolve: (answer: AskUserQuestionAnswer) => void
    cleanup: () => void
  } | null = null

  private emit(type: string, data: Record<string, unknown>): void {
    const g = globalThis as unknown as { __harnessEmit?: (s: string) => void }
    if (typeof g.__harnessEmit === 'function') {
      try { g.__harnessEmit(JSON.stringify({ type, ...data })) } catch { /* 序列化失败不阻断 */ }
    }
  }

  /** 构造某一 provider 的连接事实快照（每次请求重新读取 profile 表） */
  private buildConnection(name: string): DeepSeekConnectionOptions {
    const profile = this.profiles.get(name)
    if (!profile) throw new LlmError(`provider "${name}" is not configured`, 'PROVIDER_NOT_CONFIGURED')
    const envName = 'HARNESS_KEY_' + name.toUpperCase().replace(/[^A-Z0-9_]/g, '_')
    return {
      baseURL: profile.baseUrl,
      apiKeyEnv: credentialRef(envName),
      // 深度思考 wire 字段仅 DeepSeek 官方端点接受；Gemini 等严格 OpenAI 兼容层会以
      // HTTP 400 拒绝未知顶层字段（Unknown name "thinking"），故非 deepseek 一律不发，
      // effort 仍经 reasoning_effort 传递。
      // Gemini 3.x 强制回传工具调用的 thought_signature；OpenAI 等严格端点会拒绝
      // 未知字段，故仅 gemini 方言附加 extra_content。
      defaults: {
        emitThinking: name === 'deepseek',
        toolCallExtras: name === 'gemini' ? 'google' : undefined,
      },
      maxTokens: profile.maxTokens ?? 8192,
      defaultContextWindow: profile.contextWindow ?? 65536,
      models: profile.models.map((m) => ({
        id: m.id,
        ...(m.name !== undefined ? { name: m.name } : {}),
        ...(m.contextWindow !== undefined ? { contextWindow: m.contextWindow } : {}),
        ...(m.maxTokens !== undefined
        ? { maxTokens: m.maxTokens }
        : profile.maxTokens === undefined && name === 'deepseek' && m.id.includes('reasoner')
          ? { maxTokens: 65536 }
          : {}),
      })),
      streamIdleTimeoutMs: 300_000,
      retryPolicy: resolveRetryPolicy(undefined, `harness: ${name}`),
    }
  }

  private requireApiKey(name: string): string {
    const profile = this.profiles.get(name)
    const value = profile ? profile.apiKey : ''
    if (value === undefined || value === null || String(value).trim().length === 0) {
      throw new LlmError(
        `no API key configured for provider "${name}" — set it in Settings`,
        'MISSING_CREDENTIAL',
      )
    }
    return String(value)
  }

  /** 初始化 harness — 创建 Context + 注册所有必需服务 + 每个 provider 一个 adapter */
  async init(config: HarnessConfig): Promise<void> {
    if (this.ctx) return

    if (config.cwd) {
      try { process.chdir(config.cwd) } catch { /* cwd 不存在时忽略 */ }
    }

    for (const profile of config.providers) {
      this.profiles.set(profile.provider, profile)
    }
    this.selectionRef.current = {
      provider: config.defaultProvider,
      model: config.defaultModel,
    }

    const ctx = new Context()

    await ctx.plugin(SessionStore)
    await ctx.plugin(AgentRegistry)
    await ctx.plugin(AgentDefaultModelConfig, {
      provider: config.defaultProvider,
      model: config.defaultModel,
    })
    await ctx.plugin(LlmRuntime)
    await ctx.plugin(SystemPrompt)
    await ctx.plugin(ToolRuntime)
    // todo_write 工具（allowParallelInProgress=true：适配并行/多步任务）
    await ctx.plugin(
      ToolTodo as unknown as { name: string; inject: string[]; apply: (ctx: Context, config: Record<string, unknown>) => void },
      { allowParallelInProgress: true },
    )
    // device_* 工具（桥不可用时插件内部自动跳过注册，Node 冒烟环境零副作用）
    await ctx.plugin(DeviceToolsPlugin as unknown as { name: string; inject: string[]; apply: (ctx: Context) => void })

    // ── HostAdapter 注册：每 provider 一个 DeepSeekAdapter（OpenAI 兼容）。
    //    options()/resolveApiKey() 是活闭包 — setProviderProfile() 改 profiles 表
    //    后，下一次请求立即使用新 baseUrl/apiKey/models，无需重新注册。
    const llm = ctx.get('llm') as unknown as {
      registerAdapter: (providers: string[], adapter: unknown) => unknown
    }
    if (!llm) throw new Error('LlmRuntime service unavailable')
    this.llm = llm
    for (const name of this.profiles.keys()) {
      const adapter = new DeepSeekAdapter({
        options: () => this.buildConnection(name),
        resolveApiKey: async () => this.requireApiKey(name),
        resolveUserId: () => this.anonymousUserId as AnonymousUserId,
      })
      llm.registerAdapter([name], adapter)
    }

    // agent factory：createSession() 依赖（ReactLoopAgent 创建）
    await ctx.plugin(AgentLoop, {})

    // ── 会话标题：本地 fallback 截词兜底 + LLM 一句话标题。
    //    首条用户消息 → 自动排程；主请求路由记录后触发辅助 LLM 调用（purpose: session-title，thinking 关闭）。
    await ctx.plugin(SessionTitleService, { fallbackMaxWords: 8, fallbackMaxBytes: 96, maxTitleBytes: 192 })
    await ctx.plugin(
      SessionTitleFirstPrompt as unknown as { name: string; inject: string[]; apply: (ctx: Context, config: Record<string, unknown>) => void },
      { targetWords: 5, targetCjkCharacters: 12, maxInputBytes: 12000, maxOutputTokens: 48, timeoutMs: 15000 },
    )

    // ── 上下文压缩（compaction-basic）：
    //    · 自动：回合步间 token 压力 ≥80% 或 provider 上下文溢出时，把旧回合摘要成 summary 注入
    //    · 手动：compactNow()（见下，runMaintenance 空闲门控）
    await ctx.plugin(TokenMeter as unknown as { name: string; inject: string[]; apply: (ctx: Context, config: Record<string, unknown>) => void }, {})
    await ctx.plugin(BasicCompactionEngine as unknown as { name: string; inject: string[]; apply: (ctx: Context, config: Record<string, unknown>) => void }, {})

    // ── k7e 后台任务：进程内 JobRegistry。注册后 tool-bash / tool-subagent 等
    //    生产者才能把后台任务挂进 ctx.jobs；list/kill 供移动端后台任务面板，
    //    onJobsChanged 把可见集变化实时推成 'jobs' 事件（全量快照，host 端覆盖式镜像）。
    await ctx.plugin(LocalJobRegistry as unknown as { name: string; inject: string[]; apply: (ctx: Context, config: Record<string, unknown>) => void }, {})
    const jobsRegistry = ctx.get('jobs') as unknown as
      | {
          list: (caller?: unknown) => Array<Record<string, unknown>>
          kill: (id: unknown, caller?: unknown, reason?: string) => string
          start: (spec: {
            kind: string
            label: string
            owner?: unknown
            run: () => {
              cancel: (reason?: string) => void
              done: Promise<{ status: 'completed' | 'killed' | 'failed'; detail?: string }>
            }
          }) => string
          attachController: (name: string) => () => void
          onJobsChanged: (listener: (owner: unknown) => void) => () => void
        }
      | undefined
    this.jobs = jobsRegistry
    if (jobsRegistry) {
      jobsRegistry.onJobsChanged(() => {
        try { this.emit('jobs', { sessionId: this.sessionId, jobs: this.jobViews() }) } catch { /* 推送失败不阻断 */ }
      })
    }

    // ── k7e 验证生产者：移动端 bundle 无 bash/子代理（无子进程能力），bg_timer 以
    //    进程内计时任务充当 JobRegistry 生产者 — 模型可真实注册后台任务，驱动
    //    后台任务卡 + 终止链路（attachController 从非 scoped 上下文落入 global
    //    layer，服务所有 owner，无需装载完整 tool-jobs 插件）。
    if (jobsRegistry) {
      jobsRegistry.attachController('harness-mobile')
      const toolsSvc = ctx.get('tools') as unknown as { register: (tool: unknown) => unknown } | undefined
      toolsSvc?.register(defineTool({
        name: 'bg_timer',
        description: 'Start a background timer job and return immediately with the job id. '
          + 'The job stays running in the background (visible in the background tasks panel) '
          + 'until the user stops it or it completes after the given seconds.',
        parameters: {
          seconds: { type: 'number', required: true, description: 'Timer duration in seconds (1-600).' },
        },
        output: {
          schema: {
            type: 'object',
            additionalProperties: false,
            properties: {
              job_id: { type: 'string', required: true },
              seconds: { type: 'integer', required: true },
              status: { type: 'string', required: true },
            },
          },
          render: (_args, value) => [{
            type: 'text',
            text: `background timer ${value.job_id} started (${value.seconds}s, ${value.status})`,
          }],
        },
        execute(args) {
          const seconds = Math.max(1, Math.min(600, Math.floor(Number(args.seconds) || 0)))
          let timer: ReturnType<typeof setTimeout> | undefined
          let finish!: (outcome: { status: 'completed' | 'killed' | 'failed'; detail?: string }) => void
          const done = new Promise<{ status: 'completed' | 'killed' | 'failed'; detail?: string }>((resolve) => { finish = resolve })
          // owner 留空（未拥有任务）：agent-loop 的循环 fiber 在回合驱动结束后
          // unwind 其 agent，disposeOwned 会随 owner 生命周期清空任务（任务卡
          // 回合结束即消失）；未拥有任务无清理钩子，跨回合存活、任意会话可见/可杀，
          // 由用户经后台任务面板的终止按钮收尾（移动端 QuickJS 定时器为 no-op
          // 桩，到期自然完成仅在有真实定时器的宿主生效）。
          const id = jobsRegistry.start({
            kind: 'timer',
            label: `count ${seconds}s`,
            run: () => ({
              cancel: () => {
                if (timer !== undefined) clearTimeout(timer)
                finish({ status: 'killed', detail: 'cancelled' })
              },
              done,
            }),
          })
          timer = setTimeout(() => finish({ status: 'completed', detail: 'time elapsed' }), seconds * 1000)
          return Promise.resolve({ job_id: id, seconds, status: 'running' })
        },
        presentCall: args => ({ card: 'generic', title: `Start background timer ${String(args.seconds)}s`, kind: 'execute' }),
      }))
    }

    // ── k5 交互控制：agent 提问 + Plan 审批。
    //    user-questions 服务持有单一 provider；本引擎即 provider — ask() 把问题经
    //    'question' 事件下发宿主渲染（独立事件类型，不走 round/tool-start — 后者
    //    args 截断 300 字符装不下 plan markdown），宿主经 answerQuestion() 回填，
    //    resolver 把答案交还内核作为 tool result（模型随即看到）。
    //    exit_plan_mode 的审批问题复用同一通道（intent.kind === 'plan-review'），
    //    UI 按 intent 渲染审批面板；回答 'Approve' → 退出 plan mode，否则 custom
    //    文本作为反馈回给模型继续修改。
    await ctx.plugin(UserQuestionService, {})
    await ctx.plugin(ToolAskUser as unknown as { name: string; inject: string[]; apply: (ctx: Context, config: Record<string, unknown>) => void }, {})
    await ctx.plugin(PlanModeController, { section: 'plan:policy' })
    const userQuestions = ctx.get('userQuestions') as unknown as {
      registerProvider: (provider: { ask: (request: AskUserQuestionRequest) => Promise<AskUserQuestionAnswer> }) => void
    }
    userQuestions.registerProvider({
      ask: (request) => new Promise<AskUserQuestionAnswer>((resolve, reject) => {
        const qid = ++this.questionSeq
        // 前一挂起问题（顺序工具执行下不应出现）：作废并通知宿主撤卡
        if (this.pendingQuestion) {
          const old = this.pendingQuestion
          this.pendingQuestion = null
          old.cleanup()
          this.emit('question', { qid: old.qid, kind: 'cancelled' })
          old.resolve({ answers: old.questions.map((q) => ({ id: q.id, selected: [] })) })
        }
        const onAbort = () => {
          if (this.pendingQuestion && this.pendingQuestion.qid === qid) {
            this.pendingQuestion = null
            this.emit('question', { qid, kind: 'cancelled' })
          }
          reject(new Error('ASK_ABORTED'))
        }
        const signal = request.signal
        if (signal) {
          if (signal.aborted) { reject(new Error('ASK_ABORTED')); return }
          signal.addEventListener('abort', onAbort)
        }
        this.pendingQuestion = {
          qid,
          questions: request.questions,
          resolve,
          cleanup: () => { if (signal) signal.removeEventListener('abort', onAbort) },
        }
        this.emit('question', { qid, kind: 'asked', questions: request.questions })
      }),
    })

    // ── 实时回合事件下行：把当前 agent 会话的新事件（思考/工具/待办）转发给宿主 UI。
    //    仅监听 this.agent 的 session；seq 单调去重防重放。
    ctx.on('session/event', (subject: unknown, event: SessionEvent) => {
      try {
        const agent = this.agent
        if (!agent || subject !== (agent.session as unknown) || !event || typeof event.seq !== 'number') return
        if (event.seq <= this.lastRoundSeq) return
        this.lastRoundSeq = event.seq
        // 会话日志镜像：逐事件下行给宿主落盘（append-only jsonl — 会话内记忆持久层，
        // 引擎重启后作为 seed replay 重建上下文）。envelope 全字段透传 — time 为
        // seed 校验必填，surfaceOp/sourceEventSeqs/ignorable 决定压缩重放的 surface 语义。
        if (event.seq > this.lastLoggedSeq) {
          this.lastLoggedSeq = event.seq
          const ev = event as unknown as Record<string, unknown>
          this.emit('log', {
            sessionId: this.sessionId,
            event: {
              seq: event.seq,
              type: event.type,
              time: ev.time ?? Date.now(),
              data: event.data ?? {},
              ...(ev.surfaceOp !== undefined ? { surfaceOp: ev.surfaceOp } : {}),
              ...(ev.sourceEventSeqs !== undefined ? { sourceEventSeqs: ev.sourceEventSeqs } : {}),
              ...(ev.ignorable !== undefined ? { ignorable: ev.ignorable } : {}),
            },
          })
        }
        const d = (event.data || {}) as Record<string, unknown>
        if (event.type === 'assistant/chunk') {
          const chunk = d.chunk as { type?: string; text?: string } | undefined
          if (chunk && chunk.type === 'reasoning-delta' && typeof chunk.text === 'string' && chunk.text.length > 0) {
            const key = `${String(d.turn ?? '')}:${String(d.step ?? '')}`
            if (key !== this.thinkAccKey) {
              this.thinkAccKey = key
              this.thinkAccText = ''
              this.thinkEmitLen = 0
            }
            this.thinkAccText += chunk.text
            const now = Date.now()
            // 64 字 / 200ms：事件携带累积全文，高频小步长会让宿主端（万字思考）做 O(n) 重绘 — 收紧步长
            if (this.thinkAccText.length - this.thinkEmitLen >= 64 || now - this.thinkEmitAt >= 200) {
              this.thinkEmitAt = now
              this.thinkEmitLen = this.thinkAccText.length
              // turn/step：宿主按 (turn,step) 精确分段（多步思考各成一段），替代脆弱的前缀失配检测
              this.emit('round', {
                kind: 'thinking',
                seq: event.seq,
                turn: Number(d.turn ?? 0) || 0,
                step: Number(d.step ?? 0) || 0,
                text: this.thinkAccText,
              })
            }
          } else if (chunk && chunk.type === 'text-delta' && typeof chunk.text === 'string' && chunk.text.length > 0) {
            // 答案正文增量：与思考同构的累积 + 逐字级节流下发（16 字 / 60ms）
            const key = `${String(d.turn ?? '')}:${String(d.step ?? '')}`
            if (key !== this.ansAccKey) {
              this.ansAccKey = key
              this.ansAccText = ''
              this.ansEmitLen = 0
            }
            this.ansAccText += chunk.text
            const now = Date.now()
            if (this.ansAccText.length - this.ansEmitLen >= 16 || now - this.ansEmitAt >= 60) {
              this.ansEmitAt = now
              this.ansEmitLen = this.ansAccText.length
              this.emit('round', {
                kind: 'answer',
                seq: event.seq,
                turn: Number(d.turn ?? 0) || 0,
                step: Number(d.step ?? 0) || 0,
                text: this.ansAccText.slice(0, 20000),
              })
            }
          }
        } else if (event.type === 'assistant/message') {
          const blocks = ((d.message && (d.message as { content?: Array<{ type?: string; text?: string }> }).content) || [])
          const turn = Number(d.turn ?? 0) || 0
          const step = Number(d.step ?? 0) || 0
          const reasoning = blocks.filter((b) => b && b.type === 'reasoning').map((b) => b.text || '').join('')
          if (reasoning.length > 0) {
            // 兜底整块同键 (turn,step) 幂等覆盖流式段（join 语义与流式累积一致），非流式 provider 直接建段
            this.emit('round', { kind: 'thinking', seq: event.seq, turn, step, text: reasoning })
          }
          // 消息落定：flush 节流残留的答案尾部（不足阈值的最末几字）
          const answer = blocks.filter((b) => b && b.type === 'text').map((b) => b.text || '').join('')
          if (answer.length > 0) {
            this.emit('round', { kind: 'answer', seq: event.seq, turn, step, text: answer.slice(0, 20000) })
          }
        } else if (event.type === 'tool/call') {
          this.emit('round', {
            kind: 'tool-start',
            seq: event.seq,
            callId: String(d.callId ?? ''),
            name: String(d.name ?? 'unknown'),
            args: String(d.arguments ?? '').slice(0, 300),
          })
        } else if (event.type === 'tool/result') {
          // callId 兜底链与 extractDetails 一致（见 tool/result 分支注释）
          const message = d.message as
            | {
                callId?: unknown
                source?: { callId?: unknown }
                isError?: boolean
                content?: Array<{ type?: string; text?: string; toolCallId?: unknown; isError?: boolean; content?: Array<{ type?: string; text?: string }> }>
              }
            | undefined
          const trBlock = message && Array.isArray(message.content)
            ? message.content.find((block) => block && block.type === 'tool-result')
            : undefined
          const callId = String(
            (trBlock && trBlock.toolCallId) ??
            (message && message.source && message.source.callId) ??
            (message && message.callId) ??
            d.callId ??
            '',
          )
          let text = ((message && message.content) || [])
            .filter((block) => block.type === 'text')
            .map((block) => block.text || '')
            .join('')
          if (!text && trBlock && Array.isArray(trBlock.content)) {
            text = trBlock.content.filter((block) => block && block.type === 'text').map((block) => block.text || '').join('')
          }
          const isError = (trBlock && trBlock.isError) || (message && message.isError) || d.error !== undefined
          this.emit('round', {
            kind: 'tool-end',
            seq: event.seq,
            callId,
            status: isError ? 'error' : 'ok',
            result: text.slice(0, 600),
          })
        } else if (event.type === 'todo/write') {
          const raw = Array.isArray(d.todos) ? d.todos : []
          this.emit('round', {
            kind: 'todos',
            seq: event.seq,
            todos: raw.slice(0, 30).map((t) => {
              const item = t as { content?: unknown; status?: unknown }
              return { content: String((item && item.content) ?? ''), status: String((item && item.status) ?? 'pending') }
            }),
          })
        } else if (event.type === 'tool-workflow/agent-start') {
          // 子代理/workflow 启动：runId:seq 配对键原样下发，宿主据此建子代理节点
          this.emit('round', {
            kind: 'agent-start',
            seq: event.seq,
            runId: String(d.runId ?? ''),
            agentSeq: String(d.seq ?? ''),
            label: String(d.label ?? 'subagent'),
            phase: d.phase !== undefined ? String(d.phase) : '',
          })
        } else if (event.type === 'tool-workflow/agent-end') {
          this.emit('round', {
            kind: 'agent-end',
            seq: event.seq,
            runId: String(d.runId ?? ''),
            agentSeq: String(d.seq ?? ''),
            outcome: d.outcome !== undefined ? String(d.outcome) : '',
          })
        } else if (event.type === 'session/title') {
          // 会话标题事件（自动 LLM 标题 / 本地 fallback / 用户重命名共用）
          const source = (d.source as { kind?: unknown } | undefined)?.kind
          this.emit('title', {
            seq: event.seq,
            title: String(d.title ?? ''),
            source: String(source ?? ''),
          })
        } else if (event.type === 'compaction/summary') {
          // 压缩完成：摘要文本 + 被折叠的旧事件数（surface 替换由紧随的 user/message 完成，移动端转录不受影响）
          const blocks = Array.isArray(d.summary) ? d.summary : []
          const text = blocks
            .map((b) => String((b as { text?: unknown } | null)?.text ?? ''))
            .join('\n')
            .trim()
          this.emit('compact', {
            kind: 'summary',
            seq: event.seq,
            summary: text.slice(0, 4000),
            shadowedCount: Array.isArray(d.shadowedSeqs) ? d.shadowedSeqs.length : 0,
            shadowedTokens: Number(d.shadowedTokenCount ?? 0),
            provider: String(d.provider ?? ''),
            model: String(d.model ?? ''),
          })
        } else if (event.type === 'compaction/end') {
          if (d.error) this.emit('compact', { kind: 'error', seq: event.seq, error: String(d.error) })
        }
      } catch { /* 转发失败不阻断回合 */ }
    })

    this.ctx = ctx
  }

  /** 运行时更新 provider 配置（设置页保存/导入后调用；下一次请求生效）。
   *  init 后新增的 provider 在此动态注册 adapter（导入配置无需重启引擎）。 */
  setProviderProfile(profile: ProviderProfileInput): void {
    const isNew = !this.profiles.has(profile.provider)
    this.profiles.set(profile.provider, profile)
    if (isNew && this.llm) {
      const name = profile.provider
      const adapter = new DeepSeekAdapter({
        options: () => this.buildConnection(name),
        resolveApiKey: async () => this.requireApiKey(name),
        resolveUserId: () => this.anonymousUserId as AnonymousUserId,
      })
      this.llm.registerAdapter([name], adapter)
    }
  }

  /** 批量更新（新 provider 逐个走 setProviderProfile 以注册 adapter） */
  setProviderProfiles(profiles: ProviderProfileInput[]): void {
    for (const p of profiles) this.setProviderProfile(p)
  }

  /** 当前已配置的 provider 目录（供 UI 模型选择器使用） */
  listProviders(): Array<{ provider: string; baseUrl: string; hasKey: boolean; models: string[] }> {
    const out: Array<{ provider: string; baseUrl: string; hasKey: boolean; models: string[] }> = []
    for (const [name, p] of this.profiles) {
      out.push({
        provider: name,
        baseUrl: p.baseUrl,
        hasKey: String(p.apiKey || '').trim().length > 0,
        models: p.models.map((m) => m.id),
      })
    }
    return out
  }

  /** 创建（或恢复）会话 agent，返回 sessionId。
   *  seedJson：宿主持久的 .jsonl 事件日志（会话内记忆）— 解析为平衡前缀 seed 后
   *  replay 重建上下文（projection 逐事件重放，含被 compaction 折叠的历史）。 */
  async createSession(opts: { cwd?: string; provider?: string; model?: string; sessionId?: string; seedJson?: string } = {}): Promise<string> {
    if (!this.ctx) throw new Error('HarnessEngine not initialized')
    const agents = this.ctx.get('agents') as unknown as {
      create: (opts: Record<string, unknown>) => Promise<{ agent: NonNullable<HarnessEngine['agent']> }>
    }
    if (!agents) throw new Error('AgentRegistry service unavailable')

    if (opts.provider && opts.model) {
      this.selectionRef.current = { provider: opts.provider, model: opts.model }
    }

    const seed = parseSeedJson(opts.seedJson)
    const { agent } = await agents.create({
      sessionId: SessionId(opts.sessionId ?? `session-${randomId()}`),
      meta: { cwd: opts.cwd ?? process.cwd() },
      agentOptions: { provider: this.selectionRef.current.provider, model: this.selectionRef.current.model },
      ...(seed ? { seed } : {}),
      setup: (agentCtx: Context) => {
        installModelSelection(agentCtx, this.selectionRef)
      },
    })
    this.agent = agent
    this.sessionId = String(agent.session.id)
    // k5：前一会话残留的挂起提问作废（其宿主 UI 卡片随 cancelled 事件撤下）
    if (this.pendingQuestion) {
      const old = this.pendingQuestion
      this.pendingQuestion = null
      old.cleanup()
      this.emit('question', { qid: old.qid, kind: 'cancelled' })
      old.resolve({ answers: old.questions.map((q) => ({ id: q.id, selected: [] })) })
    }
    // 游标对齐到「已存在事件的最后一格」（seq-1）：fresh 会话为 -1，首个事件
    // （followup 的 agent/inbox/splice，seq 0）即可流过镜像；seed 会话历史已随
    // log-reset 全量下行，增量自 end-seed 标记（seq M，创建期追加、监听器未及
    // 捕获）之后接续，seq 契约（seq = log.length）保证无空洞。
    this.lastRoundSeq = agent.session.seq - 1
    this.lastLoggedSeq = agent.session.seq - 1
    this.thinkAccKey = ''
    this.thinkAccText = ''
    this.thinkEmitLen = 0
    this.thinkEmitAt = 0
    this.ansAccKey = ''
    this.ansAccText = ''
    this.ansEmitAt = 0
    this.ansEmitLen = 0
    // 日志全量下行：宿主以此重写 .jsonl（文件收敛到内核真相 — seed + end-seed 边界 + 初始事件，
    // 顺带清除崩溃残留的未平衡尾部）
    this.emit('log-reset', { sessionId: this.sessionId, events: agent.session.events })
    return String(agent.session.id)
  }

  /** 发送一条消息，等待回合结束，返回 assistant 回复（对象参数 — callFunc 单 JSON 参数协议） */
  async chat(opts: { text: string }): Promise<ChatOutcome> {
    if (!this.ctx) throw new Error('HarnessEngine not initialized')
    if (!this.agent) throw new Error('No session — call createSession() first')
    const text = opts.text
    const agent = this.agent
    const sessions = this.ctx.get('sessions') as unknown as { flush: (s: unknown) => Promise<void> } | undefined

    const firstSeq = agent.session.seq
    agent.followup(createUserMessage({
      content: [{ type: 'text', text }],
      source: { kind: 'user' },
    }))
    await agent.whenIdle()
    try {
      if (sessions) await sessions.flush(agent.session)
    } catch { /* flush 失败不影响回合结果 */ }

    const events = agent.session.events.filter((e) => e.seq >= firstSeq)
    const { text: reply, reason } = summarizeEvents(events, firstSeq)
    const details = extractDetails(events, firstSeq)
    const sessionId = String(agent.session.id)
    let finalText = reply
    if (!finalText && reason) {
      if (reason.kind === 'aborted') finalText = '（本轮已停止）'
      else if (reason.kind === 'max-steps') finalText = '（已达单回合工具步数上限，提前结束；继续发送消息可接着执行）'
      else if (reason.kind === 'max-tokens') finalText = '（模型输出达到长度上限被截断：深度思考占满了输出额度。可简化问题、降低思考强度，或换用输出额度更大的模型后重试）'
    }
    this.emit('chat', { sessionId, text: finalText, reason, details })
    return { sessionId, text: finalText, reason, details }
  }

  /** 回合运行中转向（steering）：消息注入当前回合下一 step 边界 — 不打断在途 LLM 请求，
   *  下一次请求派生历史时以普通 user/message 出现，模型随即看到。
   *  idle 时降级为普通 chat（语义：立即处理）。立即返回 {ok,steered} — 本回合剩余产物
   *  （含转向后的 assistant 输出）由仍在等待中的原 chat() 的 ChatOutcome 统一携带。
   *  注：running 检查与 steer 之间存在极小竞窗（回合恰在此间结束则 steer 会开启一个
   *  无人收口的新回合），宿主应以「busy 中才可转向」作为主闸。 */
  async steer(opts: { text: string }): Promise<Record<string, unknown>> {
    if (!this.ctx) throw new Error('HarnessEngine not initialized')
    const agent = this.agent as unknown as
      | { phase?: { kind: string }; steer: (message: unknown) => Promise<void> }
      | null
    if (!agent) throw new Error('No session — call createSession() first')
    const running = agent.phase && agent.phase.kind === 'running'
    if (!running) return this.chat(opts)
    await agent.steer(createUserMessage({
      content: [{ type: 'text', text: opts.text }],
      source: { kind: 'user' },
    }))
    return { ok: true, steered: true }
  }

  /** 回答 agent 提问（k5）：resolve 挂起的 provider ask()，答案作为 tool result 回给模型。
   *  校验对齐 apiproxy matchesQuestions 语义：answers 数量 == questions 数量、id 逐一
   *  匹配、selected 为该题选项 label 子集且无重复；非 multiSelect 时 selected ≤ 1 且
   *  custom 与 selected 互斥。qid 不匹配（已取消/过期）返回 ok:false。 */
  answerQuestion(payload: { qid: number; answers: Array<{ id: string; selected: string[]; custom?: string }> }): { ok: boolean; error?: string } {
    const pending = this.pendingQuestion
    if (!pending || Number(payload.qid) !== pending.qid) return { ok: false, error: 'no pending question' }
    const answers = Array.isArray(payload.answers) ? payload.answers : []
    if (answers.length !== pending.questions.length) {
      return { ok: false, error: `answers.length (${answers.length}) != questions.length (${pending.questions.length})` }
    }
    for (const q of pending.questions) {
      const a = answers.find((x) => x && x.id === q.id)
      if (!a) return { ok: false, error: `missing answer for "${q.id}"` }
      const labels = new Set((q.options || []).map((o) => o.label))
      const selected = Array.isArray(a.selected) ? a.selected : []
      if (new Set(selected).size !== selected.length) return { ok: false, error: `duplicate selection for "${q.id}"` }
      for (const s of selected) if (!labels.has(s)) return { ok: false, error: `"${s}" is not an option of "${q.id}"` }
      if (!q.multiSelect && selected.length > 1) return { ok: false, error: `"${q.id}" is single-select` }
      const custom = typeof a.custom === 'string' ? a.custom.trim() : ''
      if (!q.multiSelect && custom !== '' && selected.length > 0) {
        return { ok: false, error: `"${q.id}": custom and selected are mutually exclusive` }
      }
    }
    pending.cleanup()
    this.pendingQuestion = null
    pending.resolve({
      answers: answers.map((a) => ({
        id: a.id,
        selected: Array.isArray(a.selected) ? a.selected : [],
        ...(typeof a.custom === 'string' && a.custom.trim() !== '' ? { custom: a.custom } : {}),
      })),
    })
    this.emit('question', { qid: payload.qid, kind: 'answered' })
    return { ok: true }
  }

  /** 开关 Plan 模式（k5）：回合外立即落 plan/mode 事件（'committed'），回合内挂起到
   *  下一 pre-step（'queued'）。TurnDetails.planActive 随回合事件流折叠，UI 由此跟踪。 */
  setPlanMode(opts: { active: boolean }): { ok: boolean; result: 'committed' | 'queued' | 'cancelled' | 'noop'; active: boolean } {
    if (!this.ctx) throw new Error('HarnessEngine not initialized')
    const agent = this.agent
    if (!agent) throw new Error('No session — call createSession() first')
    const svc = this.ctx.get('planMode') as unknown as
      | { set: (agent: unknown, active: boolean) => 'committed' | 'queued' | 'cancelled' | 'noop'; get: (agent: unknown) => { active: boolean; pending?: boolean } }
      | undefined
    if (!svc) throw new Error('planMode service unavailable')
    const result = svc.set(agent, opts.active === true)
    const state = svc.get(agent)
    return { ok: true, result, active: state.active }
  }

  /** 设备能力全链路自测 — QuickJS 桥(__harnessDeviceCall) → native → 宿主 DeviceBridge → 回包闭环 */
  async deviceSelfTest(opts: { op: string; args?: object }): Promise<object> {
    const bridge = globalThis as unknown as { __deviceCall?: (op: string, args: object) => Promise<object> }
    if (typeof bridge.__deviceCall !== 'function') {
      throw new Error('device bridge unavailable (__harnessDeviceCall not registered)')
    }
    return await bridge.__deviceCall(opts.op, opts.args ?? {})
  }

  /** 中断当前回合 — agent.cancel 后等待空闲；UI 停止按钮 / 宿主看门狗调用 */
  async abortActive(): Promise<{ ok: boolean; wasRunning?: boolean; error?: string }> {
    const agent = this.agent as unknown as
      | { phase?: { kind: string }; cancel: (reason: unknown) => void; whenIdle: () => Promise<void> }
      | null
    if (!agent) return { ok: false, error: 'no session' }
    if (agent.phase && agent.phase.kind === 'running') {
      agent.cancel({ kind: 'user-abort', message: 'user stopped the round' })
      await agent.whenIdle()
      return { ok: true, wasRunning: true }
    }
    return { ok: true, wasRunning: false }
  }

  /** 手动压缩当前会话上下文（须在回合间调用 — 内核 runMaintenance 空闲门控）。
   *  成功：{ ok: true, summary, shadowedCount, shadowedTokens }
   *  拒绝：{ ok: false, error, code } — code ∈ busy|changed|summary|commit|persistence。 */
  async compactNow(): Promise<Record<string, unknown>> {
    if (!this.ctx) throw new Error('HarnessEngine not initialized')
    const agent = this.agent
    if (!agent) throw new Error('No session — call createSession() first')
    const svc = this.ctx.get('compaction') as unknown as
      | { compactNow: (agent: unknown, signal: AbortSignal) => Promise<unknown> }
      | undefined
    if (!svc) throw new Error('compaction service unavailable')
    const controller = new AbortController()
    try {
      const r = await svc.compactNow(agent, controller.signal)
      // 合法 no-op：无可压缩的有用历史时内核返回 null
      if (r === null || r === undefined) return { ok: true, noop: true, shadowedCount: 0, shadowedTokens: 0 }
      const res = r as {
        summary?: unknown
        shadowed?: { seqs?: unknown[]; tokenCount?: unknown } | undefined
      }
      let summary = ''
      if (typeof res.summary === 'string') summary = res.summary
      else if (Array.isArray(res.summary)) {
        summary = (res.summary as Array<{ text?: unknown }>).map((b) => String(b?.text ?? '')).join('\n').trim()
      }
      const shadowed = res.shadowed
      return {
        ok: true,
        summary: summary.slice(0, 4000),
        shadowedCount: Array.isArray(shadowed?.seqs) ? shadowed.seqs.length : 0,
        shadowedTokens: Number(shadowed?.tokenCount ?? 0),
      }
    } catch (e) {
      const err = e as { code?: unknown; message?: unknown }
      // cause 链拼接（内核 ManualCompactionError 的根因 — 如 shrink 检查的 token
      // 数字 — 在 cause.message，宿主 UI 需要区分「没东西可压」与「真失败」）
      let detail = String(err.message ?? e)
      let cause = (e as { cause?: unknown }).cause
      let hops = 0
      while (cause !== undefined && cause !== null && hops < 5) {
        detail += ` <- ${String((cause as { message?: unknown }).message ?? cause)}`
        cause = (cause as { cause?: unknown }).cause
        hops++
      }
      return {
        ok: false,
        error: detail,
        ...(err.code !== undefined && err.code !== null ? { code: String(err.code) } : {}),
      }
    }
  }

  /** 切换模型 — 对当前会话的下一条消息生效（installModelSelection 拦截 agent/request） */
  setModel(opts: { provider: string; model: string; reasoningEffort?: string }): void {
    const { provider, model } = opts
    this.selectionRef.current = { provider, model, ...(opts.reasoningEffort ? { reasoningEffort: opts.reasoningEffort } : {}) }
  }

  /** 当前模型选择 */
  getModel(): ModelSelection {
    return { ...this.selectionRef.current }
  }

  /** 当前会话的已生成标题（内核 log 折叠快照；未生成时无 title 字段） */
  getTitle(): { title?: string; source?: string } {
    const svc = this.ctx?.get('sessionTitle') as unknown as
      | { get: (session: unknown) => { title: string; source: { kind: string } } | undefined }
      | undefined
    if (!svc || !this.agent) return {}
    const snap = svc.get(this.agent.session)
    if (!snap) return {}
    return { title: snap.title, source: snap.source.kind }
  }

  /** 手动重命名会话标题 — user 来源会「固定」标题（后续用户消息不再自动生成） */
  renameSession(title: string): { title: string } {
    const svc = this.ctx?.get('sessionTitle') as unknown as
      | { rename: (session: unknown, title: string) => { title: string } }
      | undefined
    if (!svc || !this.agent) throw new Error('sessionTitle service unavailable')
    return { title: svc.rename(this.agent.session, title).title }
  }

  async dispose(): Promise<void> {
    if (this.ctx) {
      await this.ctx.fiber.dispose()
      this.ctx = null
      this.agent = null
    }
  }

  /** k7e：当前可见后台任务的精简视图（对齐 host JobView — 跨线子集，剔除内部字段） */
  private jobViews(): Array<Record<string, unknown>> {
    if (!this.jobs) return []
    try {
      const snaps = this.jobs.list(this.agent ?? undefined) || []
      return snaps.map((s) => ({
        id: String(s.id ?? ''),
        kind: String(s.kind ?? ''),
        label: String(s.label ?? ''),
        status: String(s.status ?? ''),
        ...(s.detail !== undefined ? { detail: String(s.detail) } : {}),
        startedAt: Number(s.startedAt ?? 0),
        ...(s.finishedAt !== undefined ? { finishedAt: Number(s.finishedAt) } : {}),
      }))
    } catch {
      return []
    }
  }

  /** k7e：列出当前会话可见的后台任务（后台 bash / 子代理等） */
  listJobs(): { ok: boolean; jobs: Array<Record<string, unknown>> } {
    return { ok: true, jobs: this.jobViews() }
  }

  /** k7e：请求终止一个后台任务（bash 终止）。返回 requested / already-finished。 */
  killJob(payload: { id: string; reason?: string }): { ok: boolean; result?: string; error?: string } {
    if (!this.jobs) return { ok: false, error: 'jobs service unavailable' }
    const id = String(payload?.id ?? '')
    if (!id) return { ok: false, error: 'missing job id' }
    try {
      const r = this.jobs.kill(id, this.agent ?? undefined, payload.reason ?? 'user terminated from mobile')
      // 终止后可见集变化由 onJobsChanged 推送；这里同步补一帧保证 host 立即刷新
      try { this.emit('jobs', { sessionId: this.sessionId, jobs: this.jobViews() }) } catch { /* 忽略 */ }
      return { ok: true, result: String(r) }
    } catch (e) {
      return { ok: false, error: String((e as { message?: unknown })?.message ?? e) }
    }
  }
}

// ── 工厂 + 便捷函数 ─────────────────────────────────────────

export function createEngine(): HarnessEngine {
  return new HarnessEngine()
}

// 兼容旧宿主（one-shot）：
export { Inbox, installModelSelection, SessionId, createUserMessage }
export { LlmRuntime }
