/**
 * check-quickjs-compat.mjs — QuickJS 兼容性门禁（CI 严重错误）
 *
 * 目的：内核（deepseek-harness）更新后，新增代码可能引用 QuickJS 环境不存在的
 * Web/Node API（如 performance、FormData、Blob…），此前只会在手机上运行时才爆炸。
 * 本脚本对 esbuild 产物做静态分析，把"缺失 API"提升为 CI 构建失败（exit 1），
 * 并输出 AI 可直接消费的结构化报告（quickjs-compat-report.json）。
 *
 * 判定模型：
 *   自由引用 = 代码中引用 − 代码内声明 − QuickJS 内置 − polyfill 提供 − 宿主注入 − 白名单
 *   - 自由引用缺失 → error（CI fail）
 *   - typeof X 守卫内的引用 → info（运行时安全探测，不 fail）
 *
 * 误报控制：声明收集不做作用域区分（全文件并集）——宁可漏报也不误报，
 * 因为误报会摧毁 CI 信任；真正被局部变量遮蔽的名字运行时本就不会炸。
 *
 * 用法：
 *   node check-quickjs-compat.mjs                       # 检查 output/harness.bundle.js
 *   node check-quickjs-compat.mjs --bundle <file>       # 指定 bundle
 *   node check-quickjs-compat.mjs --kernel-commit abc   # 报告附内核 commit
 *   node check-quickjs-compat.mjs --report <file.json>  # JSON 报告输出路径
 *
 * 退出码：0 = 通过；1 = 存在缺失 API（CI 明确报错）；2 = 工具自身故障。
 */

import { parse } from 'acorn'
import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

// ── CLI 参数 ──────────────────────────────────────────────
const args = process.argv.slice(2)
const getOpt = (name) => {
  const i = args.indexOf('--' + name)
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null
}
const BUNDLE = getOpt('bundle') || path.join(__dirname, 'output', 'harness.bundle.js')
const REPORT_OUT = getOpt('report') || path.join(__dirname, 'output', 'quickjs-compat-report.json')
const KERNEL_COMMIT = getOpt('kernel-commit') || ''

// ── QuickJS（ES2023）全局内置 ─────────────────────────────
const QUICKJS_BUILTINS = new Set([
  // 值与函数
  'globalThis', 'Infinity', 'NaN', 'undefined', 'arguments',
  'eval', 'isFinite', 'isNaN', 'parseFloat', 'parseInt',
  'decodeURI', 'decodeURIComponent', 'encodeURI', 'encodeURIComponent',
  'escape', 'unescape', 'gc',
  // 构造器与命名空间
  'AggregateError', // QuickJS 支持（ES2021，Promise.any 依赖）
  'Array', 'ArrayBuffer', 'Atomics', 'BigInt', 'BigInt64Array', 'BigUint64Array',
  'Boolean', 'DataView', 'Date', 'Error', 'EvalError', 'FinalizationRegistry',
  'Float32Array', 'Float64Array', 'Function', 'Int8Array', 'Int16Array', 'Int32Array',
  'JSON', 'Map', 'Math', 'Number', 'Object', 'Promise', 'Proxy', 'RangeError',
  'ReferenceError', 'Reflect', 'RegExp', 'Set', 'String', 'Symbol', 'SyntaxError',
  'TypeError', 'URIError', 'Uint8Array', 'Uint8ClampedArray', 'Uint16Array', 'Uint32Array',
  'WeakMap', 'WeakRef', 'WeakSet',
])

