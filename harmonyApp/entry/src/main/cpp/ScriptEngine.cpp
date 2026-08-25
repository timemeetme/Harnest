/**
 * ScriptEngine.cpp — 脚本沙箱引擎（per-instance QuickJS）
 *
 * 服务链路：DeviceBridge 'runScript' → scriptEngineCreate（惰性、App 级复用）
 *   → scriptEngineSetFetchHandler（ArkTS @ohos.net.http 执行 JS fetch）
 *   → scriptEngineRun(source, timeout) → Promise<envelope JSON>
 *   → fetch 回调上行 → scriptEngineFetchDone 下行结算 → Promise 推进
 *   → scriptEngineDispose（App 退出/引擎重建时）
 *
 * 线程模型：全部 ArkTS 主线程（同 harness 引擎，同线程重入安全）。
 */
#include "ScriptEngine.h"
#include <hilog/log.h>
#include <cstring>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <chrono>
#include <memory>

namespace script {

namespace fs = std::filesystem;

static const char* TAG = "ScriptEngine";

static uint64_t NowMs() {
    return (uint64_t)std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

static std::string jsonEscape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if ((unsigned char)c < 0x20) {
                    char buf[8];
                    snprintf(buf, sizeof(buf), "\\u%04x", (unsigned char)c);
                    out += buf;
                } else {
                    out += c;
                }
        }
    }
    return out;
}

// ══════════════════════════════════════════════════════════
// QuickJS 宿主函数（经 JS_SetContextOpaque 到达所属实例 — per-instance 关键）
// ══════════════════════════════════════════════════════════

static ScriptEngine* EngineOf(JSContext* ctx) {
    return static_cast<ScriptEngine*>(JS_GetContextOpaque(ctx));
}

static JSValue qsb_log(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) {
    ScriptEngine* e = EngineOf(ctx);
    const char* level = argc >= 1 ? JS_ToCString(ctx, argv[0]) : nullptr;
    const char* msg = argc >= 2 ? JS_ToCString(ctx, argv[1]) : nullptr;
    std::string line = std::string(level ? level : "log") + ": " + (msg ? msg : "");
    if (e) e->appendLog(line);
    OH_LOG_DEBUG(LOG_APP, TAG, "%{public}s", line.c_str());
    JS_FreeCString(ctx, level);
    JS_FreeCString(ctx, msg);
    return JS_UNDEFINED;
}

/** fetch 上行：JS fetch(url, opts) → Promise；宿主 handler 同步接单，结果经 fetchDone 下行 */
static JSValue qsb_fetch(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) {
    ScriptEngine* e = EngineOf(ctx);
    if (!e) return JS_ThrowTypeError(ctx, "__sbFetch: no engine");
    const char* url = argc >= 1 ? JS_ToCString(ctx, argv[0]) : nullptr;
    const char* opt = argc >= 2 ? JS_ToCString(ctx, argv[1]) : nullptr;
    std::string urlS = url ? url : "";
    std::string optS = opt ? opt : "{}";
    JS_FreeCString(ctx, url);
    JS_FreeCString(ctx, opt);

    JSValue funcs[2];
    JSValue promise = JS_NewPromiseCapability(ctx, funcs);
    if (JS_IsException(promise)) return promise;

    if (!e->fetchEnv || !e->fetchHandlerRef) {
        JSValue arg = JS_NewString(ctx, "fetch unavailable: no handler");
        JSValue r = JS_Call(ctx, funcs[1], JS_UNDEFINED, 1, &arg);
        JS_FreeValue(ctx, r);
        JS_FreeValue(ctx, arg);
        JS_FreeValue(ctx, funcs[0]);
        JS_FreeValue(ctx, funcs[1]);
        return promise;
    }

    int fetchId = e->allocFetchId();

    napi_env env = e->fetchEnv;
    napi_value fn = nullptr;
    napi_get_reference_value(env, e->fetchHandlerRef, &fn);
    if (!fn) {
        // handler 丢失 → 立即 reject（不落 pendingFetches_，避免悬垂）
        JSValue arg = JS_NewString(ctx, "fetch handler released");
        JSValue r = JS_Call(ctx, funcs[1], JS_UNDEFINED, 1, &arg);
        JS_FreeValue(ctx, r);
        JS_FreeValue(ctx, arg);
        JS_FreeValue(ctx, funcs[0]);
        JS_FreeValue(ctx, funcs[1]);
        return promise;
    }
    e->storePendingFetch(fetchId, funcs[0], funcs[1]);
    napi_value global = nullptr;
    napi_get_global(env, &global);
    napi_value aurl = nullptr;
    napi_create_string_utf8(env, urlS.c_str(), urlS.size(), &aurl);
    napi_value aopt = nullptr;
    napi_create_string_utf8(env, optS.c_str(), optS.size(), &aopt);
    napi_value aid = nullptr;
    napi_create_int32(env, fetchId, &aid);
    napi_value cbArgs[3] = { aid, aurl, aopt };
    napi_status st = napi_call_function(env, global, fn, 3, cbArgs, nullptr);
    if (st != napi_ok) {
        OH_LOG_WARN(LOG_APP, TAG, "fetch handler invoke failed: %{public}d", (int)st);
    }
    return promise;
}

