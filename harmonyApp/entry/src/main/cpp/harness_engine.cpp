#include "harness_engine.h"
#include <cstring>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>

namespace harness {

namespace fs = std::filesystem;

// 当前引擎实例（host C 函数回调需要到达；单例模型）
static HarnessEngine* g_engine = nullptr;
static HostCallbacks g_callbacks;

// ══════════════════════════════════════════════════════════
// QuickJS 宿主函数（暴露给 harness.js 的 C 回调）
// ══════════════════════════════════════════════════════════

static JSValue qjs_stdout_write(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) {
    const char* chunk = argc >= 1 ? JS_ToCString(ctx, argv[0]) : nullptr;
    if (chunk && g_callbacks.onLog) g_callbacks.onLog("stdout", chunk);
    JS_FreeCString(ctx, chunk);
    return JS_NewInt32(ctx, 1);
}

static JSValue qjs_stderr_write(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) {
    const char* chunk = argc >= 1 ? JS_ToCString(ctx, argv[0]) : nullptr;
    if (chunk && g_callbacks.onLog) g_callbacks.onLog("stderr", chunk);
    JS_FreeCString(ctx, chunk);
    return JS_NewInt32(ctx, 1);
}

static JSValue qjs_process_exit(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) {
    int code = 0;
    if (argc >= 1) JS_ToInt32(ctx, &code, argv[0]);
    if (g_callbacks.onExit) g_callbacks.onExit(code);
    return JS_UNDEFINED;
}

/** fetch 上行：harness.js 的 fetch polyfill 发起 HTTP 请求 → 宿主（ArkTS）执行 */
static JSValue qjs_fetch_start(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 1 || !g_engine) return JS_ThrowTypeError(ctx, "__harnessFetchStart: no request");
    const char* req = JS_ToCString(ctx, argv[0]);
    if (!req) return JS_ThrowTypeError(ctx, "__harnessFetchStart: bad request");
    static int s_fetchId = 0;
    int id = ++s_fetchId;
    if (g_callbacks.onFetch) g_callbacks.onFetch(id, req);
    JS_FreeCString(ctx, req);
    return JS_NewInt32(ctx, id);
}

/** 事件上行：harness.js 的 __harnessEmit（chat 完成等结构化事件） */
static JSValue qjs_emit(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) {
    const char* event = argc >= 1 ? JS_ToCString(ctx, argv[0]) : nullptr;
    if (event && g_callbacks.onEvent) g_callbacks.onEvent(event);
    JS_FreeCString(ctx, event);
    return JS_UNDEFINED;
}

/** 设备调用上行：device_* 工具 → __deviceCall(op,args) → 宿主（ArkTS DeviceBridge）执行。
 *  返回 callId；宿主完成后经 deviceResult(callId, ok, json) 下行结算。
 *  无宿主回调时抛 TypeError（polyfill 捕获转 reject，避免工具悬挂）。 */
static JSValue qjs_device_call(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 1) return JS_ThrowTypeError(ctx, "__harnessDeviceCall: no request");
    if (!g_callbacks.onDevice) return JS_ThrowTypeError(ctx, "__harnessDeviceCall: no device bridge");
    const char* req = JS_ToCString(ctx, argv[0]);
    if (!req) return JS_ThrowTypeError(ctx, "__harnessDeviceCall: bad request");
    static int s_deviceId = 0;
    int id = ++s_deviceId;
    g_callbacks.onDevice(id, req);
    JS_FreeCString(ctx, req);
    return JS_NewInt32(ctx, id);
}

// ── fs 桥（同步 POSIX/std::filesystem，沙箱限制在 cwd 下） ──

static bool pathInsideCwd(const std::string& path, std::string& resolvedOut) {
    std::error_code ec;
    (void)ec;
    fs::path base = fs::path(g_engine ? g_engine->sandboxRoot() : "").lexically_normal();
    fs::path p = fs::path(path).is_absolute() ? fs::path(path) : base / path;
    p = p.lexically_normal();
    resolvedOut = p.string();
    if (base.empty()) return true; // 未设 cwd 时不限制（不应发生）
    // 前缀校验：resolved 必须位于 base 之下（base 本身或 base/... ，防止 /a/b-evil 绕过）
    std::string baseStr = base.string();
    std::string sep = std::string(1, fs::path::preferred_separator);
    if (!baseStr.empty() && baseStr.back() != fs::path::preferred_separator) baseStr += sep;
    return resolvedOut.rfind(baseStr, 0) == 0;
}

