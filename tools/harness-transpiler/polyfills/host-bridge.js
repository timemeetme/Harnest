/**
 * host-bridge.js — QuickJS ↔ 宿主（HarmonyOS native/ArkTS）桥接 polyfill
 *
 * 注入顺序：在 harness-shims-iife.js 之后、bundle 主体之前。
 *
 * 提供：
 *   1. TextEncoder / TextDecoder / TextDecoderStream（UTF-8 流式解码，跨 chunk 安全）
 *   2. AbortController / AbortSignal
 *   3. ReadableStream / WritableStream / TransformStream（含 pipeThrough / asyncIterator）
 *   4. fetch() — 经 __harnessFetchStart 上行，__harnessOnFetchHeaders/Chunk/Done/Fail 下行
 *   5. fs shim — __harnessFsCall 同步桥（native C 层实现，沙箱内）
 *   6. setTimeout/clearTimeout — no-op 桩（watchdog 不触发，宿主层负责超时）
 *
 * 宿主契约（native 侧必须提供）：
 *   __harnessFetchStart(requestJson: string) → number        // 发起 HTTP，返回 id
 *   __harnessEmit(eventJson: string) → void                  // 结构化事件上行
 *   __harnessFsCall(opJson: string) → string(resultJson)     // 同步文件操作
 * 宿主将调用本文件注册的全局函数：
 *   __harnessOnFetchHeaders(id, status, headersJson)
 *   __harnessOnFetchChunk(id, chunkText)
 *   __harnessOnFetchDone(id)
 *   __harnessOnFetchFail(id, errorText)
 */
