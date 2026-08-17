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
  shims.AsyncLocalStorage = class {
    constructor() { this._store = new Map(); }
    run(store, fn, ...args) {
      const prev = this._store.get("current");
      this._store.set("current", store);
      try { return fn(...args); } finally { this._store.set("current", prev); }
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

  // ── path ──
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

  // ── process ──
  shims.process = {
    stdout: { write(chunk) { if (typeof global.__harnessLog === "function") global.__harnessLog("stdout", String(chunk)); }, end() {} },
    stderr: { write(chunk) { if (typeof global.__harnessLog === "function") global.__harnessLog("stderr", String(chunk)); }, end() {} },
    cwd() { return global.__HARNESS_CWD || "/data/local/tmp/harness"; },
    chdir(d) { global.__HARNESS_CWD = d; },
    env: Object.assign({}, global.__HARNESS_ENV || {}),
    argv: [],
    exit(code) { if (typeof global.__harnessExit === "function") global.__harnessExit(code); },
    on() {},
    off() {},
  };

  if (typeof global.global === "undefined") global.global = global;
  global.process = shims.process;
  global.__HARNESS_SHIMS = shims;
})(typeof globalThis !== "undefined" ? globalThis : this);