/** 沙箱内读文本：越界/打开失败 → 抛 Error（脚本 try/catch 捕获） */
static JSValue qsb_read(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) {
    ScriptEngine* e = EngineOf(ctx);
    if (!e || argc < 1) return JS_ThrowTypeError(ctx, "__sbRead: bad args");
    const char* p = JS_ToCString(ctx, argv[0]);
    if (!p) return JS_ThrowTypeError(ctx, "__sbRead: bad path");
    std::string resolved;
    bool inside = e->resolveInSandbox(p, resolved);
    JS_FreeCString(ctx, p);
    if (!inside) return JS_ThrowTypeError(ctx, "__sbRead: path escapes sandbox");
    std::ifstream f(resolved, std::ios::binary);
    if (!f) return JS_ThrowTypeError(ctx, "__sbRead: open failed");
    std::ostringstream ss;
    ss << f.rdbuf();
    std::string data = ss.str();
    return JS_NewStringLen(ctx, data.data(), data.size());
}

/** 沙箱内写文本：返回 true；越界/写失败 → 抛 Error */
static JSValue qsb_write(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) {
    ScriptEngine* e = EngineOf(ctx);
    if (!e || argc < 2) return JS_ThrowTypeError(ctx, "__sbWrite: bad args");
    const char* p = JS_ToCString(ctx, argv[0]);
    const char* data = JS_ToCString(ctx, argv[1]);
    if (!p || !data) {
        JS_FreeCString(ctx, p);
        JS_FreeCString(ctx, data);
        return JS_ThrowTypeError(ctx, "__sbWrite: bad args");
    }
    std::string resolved;
    bool inside = e->resolveInSandbox(p, resolved);
    JS_FreeCString(ctx, p);
    if (!inside) {
        JS_FreeCString(ctx, data);
        return JS_ThrowTypeError(ctx, "__sbWrite: path escapes sandbox");
    }
    std::ofstream f(resolved, std::ios::binary | std::ios::trunc);
    if (!f) {
        JS_FreeCString(ctx, data);
        return JS_ThrowTypeError(ctx, "__sbWrite: open failed");
    }
    f << data;
    JS_FreeCString(ctx, data);
    if (!f.good()) return JS_ThrowTypeError(ctx, "__sbWrite: write failed");
    return JS_TRUE;
}

/** 显式收尾（成功）：valueJson 非 JSON 时按纯字符串字面量 */
static JSValue qsb_settle(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) {
    ScriptEngine* e = EngineOf(ctx);
    if (!e) return JS_UNDEFINED;
    std::string payload = "null";
    if (argc >= 1) {
        const char* p = JS_ToCString(ctx, argv[0]);
        if (p && p[0]) {
            JSValue v = JS_ParseJSON(ctx, p, strlen(p), "<settle>");
            if (JS_IsException(v)) {
                JS_GetException(ctx); // 非 JSON → 吞掉解析异常，按纯字符串
                payload = "\"" + jsonEscape(p) + "\"";
            } else {
                payload = e->stringifyValue(v);
                JS_FreeValue(ctx, v);
            }
        }
        JS_FreeCString(ctx, p);
    }
    e->markSettled(true, payload);
    return JS_UNDEFINED;
}