// ── polyfill 提供集合：从 polyfills 源码自动提取 global.X = ──
function extractPolyfillGlobals() {
  const names = new Set()
  const files = [
    path.join(__dirname, 'polyfills', 'host-bridge.js'),
    path.join(__dirname, 'polyfills', 'harness-shims-iife.js'),
    path.join(__dirname, 'polyfills', 'device-bridge.js'),
  ]
  const re = /\bglobal(?:This)?\.([A-Za-z_$][\w$]*)\s*=/g
  for (const f of files) {
    if (!existsSync(f)) continue
    const src = readFileSync(f, 'utf-8')
    let m
    while ((m = re.exec(src)) !== null) names.add(m[1])
  }
  // 手工兜底（防止提取正则失配后全量误报）
  for (const n of [
    'console', 'crypto', 'structuredClone', 'btoa', 'atob',
    'URL', 'URLSearchParams', 'TextEncoder', 'TextDecoder', 'TextDecoderStream',
    'AbortController', 'AbortSignal',
    'ReadableStream', 'WritableStream', 'TransformStream',
    'Headers', 'fetch', 'require', 'process', 'global',
    'setTimeout', 'clearTimeout', 'setInterval', 'clearInterval',
    '__harnessOnFetchHeaders', '__harnessOnFetchChunk', '__harnessOnFetchDone', '__harnessOnFetchFail',
    '__HARNESS_SHIMS', '__HARNESS_CWD', '__HARNESS_ENV',
  ]) names.add(n)
  return names
}

// ── 宿主（native C 层 / ArkTS）注入的全局 ─────────────────
const HOST_INJECTED = new Set([
  '__harnessFetchStart', '__harnessFsCall', '__harnessEmit',
  '__harnessLog', '__harnessExit',
])

// ── 白名单：人工确认安全的引用（不报错）──────────────────
const ALLOWLIST_PATH = path.join(__dirname, 'quickjs-compat-allowlist.json')
function loadAllowlist() {
  if (!existsSync(ALLOWLIST_PATH)) return new Map()
  try {
    const obj = JSON.parse(readFileSync(ALLOWLIST_PATH, 'utf-8'))
    return new Map(Object.entries(obj.names || {}))
  } catch (e) {
    console.error(`::error title=check-quickjs-compat|allowlist 解析失败: ${e.message}`)
    process.exit(2)
  }
}

// ── AST 工具 ─────────────────────────────────────────────
/** 通用递归遍历：visitor(node, parent, key, ancestors)；自动跳过非 AST 字段 */
function traverse(node, visitor, parent = null, key = null, ancestors = []) {
  if (!node || typeof node.type !== 'string') return
  visitor(node, parent, key, ancestors)
  const next = [...ancestors, node]
  for (const k of Object.keys(node)) {
    if (k === 'type' || k === 'start' || k === 'end' || k === 'loc' || k === 'raw') continue
    const v = node[k]
    if (Array.isArray(v)) {
      for (const c of v) if (c && typeof c.type === 'string') traverse(c, visitor, node, k, next)
    } else if (v && typeof v.type === 'string') {
      traverse(v, visitor, node, k, next)
    }
  }
}

/** 递归收集 binding pattern 内的全部 Identifier（声明位置） */
function collectPattern(pattern, patternNodes, declared) {
  if (!pattern || typeof pattern.type !== 'string') return
  switch (pattern.type) {
    case 'Identifier':
      patternNodes.add(pattern)
      declared.add(pattern.name)
      return
    case 'RestElement':
      collectPattern(pattern.argument, patternNodes, declared)
      return
    case 'AssignmentPattern':
      collectPattern(pattern.left, patternNodes, declared)
      // default 值是表达式，非声明 —— 留给引用收集
      return
    case 'ArrayPattern':
      for (const el of pattern.elements) collectPattern(el, patternNodes, declared)
      return
    case 'ObjectPattern':
      for (const prop of pattern.properties) {
        if (prop.type === 'RestElement') collectPattern(prop.argument, patternNodes, declared)
        else collectPattern(prop.value, patternNodes, declared) // key 非声明
      }
      return
    default:
      return
  }
}

function isKeyPosition(node, parent, key) {
  if (key === 'property' && parent && parent.type === 'MemberExpression' && !parent.computed) return true
  if (key === 'key' && parent && !parent.computed) return true // Property / MethodDefinition / PropertyDefinition
  if ((key === 'label' || key === 'body') && parent &&
      (parent.type === 'BreakStatement' || parent.type === 'ContinueStatement' || parent.type === 'LabeledStatement') && key === 'label') return true
  if (key === 'meta' || key === 'property' && parent && parent.type === 'MetaProperty') return true
  return false
}

