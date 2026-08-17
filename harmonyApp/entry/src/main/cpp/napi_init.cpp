/**
 * napi_init.cpp — libharness_napi.so 绑定（v2 异步驱动模型）
 *
 * ArkTS API:
 *   harness.init(jsCode, cwd, env, callbacks) → boolean
 *     callbacks: { onLog(stream, chunk), onEvent(eventJson),
 *                  onFetch(fetchId, requestJson), onCallSettled(callId, ok, json) }
 *   harness.callFunc(name, jsonArgs) → string
 *     "{"async":true,"callId":N}"  — 结果经 onCallSettled 回调
 *     "{"async":false,"result":…}" — 同步完成（result 为原生 JSON）
 *     失败 → JS 异常
 *   harness.fetchEvent(fetchId, kind, a, b) → void
 *   harness.pumpJobs() → number
 *   harness.dispose() → void
 *   harness.isReady() → boolean
 *
 * 线程模型：全部 ArkTS 主线程。native → ArkTS 上行（onFetch/onCallSettled）
 * 经 napi_ref 持有回调并同步 napi_call_function（同线程重入安全）。
 */
#include <napi/native_api.h>
#include <hilog/log.h>
#include <string>
#include <map>
#include <memory>

#include "harness_engine.h"

static const char* TAG = "HarnessNapi";
static harness::HarnessEngine* g_engine = nullptr;

// ── ArkTS 回调引用（init 创建，dispose 释放） ──
struct CallbackRefs {
    napi_env env = nullptr;
    napi_ref onLog = nullptr;
    napi_ref onEvent = nullptr;
    napi_ref onFetch = nullptr;
    napi_ref onCallSettled = nullptr;
};
static CallbackRefs g_refs;

static void ReleaseCallback(napi_ref* ref) {
    if (ref && *ref) {
        napi_delete_reference(g_refs.env, *ref);
        *ref = nullptr;
    }
}

static void ReleaseAllCallbacks() {
    ReleaseCallback(&g_refs.onLog);
    ReleaseCallback(&g_refs.onEvent);
    ReleaseCallback(&g_refs.onFetch);
    ReleaseCallback(&g_refs.onCallSettled);
    g_refs.env = nullptr;
}

/** 调用 ArkTS 回调（1-3 个 string/number 参数；ref 为空时静默跳过） */
static void InvokeCallback(napi_ref ref, int argc, napi_value* argv) {
    if (!ref || !g_refs.env) return;
    napi_env env = g_refs.env;
    napi_value fn = nullptr;
    napi_get_reference_value(env, ref, &fn);
    if (!fn) return;
    napi_value global = nullptr;
    napi_get_global(env, &global);
    napi_value result = nullptr;
    napi_status st = napi_call_function(env, global, fn, argc, argv, &result);
    if (st != napi_ok) {
        OH_LOG_WARN(LOG_APP, TAG, "callback invoke failed: %{public}d", (int)st);
    }
}

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

// ── harness HostCallbacks → ArkTS 转发 ──

static void ForwardOnLog(const std::string& stream, const std::string& chunk) {
    OH_LOG_DEBUG(LOG_APP, TAG, "[%{public}s] %{public}s", stream.c_str(), chunk.c_str());
    napi_env env = g_refs.env;
    if (!env) return;
    napi_value argv[2] = { MakeString(env, stream), MakeString(env, chunk) };
    InvokeCallback(g_refs.onLog, 2, argv);
}

static void ForwardOnEvent(const std::string& eventJson) {
    OH_LOG_DEBUG(LOG_APP, TAG, "event: %{public}s", eventJson.c_str());
    napi_env env = g_refs.env;
    if (!env) return;
    napi_value argv[1] = { MakeString(env, eventJson) };
    InvokeCallback(g_refs.onEvent, 1, argv);
}

static void ForwardOnFetch(int fetchId, const std::string& requestJson) {
    napi_env env = g_refs.env;
    if (!env) {
        // 无法转发时立刻回 fail，避免 QuickJS Promise 悬挂
        if (g_engine) g_engine->fetchEvent(fetchId, "fail", "no fetch bridge", "");
        return;
    }
    napi_value argv[2] = { MakeInt(env, fetchId), MakeString(env, requestJson) };
    InvokeCallback(g_refs.onFetch, 2, argv);
}

static void ForwardOnCallSettled(int callId, bool ok, const std::string& json) {
    napi_env env = g_refs.env;
    if (!env) return;
    napi_value argv[3] = { MakeInt(env, callId), nullptr, MakeString(env, json) };
    napi_get_boolean(env, ok, &argv[1]);
    InvokeCallback(g_refs.onCallSettled, 3, argv);
}

// ── 参数提取工具 ──

static std::string ArgToString(napi_env env, napi_value v) {
    if (!v) return "";
    size_t len = 0;
    napi_get_value_string_utf8(env, v, nullptr, 0, &len);
    std::string s(len, '\0');
    napi_get_value_string_utf8(env, v, len > 0 ? s.data() : nullptr, len + 1, &len);
    return s;
}

// ── Native API ──