/** 显式收尾（失败）：message 直接作为错误文案 */
static JSValue qsb_settle_err(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) {
    ScriptEngine* e = EngineOf(ctx);
    if (!e) return JS_UNDEFINED;
    const char* p = argc >= 1 ? JS_ToCString(ctx, argv[0]) : nullptr;
    std::string msg = p ? p : "script error";
    JS_FreeCString(ctx, p);
    e->markSettled(false, "\"" + jsonEscape(msg) + "\"");
    return JS_UNDEFINED;
}

// run 级 Promise settle（then/catch 挂钩）— 完成即写 settledJson
static JSValue qsb_run_fulfilled(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv, int) {
    ScriptEngine* e = EngineOf(ctx);
    if (!e) return JS_UNDEFINED;
    e->markSettled(true, argc >= 1 ? e->stringifyValue(argv[0]) : "null");
    return JS_UNDEFINED;
}

static JSValue qsb_run_rejected(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv, int) {
    ScriptEngine* e = EngineOf(ctx);
    if (!e) return JS_UNDEFINED;
    const char* p = argc >= 1 ? JS_ToCString(ctx, argv[0]) : nullptr;
    std::string msg = p ? p : "unknown error";
    JS_FreeCString(ctx, p);
    e->markSettled(false, "\"" + jsonEscape(msg) + "\"");
    return JS_UNDEFINED;
}

// ── bootstrap：预置 JS 运行时（log/console/fetch/readText/writeText） ──
static const char* kBootstrap = R"JS((function () {
  function join(a) {
    var s = '';
    for (var i = 0; i < a.length; i++) { if (i) s += ' '; s += String(a[i]); }
    return s;
  }
  globalThis.log = function () { __sbLog('log', join(arguments)); };
  globalThis.console = {
    log: globalThis.log,
    info: globalThis.log,
    debug: globalThis.log,
    warn: function () { __sbLog('warn', join(arguments)); },
    error: function () { __sbLog('error', join(arguments)); }
  };
  globalThis.fetch = function (url, opts) {
    return __sbFetch(String(url), opts === undefined || opts === null ? '{}' : JSON.stringify(opts));
  };
  globalThis.readText = function (path) { return __sbRead(String(path)); };
  globalThis.writeText = function (path, data) {
    return __sbWrite(String(path), data === undefined ? '' : String(data));
  };
})();)JS";

// ══════════════════════════════════════════════════════════
// ScriptEngine
// ══════════════════════════════════════════════════════════

ScriptEngine::ScriptEngine(const std::string& cwd) : cwd_(cwd) {}
ScriptEngine::~ScriptEngine() { dispose(); }

bool ScriptEngine::init() {
    std::error_code ec;
    if (!cwd_.empty()) fs::create_directories(cwd_, ec);
    runtime_ = JS_NewRuntime();
    if (!runtime_) return false;
    ctx_ = JS_NewContext(runtime_);
    if (!ctx_) {
        JS_FreeRuntime(runtime_);
        runtime_ = nullptr;
        return false;
    }
    JS_SetContextOpaque(ctx_, this);
    JS_SetInterruptHandler(runtime_, &ScriptEngine::interruptHandler, this);

    JSValue global = JS_GetGlobalObject(ctx_);
    JS_SetPropertyStr(ctx_, global, "__sbLog", JS_NewCFunction(ctx_, qsb_log, "__sbLog", 2));
    JS_SetPropertyStr(ctx_, global, "__sbFetch", JS_NewCFunction(ctx_, qsb_fetch, "__sbFetch", 2));
    JS_SetPropertyStr(ctx_, global, "__sbRead", JS_NewCFunction(ctx_, qsb_read, "__sbRead", 1));
    JS_SetPropertyStr(ctx_, global, "__sbWrite", JS_NewCFunction(ctx_, qsb_write, "__sbWrite", 2));
    JS_SetPropertyStr(ctx_, global, "__sbSettle", JS_NewCFunction(ctx_, qsb_settle, "__sbSettle", 1));
    JS_SetPropertyStr(ctx_, global, "__sbSettleErr", JS_NewCFunction(ctx_, qsb_settle_err, "__sbSettleErr", 1));
    JS_FreeValue(ctx_, global);

    JSValue r = JS_Eval(ctx_, kBootstrap, strlen(kBootstrap), "<bootstrap>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(r)) {
        JSValue err = JS_GetException(ctx_);
        const char* msg = JS_ToCString(ctx_, err);
        OH_LOG_ERROR(LOG_APP, TAG, "bootstrap eval failed: %{public}s", msg ? msg : "?");
        JS_FreeCString(ctx_, msg);
        JS_FreeValue(ctx_, err);
        return false;
    }
    JS_FreeValue(ctx_, r);
    return true;
}