static std::string readFileText(const std::string& path, bool& ok, std::string& err) {
    std::ifstream f(path, std::ios::binary);
    if (!f) { ok = false; err = "open failed: " + path; return ""; }
    std::ostringstream ss;
    ss << f.rdbuf();
    ok = true;
    return ss.str();
}

/** fs 操作分发：{op, path, data?, recursive?} → {ok, ...字段} */
static JSValue qjs_fs_call(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 1) return JS_ThrowTypeError(ctx, "__harnessFsCall: no args");
    const char* argJson = JS_ToCString(ctx, argv[0]);
    if (!argJson) return JS_ThrowTypeError(ctx, "__harnessFsCall: bad args");
    JSValue args = JS_ParseJSON(ctx, argJson, strlen(argJson), "<fs>");
    JS_FreeCString(ctx, argJson);
    if (JS_IsException(args)) return JS_EXCEPTION;

    const char* op = JS_ToCString(ctx, JS_GetPropertyStr(ctx, args, "op"));
    const char* pathRaw = JS_ToCString(ctx, JS_GetPropertyStr(ctx, args, "path"));
    std::string opStr = op ? op : "";
    std::string path = pathRaw ? pathRaw : "";
    JS_FreeCString(ctx, op);
    JS_FreeCString(ctx, pathRaw);

    std::string resolved;
    if (!pathInsideCwd(path, resolved)) {
        JS_FreeValue(ctx, args);
        JSValue out = JS_NewObject(ctx);
        JS_SetPropertyStr(ctx, out, "ok", JS_FALSE);
        JS_SetPropertyStr(ctx, out, "error", JS_NewString(ctx, ("path escapes sandbox: " + path).c_str()));
        return out;
    }
    std::error_code ec;

    if (opStr == "exists") {
        JSValue out = JS_NewObject(ctx);
        JS_SetPropertyStr(ctx, out, "exists", JS_NewBool(ctx, fs::exists(resolved, ec)));
        JS_FreeValue(ctx, args);
        return out;
    }
    if (opStr == "readFile") {
        bool ok = false; std::string err;
        std::string data = readFileText(resolved, ok, err);
        JSValue out = JS_NewObject(ctx);
        if (ok) {
            JS_SetPropertyStr(ctx, out, "ok", JS_TRUE);
            JS_SetPropertyStr(ctx, out, "data", JS_NewStringLen(ctx, data.data(), data.size()));
        } else {
            JS_SetPropertyStr(ctx, out, "ok", JS_FALSE);
            JS_SetPropertyStr(ctx, out, "error", JS_NewString(ctx, err.c_str()));
        }
        JS_FreeValue(ctx, args);
        return out;
    }
    if (opStr == "writeFile") {
        const char* data = JS_ToCString(ctx, JS_GetPropertyStr(ctx, args, "data"));
        fs::path fp(resolved);
        if (fp.has_parent_path()) fs::create_directories(fp.parent_path(), ec);
        std::ofstream f(resolved, std::ios::binary | std::ios::trunc);
        JSValue out = JS_NewObject(ctx);
        if (!f || !data) {
            JS_SetPropertyStr(ctx, out, "ok", JS_FALSE);
            JS_SetPropertyStr(ctx, out, "error", JS_NewString(ctx, "write failed"));
        } else {
            size_t len = data ? strlen(data) : 0;
            f.write(data, (std::streamsize)len);
            f.close();
            JS_SetPropertyStr(ctx, out, "ok", JS_NewBool(ctx, !f.bad()));
        }
        JS_FreeCString(ctx, data);
        JS_FreeValue(ctx, args);
        return out;
    }
    if (opStr == "readdir") {
        JSValue out = JS_NewObject(ctx);
        if (!fs::is_directory(resolved, ec)) {
            JS_SetPropertyStr(ctx, out, "ok", JS_FALSE);
            JS_SetPropertyStr(ctx, out, "error", JS_NewString(ctx, "not a directory"));
        } else {
            JSValue entries = JS_NewArray(ctx);
            uint32_t i = 0;
            for (auto& e : fs::directory_iterator(resolved, ec)) {
                JS_SetPropertyUint32(ctx, entries, i++, JS_NewString(ctx, e.path().filename().string().c_str()));
                if (ec) break;
            }
            JS_SetPropertyStr(ctx, out, "ok", JS_TRUE);
            JS_SetPropertyStr(ctx, out, "entries", entries);
        }
        JS_FreeValue(ctx, args);
        return out;
    }
    if (opStr == "mkdir") {
        JSValue recursive = JS_GetPropertyStr(ctx, args, "recursive");
        bool rec = JS_ToBool(ctx, recursive) > 0;
        JS_FreeValue(ctx, recursive);
        bool ok = rec ? fs::create_directories(resolved, ec) : fs::create_directory(resolved, ec);
        (void)ok;
        JSValue out = JS_NewObject(ctx);
        JS_SetPropertyStr(ctx, out, "ok", JS_NewBool(ctx, !ec));
        if (ec) JS_SetPropertyStr(ctx, out, "error", JS_NewString(ctx, ec.message().c_str()));
        JS_FreeValue(ctx, args);
        return out;
    }
    if (opStr == "rm") {
        JSValue recursive = JS_GetPropertyStr(ctx, args, "recursive");
        bool rec = JS_ToBool(ctx, recursive) > 0;
        JS_FreeValue(ctx, recursive);
        bool removed = rec ? fs::remove_all(resolved, ec) : fs::remove(resolved, ec);
        (void)removed;
        JSValue out = JS_NewObject(ctx);
        JS_SetPropertyStr(ctx, out, "ok", JS_NewBool(ctx, !ec));
        if (ec) JS_SetPropertyStr(ctx, out, "error", JS_NewString(ctx, ec.message().c_str()));
        JS_FreeValue(ctx, args);
        return out;
    }
    if (opStr == "stat") {
        JSValue out = JS_NewObject(ctx);
        auto st = fs::status(resolved, ec);
        if (ec) {
            JS_SetPropertyStr(ctx, out, "ok", JS_FALSE);
            JS_SetPropertyStr(ctx, out, "error", JS_NewString(ctx, ec.message().c_str()));
        } else {
            bool isDir = fs::is_directory(st);
            uintmax_t size = isDir ? 0 : fs::file_size(resolved, ec);
            JS_SetPropertyStr(ctx, out, "ok", JS_TRUE);
            JS_SetPropertyStr(ctx, out, "isDir", JS_NewBool(ctx, isDir));
            JS_SetPropertyStr(ctx, out, "size", JS_NewInt64(ctx, (int64_t)size));
            JS_SetPropertyStr(ctx, out, "mtimeMs", JS_NewInt64(ctx, 0));
        }
        JS_FreeValue(ctx, args);
        return out;
    }

    JS_FreeValue(ctx, args);
    JSValue out = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, out, "ok", JS_FALSE);
    JS_SetPropertyStr(ctx, out, "error", JS_NewString(ctx, ("unknown op: " + opStr).c_str()));
    return out;
}

