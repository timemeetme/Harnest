(function(global) {
  const shims = {};

  // ── crypto ──
  shims.randomUUID = function() {
    if (global.crypto && global.crypto.randomUUID) return global.crypto.randomUUID();
    const buf = new Uint8Array(16);
    if (global.crypto && global.crypto.getRandomValues) {
      global.crypto.getRandomValues(buf);
    } else {
      for (let i = 0; i < 16; i++) buf[i] = Math.floor(Math.random() * 256);
    }
    buf[6] = (buf[6] & 0x0f) | 0x40;
    buf[8] = (buf[8] & 0x3f) | 0x80;
    const h = Array.from(buf, b => b.toString(16).padStart(2,'0')).join('');
    return h.slice(0,8)+'-'+h.slice(8,12)+'-'+h.slice(12,16)+'-'+h.slice(16,20)+'-'+h.slice(20);
  };
  shims.crypto = {
    randomUUID: shims.randomUUID,
    getRandomValues: global.crypto ? global.crypto.getRandomValues.bind(global.crypto) : undefined,
  };

  // ── module ──
  const KNOWN_VERSIONS = {
    "@deepseek-ai/dsh-llm": "0.1.0",
    "@deepseek-ai/cordis": "0.1.0",
  };
  shims.createRequire = function() {
    return function require(p) {
      const m = p.match(/(?:^|\/)(@?[^/@]+\/[^/@]+|[^/@]+)\/package\.json$/);
      if (m && KNOWN_VERSIONS[m[1]]) return { version: KNOWN_VERSIONS[m[1]] };
      if (typeof global.require === "function") return global.require(p);
      return { version: "0.0.0" };
    };
  };
  shims.module = { createRequire: shims.createRequire };

  // ── async_hooks ──
  // QuickJS polyfill: preserve the store across async boundaries by delaying
  // restoration until a returned Promise settles. Node's real AsyncLocalStorage
  // propagates the store through the async context chain; this approximation
  // keeps the store active for the full lifetime of the operation's Promise.
  shims.AsyncLocalStorage = class {
    constructor() { this._store = new Map(); }
    run(store, fn, ...args) {
      const prev = this._store.get("current");
      this._store.set("current", store);
      let result;
      try { result = fn(...args); } catch (e) { this._store.set("current", prev); throw e; }
      if (result && typeof result.then === "function") {
        const self = this;
        return result.then(
          function(v) { self._store.set("current", prev); return v; },
          function(err) { self._store.set("current", prev); throw err; }
        );
      }
      this._store.set("current", prev);
      return result;
    }
    getStore() { return this._store.get("current"); }
    exit(fn, ...args) { return fn(...args); }
    bind(fn) { return fn; }
    snapshot() { return function() {}; }
  };

  // ── util/types ──
  shims.isPromise = function(v) {
    return v && typeof v.then === "function" && typeof v.catch === "function";
  };

  // ── util 编解码器（fs-local decodeUtf8 从 node:util 取 TextDecoder；
  // QuickJS 真机由 prelude 注入同名全局）──
  shims.TextDecoder = global.TextDecoder;
  shims.TextEncoder = global.TextEncoder;

  // ── util.isDeepStrictEqual ──
  // compaction assertStable 用它比较 surface 节点/seq 数组（稳定性检查）。
  // 语义对齐 node:util：Object.is 原始值语义（NaN 相等、±0 不等），原型不参与。
  shims.isDeepStrictEqual = function isDeepStrictEqual(a, b) {
    if (Object.is(a, b)) return true;
    if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return false;
    if (Array.isArray(a) !== Array.isArray(b)) return false;
    const ka = Object.keys(a), kb = Object.keys(b);
    if (ka.length !== kb.length) return false;
    for (let i = 0; i < ka.length; i++) {
      const k = ka[i];
      if (!Object.prototype.hasOwnProperty.call(b, k)) return false;
      if (!isDeepStrictEqual(a[k], b[k])) return false;
    }
    return true;
  };

  // ── path ──
  // POSIX 路径实现（宿主 fs 桥在沙箱根内解析相对路径，platform 固定 linux）。
  // bundle 消费面：join/dirname/basename/extname/resolve/relative/sep/isAbsolute/toNamespacedPath。
  shims.sep = "/";
  shims.delimiter = ":";
  shims.isAbsolute = function(p) {
    if (!p || typeof p !== "string") return false;
    if (p.charCodeAt(0) === 47) return true;  // /
    if (p.length >= 2) {
      const c1 = p.charCodeAt(0), c2 = p.charCodeAt(1);
      if (c1 >= 65 && c1 <= 90 && c2 === 58) { // A-Z:
        const c3 = p.charCodeAt(2);
        if (c3 === 47 || c3 === 92) return true;
      }
      if (c1 === 92 && c2 === 92) return true;  // \\
    }
    return false;
  };
  shims.normalize = function(p) {
    if (!p) return ".";
    const abs = shims.isAbsolute(p);
    const segs = String(p).split("/");
    const out = [];
    for (let i = 0; i < segs.length; i++) {
      const s = segs[i];
      if (!s || s === ".") continue;
      if (s === "..") { if (out.length && out[out.length - 1] !== "..") out.pop(); else if (!abs) out.push(".."); }
      else out.push(s);
    }
    return (abs ? "/" : "") + out.join("/") || (abs ? "/" : ".");
  };
  shims.join = function() {
    const parts = [];
    for (let i = 0; i < arguments.length; i++) {
      const a = arguments[i];
      if (a) parts.push(String(a));
    }
    if (!parts.length) return ".";
    return shims.normalize(parts.join("/"));
  };
  shims.resolve = function() {
    let resolved = "";
    for (let i = arguments.length - 1; i >= 0 && !shims.isAbsolute(resolved); i--) {
      const seg = String(arguments[i] || "");
      if (!seg) continue;
      resolved = resolved ? seg + "/" + resolved : seg;
    }
    if (!shims.isAbsolute(resolved)) resolved = shims.process.cwd() + "/" + resolved;
    return shims.normalize(resolved);
  };
  shims.dirname = function(p) {
    if (!p || p === "/") return "/";
    const s = String(p).replace(/\/+$/, "");
    const i = s.lastIndexOf("/");
    if (i < 0) return ".";
    if (i === 0) return "/";
    return s.slice(0, i);
  };
  shims.basename = function(p, ext) {
    let s = String(p == null ? "" : p).replace(/\/+$/, "");
    const i = s.lastIndexOf("/");
    if (i >= 0) s = s.slice(i + 1);
    if (ext && s.endsWith(ext)) s = s.slice(0, s.length - ext.length);
    return s;
  };
  shims.extname = function(p) {
    const base = shims.basename(String(p == null ? "" : p));
    const i = base.lastIndexOf(".");
    return i <= 0 ? "" : base.slice(i);
  };
  shims.relative = function(from, to) {
    const f = shims.resolve(from).split("/").filter(Boolean);
    const t = shims.resolve(to).split("/").filter(Boolean);
    let i = 0;
    while (i < f.length && i < t.length && f[i] === t[i]) i++;
    const up = [];
    for (let j = i; j < f.length; j++) up.push("..");
    return up.concat(t.slice(i)).join("/") || ".";
  };
  shims.posix = {
    sep: "/", delimiter: ":",
    isAbsolute: shims.isAbsolute, normalize: shims.normalize, join: shims.join, resolve: shims.resolve,
    dirname: shims.dirname, basename: shims.basename, extname: shims.extname, relative: shims.relative,
    toNamespacedPath: function(p) { return p; },
  };

  // ── process ──
  shims.process = {
    stdout: { write(chunk) { if (typeof global.__harnessLog === "function") global.__harnessLog("stdout", String(chunk)); }, end() {} },
    stderr: { write(chunk) { if (typeof global.__harnessLog === "function") global.__harnessLog("stderr", String(chunk)); }, end() {} },
    cwd() { return global.__HARNESS_CWD || "/data/local/tmp/harness"; },
    chdir(d) { global.__HARNESS_CWD = d; },
    // 非 win32：fs-local writeFileAtomic 走 POSIX rename 发布路径（避开 win32 DACL 分支）
    platform: "linux",
    pid: 1,
    env: Object.assign({}, global.__HARNESS_ENV || {}),
    argv: [],
    exit(code) { if (typeof global.__harnessExit === "function") global.__harnessExit(code); },
    on() {},
    off() {},
  };

  // ── Buffer（最小实现，Uint8Array 子类）──
  // fs-local 消费面：allocUnsafe/concat/from + length/subarray/includes/set。
  if (typeof global.Buffer === "undefined") {
    const BufferShim = class Buffer extends Uint8Array {
      static allocUnsafe(size) { return new BufferShim(size); }
      static alloc(size) { return new BufferShim(size); }
      static byteLength(value, encoding) {
        // tool-fs read-render 按 utf8 字节数截断窗口；base64/hex 不在消费面
        if (typeof value !== "string") return value && value.length ? value.length : 0;
        if (encoding === "base64") return Math.floor(value.replace(/=+$/, "").length * 3 / 4);
        return new TextEncoder().encode(value).length;
      }
      static concat(list, totalLength) {
        let total = totalLength;
        if (total === undefined) { total = 0; for (const b of list) total += b.length; }
        const out = new BufferShim(total);
        let pos = 0;
        for (const b of list) {
          const take = Math.min(b.length, total - pos);
          if (take <= 0) break;
          out.set(b.subarray(0, take), pos);
          pos += take;
        }
        return out;
      }
      static from(value, encoding) {
        if (typeof value === "string") {
          if (encoding === "base64") {
            const bin = (typeof atob === "function") ? atob(value) : "";
            const out = new BufferShim(bin.length);
            for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
            return out;
          }
          const bytes = new TextEncoder().encode(value);
          const out = new BufferShim(bytes.length);
          out.set(bytes);
          return out;
        }
        if (value instanceof Uint8Array) {
          const out = new BufferShim(value.length);
          out.set(value);
          return out;
        }
        if (Array.isArray(value)) {
          const out = new BufferShim(value.length);
          for (let i = 0; i < value.length; i++) out[i] = value[i] & 255;
          return out;
        }
        return new BufferShim(0);
      }
      toString(encoding) {
        if (encoding === "base64") {
          let s = "";
          for (let i = 0; i < this.length; i++) s += String.fromCharCode(this[i]);
          return (typeof btoa === "function") ? btoa(s) : s;
        }
        return new TextDecoder("utf-8").decode(this);
      }
    };
    shims.Buffer = BufferShim;
    global.Buffer = BufferShim;
  } else {
    shims.Buffer = global.Buffer;
  }

  // ── buffer constants（fs-local diffBasisMaxBytes 上限钳制用）──
  shims.constants = { MAX_LENGTH: 2147483647, MAX_STRING_LENGTH: 536870888 };

  // ── url ──
  shims.pathToFileURL = function(p) { return { href: "file://" + String(p), toString() { return this.href; } }; };

  // ── path（win32 专用函数：非 win32 平台为恒等/透传）──
  shims.toNamespacedPath = function(p) { return p; };

  if (typeof global.global === "undefined") global.global = global;
  global.process = shims.process;
  global.__HARNESS_SHIMS = shims;
})(typeof globalThis !== "undefined" ? globalThis : this);
