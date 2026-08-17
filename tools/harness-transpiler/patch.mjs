/**
 * patch.mjs — Post-process harness.bundle.js
 *
 * 1. 把所有 `import { xxx } from "node:yyy"` → 从 __HARNESS_SHIMS 解构
 * 2. 把 import.meta.url → 假字符串
 * 3. 注入 polyfill IIFE
 * 4. 输出最终的 harness.js (Hermes-ready)
 */

import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const OUTPUT_DIR = path.resolve(__dirname, 'output')
const BUNDLE = path.join(OUTPUT_DIR, 'harness.bundle.js')
const SHIMS_FILE = path.join(__dirname, 'polyfills', 'harness-shims-iife.js')
const HOST_BRIDGE_FILE = path.join(__dirname, 'polyfills', 'host-bridge.js')
const OUTPUT = path.join(OUTPUT_DIR, 'harness.js')

console.log('='.repeat(60))
console.log('Harness Transpiler — Step 2: Patch & Polyfill')
console.log('='.repeat(60))

if (!existsSync(BUNDLE)) {
  console.error(`❌ Bundle 不存在: ${BUNDLE}`)
  process.exit(1)
}
if (!existsSync(SHIMS_FILE)) {
  console.error(`❌ Shims 文件不存在: ${SHIMS_FILE}`)
  process.exit(1)
}
if (!existsSync(HOST_BRIDGE_FILE)) {
  console.error(`❌ Host bridge 文件不存在: ${HOST_BRIDGE_FILE}`)
  process.exit(1)
}

const bundle = readFileSync(BUNDLE, 'utf-8')
const shims = readFileSync(SHIMS_FILE, 'utf-8')
const hostBridge = readFileSync(HOST_BRIDGE_FILE, 'utf-8')

console.log(`  Bundle: ${(Buffer.byteLength(bundle)/1024).toFixed(1)} KB`)
console.log(`  Shims:  ${(Buffer.byteLength(shims)/1024).toFixed(1)} KB`)
console.log()

let patched = bundle

const PATCHES = [
  // 具名导入: import { a, b } from "node:xxx";
  {
    from: /import\s*\{\s*([^}]+)\s*\}\s*from\s*["']node:[^"']+["'];?\s*\n?/g,
    to: (_m, imports) => {
      const names = imports.split(',').map(s => s.trim()).filter(Boolean)
      return `const { ${names.join(', ')} } = globalThis.__HARNESS_SHIMS;\n`
    }
  },
  // 默认导入: import xxx from "node:xxx";
  {
    from: /import\s+(\w+)\s+from\s*["']node:[^"']+["'];?\s*\n?/g,
    to: (_m, name) => `const ${name} = globalThis.__HARNESS_SHIMS;\n`
  },
  // import.meta.url → 假字符串
  {
    from: /import\.meta\.url/g,
    to: '"__harness_bundle__"'
  },
  // SSE 流修复：EventSourceParserStream（eventsource-parser@3.1.0）没有 flush —
  // 流 close 时滞留在解析器 data 变量中的最后一个事件（"data: [DONE]"）被丢弃，
  // parseSse 抛 STREAM_CLOSED → "DeepSeek API stream from ... failed"。
  // 只要流的尾随空行分隔符因任何原因缺失（服务器不发尾随 \n\n、代理剥掉、
  // 分包截断）必然复现。补 flush：close 前投喂 "\n\n" 触发 dispatch
  // （流正常结束时 dataLines=0，无副作用），再 reset({consume:true}) 消费残留半行。
  {
    from: /transform\(chunk\) \{\s*\n\s*parser\.feed\(chunk\);\s*\n\s*\}\s*\n(\s*\}\);)/g,
    to: (_m, tail) => `transform(chunk) {
        parser.feed(chunk);
      },
      flush(controller) {
        try { parser.feed("\\n\\n"); } catch (_) { }
        parser.reset({ consume: true });
        controller.close();
      }
      ${tail}`
  },
  // QuickJS 兼容：Function.prototype.toString 对原生函数的输出是多行缩进格式
  // （V8: "function Object() { [native code] }"；QuickJS: "function Object() {\n    [native code]\n}"）。
  // 内核 hasIntrinsicConstructor 用严格相等比较 → QuickJS 下全部失败 → 工具 schema 校验报错。
  // 修复：比较前把连续空白归一化为单个空格（两种格式都匹配）。
  {
    from: /Function\.prototype\.toString\.call\((\w+)\)\s*===\s*`function \$\{(\w+)\}\(\) \{ \[native code\] \}`/g,
    to: (_m, ctor, name) =>
      `Function.prototype.toString.call(${ctor}).replace(/\\s+/g, " ") === "function " + ${name} + "() { [native code] }"`
  },
]

console.log('Applying patches:')
PATCHES.forEach((rule, i) => {
  const before = patched
  patched = patched.replace(rule.from, rule.to)
  const count = (before.length - patched.length) !== 0
  if (count) {
    const n = (before.match(rule.from) || []).length
    console.log(`  [${i+1}] ✅ ${n} match(es)`)
  } else {
    console.log(`  [${i+1}] — skip (no match)`)
  }
})

// 验证没有残留
const remaining = patched.match(/from\s*["']node:/g) || []
const remainingImportMeta = patched.match(/import\.meta/g) || []
console.log()
console.log(`  node: residual: ${remaining.length}`)
console.log(`  import.meta residual: ${remainingImportMeta.length}`)

// ── 组装最终文件 ────────────────────────────────────────────
// 顺序: shims（Node 基础垫片）→ host-bridge（QuickJS 宿主桥: fetch/fs/streams）
//       → bundle 主体。host-bridge 通过探测 __harnessFetchStart/__harnessFsCall
//       决定是否装桥（Node 冒烟测试下保留原生实现）。
const final = [
  '// ╔══════════════════════════════════════════════════════╗',
  '// ║  Harness.js — QuickJS/Node-ready deepseek-harness    ║',
  '// ╚══════════════════════════════════════════════════════╝',
  '',
  shims,
  '',
  hostBridge,
  '',
  patched,
  '',
].join('\n')

writeFileSync(OUTPUT, final)
console.log()
console.log('✅ Output written:', OUTPUT)
console.log('   Size:', (Buffer.byteLength(final)/1024).toFixed(1), 'KB')

// 验证语法（ESM parse）
try {
  await import('file://' + OUTPUT + '?verify=' + Date.now())
  console.log('   ✅ ESM load check passed')
} catch (e) {
  const msg = e.message || ''
  if (msg.includes('ERR_MODULE_NOT_FOUND') || msg.includes('Cannot find module')) {
    console.log('   ✅ Parse OK (runtime deps missing — expected)')
  } else if (msg.includes('SyntaxError') || msg.includes('Invalid')) {
    console.error('   ❌ Parse FAILED:', msg)
  } else {
    console.log('   ℹ️  Loaded (runtime error — expected):', msg.slice(0, 80))
  }
}