// ── 主分析 ────────────────────────────────────────────────
function analyze(bundleSrc, fileLabel) {
  let ast
  try {
    ast = parse(bundleSrc, { ecmaVersion: 'latest', sourceType: 'module', allowHashBang: true })
  } catch (e) {
    console.error(`::error title=check-quickjs-compat|解析失败 ${fileLabel}:${e.loc ? e.loc.line : '?'} — ${e.message}`)
    process.exit(2)
  }

  const lineOf = (pos) => bundleSrc.slice(0, pos).split('\n').length
  const patternNodes = new WeakSet()
  const declared = new Set()

  // pass 1.5：收集 typeof 守卫区域 —— 这些子树内的裸引用运行时被短路/if 保护：
  //   if (typeof X !== "undefined") { X… }   → consequent 为 X 的守卫区域
  //   if (typeof X === "undefined") { } else { X… } → alternate 为守卫区域
  //   typeof X !== "undefined" && X…          → 右侧为守卫区域
  const guardRegions = [] // { name, node }
  function extractGuardName(test) {
    // 匹配 typeof X (!==|!=|===|==) "undefined"（含 ! 反转与操作数互换）
    if (test.type === 'UnaryExpression' && test.operator === '!') {
      const inner = extractGuardName(test.argument)
      if (!inner) return null
      return { name: inner.name, branch: inner.branch === 'consequent' ? 'alternate' : 'consequent' }
    }
    if (test.type !== 'BinaryExpression') return null
    const { left, right, operator } = test
    const isEq = operator === '===' || operator === '=='
    const isNe = operator === '!==' || operator === '!='
    if (!isEq && !isNe) return null
    let nameId = null
    if (left.type === 'UnaryExpression' && left.operator === 'typeof' &&
        left.argument.type === 'Identifier' &&
        right.type === 'Literal' && right.value === 'undefined') {
      nameId = left.argument
    } else if (right.type === 'UnaryExpression' && right.operator === 'typeof' &&
        right.argument.type === 'Identifier' &&
        left.type === 'Literal' && left.value === 'undefined') {
      nameId = right.argument
    }
    if (!nameId) return null
    // typeof X !== undefined 为真 ⇔ X 存在 → consequent 是存在区域；
    // typeof X === undefined 为真 ⇔ X 不存在 → alternate 是存在区域
    return { name: nameId.name, branch: isNe ? 'consequent' : 'alternate' }
  }
  traverse(ast, (node) => {
    if (node.type === 'IfStatement') {
      const g = extractGuardName(node.test)
      if (g) {
        const region = g.branch === 'consequent' ? node.consequent : node.alternate
        if (region) guardRegions.push({ name: g.name, node: region })
      }
    } else if (node.type === 'LogicalExpression' && node.operator === '&&') {
      const g = extractGuardName(node.left)
      if (g && g.branch === 'consequent') guardRegions.push({ name: g.name, node: node.right })
    }
  })
  const inGuardRegion = (name, ancestors) =>
    guardRegions.some((r) => r.name === name && ancestors.includes(r.node))

  // pass 1：收集全部声明（import / var / function / class / params / catch）
  // 注意：traverse 进入 visitor 的 node 是「子节点」，parent 是其父 ——
  // 因此这里的条件以 parent 类型 + key 位置判断，而非 node 自身类型
  const FN_TYPES = new Set(['FunctionDeclaration', 'FunctionExpression', 'ArrowFunctionExpression'])
  const IMPORT_SPECIFIERS = new Set(['ImportSpecifier', 'ImportDefaultSpecifier', 'ImportNamespaceSpecifier'])
  traverse(ast, (node, parent, key) => {
    if (!parent) return
    if (key === 'local' && IMPORT_SPECIFIERS.has(parent.type)) {
      collectPattern(node, patternNodes, declared)
      return
    }
    if (key === 'id' && (parent.type === 'VariableDeclarator' ||
        parent.type === 'FunctionDeclaration' || parent.type === 'ClassDeclaration' ||
        parent.type === 'FunctionExpression' || parent.type === 'ClassExpression')) {
      collectPattern(node, patternNodes, declared)
      return
    }
    if (key === 'param' && parent.type === 'CatchClause') {
      collectPattern(node, patternNodes, declared)
      return
    }
    if (key === 'params' && FN_TYPES.has(parent.type)) {
      // 数组元素逐个进入：node 是单个参数 pattern
      collectPattern(node, patternNodes, declared)
      return
    }
  })

  // pass 2：收集自由引用
  /** name → { lines: Set<number>, guarded: Set<number>, bare: Set<number> } */
  const refs = new Map()
  const get = (name) => {
    if (!refs.has(name)) refs.set(name, { lines: new Set(), guarded: new Set(), bare: new Set() })
    return refs.get(name)
  }

  traverse(ast, (node, parent, key, ancestors) => {
    if (node.type !== 'Identifier') return
    if (patternNodes.has(node)) return          // 声明位置
    if (isKeyPosition(node, parent, key)) return // 属性名 / 标签 / meta
    if (key === 'exported' && parent && parent.type === 'ExportSpecifier') return // 导出别名
    if (key === 'imported' && parent && parent.type === 'ImportSpecifier') return // 导入别名（模块说明符字符串）
    if (key === 'id' && parent && (parent.type === 'MethodDefinition' || parent.type === 'Property' || parent.type === 'PropertyDefinition')) return
    if (parent && parent.type === 'ExportSpecifier' && key === 'local') {
      // export { x } 的 local 是对 x 的引用 → 继续收集
    }
    const directTypeof = parent && parent.type === 'UnaryExpression' && parent.operator === 'typeof'
    const regionGuarded = inGuardRegion(node.name, ancestors)
    const rec = get(node.name)
    rec.lines.add(lineOf(node.start))
    if (directTypeof || regionGuarded) rec.guarded.add(lineOf(node.start))
    else rec.bare.add(lineOf(node.start))
  })

  return { refs, declared }
}

