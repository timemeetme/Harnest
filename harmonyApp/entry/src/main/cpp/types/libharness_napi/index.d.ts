/**
 * libharness_napi.so — QuickJS harness 引擎 + 脚本沙箱类型声明
 *
 * 主引擎（单例）：init 后 callFunc 驱动 harness.js 内核
 * 脚本沙箱（per-instance）：scriptEngineCreate → Run/FetchDone/SetFetchHandler → Dispose
 */

export interface NativeCallbacks {
  onLog: (stream: string, chunk: string) => void;
  onEvent: (eventJson: string) => void;
  onFetch: (fetchId: number, requestJson: string) => void;
  onCallSettled: (callId: number, ok: boolean, json: string) => void;
  onDevice: (deviceId: number, requestJson: string) => void;
}

/** 脚本沙箱 fetch 上行回调（ArkTS 执行 HTTP，完成后 scriptEngineFetchDone 下行结算） */
export type ScriptFetchHandler = (fetchId: number, url: string, optionsJson: string) => void;

// ── 主引擎（单例） ──

export const init: (code: string, cwd: string, env: Record<string, string>, callbacks: NativeCallbacks) => void;

/** 同步/异步统一入口：返回 envelope JSON（{"async":bool,"callId":n,"result":…}） */
export const callFunc: (name: string, argsJson: string) => string;

export const fetchEvent: (fetchId: number, kind: string, a: string, b: string) => void;

export const deviceResult: (deviceId: number, ok: boolean, resultJson: string) => void;

export const pumpJobs: () => void;

export const dispose: () => void;

export const isReady: () => boolean;

// ── 脚本沙箱（per-instance，engineId 索引） ──

/** 创建沙箱引擎（cwd 为空回退 /data/local/tmp/script-sandbox）→ engineId */
export const scriptEngineCreate: (cwd: string) => number;

/**
 * 执行脚本，永远返回 Promise<envelope JSON 字符串>：
 *   {"ok":true,"value":…,"durationMs":n,"logs":[…]}
 *   {"ok":false,"error":"…","durationMs":n,"logs":[…]}
 * timeoutMs 缺省 60000，0 = 不限时。
 */
export const scriptEngineRun: (engineId: number, source: string, timeoutMs?: number) => Promise<string>;

/** 销毁沙箱引擎（挂起 run 强制以 "engine disposed" 收尾）→ 是否销毁成功 */
export const scriptEngineDispose: (engineId: number) => boolean;

/** 沙箱 fetch 结果下行：resolve(ok)/reject(!ok) fetchId 的 Promise 并推进事件循环 */
export const scriptEngineFetchDone: (engineId: number, fetchId: number, ok: boolean, body: string) => void;

/** 注册沙箱 fetch 处理器（重复注册覆盖旧的） */
export const scriptEngineSetFetchHandler: (engineId: number, handler: ScriptFetchHandler) => void;
