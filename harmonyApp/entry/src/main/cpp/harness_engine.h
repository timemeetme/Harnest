#pragma once

#include "quickjs.h"
#include <string>
#include <functional>
#include <map>
#include <memory>

namespace harness {

/**
 * 宿主回调 — 由 napi 层实现（转发到 ArkTS 或 hilog）。
 * 全部在 ArkTS 主线程（QuickJS 所在线程）被调用。
 */
struct HostCallbacks {
    /** process.stdout/stderr 写出 */
    std::function<void(const std::string& stream, const std::string& chunk)> onLog;
    /** process.exit */
    std::function<void(int code)> onExit;
    /** __harnessEmit（harness.js 结构化事件上行，如 chat 完成） */
    std::function<void(const std::string& eventJson)> onEvent;
    /** __harnessFetchStart — QuickJS 请求宿主发起 HTTP（ArkTS 用 @ohos.net.http 执行） */
    std::function<void(int fetchId, const std::string& requestJson)> onFetch;
    /** callFunc 的 Promise settle（chat/init 等异步调用完成） */
    std::function<void(int callId, bool ok, const std::string& json)> onCallSettled;
};

/**
 * QuickJS 引擎封装。
 *
 * 异步驱动模型（全部单线程 — ArkTS 主线程）：
 *   1. callFunc() 调用 engine 实例方法；若返回 Promise 则挂 fulfill/reject
 *      回调（携带 callId），立即 pump jobs，未 settle 则报 callId 给宿主。
 *   2. harness.js 内 fetch() → __harnessFetchStart（C 函数）→ onFetch 回调
 *      → ArkTS 发起 HTTP → fetchEvent(id,'headers'/'chunk'/'done'/'fail')
 *      → C 调 JS __harnessOnFetchXxx + pump jobs → Promise 链推进。
 *   3. 最终 chat Promise settle → onCallSettled(callId, ok, json) → ArkTS
 *      resolve 外层 Promise。
 */
class HarnessEngine {
public:
    HarnessEngine();
    ~HarnessEngine();

    bool init(const std::string& jsCode, const HostCallbacks& callbacks);
    bool dispose();

    /**
     * 调用 engineInstance_[funcName](jsonArgs)。
     * 返回值：>= 1 — 异步 callId（结果经 onCallSettled 回调）
     *          0 — 同步完成（outResult 为 JSON 结果）
     *         -1 — 失败（outResult 为错误消息）
     */
    int callFunc(const std::string& funcName, const std::string& jsonArgs, std::string& outResult);

    /** 宿主 HTTP 事件下行：kind = "headers"(a=status,b=headersJson) / "chunk"(a=text) / "done" / "fail"(a=error) */
    void fetchEvent(int fetchId, const std::string& kind, const std::string& a, const std::string& b);

    /** Promise settle 通知（静态 C 回调经 g_engine 调用 — 需 public） */
    void notifySettled(int callId, bool ok, const std::string& json);

    /** 执行 QuickJS pending jobs（promise 续链）；返回执行条数 */
    int pumpJobs();

    // 宿主环境注入
    void setCwd(const std::string& cwd);
    void setEnv(const std::string& key, const std::string& value);
    /** fs 沙箱根（= cwd_）；pathInsideCwd 前缀校验用 */
    const std::string& sandboxRoot() const { return cwd_; }

private:
    void installHostFunctions();
    JSRuntime* runtime_ = nullptr;
    JSContext* ctx_ = nullptr;
    HostCallbacks callbacks_;
    std::string cwd_;
    /** init 前暂存的 env（ctx_ 创建后写入 __HARNESS_ENV） */
    std::map<std::string, std::string> envVars_;
    int nextCallId_ = 0;
    int nextFetchId_ = 0;
    /** callId → 是否已 settle（防止 pump 后误报 async） */
    std::map<int, bool> settled_;

    JSValue engineInstance_ = JS_UNDEFINED;

    std::string stringifyValue(JSValue v);
    std::string jsErrorString(JSValue err);
};

} // namespace harness