// ── Promise settle 回调（magic = callId） ──

static JSValue qjs_call_fulfilled(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv, int magic) {
    if (!g_engine) return JS_UNDEFINED;
    std::string json = "null";
    if (argc >= 1) {
        JSValue s = JS_JSONStringify(ctx, argv[0], JS_UNDEFINED, JS_UNDEFINED);
        if (JS_IsException(s)) {
            JS_GetException(ctx); // 清理异常
        } else if (!JS_IsUndefined(s)) {
            const char* p = JS_ToCString(ctx, s);
            if (p) json = p;
            JS_FreeCString(ctx, p);
        }
        JS_FreeValue(ctx, s);
    }
    g_engine->notifySettled(magic, true, json);
    return JS_UNDEFINED;
}

static JSValue qjs_call_rejected(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv, int magic) {
    if (!g_engine) return JS_UNDEFINED;
    std::string msg = "unknown error";
    if (argc >= 1) {
        const char* p = JS_ToCString(ctx, argv[0]);
        if (p) msg = p;
        JS_FreeCString(ctx, p);
    }
    g_engine->notifySettled(magic, false, msg);
    return JS_UNDEFINED;
}

// ══════════════════════════════════════════════════════════
// HarnessEngine
// ══════════════════════════════════════════════════════════

HarnessEngine::HarnessEngine() = default;
HarnessEngine::~HarnessEngine() { dispose(); }