(function (global) {
  'use strict';

  // ══════════════════════════════════════════════════════════
  // 0. Symbol.dispose / SuppressedError（QuickJS 无原生支持）
  //    esbuild 的 __using/__callDispose helper 用 using 声明实现资源管理：
  //    查找端回退 Symbol.for("Symbol.dispose")，而类定义 [Symbol.dispose]()
  //    在 Symbol.dispose === undefined 时键退化为字符串 "undefined" → 不匹配。
  //    必须在 bundle 执行前统一两端 symbol。
  // ══════════════════════════════════════════════════════════

  if (typeof Symbol.dispose !== 'symbol') {
    Symbol.dispose = Symbol.for('Symbol.dispose');
  }
  if (typeof Symbol.asyncDispose !== 'symbol') {
    Symbol.asyncDispose = Symbol.for('Symbol.asyncDispose');
  }
  if (typeof global.SuppressedError !== 'function') {
    class SuppressedErrorPolyfill extends Error {
      constructor(error, suppressed, message) {
        super(message);
        this.name = 'SuppressedError';
        this.error = error;
        this.suppressed = suppressed;
      }
    }
    global.SuppressedError = SuppressedErrorPolyfill;
  }

  // Node Buffer 最小 polyfill — 内核（session-title 截词/输入字节数计量）仅裸用
  // Buffer.byteLength(str, 'utf8')。完整 Buffer 语义不实现；
  // byteLength 调用时 TextEncoder 已由本文件注册（惰性取用，无顺序依赖）。
  if (typeof global.Buffer === 'undefined' || global.Buffer === null) {
    global.Buffer = {
      byteLength(input, _encoding) {
        return new global.TextEncoder().encode(String(input)).length;
      },
      isBuffer() { return false; },
    };
  }

  // QuickJS 宿主无 console（内核 adapter/桥的 console.log 会 ReferenceError，
  // 且在 __harnessOnFetchHeaders/Done 等回调里抛错会中断整个 fetch 生命周期）。
  // 桥接到 native 的 __harnessLog（shims 的 process.stderr 同款通道）；不可用时 no-op。
  if (typeof global.console === 'undefined' || global.console === null) {
    const conLog = (level) => (...args) => {
      try {
        if (typeof global.__harnessLog !== 'function') return;
        const text = args.map((a) => {
          if (typeof a === 'string') return a;
          try { return JSON.stringify(a); } catch (_) { return String(a); }
        }).join(' ');
        global.__harnessLog(level, text);
      } catch (_) { /* 日志绝不阻断业务 */ }
    };
    global.console = {
      log: conLog('stdout'),
      info: conLog('stdout'),
      debug: conLog('stdout'),
      warn: conLog('stderr'),
      error: conLog('stderr'),
    };
  }

  // QuickJS 无全局 crypto（Web Crypto 风格引用 `crypto.randomUUID()` 会 ReferenceError）
  if (typeof global.crypto === 'undefined' || global.crypto === null) {
    global.crypto = {
      randomUUID() {
        const buf = new Uint8Array(16);
        for (let i = 0; i < 16; i++) buf[i] = Math.floor(Math.random() * 256);
        buf[6] = (buf[6] & 0x0f) | 0x40;
        buf[8] = (buf[8] & 0x3f) | 0x80;
        const h = Array.from(buf, (b) => b.toString(16).padStart(2, '0')).join('');
        return h.slice(0, 8) + '-' + h.slice(8, 12) + '-' + h.slice(12, 16) + '-' + h.slice(16, 20) + '-' + h.slice(20);
      },
      getRandomValues(buf) {
        for (let i = 0; i < buf.length; i++) buf[i] = Math.floor(Math.random() * 256);
        return buf;
      },
    };
  }

  // QuickJS 无 structuredClone / btoa / atob / URL — 内核 chat 链路依赖
  if (typeof global.structuredClone !== 'function') {
    global.structuredClone = function (value) {
      if (value === null || typeof value !== 'object') return value;
      const seen = new Map();
      function clone(v) {
        if (v === null || typeof v !== 'object') return v;
        if (seen.has(v)) return seen.get(v);
        if (v instanceof Date) return new Date(v.getTime());
        if (v instanceof RegExp) return new RegExp(v.source, v.flags);
        if (v instanceof ArrayBuffer) return v.slice(0);
        if (ArrayBuffer.isView(v)) return new v.constructor(v);
        if (v instanceof Map) {
          const m = new Map();
          seen.set(v, m);
          for (const entry of v) m.set(clone(entry[0]), clone(entry[1]));
          return m;
        }
        if (v instanceof Set) {
          const s = new Set();
          seen.set(v, s);
          for (const item of v) s.add(clone(item));
          return s;
        }
        const out = Array.isArray(v) ? [] : {};
        seen.set(v, out);
        for (const key of Object.keys(v)) out[key] = clone(v[key]);
        return out;
      }
      return clone(value);
    };
  }

  if (typeof global.btoa !== 'function') {
    const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    global.btoa = function (s) {
      const bytes = utf8Encode(String(s));
      let out = '';
      for (let i = 0; i < bytes.length; i += 3) {
        const b0 = bytes[i], b1 = bytes[i + 1], b2 = bytes[i + 2];
        out += B64[b0 >> 2];
        out += B64[((b0 & 3) << 4) | ((b1 === undefined ? 0 : b1) >> 4)];
        out += b1 === undefined ? '=' : B64[((b1 & 15) << 2) | ((b2 === undefined ? 0 : b2) >> 6)];
        out += (b2 === undefined || b1 === undefined) ? '=' : B64[b2 & 63];
      }
      return out;
    };
  }
  if (typeof global.atob !== 'function') {
    global.atob = function (s) {
      const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      const str = String(s).replace(/[^A-Za-z0-9+/]/g, '');
      let out = '';
      for (let i = 0; i < str.length; i += 4) {
        const n = [0, 1, 2, 3].map((k) => B64.indexOf(str[i + k] || 'A'));
        out += String.fromCharCode((n[0] << 2) | (n[1] >> 4));
        if (str[i + 2] !== undefined && str[i + 2] !== '=') out += String.fromCharCode(((n[1] & 15) << 4) | (n[2] >> 2));
        if (str[i + 3] !== undefined && str[i + 3] !== '=') out += String.fromCharCode(((n[2] & 3) << 6) | n[3]);
      }
      return out;
    };
  }

  if (typeof global.URL !== 'function') {
    class URLSearchParamsPolyfill2 {
      constructor(init) {
        this._pairs = [];
        if (typeof init === 'string') {
          const q = init.charAt(0) === '?' ? init.slice(1) : init;
          if (q) {
            for (const part of q.split('&')) {
              if (!part) continue;
              const eq = part.indexOf('=');
              const k = eq < 0 ? part : part.slice(0, eq);
              const v = eq < 0 ? '' : part.slice(eq + 1);
              this._pairs.push([decodeURIComponent(k.replace(/\+/g, ' ')), decodeURIComponent(v.replace(/\+/g, ' '))]);
            }
          }
        } else if (init && typeof init.forEach === 'function') {
          init.forEach((v, k) => this._pairs.push([String(k), String(v)]));
        }
      }
      append(k, v) { this._pairs.push([String(k), String(v)]); }
      set(k, v) {
        this.delete(k);
        this._pairs.push([String(k), String(v)]);
      }
      get(k) { const p = this._pairs.find((x) => x[0] === String(k)); return p ? p[1] : null; }
      getAll(k) { return this._pairs.filter((x) => x[0] === String(k)).map((x) => x[1]); }
      has(k) { return this._pairs.some((x) => x[0] === String(k)); }
      delete(k) { this._pairs = this._pairs.filter((x) => x[0] !== String(k)); }
      toString() {
        return this._pairs.map((p) => `${encodeURIComponent(p[0])}=${encodeURIComponent(p[1])}`).join('&');
      }
    }

    class URLPolyfill {
      constructor(input, base) {
        let url = String(input);
        if (base) {
          const b = new URLPolyfill(base);
          if (url.startsWith('//')) {
            url = b.protocol + url;
          } else if (!/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(url)) {
            // 相对路径：基于 base 的目录解析
            let basePath = b.pathname;
            const dir = basePath.includes('/') ? basePath.slice(0, basePath.lastIndexOf('/') + 1) : '/';
            url = `${b.protocol}//${b.host}${dir}${url}`;
          }
        }
        const m = /^([a-zA-Z][a-zA-Z0-9+.-]*:)?\/\/([^/?#]*)([^?#]*)(\?[^#]*)?(#.*)?/.exec(url)
          || /^([a-zA-Z][a-zA-Z0-9+.-]*:)([^?#]*)(\?[^#]*)?(#.*)?/.exec(url);
        if (!m) throw new TypeError(`Invalid URL: ${input}`);
        this.protocol = m[1] || 'https:';
        let host = m[2] || '';
        let rest = m[3] || '/';
        if (!m[2] && m[3]) {
          // 无 //：data: 之类的非 host URL
          rest = m[2] ? m[3] : (m[1] ? m[3] : '/');
          host = '';
        }
        const at = host.lastIndexOf('@');
        if (at >= 0) host = host.slice(at + 1);
        const portMatch = /:(\d+)$/.exec(host);
        if (portMatch) {
          this.hostname = host.slice(0, portMatch.index);
          this.port = portMatch[1];
        } else {
          this.hostname = host;
          this.port = '';
        }
        this.host = host;
        this.pathname = rest.startsWith('/') ? rest : '/' + rest;
        this.search = m[4] || '';
        this.hash = m[5] || '';
        this.searchParams = new URLSearchParamsPolyfill2(this.search);
        this._rebuild();
      }
      _rebuild() {
        const q = this.searchParams.toString();
        this.search = q ? '?' + q : '';
        this.href = `${this.protocol}//${this.host}${this.pathname}${this.search}${this.hash}`;
        this.origin = `${this.protocol}//${this.host}`;
      }
      toString() { this._rebuild(); return this.href; }
      toJSON() { return this.toString(); }
    }
    global.URL = URLPolyfill;
    if (typeof global.URLSearchParams !== 'function') {
      global.URLSearchParams = URLSearchParamsPolyfill2;
    }
  }

  // ══════════════════════════════════════════════════════════
  // 1. UTF-8 编解码（纯 JS，流式安全）
  // ══════════════════════════════════════════════════════════

  function utf8Encode(str) {
    const out = [];
    for (let i = 0; i < str.length; i++) {
      let code = str.charCodeAt(i);
      if (code >= 0xd800 && code <= 0xdbff && i + 1 < str.length) {
        const lo = str.charCodeAt(i + 1);
        if (lo >= 0xdc00 && lo <= 0xdfff) {
          code = 0x10000 + ((code - 0xd800) << 10) + (lo - 0xdc00);
          i++;
        }
      }
      if (code < 0x80) {
        out.push(code);
      } else if (code < 0x800) {
        out.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
      } else if (code < 0x10000) {
        out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
      } else {
        out.push(
          0xf0 | (code >> 18), 0x80 | ((code >> 12) & 0x3f),
          0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f),
        );
      }
    }
    return new Uint8Array(out);
  }

  // 流式 UTF-8 解码器：保存跨 chunk 的不完整多字节序列
  class Utf8StreamDecoder {
    constructor() { this.pending = []; }

    /** 喂入 Uint8Array，返回可安全解码的文本（BOM 首次剥离） */
    push(bytes) {
      const all = this.pending.concat(Array.from(bytes));
      this.pending = [];
      let end = all.length;
      // 从尾部找完整 UTF-8 序列边界：最多回退 3 字节
      for (let back = 0; back < 3 && end > 0; back++) {
        const b = all[end - 1];
        if (b < 0x80) break;                       // ASCII 完整
        if (b >= 0xc0) { end--; break; }           // 序列首字节不完整 → 留 pending
        end--;                                      // 继续回退找首字节
      }
      this.pending = all.slice(end);
      let text = this._decode(all.slice(0, end));
      if (!this._bomSkipped && text.charCodeAt(0) === 0xfeff) {
        text = text.slice(1);
        this._bomSkipped = true;
      }
      return text;
    }

    /** 流结束：把残留字节按替换字符解码 */
    flush() {
      const rest = this.pending;
      this.pending = [];
      return rest.length ? this._decode(rest, true) : '';
    }

    _decode(bytes, lossy) {
      let out = '';
      let i = 0;
      while (i < bytes.length) {
        const b = bytes[i];
        let cp = 0, len = 0;
        if (b < 0x80) { cp = b; len = 1; }
        else if (b >= 0xc0 && b < 0xe0) { cp = b & 0x1f; len = 2; }
        else if (b >= 0xe0 && b < 0xf0) { cp = b & 0x0f; len = 3; }
        else if (b >= 0xf0 && b < 0xf8) { cp = b & 0x07; len = 4; }
        else { out += '\ufffd'; i++; continue; }
        if (i + len > bytes.length) { out += '\ufffd'; i++; continue; }
        let valid = true;
        for (let j = 1; j < len; j++) {
          const c = bytes[i + j];
          if ((c & 0xc0) !== 0x80) { valid = false; break; }
          cp = (cp << 6) | (c & 0x3f);
        }
        if (!valid) { out += '\ufffd'; i++; continue; }
        if (cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) { out += '\ufffd'; i += len; continue; }
        if (cp < 0x10000) {
          out += String.fromCharCode(cp);
        } else {
          cp -= 0x10000;
          out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
        }
        i += len;
      }
      return out;
    }
  }

  class TextEncoderPolyfill {
    encode(s) { return utf8Encode(String(s)); }
  }

  class TextDecoderPolyfill {
    decode(buf) {
      if (buf == null) return '';
      const bytes = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
      return new Utf8StreamDecoder().push(bytes) ;
    }
  }

  if (typeof global.TextEncoder === 'undefined') global.TextEncoder = TextEncoderPolyfill;
  if (typeof global.TextDecoder === 'undefined') global.TextDecoder = TextDecoderPolyfill;

  // ══════════════════════════════════════════════════════════
  // 2. AbortController / AbortSignal
  // ══════════════════════════════════════════════════════════

  class AbortSignalPolyfill {
    constructor() {
      this._aborted = false;
      this._reason = undefined;
      this._listeners = [];
      this.onabort = null;
    }
    get aborted() { return this._aborted; }
    get reason() { return this._reason; }
    addEventListener(type, fn) { if (type === 'abort') this._listeners.push(fn); }
    removeEventListener(type, fn) {
      if (type !== 'abort') return;
      const i = this._listeners.indexOf(fn);
      if (i >= 0) this._listeners.splice(i, 1);
    }
    /** 规范 API：已 abort 则抛出 reason（内核 turn/step 循环每步调用） */
    throwIfAborted() {
      if (this._aborted) throw this._reason;
    }
    _fire(reason) {
      if (this._aborted) return;
      this._aborted = true;
      this._reason = reason !== undefined ? reason : new Error('The operation was aborted');
      if (typeof this.onabort === 'function') this.onabort({ type: 'abort' });
      for (const fn of this._listeners.slice()) {
        try { fn({ type: 'abort' }); } catch (_) { /* listener 错误不阻断 */ }
      }
    }
    /** 规范静态方法：已 abort 的 signal */
    static abort(reason) {
      const s = new AbortSignalPolyfill();
      s._fire(reason);
      return s;
    }
    /** 规范静态方法：聚合多个 signal，任一 abort 即 abort（reason 取首个） */
    static any(signals) {
      const controller = new AbortControllerPolyfill();
      const list = Array.isArray(signals) ? signals : Array.from(signals);
      for (const s of list) {
        if (s && s.aborted) {
          controller.abort(s.reason);
          break;
        }
        if (s && typeof s.addEventListener === 'function') {
          s.addEventListener('abort', () => controller.abort(s.reason));
        }
      }
      return controller.signal;
    }
  }

  class AbortControllerPolyfill {
    constructor() { this.signal = new AbortSignalPolyfill(); }
    abort(reason) { this.signal._fire(reason); }
  }

  if (typeof global.AbortController === 'undefined') global.AbortController = AbortControllerPolyfill;
  if (typeof global.AbortSignal === 'undefined') {
    global.AbortSignal = AbortSignalPolyfill;
  }

  // ══════════════════════════════════════════════════════════
  // 3. ReadableStream / WritableStream / TransformStream
  //    （最小实现：无背压，满足 adapter SSE 消费链）
  // ══════════════════════════════════════════════════════════

  class ReadableStreamPolyfill {
    constructor(source) {
      source = source || {};
      this._queue = [];
      this._closed = false;
      this._errored = null;
      this._canceled = false;
      this._waiters = [];
      this._controller = {
        enqueue: (v) => {
          if (this._closed || this._errored || this._canceled) return;
          this._queue.push(v);
          this._settle();
        },
        close: () => {
          if (this._closed || this._errored) return;
          this._closed = true;
          this._settle();
        },
        error: (e) => {
          if (this._errored || this._closed) return;
          this._errored = e instanceof Error ? e : new Error(String(e));
          this._settle();
        },
      };
      if (typeof source.start === 'function') source.start(this._controller);
    }

    _cancel() {
      if (this._errored) return;
      this._canceled = true;
      this._queue.length = 0;
      this._settle();
    }

    _settle() {
      while (this._waiters.length > 0) {
        const w = this._waiters.shift();
        if (this._errored !== null) {
          w.reject(this._errored);
        } else if (this._canceled || this._closed) {
          // canceled 优先于队列余量：丢弃剩余数据立即结束
          if (this._canceled || this._queue.length === 0) {
            w.resolve({ done: true, value: undefined });
            continue;
          }
          w.resolve({ done: false, value: this._queue.shift() });
        } else if (this._queue.length > 0) {
          w.resolve({ done: false, value: this._queue.shift() });
        } else if (this._closed) {
          w.resolve({ done: true, value: undefined });
        } else {
          this._waiters.unshift(w); // 无数据可交付，放回
          return;
        }
      }
    }

    getReader() {
      const stream = this;
      return {
        read() {
          return new Promise((resolve, reject) => {
            stream._waiters.push({ resolve, reject });
            stream._settle();
          });
        },
        cancel() { stream._cancel(); return Promise.resolve(); },
        releaseLock() { /* no-op */ },
      };
    }

    pipeThrough(transform) {
      const reader = this.getReader();
      const writer = transform.writable.getWriter();
      (async () => {
        try {
          for (;;) {
            const r = await reader.read();
            if (r.done) { await writer.close(); return; }
            await writer.write(r.value);
          }
        } catch (e) {
          try { await writer.abort(e); } catch (_) { /* ignore */ }
        }
      })();
      return transform.readable;
    }

    [Symbol.asyncIterator]() {
      const reader = this.getReader();
      return {
        next() { return reader.read(); },
        return() { reader.releaseLock(); return Promise.resolve({ done: true, value: undefined }); },
      };
    }
  }

  class WritableStreamPolyfill {
    constructor(sink) {
      this._sink = sink || {};
    }
    getWriter() {
      const sink = this._sink;
      return {
        write(chunk) {
          try {
            return Promise.resolve(sink.write ? sink.write(chunk) : undefined);
          } catch (e) { return Promise.reject(e); }
        },
        close() { return Promise.resolve(sink.close ? sink.close() : undefined); },
        abort(reason) { return Promise.resolve(sink.abort ? sink.abort(reason) : undefined); },
        releaseLock() { /* no-op */ },
      };
    }
  }

  class TransformStreamPolyfill {
    constructor(transformer) {
      transformer = transformer || {};
      this.readable = new ReadableStreamPolyfill();
      const ctl = this.readable._controller;
      const self = this;
      this.writable = new WritableStreamPolyfill({
        write(chunk) {
          if (transformer.transform) return transformer.transform(chunk, ctl);
          ctl.enqueue(chunk);
        },
        close() {
          if (transformer.flush) transformer.flush(ctl);
          ctl.close();
        },
        abort(reason) { ctl.error(reason instanceof Error ? reason : new Error(String(reason))); },
      });
      if (typeof transformer.start === 'function') transformer.start(ctl);
    }
  }

  class TextDecoderStreamPolyfill extends TransformStreamPolyfill {
    constructor() {
      const decoder = new Utf8StreamDecoder();
      super({
        transform(chunk, ctl) {
          const bytes = chunk instanceof Uint8Array ? chunk : new Uint8Array(chunk);
          ctl.enqueue(decoder.push(bytes));
        },
        flush(ctl) {
          const rest = decoder.flush();
          if (rest) ctl.enqueue(rest);
        },
      });
    }
  }

  if (typeof global.ReadableStream === 'undefined') global.ReadableStream = ReadableStreamPolyfill;
  if (typeof global.WritableStream === 'undefined') global.WritableStream = WritableStreamPolyfill;
  if (typeof global.TransformStream === 'undefined') global.TransformStream = TransformStreamPolyfill;
  if (typeof global.TextDecoderStream === 'undefined') global.TextDecoderStream = TextDecoderStreamPolyfill;

  // File / Blob：宿主环境无文件对象。内核（zod v4 类型探测 / ZodFile.parse）以
  // `x instanceof File` 裸引用探测 —— 缺失会在运行时抛 ReferenceError 中断 turn。
  // no-op class 使探测语义正确：instanceof 恒 false → 类型判定为 unknown / 校验失败。
  if (typeof global.File === 'undefined') {
    global.File = class File {
      constructor(parts, name, opts) {
        this.parts = parts; this.name = name; this.opts = opts;
      }
    };
  }

  // ══════════════════════════════════════════════════════════
  // 4. Headers / Response / fetch（宿主 HTTP 桥）
  // ══════════════════════════════════════════════════════════

  class HeadersPolyfill {
    constructor(init) {
      this._map = {};
      if (init) {
        if (typeof init.forEach === 'function') {
          init.forEach((v, k) => { this._map[String(k).toLowerCase()] = String(v); });
        } else {
          for (const k of Object.keys(init)) {
            this._map[String(k).toLowerCase()] = String(init[k]);
          }
        }
      }
    }
    get(name) {
      const v = this._map[String(name).toLowerCase()];
      return v === undefined ? null : v;
    }
    has(name) { return this._map[String(name).toLowerCase()] !== undefined; }
    set(name, value) { this._map[String(name).toLowerCase()] = String(value); }
    append(name, value) {
      const k = String(name).toLowerCase();
      if (this._map[k] === undefined) this._map[k] = String(value);
      else this._map[k] += ', ' + value;
    }
    forEach(fn) { for (const k of Object.keys(this._map)) fn(this._map[k], k); }
  }

  if (typeof global.Headers === 'undefined') global.Headers = HeadersPolyfill;

  const pendingFetches = new Map();
  let fetchSeq = 1;

  // WHATWG fetch 语义：Promise 在响应头就绪时 resolve，body 之后渐进流入。
  // kernel 的 SSE 客户端（llm-deepseek adapter）在 await fetch 后才消费
  // response.body —— 若推迟到 done 才 resolve，流式传输退化为结束瞬间一次性
  // 交付（宿主 chunk 渐进入队但无人读取）。故 headers 事件到达即 settle。
  global.__harnessOnFetchHeaders = function (id, status, headersJson) {
    const entry = pendingFetches.get(id);
    if (!entry) return;
    entry.status = status;
    try {
      const raw = headersJson ? JSON.parse(headersJson) : {};
      entry.headers = new HeadersPolyfill(raw);
    } catch (_) { entry.headers = new HeadersPolyfill(); }
    if (!entry.settled) {
      entry.settled = true;
      entry.resolve(entry._makeResponse());
    }
  };

  global.__harnessOnFetchChunk = function (id, chunkText) {
    const entry = pendingFetches.get(id);
    if (!entry) return;
    if (chunkText) {
      entry.text += chunkText;
      try { entry.body._controller.enqueue(utf8Encode(chunkText)); } catch (_) { /* 已关闭 */ }
    }
  };

  // 临时 200 headers 的真实状态码修正（HarmonyOS requestInStream 到 dataEnd 才
  // 给出状态码；HttpBridge 已按 200 交付，非 2xx 在此以流错误收尾并携带响应体）
  global.__harnessOnFetchStatus = function (id, status) {
    const entry = pendingFetches.get(id);
    if (!entry) return;
    pendingFetches.delete(id);
    const code = Number(status) || 0;
    entry.status = code;
    const err = new TypeError('fetch failed: HTTP ' + code +
      (entry.text ? ': ' + entry.text.slice(0, 500) : ''));
    entry.body._controller.error(err);
    if (entry._doneReject) entry._doneReject(err);
    if (!entry.settled) { entry.settled = true; entry.reject(err); }
  };

  global.__harnessOnFetchDone = function (id) {
    const entry = pendingFetches.get(id);
    if (!entry) return;
    pendingFetches.delete(id);
    entry.body._controller.close();
    if (!entry.settled) {
      entry.settled = true;
      entry.resolve(entry._makeResponse());
    }
    if (entry._doneResolve) entry._doneResolve();
  };

  global.__harnessOnFetchFail = function (id, errorText) {
    const entry = pendingFetches.get(id);
    if (!entry) return;
    pendingFetches.delete(id);
    const err = new TypeError('fetch failed: ' + (errorText || 'unknown'));
    entry.body._controller.error(err);
    if (entry._doneReject) entry._doneReject(err);
    if (!entry.settled) { entry.settled = true; entry.reject(err); }
  };

  // 仅 QuickJS 宿主（native 已注册 __harnessFetchStart）装 fetch 桥；
  // Node 冒烟测试环境保留原生 fetch。
  if (typeof global.__harnessFetchStart === 'function' && typeof global.fetch === 'undefined') global.fetch = function (input, init) {
    init = init || {};
    const url = typeof input === 'string' ? input
      : (input && input.url ? String(input.url) : String(input));
    let headers = {};
    if (init.headers) {
      if (typeof init.headers.forEach === 'function') {
        init.headers.forEach((v, k) => { headers[k] = String(v); });
      } else {
        for (const k of Object.keys(init.headers)) headers[k] = String(init.headers[k]);
      }
    }
    let body = null;
    if (init.body != null) {
      if (typeof init.body === 'string') body = init.body;
      else if (init.body instanceof Uint8Array) body = new TextDecoderPolyfill().decode(init.body);
      else body = String(init.body);
    }

    return new Promise((resolve, reject) => {
      let id;
      const request = JSON.stringify({
        url: String(url),
        method: String(init.method || 'GET'),
        headers,
        body,
      });
      try {
        id = global.__harnessFetchStart(request);
      } catch (e) {
        reject(new TypeError('fetch failed: ' + (e && e.message ? e.message : String(e))));
        return;
      }
      const bodyStream = new ReadableStreamPolyfill();
      // text()/json() 非流式消费门闩：fetch Promise 已提前到 headers resolve，
      // 此刻 body 可能仍在流入 —— 须等流终结（done/fail/status）再返回全文，
      // 否则消费者会读到半截响应。
      let doneResolve = null;
      let doneReject = null;
      const doneP = new Promise((res, rej) => { doneResolve = res; doneReject = rej; });
      const entry = {
        status: 0,
        settled: false,
        headers: new HeadersPolyfill(),
        text: '',
        body: bodyStream,
        _doneResolve: doneResolve,
        _doneReject: doneReject,
        resolve,
        reject,
        _makeResponse() {
          const status = entry.status;
          const self = this;
          return {
            ok: status >= 200 && status < 300,
            status,
            statusText: '',
            url: String(url),
            headers: entry.headers,
            body: self.body,
            text() { return doneP.then(() => self.text); },
            json() {
              return doneP.then(() => {
                try { return JSON.parse(self.text); }
                catch (e) { return Promise.reject(e); }
              });
            },
          };
        },
      };
      pendingFetches.set(id, entry);
    });
  };

  // ══════════════════════════════════════════════════════════
  // 5. fs shim — 经 __harnessFsCall 同步桥
  // ══════════════════════════════════════════════════════════

  function fsCall(op, payload) {
    const resultJson = global.__harnessFsCall(JSON.stringify({ op, ...payload }));
    return JSON.parse(resultJson);
  }

  // 宿主错误串 → Node errno 代码映射（内核 isENOENT/isEEXIST 等按 e.code 判定）
  function fsErr(message, code) {
    const e = new Error(message);
    if (code) e.code = code;
    return e;
  }
  function mapFsError(r, verb, path) {
    const msg = (r && r.error) || (verb + ' failed: ' + path);
    let code;
    if (/not found|no such|ENOENT/i.test(msg)) code = 'ENOENT';
    else if (/EEXIST|already exists/i.test(msg)) code = 'EEXIST';
    else if (/not a directory|ENOTDIR/i.test(msg)) code = 'ENOTDIR';
    else if (/is a directory|EISDIR/i.test(msg)) code = 'EISDIR';
    else if (/permission|EACCES/i.test(msg)) code = 'EACCES';
    return fsErr(msg, code);
  }

  // ── b64 编解码（宿主桥二进制读写用）——自包含，不依赖 Prelude ──
  const B64CH = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  function b64FromBytes(u8) {
    let s = '';
    for (let i = 0; i < u8.length; i += 3) {
      const a = u8[i], b = i + 1 < u8.length ? u8[i + 1] : 0, c = i + 2 < u8.length ? u8[i + 2] : 0;
      s += B64CH[a >> 2] + B64CH[((a & 3) << 4) | (b >> 4)]
        + (i + 1 < u8.length ? B64CH[((b & 15) << 2) | (c >> 6)] : '=')
        + (i + 2 < u8.length ? B64CH[c & 63] : '=');
    }
    return s;
  }
  function bytesFromB64(s) {
    const t = s.replace(/=+$/, '');
    const out = new Uint8Array(Math.floor(t.length * 3 / 4));
    let o = 0;
    for (let i = 0; i < t.length; i += 4) {
      const n = (B64CH.indexOf(t[i]) << 18) | (B64CH.indexOf(t[i + 1]) << 12)
        | ((i + 2 < t.length ? B64CH.indexOf(t[i + 2]) : 0) << 6)
        | (i + 3 < t.length ? B64CH.indexOf(t[i + 3]) : 0);
      out[o++] = (n >> 16) & 255;
      if (i + 2 < t.length) out[o++] = (n >> 8) & 255;
      if (i + 3 < t.length) out[o++] = n & 255;
    }
    return out;
  }

  function isBytes(v) { return v instanceof Uint8Array || (typeof Buffer !== 'undefined' && v instanceof Buffer); }

  // stat 结果 → Node Stats/BigIntStats 形状（内核 versionOf 需 dev/ino/size/mtimeNs/ctimeNs；
  // fs-local probe 另消费 mode：BigInt 位运算，宿主沙箱无权限位，用常规值近似）
  function statsShape(r, bigint) {
    const size = Number(r.size || 0);
    const mtimeMs = Number(r.mtimeMs || 0);
    const isDir = !!r.isDir;
    if (bigint) {
      const ns = BigInt(Math.round(mtimeMs * 1e6));
      return {
        dev: 0n, ino: 0n, mode: isDir ? 0o40755n : 0o100644n, size: BigInt(size), mtimeNs: ns, ctimeNs: ns,
        mtimeMs: mtimeMs, ctimeMs: mtimeMs,
        isDirectory: () => isDir, isFile: () => !isDir, isSymbolicLink: () => false,
      };
    }
    return {
      dev: 0, ino: 0, mode: isDir ? 0o40755 : 0o100644, size, mtimeMs, ctimeMs: mtimeMs,
      isDirectory: () => isDir, isFile: () => !isDir, isSymbolicLink: () => false,
    };
  }

  // Dirent 形状（listDirectory 只用 .name；宿主沙箱无 symlink）
  function direntOf(entry) {
    const name = typeof entry === 'string' ? entry : String(entry && entry.name);
    const dir = typeof entry === 'object' && entry !== null ? !!entry.isDir : false;
    return { name, isDirectory: () => dir, isFile: () => !dir, isSymbolicLink: () => false };
  }

  // 伪 FileHandle：writeFileAtomic 的 open('wx')/chmod/writeFile/sync/close 与
  // readTextForDiff 的 open('r')/stat/read/close 均在此承接（宿主无 fd 概念，
  // 'wx' 句柄写缓冲、close 时经 writeFile op 落盘；'r' 句柄一次性读全量）
  function makeFakeHandle(path, flags) {
    if (flags === 'wx' || flags === 'ax') {
      let content = '';
      return {
        chmod: () => Promise.resolve(),
        writeFile: (data) => { content = typeof data === 'string' ? data : String(data); return Promise.resolve(); },
        sync: () => Promise.resolve(),
        close: () => new Promise((resolve, reject) => {
          const r = fsCall('writeFile', { path, data: content });
          r.ok ? resolve() : reject(mapFsError(r, 'writeFile', path));
        }),
        stat: () => Promise.reject(fsErr('ENOENT: fake handle', 'ENOENT')),
      };
    }
    // 读句柄：首次使用时拉全量字节
    let bytes = null;
    const load = () => {
      if (bytes === null) {
        const r = fsCall('readFile', { path, text: false });
        if (!r.ok) throw mapFsError(r, 'readFile', path);
        bytes = bytesFromB64(String(r.data || ''));
      }
      return bytes;
    };
    return {
      stat: () => {
        const r = fsCall('stat', { path });
        return r.ok ? Promise.resolve(statsShape(r, false)) : Promise.reject(mapFsError(r, 'stat', path));
      },
      read: (buffer, offset, length) => new Promise((resolve, reject) => {
        try {
          const src = load();
          const take = Math.min(length, Math.max(0, src.length - offset));
          if (buffer && buffer.set) buffer.set(src.subarray(offset, offset + take), offset);
          resolve({ bytesRead: take });
        } catch (e) { reject(e); }
      }),
      close: () => Promise.resolve(),
    };
  }

  // createReadStream → 最小异步可迭代流（readWholeBytes/streamWholeText 只 for-await 消费 chunk）
  function makeFakeStream(path, opts) {
    opts = opts || {};
    return {
      [Symbol.asyncIterator]() {
        let done = false;
        return {
          next: () => {
            if (done) return Promise.resolve({ done: true });
            done = true;
            if (opts.signal && opts.signal.aborted) {
              return Promise.reject(fsErr('The operation was aborted', 'ABORT_ERR'));
            }
            try {
              const r = fsCall('readFile', { path, text: false });
              if (!r.ok) return Promise.reject(mapFsError(r, 'readFile', path));
              let bytes = bytesFromB64(String(r.data || ''));
              if (typeof opts.end === 'number' && bytes.length > opts.end) bytes = bytes.subarray(0, opts.end);
              return Promise.resolve({ done: false, value: bytes });
            } catch (e) { return Promise.reject(e); }
          },
        };
      },
      on() { return this; },
      destroy() {},
      close() {},
    };
  }

  const fsShim = {
    existsSync(path) { return !!fsCall('exists', { path }).exists; },
    readFileSync(path, opts) {
      const enc = typeof opts === 'string' ? opts : (opts && opts.encoding);
      const binary = enc === undefined || enc === null;
      const r = fsCall('readFile', { path, text: !binary });
      if (!r.ok) throw mapFsError(r, 'readFile', path);
      if (binary) return bytesFromB64(String(r.data || ''));
      return String(r.data || '');
    },
    writeFileSync(path, data) {
      let r;
      if (isBytes(data)) {
        r = fsCall('writeFile', { path, data: b64FromBytes(data), base64: true });
      } else {
        r = fsCall('writeFile', { path, data: typeof data === 'string' ? data : String(data) });
      }
      if (!r.ok) throw mapFsError(r, 'writeFile', path);
    },
    readdirSync(path, opts) {
      const r = fsCall('readdir', { path });
      if (!r.ok) throw mapFsError(r, 'readdir', path);
      const entries = r.entries || [];
      const withTypes = !!(opts && opts.withFileTypes);
      return withTypes ? entries.map(direntOf) : entries.map(e => (typeof e === 'string' ? e : String(e && e.name)));
    },
    mkdirSync(path, opts) {
      const r = fsCall('mkdir', { path, recursive: !!(opts && opts.recursive) });
      if (!r.ok) throw mapFsError(r, 'mkdir', path);
    },
    rmSync(path, opts) {
      const r = fsCall('rm', { path, recursive: !!(opts && opts.recursive), force: !!(opts && opts.force) });
      if (!r.ok && !(opts && opts.force)) throw mapFsError(r, 'rm', path);
    },
    statSync(path, opts) {
      const r = fsCall('stat', { path });
      if (!r.ok) throw mapFsError(r, 'stat', path);
      return statsShape(r, !!(opts && opts.bigint));
    },
    lstatSync(path, opts) {
      // 宿主沙箱无 symlink：lstat 与 stat 等价
      return fsShim.statSync(path, opts);
    },
    realpathSync(path) {
      // resolve() 已在宿主侧规范化/限沙箱，直接返回
      return path;
    },
    renameSync(oldPath, newPath) {
      const r = fsCall('rename', { path: oldPath, newPath });
      if (!r.ok) throw mapFsError(r, 'rename', oldPath);
    },
    linkSync(existingPath, newPath) {
      // 无硬链接：以「目标不存在才复制」近似 no-replace 语义
      if (fsCall('exists', { path: newPath }).exists) {
        throw fsErr('EEXIST: file already exists: ' + newPath, 'EEXIST');
      }
      const bytes = fsShim.readFileSync(existingPath);
      fsShim.writeFileSync(newPath, bytes);
    },
    chmodSync() { /* 沙箱内无 POSIX 权限位语义：no-op */ },
    createReadStream(path, opts) { return makeFakeStream(path, opts); },
    promises: {
      async readFile(path, opts) { return fsShim.readFileSync(path, opts); },
      async writeFile(path, data) { return fsShim.writeFileSync(path, data); },
      async readdir(path, opts) { return fsShim.readdirSync(path, opts); },
      async mkdir(path, opts) { return fsShim.mkdirSync(path, opts); },
      async rm(path, opts) { return fsShim.rmSync(path, opts); },
      async stat(path, opts) { return fsShim.statSync(path, opts); },
      async lstat(path, opts) { return fsShim.lstatSync(path, opts); },
      async realpath(path) { return fsShim.realpathSync(path); },
      async rename(oldPath, newPath) { return fsShim.renameSync(oldPath, newPath); },
      async link(existingPath, newPath) { return fsShim.linkSync(existingPath, newPath); },
      async chmod() { /* no-op */ },
      async open(path, flags) {
        if (flags === 'wx' || flags === 'ax') {
          if (fsCall('exists', { path }).exists) {
            throw fsErr('EEXIST: file already exists: ' + path, 'EEXIST');
          }
        }
        return makeFakeHandle(path, flags);
      },
    },
  };

  // 仅 QuickJS 宿主（native 已注册 __harnessFsCall）覆盖 fs 桥；
  // Node 冒烟测试环境保留 shims 的真实 fs。
  if (typeof global.__harnessFsCall === 'function') {
    if (global.__HARNESS_SHIMS) {
      global.__HARNESS_SHIMS.fs = fsShim;
      global.__HARNESS_SHIMS.defaultFsShim = fsShim;
      // fs-local 直消费 node:fs/promises（realpath/open/rename 等 11 个 API）
      global.__HARNESS_SHIMS.fsPromises = fsShim.promises;
    }
    if (typeof global.require !== 'function') {
      global.require = function (p) {
        if (p === 'fs' || p === 'node:fs') return fsShim;
        if (p === 'fs/promises' || p === 'node:fs/promises') return fsShim.promises;
        if (global.__HARNESS_SHIMS) return global.__HARNESS_SHIMS;
        return {};
      };
    }
  }

  // ══════════════════════════════════════════════════════════
  // 6. 定时器桩（QuickJS 无定时器；宿主层负责整体超时）
  // ══════════════════════════════════════════════════════════

  if (typeof global.setTimeout !== 'function') {
    global.setTimeout = function (fn, _ms) {
      // 注意：不执行回调。adapter 的 idle watchdog 因此不触发；
      // 超时保护由宿主（ArkTS LocalEngine）实现。
      return 0;
    };
    global.clearTimeout = function () { };
    global.setInterval = function () { return 0; };
    global.clearInterval = function () { };
  }
})(typeof globalThis !== 'undefined' ? globalThis : this);