// ── 执行 ──────────────────────────────────────────────────
function main() {
  if (!existsSync(BUNDLE)) {
    console.error(`::error title=check-quickjs-compat|bundle 不存在: ${BUNDLE}（先运行 build.mjs）`)
    process.exit(2)
  }

  const polyfills = extractPolyfillGlobals()
  const allowlist = loadAllowlist()
  const src = readFileSync(BUNDLE, 'utf-8')
  const { refs, declared } = analyze(src, BUNDLE)

  const available = (name) =>
    QUICKJS_BUILTINS.has(name) || polyfills.has(name) || HOST_INJECTED.has(name) ||
    declared.has(name) || allowlist.has(name)

  const missing = []
  const typeofGuardedOnly = []

  for (const [name, rec] of refs) {
    if (available(name)) continue
    if (rec.bare.size > 0) {
      missing.push({
        name,
        kind: 'error',
        bareUseLines: [...rec.bare].sort((a, b) => a - b),
        typeofGuardedLines: [...rec.guarded].sort((a, b) => a - b),
        totalRefs: rec.lines.size,
      })
    } else {
      typeofGuardedOnly.push({
        name, kind: 'typeof-guarded',
        typeofGuardedLines: [...rec.guarded].sort((a, b) => a - b),
      })
    }
  }

  missing.sort((a, b) => b.totalRefs - a.totalRefs)

  // ── 控制台输出（CI 直接可读）────────────────────────────
  console.log('='.repeat(70))
  console.log('QuickJS Compatibility Gate — ' + path.basename(BUNDLE))
  console.log('='.repeat(70))
  console.log(`  Bundle:           ${BUNDLE}`)
  console.log(`  Kernel commit:    ${KERNEL_COMMIT || '(not provided)'}`)
  console.log(`  Free references:  ${refs.size}`)
  console.log(`  Polyfill globals: ${polyfills.size}`)
  console.log(`  Allowlisted:      ${allowlist.size}`)
  console.log()

  if (typeofGuardedOnly.length > 0) {
    console.log(`ℹ️  typeof 守卫的引用（${typeofGuardedOnly.length} 个，运行时安全探测，不阻断）:`)
    for (const it of typeofGuardedOnly.slice(0, 20)) {
      console.log(`     - ${it.name}  (lines: ${it.typeofGuardedLines.slice(0, 5).join(', ')}${it.typeofGuardedLines.length > 5 ? '…' : ''})`)
    }
    if (typeofGuardedOnly.length > 20) console.log(`     … 其余 ${typeofGuardedOnly.length - 20} 个见 JSON 报告`)
    console.log()
  }

  if (missing.length === 0) {
    console.log('✅ PASS — 未检测到 QuickJS 缺失的全局 API')
    writeReport(true, missing, typeofGuardedOnly)
    process.exit(0)
  }

  console.log('❌ FAIL — 检测到 QuickJS 缺失的全局 API（严重错误）')
  console.log()
  for (const it of missing) {
    const lines = it.bareUseLines.slice(0, 8).join(', ') + (it.bareUseLines.length > 8 ? '…' : '')
    console.log(`   ✖ ${it.name}  ×${it.totalRefs}  bare@ ${lines}`)
    // GitHub Annotations：CI 界面直接标红定位
    const first = it.bareUseLines[0]
    console.log(`::error file=${path.relative(path.join(__dirname, '..', '..'), BUNDLE).replace(/\\/g, '/')},line=${first},title=QuickJS 缺失 API: ${it.name}|内核代码引用了 QuickJS+polyfill 环境不存在的全局 "${it.name}"（裸引用 ${it.bareUseLines.length} 处）。需在 polyfills/host-bridge.js 补齐，或确认守卫安全后加入 quickjs-compat-allowlist.json`)
  }
  console.log()
  console.log('修复指引（供 AI 工具消费）：')
  console.log('  1. 为上述每个 API 在 tools/harness-transpiler/polyfills/host-bridge.js 实现 polyfill')
  console.log('     （参考现有 TextEncoder/AbortSignal/ReadableStream 的实现模式）')
  console.log('  2. 运行 pnpm -C tools/harness-transpiler all 重新生成 harness.js')
  console.log('  3. 本地复现：node tools/harness-transpiler/check-quickjs-compat.mjs')
  console.log('  4. 若某 API 已被 typeof 守卫且确认不会执行裸引用，加入 quickjs-compat-allowlist.json')

  writeReport(false, missing, typeofGuardedOnly)
  process.exit(1)
}