void ScriptEngine::dispose() {
    if (ctx_) {
        for (auto& kv : pendingFetches_) {
            if (!JS_IsUndefined(kv.second.first)) JS_FreeValue(ctx_, kv.second.first);
            if (!JS_IsUndefined(kv.second.second)) JS_FreeValue(ctx_, kv.second.second);
        }
        pendingFetches_.clear();
        JS_FreeContext(ctx_);
        ctx_ = nullptr;
    }
    if (runtime_) {
        JS_FreeRuntime(runtime_);
        runtime_ = nullptr;
    }
    if (fetchEnv && fetchHandlerRef) {
        napi_delete_reference(fetchEnv, fetchHandlerRef);
    }
    fetchEnv = nullptr;
    fetchHandlerRef = nullptr;
    running = false;
    napiEnv = nullptr;
    pendingDeferred = nullptr;
}

bool ScriptEngine::run(const std::string& source, uint64_t timeoutMs, std::string& outJson) {
    startMs_ = NowMs();
    deadlineMs_ = timeoutMs > 0 ? startMs_ + timeoutMs : 0;
    logs_.clear();
    settled = false;
    settledJson.clear();
    running = false;

    JSValue result = JS_Eval(ctx_, source.c_str(), source.size(), "<script>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(result)) {
        JSValue err = JS_GetException(ctx_);
        outJson = buildEnvelope(false, "\"" + jsonEscape(jsErrorString(err)) + "\"");
        JS_FreeValue(ctx_, err);
        return true;
    }

    // run 级 Promise → then/catch 挂钩异步结算
    bool isPromise = false;
    if (JS_IsObject(result)) {
        JSValue thenFn = JS_GetPropertyStr(ctx_, result, "then");
        isPromise = JS_IsFunction(ctx_, thenFn);
        JS_FreeValue(ctx_, thenFn);
    }
    if (isPromise) {
        JSValue fulfill = JS_NewCFunctionMagic(ctx_, qsb_run_fulfilled, "sbFulfilled", 1, JS_CFUNC_generic_magic, 0);
        JSValue reject = JS_NewCFunctionMagic(ctx_, qsb_run_rejected, "sbRejected", 1, JS_CFUNC_generic_magic, 0);
        JSValue thenFn = JS_GetPropertyStr(ctx_, result, "then");
        JSValue thenArgs[2] = { fulfill, reject };
        JSValue ignored = JS_Call(ctx_, thenFn, result, 2, thenArgs);
        JS_FreeValue(ctx_, ignored);
        JS_FreeValue(ctx_, thenFn);
        JS_FreeValue(ctx_, fulfill);
        JS_FreeValue(ctx_, reject);
        JS_FreeValue(ctx_, result);
        pumpJobs();
        if (settled) {
            outJson = settledJson;
            return true;
        }
        running = true; // 异步挂起 — napi 层挂 deferred
        return false;
    }

    pumpJobs();
    if (settled) { // 同步 eval 中已 __sbSettle
        outJson = settledJson;
        JS_FreeValue(ctx_, result);
        return true;
    }
    std::string value = stringifyValue(result);
    JS_FreeValue(ctx_, result);
    outJson = buildEnvelope(true, value);
    return true;
}