const char* HarnessEngine_patchNote() { return "v2 async driver"; }

// patchForGlobalEval 声明为文件内静态
static std::string patchForGlobalEval(const std::string& src) {
    auto pos = src.rfind("export {");
    if (pos == std::string::npos) return src;
    return src.substr(0, pos);
}

bool HarnessEngine::init(const std::string& jsCode, const HostCallbacks& callbacks) {
    callbacks_ = callbacks;
    g_callbacks = callbacks;
    g_engine = this;

    runtime_ = JS_NewRuntime();
    if (!runtime_) return false;
    ctx_ = JS_NewContext(runtime_);
    if (!ctx_) { JS_FreeRuntime(runtime_); runtime_ = nullptr; return false; }

    // 1. 沙箱目录就绪 + 全局环境（envVars_ 在 init 前由 setEnv 暂存）
    std::error_code ec;
    if (!cwd_.empty()) fs::create_directories(cwd_, ec);
    JSValue global = JS_GetGlobalObject(ctx_);
    JS_SetPropertyStr(ctx_, global, "__HARNESS_CWD", JS_NewString(ctx_, cwd_.c_str()));
    JSValue envObj = JS_NewObject(ctx_);
    for (const auto& [k, v] : envVars_) {
        JS_SetPropertyStr(ctx_, envObj, k.c_str(), JS_NewString(ctx_, v.c_str()));
    }
    JS_SetPropertyStr(ctx_, global, "__HARNESS_ENV", envObj);

    // 2. 注册宿主桥函数（必须在 eval harness.js 之前 — host-bridge.js 探测后装 fetch/fs，
    //    device-bridge.js 探测 __harnessDeviceCall 后注册 device_* 工具）
    JS_SetPropertyStr(ctx_, global, "__harnessFetchStart",
        JS_NewCFunction(ctx_, qjs_fetch_start, "__harnessFetchStart", 1));
    JS_SetPropertyStr(ctx_, global, "__harnessEmit",
        JS_NewCFunction(ctx_, qjs_emit, "__harnessEmit", 1));
    JS_SetPropertyStr(ctx_, global, "__harnessFsCall",
        JS_NewCFunction(ctx_, qjs_fs_call, "__harnessFsCall", 1));
    JS_SetPropertyStr(ctx_, global, "__harnessDeviceCall",
        JS_NewCFunction(ctx_, qjs_device_call, "__harnessDeviceCall", 1));
    JS_FreeValue(ctx_, global);

    // 3. Patch + eval harness.js（GLOBAL 模式，export 块截断）
    std::string patched = patchForGlobalEval(jsCode);
    JSValue result = JS_Eval(ctx_, patched.c_str(), patched.size(), "<harness>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(result)) {
        JSValue err = JS_GetException(ctx_);
        const char* msg = JS_ToCString(ctx_, err);
        fprintf(stderr, "[harness] eval error: %s\n", msg ? msg : "unknown");
        if (g_callbacks.onLog) g_callbacks.onLog("stderr", std::string("[harness] eval error: ") + (msg ? msg : "unknown"));
        // 异常 stack（含行号）— 定位 eval 失败位置
        JSValue stackV = JS_GetPropertyStr(ctx_, err, "stack");
        if (!JS_IsException(stackV) && !JS_IsUndefined(stackV)) {
            const char* stackStr = JS_ToCString(ctx_, stackV);
            if (stackStr) {
                fprintf(stderr, "[harness] eval stack: %s\n", stackStr);
                if (g_callbacks.onLog) g_callbacks.onLog("stderr", std::string("[harness] eval stack: ") + stackStr);
                JS_FreeCString(ctx_, stackStr);
            }
        }
        JS_FreeValue(ctx_, stackV);
        JS_FreeCString(ctx_, msg);
        JS_FreeValue(ctx_, err);
        JS_FreeValue(ctx_, result);
        JS_FreeContext(ctx_); ctx_ = nullptr;
        JS_FreeRuntime(runtime_); runtime_ = nullptr;
        g_engine = nullptr;
        return false;
    }
    JS_FreeValue(ctx_, result);
    pumpJobs();

    // 4. 接管 process.stdout/stderr/exit
    global = JS_GetGlobalObject(ctx_);
    JSValue process = JS_GetPropertyStr(ctx_, global, "process");
    if (JS_IsObject(process)) {
        JSValue out = JS_GetPropertyStr(ctx_, process, "stdout");
        if (JS_IsObject(out)) JS_SetPropertyStr(ctx_, out, "write", JS_NewCFunction(ctx_, qjs_stdout_write, "write", 1));
        JS_FreeValue(ctx_, out);
        JSValue errS = JS_GetPropertyStr(ctx_, process, "stderr");
        if (JS_IsObject(errS)) JS_SetPropertyStr(ctx_, errS, "write", JS_NewCFunction(ctx_, qjs_stderr_write, "write", 1));
        JS_FreeValue(ctx_, errS);
        JS_SetPropertyStr(ctx_, process, "exit", JS_NewCFunction(ctx_, qjs_process_exit, "exit", 1));
    }
    JS_FreeValue(ctx_, process);
    JS_FreeValue(ctx_, global);

    // 5. createEngine() 工厂 → engineInstance_
    global = JS_GetGlobalObject(ctx_);
    JSValue createEngine = JS_GetPropertyStr(ctx_, global, "createEngine");
    JS_FreeValue(ctx_, global);
    if (!JS_IsFunction(ctx_, createEngine)) {
        fprintf(stderr, "[harness] createEngine not found on globalThis\n");
        JS_FreeValue(ctx_, createEngine);
        JS_FreeContext(ctx_); ctx_ = nullptr;
        JS_FreeRuntime(runtime_); runtime_ = nullptr;
        g_engine = nullptr;
        return false;
    }
    JSValue instance = JS_Call(ctx_, createEngine, JS_UNDEFINED, 0, nullptr);
    JS_FreeValue(ctx_, createEngine);
    if (JS_IsException(instance)) {
        JSValue err = JS_GetException(ctx_);
        const char* msg = JS_ToCString(ctx_, err);
        fprintf(stderr, "[harness] createEngine() error: %s\n", msg ? msg : "unknown");
        if (g_callbacks.onLog) g_callbacks.onLog("stderr", std::string("[harness] createEngine() error: ") + (msg ? msg : "unknown"));
        JS_FreeCString(ctx_, msg);
        JS_FreeValue(ctx_, err);
        JS_FreeValue(ctx_, instance);
        JS_FreeContext(ctx_); ctx_ = nullptr;
        JS_FreeRuntime(runtime_); runtime_ = nullptr;
        g_engine = nullptr;
        return false;
    }
    engineInstance_ = instance;
    pumpJobs();
    return true;
}

