/**
 * build.mjs — 从 headless 包目录 bundle（利用其嵌套 node_modules symlink）
 */

import { build } from 'esbuild'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { existsSync, mkdirSync, writeFileSync, copyFileSync } from 'node:fs'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const HARNESS_ROOT = path.resolve(__dirname, '..', '..', 'kernel', 'deepseek-harness')
const HEADLESS_DIR = path.join(HARNESS_ROOT, 'packages', 'bundle', 'headless')
const OUTPUT_DIR = path.join(__dirname, 'output')

if (!existsSync(OUTPUT_DIR)) mkdirSync(OUTPUT_DIR, { recursive: true })

// 把 harness-entry.ts 复制到 headless 目录（利用它的 node_modules symlink）
const ENTRY_TS = path.join(__dirname, 'src', 'harness-entry.ts')
const ENTRY_COPY = path.join(HEADLESS_DIR, 'harness-entry.ts')
copyFileSync(ENTRY_TS, ENTRY_COPY)

console.log('='.repeat(60))
console.log('Harness Transpiler — Step 1: Bundle')
console.log('='.repeat(60))
console.log(`  Entry:    ${ENTRY_COPY}`)
console.log(`  CWD:      ${HEADLESS_DIR}`)
console.log()

try {
  const result = await build({
    entryPoints: [ENTRY_COPY],
    bundle: true,
    format: 'esm',
    platform: 'node',
    target: 'node20',
    logLevel: 'info',
    outfile: path.join(OUTPUT_DIR, 'harness.bundle.js'),
    absWorkingDir: HEADLESS_DIR,
    external: [],
    resolveExtensions: ['.js', '.mjs', '.ts', '.d.ts'],
    mainFields: ['module', 'main'],
    conditions: ['import', 'default', 'node'],
    minify: false,
    metafile: true,
    keepNames: true,
  })

  const outPath = path.join(OUTPUT_DIR, 'harness.bundle.js')
  const sizeKB = (await import('node:fs')).statSync(outPath).size / 1024

  console.log()
  console.log('✅ Bundle SUCCESS')
  console.log(`  📦 Size: ${sizeKB.toFixed(1)} KB`)

  writeFileSync(
    path.join(OUTPUT_DIR, 'harness.meta.json'),
    JSON.stringify(result.metafile || {}, null, 2)
  )

  const meta = result.metafile || { inputs: {} }
  const dshFiles = Object.keys(meta.inputs || {}).filter(
    f => f.includes('deepseek-harness') && !f.includes('node_modules') && !f.includes('.pnpm')
  )
  console.log(`  📚 Harness source files: ${dshFiles.length}`)
  dshFiles.forEach(f => console.log(`     ${f.replace(HARNESS_ROOT + path.sep, '')}`))

} catch (err) {
  console.error('\n❌ Bundle FAILED')
  if (err.errors) {
    err.errors.forEach(e => {
      console.error(`  ${e.location?.file ?? ''}:${e.location?.line ?? '?'} — ${e.text}`)
    })
  } else {
    console.error(err.message)
  }
  process.exit(1)
}
