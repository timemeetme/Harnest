/**
 * polyfills/node-shims.js — Hermes 兼容的 Node API polyfill
 *
 * 设计原则:
 * - 只实现 harness 实际用到的函数（randomUUID, createRequire, process 等）
 * - 不实现完整版 Node shim（那是冗余的）
 * - 总代码量 < 100 行，确保 Hermes 启动快
 */

// ── 1. node:crypto ────────────────────────────────────────────
// Hermes 不支持 crypto global 的完整 API，但有 getRandomValues
const crypto = {
  randomUUID() {
    if (typeof globalThis.crypto?.randomUUID === 'function') {
      return globalThis.crypto.randomUUID()
    }
    // fallback: 自己生成 UUID v4
    const buf = new Uint8Array(16)
    if (typeof globalThis.crypto?.getRandomValues === 'function') {
      globalThis.crypto.getRandomValues(buf)
    } else {
      for (let i = 0; i < 16; i++) buf[i] = Math.floor(Math.random() * 256)
    }
    // 设置 UUID v4 版本位
    buf[6] = (buf[6] & 0x0f) | 0x40
    buf[8] = (buf[8] & 0x3f) | 0x80
    const hex = Array.from(buf, b => b.toString(16).padStart(2, '0')).join('')
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
  },
  getRandomValues: globalThis.crypto?.getRandomValues?.bind(globalThis.crypto)
}

// ── 2. node:module ───────────────────────────────────────────
// harness 只用 createRequire 来读 package.json 的 version
// 我们直接返回一个能 resolve 到已知版本的 stub
const KNOWN_PACKAGE_VERSIONS = {
  // 这些是 harness 里会被 createRequire 读的包
  '@deepseek-ai/dsh-llm': { version: '0.1.0' },
  '@deepseek-ai/cordis': { version: '0.1.0' },
}

const moduleShim = {
  createRequire(importMetaUrl) {
    // 返回一个 require 函数，但只支持读我们知道的 package.json
    return function require(path) {
      // 去掉 ../ 和 /package.json 后缀，找到真正的包名
      const pkgMatch = path.match(/(?:^|\/)(@?[^/@]+\/[^/@]+|[^/@]+)\/package\.json$/)
      if (pkgMatch) {
        const known = KNOWN_PACKAGE_VERSIONS[pkgMatch[1]]
        if (known) return known
      }
      // 尝试 globalThis.require（Hermes 上可能有宿主注入）
      if (typeof globalThis.require === 'function') {
        return globalThis.require(path)
      }
      // 返回空 package.json
      return { version: '0.0.0' }
    }
  }
}

// ── 3. process global ────────────────────────────────────────
// harness 只用到了 stdout, stderr, cwd
const processShim = {
  stdout: {
    write(chunk) {
      if (typeof globalThis.__harnessLog === 'function') {
        globalThis.__harnessLog('stdout', String(chunk))
      } else {
        // Hermes 没有 console，但宿主可以拦截
        // eslint-disable-next-line no-console
        if (typeof console !== 'undefined' && console.log) {
          // console.log(String(chunk))  // 注释掉：避免刷屏
        }
      }
    },
    end() {},
  },
  stderr: {
    write(chunk) {
      if (typeof globalThis.__harnessLog === 'function') {
        globalThis.__harnessLog('stderr', String(chunk))
      }
    },
    end() {},
  },
  cwd() {
    // 返回宿主设置的工作目录，或者默认 '/data/local/tmp/harness'（Android）/ app 沙盒
    return globalThis.__HARNESS_CWD || '/data/local/tmp/harness'
  },
  chdir(dir) {
    globalThis.__HARNESS_CWD = dir
  },
  env: {
    // API keys 等通过宿主注入
    ...(globalThis.__HARNESS_ENV || {}),
  },
  argv: [],
  exit(code) {
    // harness 正常退出时调用，不应该真的 exit Hermes VM
    if (typeof globalThis.__harnessExit === 'function') {
      globalThis.__harnessExit(code)
    }
  },
  on() {},
  off() {},
}

// ── 4. globalThis 补丁 ───────────────────────────────────────
// Hermes 可能没有 global，或 global 不等同于 globalThis
if (typeof globalThis.global === 'undefined') {
  globalThis.global = globalThis
}

// 注入 process
globalThis.process = processShim

// ── 5. 导出 polyfill 模块 ────────────────────────────────────
// patch.mjs 会把 bundle 里的 `node:crypto` import 替换成从这里 import
// 但因为 bundle 是 ESM，我们需要用具名导出
export {
  crypto as default,
  crypto,
  moduleShim as module,
  processShim as process,
}

// 也把 createRequire 和 randomUUID 单独导出（方便 patch 后的 import 语句）
export const createRequire = moduleShim.createRequire
export const randomUUID = crypto.randomUUID