void ScriptEngine::fetchDone(int fetchId, bool ok, const std::string& body) {
    auto it = pendingFetches_.find(fetchId);
    if (it == pendingFetches_.end()) return;
    JSValue resolve = it->second.first;
    JSValue reject = it->second.second;
    JSValue fn = ok && !JS_IsUndefined(resolve) ? resolve : reject;
    JSValue arg = JS_NewStringLen(ctx_, body.data(), body.size());
    JSValue r = JS_Call(ctx_, fn, JS_UNDEFINED, 1, &arg);
    if (JS_IsException(r)) {
        JSValue err = JS_GetException(ctx_);
        appendLog(std::string("fetch settle error: ") + jsErrorString(err));
        JS_FreeValue(ctx_, err);
    }
    JS_FreeValue(ctx_, r);
    JS_FreeValue(ctx_, arg);
    if (!JS_IsUndefined(resolve)) JS_FreeValue(ctx_, resolve);
    if (!JS_IsUndefined(reject)) JS_FreeValue(ctx_, reject);
    pendingFetches_.erase(it);
    pumpJobs();
}

bool ScriptEngine::enforceTimeout(std::string& outJson) {
    if (!running || settled) return false;
    if (deadlineMs_ == 0 || NowMs() <= deadlineMs_) return false;
    // fail 全部未决 fetch（脚本 catch 链有机会走一次）再判
    std::vector<int> ids;
    for (auto& kv : pendingFetches_) ids.push_back(kv.first);
    for (int id : ids) {
        auto it = pendingFetches_.find(id);
        if (it == pendingFetches_.end()) continue;
        JSValue reject = it->second.second;
        if (!JS_IsUndefined(reject)) {
            JSValue arg = JS_NewString(ctx_, "timeout: script exceeded time budget");
            JSValue r = JS_Call(ctx_, reject, JS_UNDEFINED, 1, &arg);
            JS_FreeValue(ctx_, r);
            JS_FreeValue(ctx_, arg);
            JS_FreeValue(ctx_, reject);
        }
        if (!JS_IsUndefined(it->second.first)) JS_FreeValue(ctx_, it->second.first);
        pendingFetches_.erase(it);
    }
    pumpJobs();
    if (!settled) markSettled(false, "\"timeout: script exceeded time budget\"");
    outJson = settledJson;
    return true;
}

void ScriptEngine::markSettled(bool ok, const std::string& payloadJson) {
    if (settled) return; // 首个结算生效（显式 settle 与 Promise settle 竞争取先）
    settled = true;
    settledJson = buildEnvelope(ok, payloadJson);
}

void ScriptEngine::appendLog(const std::string& line) {
    if (logs_.size() >= 500) logs_.erase(logs_.begin()); // 环形封顶
    logs_.push_back(line);
}

std::string ScriptEngine::stringifyValue(JSValue v) {
    JSValue s = JS_JSONStringify(ctx_, v, JS_UNDEFINED, JS_UNDEFINED);
    if (JS_IsException(s)) {
        JS_GetException(ctx_);
        return "null";
    }
    if (JS_IsUndefined(s) || JS_IsNull(s)) {
        JS_FreeValue(ctx_, s);
        return "null";
    }
    const char* p = JS_ToCString(ctx_, s);
    std::string out = p ? p : "null";
    JS_FreeCString(ctx_, p);
    JS_FreeValue(ctx_, s);
    return out;
}

std::string ScriptEngine::jsErrorString(JSValue err) {
    const char* p = JS_ToCString(ctx_, err);
    std::string out = p ? p : "unknown error";
    JS_FreeCString(ctx_, p);
    return out;
}

std::string ScriptEngine::buildEnvelope(bool ok, const std::string& payloadJson) const {
    uint64_t dur = NowMs() - startMs_;
    std::string j = "{\"ok\":";
    j += ok ? "true" : "false";
    if (ok) {
        j += ",\"value\":";
        j += payloadJson.empty() ? "null" : payloadJson;
    } else {
        j += ",\"error\":";
        j += payloadJson.empty() ? "\"unknown error\"" : payloadJson;
    }
    j += ",\"durationMs\":";
    j += std::to_string(dur);
    j += ",\"logs\":[";
    for (size_t i = 0; i < logs_.size(); i++) {
        if (i > 0) j += ",";
        j += "\"" + jsonEscape(logs_[i]) + "\"";
    }
    j += "]}";
    return j;
}