function writeReport(pass, missing, typeofGuardedOnly) {
  const report = {
    tool: 'check-quickjs-compat',
    version: 1,
    generatedAt: new Date().toISOString(),
    pass,
    bundle: BUNDLE,
    kernelCommit: KERNEL_COMMIT,
    summary: {
      missingCount: missing.length,
      typeofGuardedCount: typeofGuardedOnly.length,
      verdict: pass
        ? 'QuickJS 兼容性通过'
        : `存在 ${missing.length} 个 QuickJS 缺失的全局 API — CI 必须失败`,
    },
    missing,
    typeofGuardedOnly,
    howToFix: {
      forHuman: [
        '在 tools/harness-transpiler/polyfills/host-bridge.js 为每个 missing API 添加 polyfill',
        '运行 pnpm -C tools/harness-transpiler all 重新生成',
        '本地验证 node tools/harness-transpiler/check-quickjs-compat.mjs',
      ],
      forAi: [
        '你在修复 HarnessApp 的 QuickJS 兼容性门禁失败。',
        '对 report.missing[] 中每个 name：在 d:/Projects/HarnessApp/tools/harness-transpiler/polyfills/host-bridge.js 中按现有 polyfill 模式实现该 API（IIFE 内 if (typeof global.X === "undefined") global.X = ...）。',
        '重跑: pnpm -C tools/harness-transpiler patch 生成 harness.js，然后 node tools/harness-transpiler/check-quickjs-compat.mjs 直至 exit 0。',
        '同步部署物: 复制 output/harness.js 到 harmonyApp/entry/src/main/resources/rawfile/harness.js。',
        '若 API 属于 Node 专有且内核有 typeof 守卫（bareUseLines 为空本不该出现在 missing），加入 quickjs-compat-allowlist.json 并注明理由。',
      ],
      localRepro: 'node tools/harness-transpiler/check-quickjs-compat.mjs',
    },
  }
  writeFileSync(REPORT_OUT, JSON.stringify(report, null, 2))
  console.log()
  console.log(`📄 JSON 报告: ${REPORT_OUT}`)
}

main()
