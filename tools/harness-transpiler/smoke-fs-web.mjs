/**
 * smoke-fs-web.mjs — 阶段 1 能力补齐冒烟（Node vm 模拟 QuickJS 宿主）
 *
 * 覆盖：
 *  1. fs 工具三件套：write → read → edit 全链路（__harnessFsCall mock 落真实临时目录）
 *  2. rename/realpath 宿主新 op（fs shim renameSync/realpathSync 往返）
 *  3. web_fetch：mock 页面抓取 → markdown 化输出
 *  4. subagent：进程内子代理单轮完成并回报
 *
 * 退出码 0=全过；1=失败。
 */
import { readFileSync, writeFileSync, mkdirSync, rmSync, readdirSync, statSync, existsSync, renameSync } from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import vm from 'node:vm'
import { fileURLToPath } from 'node:url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const HARNESS = path.join(__dirname, 'output', 'harness.js')
const code = readFileSync(HARNESS, 'utf8')

// ── 临时沙箱目录（POSIX 路径形态，与真机 App 沙箱一致；mock fs 映射到本地真实目录）──
const SANDBOX = `/data/local/tmp/harness-smoke-fs-${Date.now()}`
const SANDBOX_HOST = path.join(os.tmpdir(), `harness-smoke-fs-${Date.now()}`)
mkdirSync(SANDBOX_HOST, { recursive: true })
const fsCallLog = []

// ── mock __harnessFsCall：同步桥，契约与三端宿主一致（{op,...} → {ok,...}）──
function fsResolve(p) {
  let norm = String(p).replace(/\\/g, '/')
  if (norm.startsWith(SANDBOX + '/')) norm = norm.slice(SANDBOX.length + 1)
  else if (norm === SANDBOX) norm = ''
  const abs = path.isAbsolute(norm) ? path.join(SANDBOX_HOST, path.basename(norm)) : path.join(SANDBOX_HOST, norm)
  const rel = path.relative(SANDBOX_HOST, abs)
  if (rel.startsWith('..') || path.isAbsolute(rel)) return null
  return abs
}
function fsCall(reqJson) {
  const req = JSON.parse(String(reqJson))
  const { op, path: p } = req
  fsCallLog.push(`${op} ${p}${req.newPath ? ' -> ' + req.newPath : ''}`)
  try {
    const abs = fsResolve(p)
    if (!abs) return JSON.stringify({ ok: false, error: `path escapes sandbox: ${p}` })
    switch (op) {
      case 'exists': {
        const ok = existsSync(abs)
        return JSON.stringify({ ok: true, exists: ok, isDir: ok && statSync(abs).isDirectory() })
      }
      case 'readFile': {
        const buf = readFileSync(abs)
        if (req.text === false) return JSON.stringify({ ok: true, data: buf.toString('base64') })
        return JSON.stringify({ ok: true, data: buf.toString('utf8') })
      }
      case 'writeFile': {
        mkdirSync(path.dirname(abs), { recursive: true })
        const data = req.base64 ? Buffer.from(req.data ?? '', 'base64') : Buffer.from(req.data ?? '', 'utf8')
        writeFileSync(abs, data)
        return JSON.stringify({ ok: true })
      }
      case 'readdir':
        return JSON.stringify({ ok: true, entries: readdirSync(abs) })
      case 'mkdir':
        mkdirSync(abs, { recursive: req.recursive !== false })
        return JSON.stringify({ ok: true })
      case 'rm':
        if (!existsSync(abs)) return JSON.stringify({ ok: false })
        rmSync(abs, { recursive: !!req.recursive, force: true })
        return JSON.stringify({ ok: true })
      case 'stat': {
        const st = statSync(abs)
        return JSON.stringify({ ok: true, isDir: st.isDirectory(), size: st.isDirectory() ? 0 : st.size, mtimeMs: st.mtimeMs })
      }
      case 'rename': {
        const target = fsResolve(req.newPath ?? '')
        if (!target) return JSON.stringify({ ok: false, error: `path escapes sandbox: ${req.newPath}` })
        mkdirSync(path.dirname(target), { recursive: true })
        renameSync(abs, target)
        return JSON.stringify({ ok: true })
      }
      case 'realpath':
        return JSON.stringify({ ok: true, path: abs })
      default:
        return JSON.stringify({ ok: false, error: `unknown op: ${op}` })
    }
  } catch (e) {
    return JSON.stringify({ ok: false, error: String(e?.message ?? e) })
  }
}