void ScriptEngine::pumpJobs() {
    int executed = 0;
    for (;;) {
        JSContext* ctx = nullptr;
        int err = JS_ExecutePendingJob(runtime_, &ctx);
        if (err <= 0) {
            if (err < 0 && ctx) {
                JSValue exc = JS_GetException(ctx);
                appendLog(std::string("job error: ") + jsErrorString(exc));
                JS_FreeValue(ctx, exc);
            }
            break;
        }
        executed++;
        if (executed > 100000) break; // 防御性上限
    }
}

/** wall-clock 中断器：掐同步死循环（QuickJS 周期性回调；1 = interrupt → 抛 InternalError） */
int ScriptEngine::interruptHandler(JSRuntime* rt, void* opaque) {
    (void)rt;
    ScriptEngine* e = static_cast<ScriptEngine*>(opaque);
    if (!e) return 0;
    return e->deadlineMs_ != 0 && NowMs() > e->deadlineMs_ ? 1 : 0;
}

/** 沙箱路径校验：resolved 必须位于 cwd_ 之下（防 /a/b-evil 前缀绕过） */
bool ScriptEngine::resolveInSandbox(const std::string& path, std::string& out) {
    fs::path base = fs::path(cwd_).lexically_normal();
    fs::path p = fs::path(path).is_absolute() ? fs::path(path) : base / path;
    p = p.lexically_normal();
    out = p.string();
    std::string baseStr = base.string();
    std::string sep = std::string(1, fs::path::preferred_separator);
    if (!baseStr.empty() && baseStr.back() != fs::path::preferred_separator) baseStr += sep;
    return out.rfind(baseStr, 0) == 0;
}

// ══════════════════════════════════════════════════════════
// napi 胶水（实例注册表按 engineId 索引 — per-instance 多实例并存）
// ══════════════════════════════════════════════════════════

static std::map<int, std::unique_ptr<ScriptEngine>> g_scriptEngines;
static int g_nextScriptEngineId = 0;

static napi_value MakeString(napi_env env, const std::string& s) {
    napi_value v = nullptr;
    napi_create_string_utf8(env, s.c_str(), s.size(), &v);
    return v;
}

static napi_value MakeInt(napi_env env, int32_t n) {
    napi_value v = nullptr;
    napi_create_int32(env, n, &v);
    return v;
}

static std::string ArgToString(napi_env env, napi_value v) {
    if (!v) return "";
    size_t len = 0;
    napi_get_value_string_utf8(env, v, nullptr, 0, &len);
    std::string s(len, '\0');
    if (len > 0) napi_get_value_string_utf8(env, v, s.data(), len + 1, &len);
    return s;
}

static ScriptEngine* FindScriptEngine(napi_env env, napi_value idVal) {
    int32_t id = 0;
    napi_get_value_int32(env, idVal, &id);
    auto it = g_scriptEngines.find(id);
    return it == g_scriptEngines.end() ? nullptr : it->second.get();
}

/** 挂起 run 已 settle → resolve deferred 并复位（fetchDone/超时/销毁 各入口调用） */
static void FlushPendingRun(ScriptEngine* e) {
    if (!e || !e->running || !e->settled) return;
    if (e->napiEnv && e->pendingDeferred) {
        napi_resolve_deferred(e->napiEnv, e->pendingDeferred, MakeString(e->napiEnv, e->settledJson));
    }
    e->running = false;
    e->napiEnv = nullptr;
    e->pendingDeferred = nullptr;
}

// scriptEngineCreate(cwd: string) → number
napi_value NativeScriptEngineCreate(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_error(env, nullptr, "scriptEngineCreate requires cwd");
        return nullptr;
    }
    std::string cwd = ArgToString(env, args[0]);
    if (cwd.empty()) cwd = "/data/local/tmp/script-sandbox";
    auto engine = std::make_unique<ScriptEngine>(cwd);
    if (!engine->init()) {
        napi_throw_error(env, nullptr, "script engine init failed");
        return nullptr;
    }
    int id = ++g_nextScriptEngineId;
    g_scriptEngines[id] = std::move(engine);
    OH_LOG_INFO(LOG_APP, TAG, "engine %{public}d created (cwd=%{public}s)", id, cwd.c_str());
    return MakeInt(env, id);
}

