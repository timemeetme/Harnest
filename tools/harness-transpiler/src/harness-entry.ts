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
import AgentLoop from '../../core/agent-loop/src/index.ts'
// 工具层：todo_write（整表快照事件 todo/write — 消息流/详情页渲染数据源）
import * as ToolTodo from '../../todo/tool-todo/src/index.ts'

// ── LLM 层 ─────────────────────────────────────────────────
import LlmRuntime, { createUserMessage, resolveRetryPolicy, LlmError } from '@deepseek-ai/dsh-llm'
// 注意：headless 包的 node_modules 未链接 dsh-llm-deepseek / dsh-credentials，
// 用相对路径直达源码（构建时 harness-entry.ts 位于 packages/bundle/headless/）
import { DeepSeekAdapter } from '../../llm/llm-deepseek/src/adapter.ts'
import type { DeepSeekConnectionOptions } from '../../llm/llm-deepseek/src/adapter.ts'
import { credentialRef } from '../../credentials/credentials/src/index.ts'
import type { AnonymousUserId } from '../../identity/anonymous-user-id/src/index.ts'

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
  todos: TodoSnapshotItem[] | null
  subagents: SubagentEntry[]
  planActive: boolean
  usage: TurnUsage | null
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
  let todos: TodoSnapshotItem[] | null = null
  let planActive = false
  let usage: TurnUsage | null = null
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
      const message = d.message as
        | { callId?: unknown; content?: Array<{ type?: string; text?: string }>; isError?: boolean }
        | undefined
      const callId = String((message && message.callId) ?? d.callId ?? '')
      const entry = byId.get(callId)
      if (!entry) continue
      const text = ((message && message.content) || [])
        .filter((block) => block.type === 'text')
        .map((block) => block.text || '')
        .join('')
      entry.status = (message && message.isError) || d.error !== undefined ? 'error' : 'ok'
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
      defaults: {},
      maxTokens: profile.maxTokens ?? 8192,
      defaultContextWindow: profile.contextWindow ?? 65536,
      models: profile.models.map((m) => ({
        id: m.id,
        ...(m.name !== undefined ? { name: m.name } : {}),
        ...(m.contextWindow !== undefined ? { contextWindow: m.contextWindow } : {}),
        ...(m.maxTokens !== undefined ? { maxTokens: m.maxTokens } : {}),
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

  /** 创建（或恢复）会话 agent，返回 sessionId */
  async createSession(opts: { cwd?: string; provider?: string; model?: string; sessionId?: string } = {}): Promise<string> {
    if (!this.ctx) throw new Error('HarnessEngine not initialized')
    const agents = this.ctx.get('agents') as unknown as {
      create: (opts: Record<string, unknown>) => Promise<{ agent: NonNullable<HarnessEngine['agent']> }>
    }
    if (!agents) throw new Error('AgentRegistry service unavailable')

    if (opts.provider && opts.model) {
      this.selectionRef.current = { provider: opts.provider, model: opts.model }
    }

    const { agent } = await agents.create({
      sessionId: SessionId(opts.sessionId ?? `session-${randomId()}`),
      meta: { cwd: opts.cwd ?? process.cwd() },
      agentOptions: { provider: this.selectionRef.current.provider, model: this.selectionRef.current.model },
      setup: (agentCtx: Context) => {
        installModelSelection(agentCtx, this.selectionRef)
      },
    })
    this.agent = agent
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
    this.emit('chat', { sessionId, text: reply, reason, details })
    return { sessionId, text: reply, reason, details }
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

  async dispose(): Promise<void> {
    if (this.ctx) {
      await this.ctx.fiber.dispose()
      this.ctx = null
      this.agent = null
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