/** init(jsCode: string, cwd: string, env: Record<string,string>, callbacks: object) → boolean */
static napi_value NativeInit(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_error(env, nullptr, "init requires jsCode");
        return nullptr;
    }

    const std::string jsCode = ArgToString(env, args[0]);
    std::string cwd = "/data/local/harness";
    if (argc >= 2) {
        std::string c = ArgToString(env, args[1]);
        if (!c.empty()) cwd = c;
    }

    // 释放旧引擎 + 旧回调
    if (g_engine) {
        g_engine->dispose();
        delete g_engine;
        g_engine = nullptr;
    }
    ReleaseAllCallbacks();
    g_refs.env = env;

    // callbacks（第 4 参）→ napi_ref
    if (argc >= 4) {
        napi_valuetype t;
        napi_typeof(env, args[3], &t);
        if (t == napi_object) {
            auto bindRef = [&](const char* name, napi_ref* out) {
                napi_value fn = nullptr;
                napi_get_named_property(env, args[3], name, &fn);
                napi_valuetype ft;
                napi_typeof(env, fn, &ft);
                if (ft == napi_function) {
                    napi_create_reference(env, fn, 1, out);
                }
            };
            bindRef("onLog", &g_refs.onLog);
            bindRef("onEvent", &g_refs.onEvent);
            bindRef("onFetch", &g_refs.onFetch);
            bindRef("onCallSettled", &g_refs.onCallSettled);
        }
    }

    auto* engine = new harness::HarnessEngine();
    engine->setCwd(cwd);

    // env（第 3 参，Record<string, string>）— init 前暂存，eval 前注入 __HARNESS_ENV
    if (argc >= 3) {
        napi_valuetype t;
        napi_typeof(env, args[2], &t);
        if (t == napi_object) {
            napi_value keys = nullptr;
            napi_get_property_names(env, args[2], &keys);
            uint32_t count = 0;
            napi_get_array_length(env, keys, &count);
            for (uint32_t i = 0; i < count; i++) {
                napi_value key = nullptr, val = nullptr;
                napi_get_element(env, keys, i, &key);
                napi_get_property(env, args[2], key, &val);
                engine->setEnv(ArgToString(env, key), ArgToString(env, val));
            }
        }
    }

    harness::HostCallbacks cb;
    cb.onLog = ForwardOnLog;
    cb.onExit = [](int code) {
        OH_LOG_INFO(LOG_APP, TAG, "exit code: %{public}d", code);
    };
    cb.onEvent = ForwardOnEvent;
    cb.onFetch = ForwardOnFetch;
    cb.onCallSettled = ForwardOnCallSettled;

    if (!engine->init(jsCode, cb)) {
        delete engine;
        ReleaseAllCallbacks();
        napi_throw_error(env, nullptr, "HarnessEngine init failed — check harness.js");
        return nullptr;
    }
    g_engine = engine;

    napi_value result = nullptr;
    napi_get_boolean(env, true, &result);
    return result;
}

/** callFunc(name: string, jsonArgs?: string) → string（envelope JSON） */
static napi_value NativeCallFunc(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (!g_engine) {
        napi_throw_error(env, nullptr, "Engine not initialized — call init() first");
        return nullptr;
    }
    if (argc < 1) {
        napi_throw_error(env, nullptr, "callFunc requires name");
        return nullptr;
    }

    const std::string name = ArgToString(env, args[0]);
    std::string jsonArgs;
    if (argc >= 2) {
        jsonArgs = ArgToString(env, args[1]);
    }

    std::string outResult;
    int rc = g_engine->callFunc(name, jsonArgs, outResult);
    if (rc < 0) {
        napi_throw_error(env, nullptr, outResult.c_str());
        return nullptr;
    }

    std::string envelope = rc > 0
        ? "{\"async\":true,\"callId\":" + std::to_string(rc) + "}"
        : "{\"async\":false,\"result\":" + (outResult.empty() ? "null" : outResult) + "}";
    return MakeString(env, envelope);
}

/** fetchEvent(fetchId: number, kind: string, a: string, b: string) → void */
static napi_value NativeFetchEvent(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (!g_engine || argc < 2) {
        napi_value undef = nullptr;
        napi_get_undefined(env, &undef);
        return undef;
    }
    int32_t fetchId = 0;
    napi_get_value_int32(env, args[0], &fetchId);
    const std::string kind = ArgToString(env, args[1]);
    std::string a, b;
    if (argc >= 3) a = ArgToString(env, args[2]);
    if (argc >= 4) b = ArgToString(env, args[3]);
    g_engine->fetchEvent(fetchId, kind, a, b);
    napi_value undef = nullptr;
    napi_get_undefined(env, &undef);
    return undef;
}

/** pumpJobs() → number */
static napi_value NativePumpJobs(napi_env env, napi_callback_info info) {
    (void)info;
    napi_value result = nullptr;
    napi_create_int32(env, g_engine ? g_engine->pumpJobs() : 0, &result);
    return result;
}

/** dispose() → void */
static napi_value NativeDispose(napi_env env, napi_callback_info info) {
    (void)info;
    if (g_engine) {
        g_engine->dispose();
        delete g_engine;
        g_engine = nullptr;
    }
    ReleaseAllCallbacks();
    napi_value undef = nullptr;
    napi_get_undefined(env, &undef);
    return undef;
}

/** isReady() → boolean */
static napi_value NativeIsReady(napi_env env, napi_callback_info info) {
    (void)info;
    napi_value result = nullptr;
    napi_get_boolean(env, g_engine != nullptr, &result);
    return result;
}

// ── 模块注册 ──

static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        { "init",       nullptr, NativeInit,       nullptr, nullptr, nullptr, napi_default, nullptr },
        { "callFunc",   nullptr, NativeCallFunc,   nullptr, nullptr, nullptr, napi_default, nullptr },
        { "fetchEvent", nullptr, NativeFetchEvent, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pumpJobs",   nullptr, NativePumpJobs,   nullptr, nullptr, nullptr, napi_default, nullptr },
        { "dispose",    nullptr, NativeDispose,    nullptr, nullptr, nullptr, napi_default, nullptr },
        { "isReady",    nullptr, NativeIsReady,    nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

static napi_module g_harnessModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "harness_napi",
    .nm_priv = nullptr,
};

extern "C" __attribute__((constructor)) void RegisterHarnessModule() {
    napi_module_register(&g_harnessModule);
}