// scriptEngineRun(engineId: number, source: string, timeoutMs?: number) → Promise<string>
napi_value NativeScriptEngineRun(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    napi_deferred deferred = nullptr;
    napi_value promise = nullptr;
    napi_create_promise(env, &deferred, &promise);
    if (argc < 2) {
        napi_resolve_deferred(env, deferred, MakeString(env, "{\"ok\":false,\"error\":\"scriptEngineRun requires (engineId, source)\",\"logs\":[]}"));
        return promise;
    }
    ScriptEngine* e = FindScriptEngine(env, args[0]);
    if (!e) {
        napi_resolve_deferred(env, deferred, MakeString(env, "{\"ok\":false,\"error\":\"script engine not found\",\"logs\":[]}"));
        return promise;
    }
    if (e->running) {
        napi_resolve_deferred(env, deferred, MakeString(env, "{\"ok\":false,\"error\":\"engine busy: previous run still pending\",\"logs\":[]}"));
        return promise;
    }
    std::string source = ArgToString(env, args[1]);
    int32_t timeoutMs = 60000;
    if (argc >= 3) napi_get_value_int32(env, args[2], &timeoutMs);
    std::string outJson;
    if (e->run(source, timeoutMs > 0 ? (uint64_t)timeoutMs : 0, outJson)) {
        napi_resolve_deferred(env, deferred, MakeString(env, outJson));
    } else {
        e->napiEnv = env;
        e->pendingDeferred = deferred;
    }
    return promise;
}

// scriptEngineDispose(engineId: number) → boolean
napi_value NativeScriptEngineDispose(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    napi_value out = nullptr;
    napi_get_boolean(env, false, &out);
    if (argc < 1) return out;
    int32_t id = 0;
    napi_get_value_int32(env, args[0], &id);
    auto it = g_scriptEngines.find(id);
    if (it == g_scriptEngines.end()) return out;
    ScriptEngine* e = it->second.get();
    if (e->running && !e->settled) {
        e->markSettled(false, "\"engine disposed\"");
    }
    FlushPendingRun(e);
    e->dispose();
    g_scriptEngines.erase(it);
    OH_LOG_INFO(LOG_APP, TAG, "engine %{public}d disposed", id);
    napi_get_boolean(env, true, &out);
    return out;
}

// scriptEngineFetchDone(engineId: number, fetchId: number, ok: boolean, body: string) → void
napi_value NativeScriptEngineFetchDone(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc >= 4) {
        ScriptEngine* e = FindScriptEngine(env, args[0]);
        if (e) {
            int32_t fetchId = 0;
            bool ok = false;
            napi_get_value_int32(env, args[1], &fetchId);
            napi_get_value_bool(env, args[2], &ok);
            std::string body = ArgToString(env, args[3]);
            std::string forced;
            if (!e->enforceTimeout(forced)) {
                e->fetchDone(fetchId, ok, body);
                (void)e->enforceTimeout(forced); // fetch 结算后仍过线 → 强制收尾
            }
            FlushPendingRun(e);
        }
    }
    napi_value undef = nullptr;
    napi_get_undefined(env, &undef);
    return undef;
}

// scriptEngineSetFetchHandler(engineId: number, handler: (fetchId, url, optionsJson) => void) → void
napi_value NativeScriptEngineSetFetchHandler(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc >= 2) {
        ScriptEngine* e = FindScriptEngine(env, args[0]);
        napi_valuetype t = napi_undefined;
        napi_typeof(env, args[1], &t);
        if (e && t == napi_function) {
            if (e->fetchEnv && e->fetchHandlerRef) {
                napi_delete_reference(e->fetchEnv, e->fetchHandlerRef);
            }
            napi_create_reference(env, args[1], 1, &e->fetchHandlerRef);
            e->fetchEnv = env;
        }
    }
    napi_value undef = nullptr;
    napi_get_undefined(env, &undef);
    return undef;
}

} // namespace script