// ── mock fetch：chat SSE + web_fetch 页面抓取 ──
let fetchStep = 0
const sandbox = {
  console,
  setTimeout, clearTimeout, setInterval, clearInterval,
  queueMicrotask,
  performance,
  TextEncoder, TextDecoder,
  URL, URLSearchParams,
  Blob, FormData, Headers, Request, Response,
  crypto: globalThis.crypto,
  navigator: { userAgent: 'smoke' },
  // 与真机 QuickJS 一致：不预注 require，让 host-bridge 的 require 拦截生效
  // （node:fs → fsShim / node:fs/promises → fsShim.promises / 其余 → __HARNESS_SHIMS）
  __harnessFsCall: fsCall,
  __harnessEmit: () => {},
}

const mkChunk = (delta, finish = null) => ({
  id: `chatcmpl-fs-${fetchStep}`, object: 'chat.completion.chunk', created: Date.now() / 1000 | 0, model: 'smoke',
  choices: [{ index: 0, delta, finish_reason: finish }],
})
const toolChunk = (name, argsObj, callId) => [
  mkChunk({ tool_calls: [{ index: 0, id: callId, type: 'function', function: { name, arguments: JSON.stringify(argsObj) } }] }),
  mkChunk({}, 'tool_calls'),
]
const sseOf = (chunks) => chunks.map((c) => `data: ${JSON.stringify(c)}\n\n`).join('') + 'data: [DONE]\n\n'

sandbox.fetch = async (url, init) => {
  const u = String(url)
  // web_fetch 页面抓取：返回简单 HTML（tool-web 会做 Readability/markdown 化）
  if (u.includes('page.local')) {
    const html = '<html><head><title>Smoke Page</title></head><body><h1>Smoke Page</h1><p>WEBFETCH_MARKER 冒烟页面正文。</p></body></html>'
    const rs = new sandbox.ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode(html)); c.close() } })
    return { ok: true, status: 200, headers: { get: (k) => (String(k).toLowerCase() === 'content-type' ? 'text/html' : null) }, body: rs }
  }
  const body = String(init?.body ?? '')
  // 辅助调用（会话标题 / 压缩）：短文本收尾
  if (/"max_tokens":48[,.}]/.test(body) || body.includes('acting as a compaction engine')) {
    const cs = [mkChunk({ content: '冒烟' }, null), mkChunk({}, 'stop')]
    const rs = new sandbox.ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode(sseOf(cs))); c.close() } })
    return { ok: true, status: 200, headers: { get: () => null }, body: rs }
  }
  fetchStep++
  let chunks
  if (fetchStep === 1) {
    chunks = [...toolChunk('write', { file_path: 'out/smoke_fs.txt', content: 'hello 冒烟 😀 第一行\n第二行原文\n' }, 'call_w1')]
  } else if (fetchStep === 2) {
    chunks = [...toolChunk('read', { file_path: 'out/smoke_fs.txt' }, 'call_r1')]
  } else if (fetchStep === 3) {
    chunks = [...toolChunk('edit', { file_path: 'out/smoke_fs.txt', old_string: '第二行原文', new_string: '第二行已编辑' }, 'call_e1')]
  } else if (fetchStep === 4) {
    chunks = [mkChunk({ content: 'FS_ROUND_DONE' }), mkChunk({}, 'stop')]
  } else if (fetchStep === 5) {
    chunks = [...toolChunk('web_fetch', { url: 'http://page.local/index.html' }, 'call_wf1')]
  } else if (fetchStep === 6) {
    chunks = [mkChunk({ content: 'WEB_ROUND_DONE' }), mkChunk({}, 'stop')]
  } else if (fetchStep === 7) {
    chunks = [...toolChunk('subagent', { description: '冒烟子代理', prompt: '请直接回复 SUBAGENT_CHILD_OK，不要使用任何工具。' }, 'call_sa1')]
  } else if (fetchStep === 9) {
    // step 8 被子代理内部回合消费，主循环收尾在 step 9
    chunks = [mkChunk({ content: 'SUB_ROUND_DONE' }), mkChunk({}, 'stop')]
  } else {
    // 子代理内部回合：直接收尾（不调用工具）
    chunks = [mkChunk({ content: 'SUBAGENT_CHILD_OK' }), mkChunk({}, 'stop')]
  }
  chunks = [...chunks, { id: `chatcmpl-fs-${fetchStep}`, object: 'chat.completion.chunk', created: Date.now() / 1000 | 0, model: 'smoke', choices: [], usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 } }]
  const rs = new sandbox.ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode(sseOf(chunks))); c.close() } })
  return { ok: true, status: 200, headers: { get: () => null }, body: rs }
}

