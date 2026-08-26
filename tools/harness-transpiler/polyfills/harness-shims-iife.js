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

  // ── os ──
  // dsh-v0.1.1 新增：DeepSeekAdapter 构造即建 DeepSeekUploadIndex → resolveDshHome()
  // → 无 $DSH_HOME 时回落 os.homedir()。返回会话沙箱根，使 files-v3.json 索引
  // 落在宿主 fs 桥可见的沙箱内。
  shims.homedir = function() { return global.__HARNESS_CWD || "/data/local/tmp/harness"; };

  // ── crypto.createHash（纯 JS SHA-256：llm-deepseek upload-index 文件指纹）──
  function sha256(bytes) {
    const K = [
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
      0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
      0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
      0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
      0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
      0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];
    let h0 = 0x6a09e667, h1 = 0xbb67ae85, h2 = 0x3c6ef372, h3 = 0xa54ff53a;
    let h4 = 0x510e527f, h5 = 0x9b05688c, h6 = 0x1f83d9ab, h7 = 0x5be0cd19;
    const bitLen = bytes.length * 8;
    const padded = new Uint8Array((((bytes.length + 8) >> 6) + 1) << 6);
    padded.set(bytes);
    padded[bytes.length] = 0x80;
    const dv = new DataView(padded.buffer);
    dv.setUint32(padded.length - 4, bitLen >>> 0);
    dv.setUint32(padded.length - 8, Math.floor(bitLen / 0x100000000));
    const w = new Int32Array(64);
    for (let off = 0; off < padded.length; off += 64) {
      for (let i = 0; i < 16; i++) w[i] = dv.getInt32(off + i * 4);
      for (let i = 16; i < 64; i++) {
        const s0 = ((w[i - 15] >>> 7) | (w[i - 15] << 25)) ^ ((w[i - 15] >>> 18) | (w[i - 15] << 14)) ^ (w[i - 15] >>> 3);
        const s1 = ((w[i - 2] >>> 17) | (w[i - 2] << 15)) ^ ((w[i - 2] >>> 19) | (w[i - 2] << 13)) ^ (w[i - 2] >>> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0;
      }
      let a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
      for (let i = 0; i < 64; i++) {
        const S1 = ((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7));
        const ch = (e & f) ^ (~e & g);
        const t1 = (h + S1 + ch + K[i] + w[i]) | 0;
        const S0 = ((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10));
        const maj = (a & b) ^ (a & c) ^ (b & c);
        const t2 = (S0 + maj) | 0;
        h = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0;
      }
      h0 = (h0 + a) | 0; h1 = (h1 + b) | 0; h2 = (h2 + c) | 0; h3 = (h3 + d) | 0;
      h4 = (h4 + e) | 0; h5 = (h5 + f) | 0; h6 = (h6 + g) | 0; h7 = (h7 + h) | 0;
    }
    const out = new Uint8Array(32);
    const odv = new DataView(out.buffer);
    odv.setInt32(0, h0); odv.setInt32(4, h1); odv.setInt32(8, h2); odv.setInt32(12, h3);
    odv.setInt32(16, h4); odv.setInt32(20, h5); odv.setInt32(24, h6); odv.setInt32(28, h7);
    return out;
  }
  shims.createHash = function(algo) {
    if (String(algo).toLowerCase().replace('-', '') !== 'sha256') throw new Error('createHash shim supports sha256 only');
    const chunks = [];
    return {
      update(data, encoding) {
        let bytes;
        if (data instanceof Uint8Array) bytes = data;
        else if (typeof data === 'string') {
          if (encoding === 'base64') {
            const bin = (typeof atob === 'function') ? atob(data) : '';
            bytes = new Uint8Array(bin.length);
            for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
          } else bytes = new TextEncoder().encode(data);
        } else if (data instanceof ArrayBuffer) bytes = new Uint8Array(data);
        else throw new Error('createHash shim: unsupported update data');
        chunks.push(bytes);
        return this;
      },
      digest(encoding) {
        let total = 0;
        for (const c of chunks) total += c.length;
        const all = new Uint8Array(total);
        let pos = 0;
        for (const c of chunks) { all.set(c, pos); pos += c.length; }
        const hash = sha256(all);
        if (encoding === 'hex') return Array.from(hash, b => b.toString(16).padStart(2, '0')).join('');
        if (encoding === 'base64' && typeof btoa === 'function') {
          let s = '';
          for (let i = 0; i < hash.length; i++) s += String.fromCharCode(hash[i]);
          return btoa(s);
        }
        return hash;
      },
    };
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
