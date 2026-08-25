#pragma once

#include "quickjs.h"
#include <napi/native_api.h>
#include <string>
#include <vector>
#include <map>
#include <utility>

namespace script {

/**
 * 脚本沙箱引擎 — per-instance 独立 QuickJS（各自 runtime/context，互不隔离污染），
 * 服务 device runScript 工具。与 harness 主引擎（单例）不同：多实例并存，按 engineId 索引。
 *
 * 预置 JS 全局（C 桥，双下划线内部契约）：
 *   __sbLog(level, msg)        — 日志上行（环形缓冲，随结果 JSON 返回）
 *   __sbFetch(url, optsJson)   — HTTP 上行（Promise；宿主经 setFetchHandler 执行，
 *                                 完成后 scriptEngineFetchDone 下行结算）
 *   __sbRead(path) / __sbWrite(path, data) — 沙箱内文件读写（限 cwd 之下，越界抛错）
 *   __sbSettle(valueJson)      — 显式成功收尾（值为 JSON 文本；非 JSON 按纯字符串）
 *   __sbSettleErr(message)     — 显式失败收尾
 *
 * 预置 JS 运行时（bootstrap 注入）：log / console / fetch / readText / writeText
 *
 * 驱动模型（全部 ArkTS 主线程，同线程重入 — 同 harness 引擎）：
 *   scriptEngineRun 永远返回 napi Promise<string>（JSON envelope）：
 *     同步完成（eval 结果非 Promise 且无未决 fetch）→ 立即 resolve；
 *     异步挂起 → deferred 存引擎，fetchDone/超时/销毁 时 resolve。
 *   envelope：{"ok":true,"value":…,"durationMs":N,"logs":[…]}
 *            {"ok":false,"error":"…","durationMs":N,"logs":[…]}
 *   超时：wall-clock 中断器掐同步死循环（JS_SetInterruptHandler）；
 *         异步挂起则在下一个 native 入口（fetchDone/dispose）强制收尾。
 */
struct ScriptEngine {
    explicit ScriptEngine(const std::string& cwd);
    ~ScriptEngine();

    bool init();
    void dispose();

    /** eval source（timeoutMs=0 不限时）。
     *  返回 true = 同步完成（outJson = envelope）；
     *  返回 false = 异步挂起（run 级 Promise 或 fetch 未决），napi 层挂 deferred 等结算。 */
    bool run(const std::string& source, uint64_t timeoutMs, std::string& outJson);

    /** 宿主 HTTP 完成下行：resolve/reject fetchId 的 Promise 并 pump jobs。
     *  之后 napi 层检查 settled 决定是否 resolve pendingDeferred。 */
    void fetchDone(int fetchId, bool ok, const std::string& body);

    /** 超时强制收尾（每个 native 入口调用）：挂起且过线 → fail 全部未决 fetch、
     *  仍未 settle 则强制 timeout 错误。返回 true = 本次产生完成 JSON。 */
    bool enforceTimeout(std::string& outJson);

    // ── 运行状态（napi 胶水层直读直写） ──
    bool running = false;                    // 一次 run 异步挂起中
    bool settled = false;                    // 挂起 run 已出结果（settledJson 就绪）
    std::string settledJson;                 // 完成 envelope（value 为 JSON / error 为字符串字面量）
    napi_env napiEnv = nullptr;              // pendingDeferred 所属 env
    napi_deferred pendingDeferred = nullptr; // 异步 run 的 deferred
    napi_env fetchEnv = nullptr;             // fetchHandlerRef 所属 env
    napi_ref fetchHandlerRef = nullptr;      // ArkTS fetch 处理器 (fetchId, url, optionsJson) → void

    // 供文件内静态 C 回调使用
    void markSettled(bool ok, const std::string& payloadJson);
    void appendLog(const std::string& line);
    std::string stringifyValue(JSValue v);
    std::string jsErrorString(JSValue err);
    const std::string& sandboxRoot() const { return cwd_; }
    int allocFetchId() { return ++nextFetchId_; }
    void storePendingFetch(int id, JSValue resolve, JSValue reject) {
        pendingFetches_[id] = {resolve, reject};
    }
    bool resolveInSandbox(const std::string& path, std::string& out);

private:
    static int interruptHandler(JSRuntime* rt, void* opaque);
    std::string buildEnvelope(bool ok, const std::string& payloadJson) const;
    void pumpJobs();

    JSRuntime* runtime_ = nullptr;
    JSContext* ctx_ = nullptr;
    std::string cwd_;
    std::vector<std::string> logs_;
    uint64_t startMs_ = 0;
    uint64_t deadlineMs_ = 0; // 0 = 不限时
    int nextFetchId_ = 0;
    /** fetchId → {resolve, reject}（JS_NewPromiseCapability 产物） */
    std::map<int, std::pair<JSValue, JSValue>> pendingFetches_;
};

// ── napi 入口（napi_init.cpp 注册，并入 libharness_napi.so 导出面） ──
// scriptEngineCreate(cwd: string) → number
napi_value NativeScriptEngineCreate(napi_env env, napi_callback_info info);
// scriptEngineRun(engineId: number, source: string, timeoutMs?: number) → Promise<string>
napi_value NativeScriptEngineRun(napi_env env, napi_callback_info info);
// scriptEngineDispose(engineId: number) → boolean
napi_value NativeScriptEngineDispose(napi_env env, napi_callback_info info);
// scriptEngineFetchDone(engineId: number, fetchId: number, ok: boolean, body: string) → void
napi_value NativeScriptEngineFetchDone(napi_env env, napi_callback_info info);
// scriptEngineSetFetchHandler(engineId: number, handler: (fetchId: number, url: string, optionsJson: string) => void) → void
napi_value NativeScriptEngineSetFetchHandler(napi_env env, napi_callback_info info);

} // namespace script