vm.createContext(sandbox)
const results = []
const check = (name, cond) => { results.push([name, !!cond]); console.log(`${cond ? 'PASS' : 'FAIL'} ${name}`) }

try {
  vm.runInContext(code, sandbox, { filename: 'harness.js' })
  check('bundle boots & createEngine exposed', typeof sandbox.createEngine === 'function')

  const engine = sandbox.createEngine()
  await engine.init({
    cwd: SANDBOX,
    providers: [{
      provider: 'smoke-provider', baseUrl: 'http://smoke.local/v1', apiKey: 'sk-smoke',
      models: [{ id: 'smoke-model', name: 'Smoke Model', contextWindow: 65536, maxTokens: 4096 }],
    }],
    defaultProvider: 'smoke-provider', defaultModel: 'smoke-model',
  })
  check('init() ok with fs/web/subagent plugins', true)

  await engine.createSession({ cwd: SANDBOX })

  // ── 回合 1：fs 三件套 write → read → edit ──
  const chat1 = await engine.chat({ text: '写入并编辑文件' })
  const t1 = (chat1?.details?.toolCalls ?? []).map(t => t.name)
  console.log('DEBUG fsCallLog:', JSON.stringify(fsCallLog.slice(0, 24)))
  console.log('DEBUG toolResults:', JSON.stringify((chat1?.details?.toolCalls ?? []).map(t => ({ n: t.name, r: String(t.result ?? '').slice(0, 160) }))))
  check('fs round completed', chat1?.text === 'FS_ROUND_DONE')
  check('model invoked write/read/edit', ['write', 'read', 'edit'].every(n => t1.includes(n)))
  const onDisk = readFileSync(path.join(SANDBOX_HOST, 'out', 'smoke_fs.txt'), 'utf8')
  check('write+edit landed on host fs', onDisk.includes('hello 冒烟 😀') && onDisk.includes('第二行已编辑') && !onDisk.includes('第二行原文'))

  // ── rename/realpath 宿主新 op（shim 层直测）──
  const renameOk = JSON.parse(fsCall(JSON.stringify({ op: 'rename', path: 'out/smoke_fs.txt', newPath: 'out/renamed.txt' })))
  const realOk = JSON.parse(fsCall(JSON.stringify({ op: 'realpath', path: 'out/renamed.txt' })))
  check('rename op round-trip', renameOk.ok === true && existsSync(path.join(SANDBOX_HOST, 'out', 'renamed.txt')))
  check('realpath op round-trip', realOk.ok === true && String(realOk.path).includes('renamed.txt'))

  // ── 回合 2：web_fetch ──
  const chat2 = await engine.chat({ text: '抓取页面' })
  const wf = (chat2?.details?.toolCalls ?? []).find(t => t.name === 'web_fetch')
  console.log('DEBUG web_fetch result:', JSON.stringify(String(wf?.result ?? '')).slice(0, 500))
  check('web_fetch round completed', chat2?.text === 'WEB_ROUND_DONE')
  check('web_fetch returned page content', !!wf && /WEBFETCH\\?_MARKER/.test(String(wf.result ?? '')))

  // ── 回合 3：subagent（进程内子代理）──
  const chat3 = await engine.chat({ text: '派一个子代理' })
  const sa = (chat3?.details?.toolCalls ?? []).find(t => t.name === 'subagent')
  console.log('DEBUG chat3.text:', JSON.stringify(chat3?.text), 'subagent result:', JSON.stringify(String(sa?.result ?? '')).slice(0, 500))
  check('subagent round completed', chat3?.text === 'SUB_ROUND_DONE')
  check('subagent child completed & reported', !!sa && /SUBAGENT_CHILD_OK/.test(String(sa.result ?? '')))
} catch (e) {
  console.log('SMOKE CRASH:', e?.stack ?? String(e))
  results.push(['no crash', false])
} finally {
  try { rmSync(SANDBOX_HOST, { recursive: true, force: true }) } catch { /* 清理失败不致命 */ }
}

const failed = results.filter(([, ok]) => !ok)
console.log(failed.length === 0 ? `\nALL ${results.length} PASS` : `\n${failed.length}/${results.length} FAILED`)
process.exit(failed.length === 0 ? 0 : 1)
