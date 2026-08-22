/**
 * HttpBridge.ets — QuickJS fetch 桥的宿主侧执行器
 *
 * 职责：接收 native onFetch(fetchId, requestJson)，用 @ohos.net.http
 * requestInStream 发起流式 HTTP，将 headers/chunk/done/fail 事件经
 * emit 回调转发回 native（→ QuickJS 的 __harnessOnFetchXxx）。
 *
 * UTF-8 多字节序列可能跨 dataReceive 分包 — 用 TextDecoder stream 模式解码。
 *
 * 本 SDK headersReceive 回调参数不带 responseCode（实测 undefined），且
 * requestInStream 的 resolve（唯一状态码来源）晚于 dataEnd。为保住流式
 * （kernel 的 fetch Promise 现于 headers 即 resolve，见 host-bridge.js）：
 *   - headersReceive 无状态码时先发临时 headers（status=200）让 body 渐进交付
 *   - dataEnd 挂起 done，等 requestInStream resolve 校验真实状态码：
 *     2xx → 补发 done；非 2xx → 发 status 事件（JS 侧将流置错并携带响应体）
 *   - headersReceive 带状态码（其他 SDK）时直接发真实 headers
 */
import http from '@ohos.net.http';
import util from '@ohos.util';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** host-bridge.js 上行的 fetch 请求（JSON） */
export interface BridgeFetchRequest {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: string | null;
}

export type FetchEventEmitter = (fetchId: number, kind: string, a: string, b: string) => void;

export class HttpBridge {
  private requests: Map<number, http.HttpRequest> = new Map();
  private decoders: Map<number, util.TextDecoder> = new Map();
  /** headers 事件尚未发出（headersReceive 从未触发，兜底路径） */
  private needLateHeaders: Map<number, boolean> = new Map();
  /** dataEnd 已到但 done 挂起中 */
  private pendingDone: Map<number, boolean> = new Map();
  /** headers 已按临时 200 发出，真实状态码待 requestInStream resolve 校验 */
  private statusUnverified: Map<number, boolean> = new Map();
  private emit: FetchEventEmitter;

  constructor(emit: FetchEventEmitter) {
    this.emit = emit;
  }