std::string HarnessEngine::stringifyValue(JSValue v) {
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

std::string HarnessEngine::jsErrorString(JSValue err) {
    const char* p = JS_ToCString(ctx_, err);
    std::string out = p ? p : "unknown error";
    JS_FreeCString(ctx_, p);
    return out;
}

int HarnessEngine::callFunc(const std::string& funcName, const std::string& jsonArgs, std::string& outResult) {
    if (!ctx_ || JS_IsNull(engineInstance_) || JS_IsUndefined(engineInstance_)) {
        outResult = "engine not initialized";
        return -1;
    }

    JSValue func = JS_GetPropertyStr(ctx_, engineInstance_, funcName.c_str());
    if (!JS_IsFunction(ctx_, func)) {
        JS_FreeValue(ctx_, func);
        // 尝试全局函数（兼容直接暴露的工具函数）
        JSValue global = JS_GetGlobalObject(ctx_);
        func = JS_GetPropertyStr(ctx_, global, funcName.c_str());
        JS_FreeValue(ctx_, global);
        if (!JS_IsFunction(ctx_, func)) {
            JS_FreeValue(ctx_, func);
            outResult = "function not found: " + funcName;
            return -1;
        }
    }

    JSValue argv[1] = { JS_NULL };
    int argc = 0;
    if (!jsonArgs.empty()) {
        argv[0] = JS_ParseJSON(ctx_, jsonArgs.c_str(), jsonArgs.size(), nullptr);
        if (JS_IsException(argv[0])) {
            JSValue err = JS_GetException(ctx_);
            outResult = "JSON parse error: " + jsErrorString(err);
            JS_FreeValue(ctx_, err);
            JS_FreeValue(ctx_, func);
            return -1;
        }
        argc = 1;
    }

    JSValue callResult = JS_Call(ctx_, func, engineInstance_, argc, argv);
    if (argc >= 1) JS_FreeValue(ctx_, argv[0]);
    JS_FreeValue(ctx_, func);

    if (JS_IsException(callResult)) {
        JSValue err = JS_GetException(ctx_);
        outResult = jsErrorString(err);
        JS_FreeValue(ctx_, err);
        return -1;
    }

    // Promise 检测 → 挂 settle 回调 + 立即 pump
    bool isPromise = false;
    if (JS_IsObject(callResult)) {
        JSValue thenFn = JS_GetPropertyStr(ctx_, callResult, "then");
        isPromise = JS_IsFunction(ctx_, thenFn);
        JS_FreeValue(ctx_, thenFn);
    }
    if (isPromise) {
        int callId = ++nextCallId_;
        settled_[callId] = false;
        JSValue fulfill = JS_NewCFunctionMagic(ctx_, qjs_call_fulfilled, "fulfilled", 1, JS_CFUNC_generic_magic, callId);
        JSValue reject = JS_NewCFunctionMagic(ctx_, qjs_call_rejected, "rejected", 1, JS_CFUNC_generic_magic, callId);
        JSValue thenFn = JS_GetPropertyStr(ctx_, callResult, "then");
        JSValue thenArgs[2] = { fulfill, reject };
        JSValue ignored = JS_Call(ctx_, thenFn, callResult, 2, thenArgs);
        JS_FreeValue(ctx_, ignored);
        JS_FreeValue(ctx_, thenFn);
        JS_FreeValue(ctx_, fulfill);
        JS_FreeValue(ctx_, reject);
        JS_FreeValue(ctx_, callResult);
        pumpJobs(); // 同步 settle 场景（如立即 reject）在此完成
        outResult = "";
        return callId;
    }

    outResult = stringifyValue(callResult);
    JS_FreeValue(ctx_, callResult);
    return 0;
}

void HarnessEngine::notifySettled(int callId, bool ok, const std::string& json) {
    auto it = settled_.find(callId);
    if (it == settled_.end() || it->second) return; // 重复/未知 callId 忽略
    it->second = true;
    if (callbacks_.onCallSettled) callbacks_.onCallSettled(callId, ok, json);
}

void HarnessEngine::fetchEvent(int fetchId, const std::string& kind, const std::string& a, const std::string& b) {
    if (!ctx_) return;
    JSValue global = JS_GetGlobalObject(ctx_);
    const char* fnName = nullptr;
    if (kind == "headers") fnName = "__harnessOnFetchHeaders";
    else if (kind == "chunk") fnName = "__harnessOnFetchChunk";
    else if (kind == "done") fnName = "__harnessOnFetchDone";
    else if (kind == "fail") fnName = "__harnessOnFetchFail";
    else if (kind == "status") fnName = "__harnessOnFetchStatus";
    if (!fnName) { JS_FreeValue(ctx_, global); return; }

    JSValue fn = JS_GetPropertyStr(ctx_, global, fnName);
    JS_FreeValue(ctx_, global);
    if (!JS_IsFunction(ctx_, fn)) { JS_FreeValue(ctx_, fn); return; }

    JSValue argv[3] = { JS_NewInt32(ctx_, fetchId), JS_UNDEFINED, JS_UNDEFINED };
    int argc = 1;
    if (kind == "headers") {
        argv[1] = JS_NewInt32(ctx_, atoi(a.c_str()));
        argv[2] = JS_NewString(ctx_, b.c_str());
        argc = 3;
    } else if (kind == "chunk") {
        argv[1] = JS_NewStringLen(ctx_, a.data(), a.size());
        argc = 2;
    } else if (kind == "fail") {
        argv[1] = JS_NewString(ctx_, a.c_str());
        argc = 2;
    } else if (kind == "status") {
        argv[1] = JS_NewInt32(ctx_, atoi(a.c_str()));
        argc = 2;
    }
    JSValue r = JS_Call(ctx_, fn, JS_UNDEFINED, argc, argv);
    if (JS_IsException(r)) {
        JSValue err = JS_GetException(ctx_);
        const char* msg = JS_ToCString(ctx_, err);
        fprintf(stderr, "[harness] %s error: %s\n", fnName, msg ? msg : "?");
        if (g_callbacks.onLog) g_callbacks.onLog("stderr", std::string("[harness] ") + fnName + " error: " + (msg ? msg : "?"));
        JS_FreeCString(ctx_, msg);
        JS_FreeValue(ctx_, err);
    }
    JS_FreeValue(ctx_, r);
    for (int i = 0; i < argc; i++) JS_FreeValue(ctx_, argv[i]);
    JS_FreeValue(ctx_, fn);
    pumpJobs();
}

void HarnessEngine::deviceResult(int deviceId, bool ok, const std::string& json) {
    if (!ctx_) return;
    JSValue global = JS_GetGlobalObject(ctx_);
    JSValue fn = JS_GetPropertyStr(ctx_, global, "__harnessOnDeviceResult");
    JS_FreeValue(ctx_, global);
    if (!JS_IsFunction(ctx_, fn)) { JS_FreeValue(ctx_, fn); return; }

    JSValue argv[3] = {
        JS_NewInt32(ctx_, deviceId),
        JS_NewBool(ctx_, ok ? 1 : 0),
        JS_NewString(ctx_, json.empty() ? "{}" : json.c_str()),
    };
    JSValue r = JS_Call(ctx_, fn, JS_UNDEFINED, 3, argv);
    if (JS_IsException(r)) {
        JSValue err = JS_GetException(ctx_);
        const char* msg = JS_ToCString(ctx_, err);
        fprintf(stderr, "[harness] __harnessOnDeviceResult error: %s\n", msg ? msg : "?");
        if (g_callbacks.onLog) g_callbacks.onLog("stderr", std::string("[harness] deviceResult error: ") + (msg ? msg : "?"));
        JS_FreeCString(ctx_, msg);
        JS_FreeValue(ctx_, err);
    }
    JS_FreeValue(ctx_, r);
    for (int i = 0; i < 3; i++) JS_FreeValue(ctx_, argv[i]);
    JS_FreeValue(ctx_, fn);
    pumpJobs();
}

int HarnessEngine::pumpJobs() {
    int executed = 0;
    for (;;) {
        JSContext* ctx = nullptr;
        int err = JS_ExecutePendingJob(runtime_, &ctx);
        if (err <= 0) {
            if (err < 0 && ctx) {
                JSValue exc = JS_GetException(ctx);
                const char* msg = ctx ? JS_ToCString(ctx, exc) : nullptr;
                fprintf(stderr, "[harness] job error: %s\n", msg ? msg : "?");
                if (g_callbacks.onLog) g_callbacks.onLog("stderr", std::string("[harness] job error: ") + (msg ? msg : "?"));
                if (msg) JS_FreeCString(ctx, msg);
                JS_FreeValue(ctx, exc);
            }
            break;
        }
        executed++;
        if (executed > 100000) break; // 防御性上限
    }
    return executed;
}

bool HarnessEngine::dispose() {
    if (ctx_) {
        JS_FreeValue(ctx_, engineInstance_);
        JS_FreeContext(ctx_);
        ctx_ = nullptr;
    }
    if (runtime_) {
        JS_FreeRuntime(runtime_);
        runtime_ = nullptr;
    }
    if (g_engine == this) g_engine = nullptr;
    return true;
}

void HarnessEngine::setCwd(const std::string& cwd) {
    cwd_ = cwd;
    std::error_code ec;
    fs::create_directories(cwd_, ec);
}

void HarnessEngine::setEnv(const std::string& key, const std::string& value) {
    envVars_[key] = value; // init 前暂存（init 时写入 __HARNESS_ENV）
    if (!ctx_) return;
    JSValue global = JS_GetGlobalObject(ctx_);
    JSValue env = JS_GetPropertyStr(ctx_, global, "__HARNESS_ENV");
    JS_SetPropertyStr(ctx_, env, key.c_str(), JS_NewString(ctx_, value.c_str()));
    JS_FreeValue(ctx_, env);
    JSValue process = JS_GetPropertyStr(ctx_, global, "process");
    if (JS_IsObject(process)) {
        JSValue penv = JS_GetPropertyStr(ctx_, process, "env");
        if (JS_IsObject(penv)) {
            JS_SetPropertyStr(ctx_, penv, key.c_str(), JS_NewString(ctx_, value.c_str()));
        }
        JS_FreeValue(ctx_, penv);
    }
    JS_FreeValue(ctx_, process);
    JS_FreeValue(ctx_, global);
}

} // namespace harness