  /** onFetch 入口：requestJson = BridgeFetchRequest */
  start(fetchId: number, requestJson: string): void {
    let req: BridgeFetchRequest;
    try {
      req = JSON.parse(requestJson) as BridgeFetchRequest;
    } catch (e) {
      this.emit(fetchId, 'fail', 'bad fetch request json: ' + JSON.stringify(e), '');
      return;
    }
    hilog.info(0x0307, 'HttpBridge', 'fetch#%{public}d %{public}s %{public}s', fetchId, req.method, req.url);

    const session = http.createHttp();
    const decoder = util.TextDecoder.create('utf-8');
    this.requests.set(fetchId, session);
    this.decoders.set(fetchId, decoder);
    this.needLateHeaders.set(fetchId, true);
    this.pendingDone.set(fetchId, false);
    this.statusUnverified.set(fetchId, false);

    session.on('headersReceive', (header: Object) => {
      const h = header as Record<string, Object>;
      const code = h['responseCode'];
      const headers = h['header'];
      const headerJson: string = headers !== undefined ? JSON.stringify(headers) : '{}';
      hilog.info(0x0307, 'HttpBridge', 'fetch#%{public}d headers status=%{public}s', fetchId, String(code));
      this.needLateHeaders.set(fetchId, false);
      if (code !== undefined) {
        this.emit(fetchId, 'headers', String(code), headerJson);
      } else {
        // responseCode 实测 undefined：先发临时 200 让 JS 侧 fetch 立即 resolve、
        // SSE 渐进消费；真实状态码由 requestInStream resolve 校验（见 then）
        this.statusUnverified.set(fetchId, true);
        this.emit(fetchId, 'headers', '200', headerJson);
      }
    });
    session.on('dataReceive', (data: ArrayBuffer) => {
      const dec = this.decoders.get(fetchId);
      if (!dec) return;
      const text = dec.decodeWithStream(new Uint8Array(data), { stream: true });
      if (text !== undefined && text.length > 0) {
        hilog.debug(0x0307, 'HttpBridge', 'fetch#%{public}d chunk(%{public}d): %{public}s',
          fetchId, text.length, text.substring(0, 200));
        this.emit(fetchId, 'chunk', text, '');
      }
    });
    session.on('dataEnd', () => {
      hilog.info(0x0307, 'HttpBridge', 'fetch#%{public}d dataEnd', fetchId);
      // final flush：decodeWithStream({stream:true}) 可能残留未决字节，
      // 须以 stream:false 收尾，否则尾部内容（含 [DONE] 空行）丢失
      const dec = this.decoders.get(fetchId);
      if (dec) {
        try {
          const rest: string | undefined = dec.decodeWithStream(new Uint8Array(0), { stream: false });
          if (rest !== undefined && rest.length > 0) {
            hilog.debug(0x0307, 'HttpBridge', 'fetch#%{public}d final flush(%{public}d bytes)', fetchId, rest.length);
            this.emit(fetchId, 'chunk', rest, '');
          }
        } catch (e) {
          hilog.warn(0x0307, 'HttpBridge', 'fetch#%{public}d final flush failed: %{public}s', fetchId, String(e));
        }
      }
      if (this.needLateHeaders.get(fetchId) === true || this.statusUnverified.get(fetchId) === true) {
        // 状态码未校验（或 headers 未发）：挂起 done，等 requestInStream resolve 一起处理
        this.pendingDone.set(fetchId, true);
        return;
      }
      this.finish(fetchId);
    });

    const options: http.HttpRequestOptions = {
      method: this.toMethod(req.method),
      header: req.headers,
      extraData: req.body ?? undefined,
      usingCache: false,
      connectTimeout: 30000,
      readTimeout: 300000,
      maxLimit: 100 * 1024 * 1024,
    };

    session.requestInStream(req.url, options).then((code: number) => {
      hilog.info(0x0307, 'HttpBridge', 'fetch#%{public}d resolved status=%{public}d', fetchId, code);
      if (this.statusUnverified.get(fetchId) === true) {
        // headers 已按临时 200 发出：真实状态码校验
        this.statusUnverified.set(fetchId, false);
        if (code >= 200 && code < 300) {
          // dataEnd 已先到达：补发挂起的 done
          if (this.pendingDone.get(fetchId) === true) {
            this.finish(fetchId);
          }
          return;
        }
        // 临时 200 误报：不发 done，以 status 事件将 JS 侧流置错（携带响应体）
        this.pendingDone.set(fetchId, false);
        this.cleanup(fetchId);
        this.emit(fetchId, 'status', String(code), '');
        return;
      }
      if (this.needLateHeaders.get(fetchId) === true) {
        // headersReceive 从未触发（兜底）：此刻才发真实 headers
        this.needLateHeaders.set(fetchId, false);
        this.emit(fetchId, 'headers', String(code), '{}');
      }
      // dataEnd 已先到达：补发挂起的 done
      if (this.pendingDone.get(fetchId) === true) {
        this.finish(fetchId);
      }
    }).catch((err: Error) => {
      this.cleanup(fetchId);
      this.emit(fetchId, 'fail', err.message ?? String(err), '');
    });
  }

  /** 发出 done 并清理（headers 已发后调用） */
  private finish(fetchId: number): void {
    this.pendingDone.set(fetchId, false);
    this.cleanup(fetchId);
    this.emit(fetchId, 'done', '', '');
  }

  /** 中止指定 fetch（引擎 dispose 时调用） */
  abort(fetchId: number): void {
    const session = this.requests.get(fetchId);
    if (session) {
      this.cleanup(fetchId);
      session.destroy();
      this.emit(fetchId, 'fail', 'aborted', '');
    }
  }

  abortAll(): void {
    const ids: number[] = [];
    this.requests.forEach((_v: http.HttpRequest, k: number) => { ids.push(k); });
    for (const id of ids) this.abort(id);
  }

  private cleanup(fetchId: number): void {
    const session = this.requests.get(fetchId);
    if (session) {
      session.off('headersReceive');
      session.off('dataReceive');
      session.off('dataEnd');
      this.requests.delete(fetchId);
    }
    this.decoders.delete(fetchId);
    this.needLateHeaders.delete(fetchId);
    this.pendingDone.delete(fetchId);
    this.statusUnverified.delete(fetchId);
  }

  private toMethod(m: string): http.RequestMethod {
    const upper = m.toUpperCase();
    if (upper === 'POST') return http.RequestMethod.POST;
    if (upper === 'PUT') return http.RequestMethod.PUT;
    if (upper === 'DELETE') return http.RequestMethod.DELETE;
    if (upper === 'HEAD') return http.RequestMethod.HEAD;
    if (upper === 'OPTIONS') return http.RequestMethod.OPTIONS;
    // SDK RequestMethod 无 PATCH；OpenAI 兼容 API 仅用 GET/POST，此处兜底 POST
    if (upper === 'PATCH') return http.RequestMethod.POST;
    return http.RequestMethod.GET;
  }
}
