/**
 * DshWebSocketClient — DeepSeek Harness SDK JSON-RPC over WebSocket (HarmonyOS).
 * 对应 shared/dsh/sdk/DshClient.kt + DshTransport.kt。
 *
 * 三端统一：Android (Kotlin) / iOS (Kotlin→Swift) / HarmonyOS (ArkTS) 都通过
 * 同一套 JSON-RPC 2.0 协议与 headless 内核交互。
 *
 * 使用：
 *   const client = new DshWebSocketClient();
 *   client.connect('ws://host:port').then(...)
 *   client.subscribe((method, params) => { ... })  // 所有通知
 *   client.setNotificationHandler('session.event', fn) // 按 method 订阅
 *   client.setErrorHandler(fn)
 */

import webSocket from '@ohos.net.webSocket';
import type { JsonRpcRequest, JsonRpcResponse } from '../model/JsonRpcTypes';

type NotifyHandler = (method: string, params: Record<string, Object>) => void;
type ErrorHandler = (err: Error) => void;
type CloseHandler = () => void;

interface PendingRequest {
  resolve: (result: Record<string, Object>) => void;
  reject: (err: Error) => void;
}

export class DshWebSocketClient {
  private ws: webSocket.WebSocket | null = null;
  private pending: Map<string, PendingRequest> = new Map();
  private notifyHandlers: Map<string, NotifyHandler> = new Map();
  private globalNotifyHandlers: NotifyHandler[] = [];
  private onError: ErrorHandler | null = null;
  private onClose: CloseHandler | null = null;

  get isConnected(): boolean {
    return this.ws !== null;
  }

  setNotificationHandler(method: string, handler: NotifyHandler): void {
    this.notifyHandlers.set(method, handler);
  }

  subscribe(handler: NotifyHandler): () => void {
    this.globalNotifyHandlers.push(handler);
    return () => {
      const i = this.globalNotifyHandlers.indexOf(handler);
      if (i >= 0) this.globalNotifyHandlers.splice(i, 1);
    };
  }

  setErrorHandler(handler: ErrorHandler): void {
    this.onError = handler;
  }

  setCloseHandler(handler: CloseHandler): void {
    this.onClose = handler;
  }

  async connect(url: string): Promise<void> {
    if (this.ws) { await this.disconnect(); }
    const ws = webSocket.createWebSocket();
    ws.on('message', (err: Object | undefined, data: Object) => this.handleMessage(err, data));
    ws.on('error', (err: Object) => this.onError?.(new Error(JSON.stringify(err))));
    ws.on('close', () => {
      this.ws = null;
      this.pending.clear();
      this.onClose?.();
    });
    await ws.connect(url);
    this.ws = ws;
  }

  async disconnect(): Promise<void> {
    if (!this.ws) return;
    try { await this.ws.close(); } catch (_) { /* ignore */ }
    this.ws = null;
    this.pending.clear();
  }

  async request(method: string, params: Record<string, Object> | Object[] = {}): Promise<Record<string, Object>> {
    if (!this.ws) throw new Error('Not connected');
    const id = String(Date.now()) + '-' + Math.random().toString(36).slice(2, 10);
    const frame: JsonRpcRequest = { jsonrpc: '2.0', id, method, params };
    const frameStr = JSON.stringify(frame);
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      const timeout = setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error('Request timeout: ' + method));
        }
      }, 30000);
      this.ws!.send(frameStr).catch((e: Error) => {
        clearTimeout(timeout);
        this.pending.delete(id);
        reject(e);
      });
    });
  }

  async initialize(params: { cwd: string; provider: string; model: string; maxTokens?: number }): Promise<{ name: string; version: string }> {
    const result = await this.request('initialize', params as unknown as Record<string, Object>);
    const si = result['serverInfo'] as Record<string, Object>;
    return { name: String(si['name'] ?? ''), version: String(si['version'] ?? '') };
  }

  async prompt(sessionId: string, contentBlocks: Object[] = []): Promise<{ messageId: string }> {
    const result = await this.request('session/prompt', { sessionId, contentBlocks } as unknown as Record<string, Object>);
    return { messageId: String(result['messageId'] ?? '') };
  }

  async shutdown(): Promise<void> {
    await this.request('shutdown');
  }

  private handleMessage(err: Object | undefined, data: Object): void {
    if (err) {
      this.onError?.(new Error(JSON.stringify(err)));
      return;
    }
    const text = data as string;
    let frame: Record<string, Object>;
    try { frame = JSON.parse(text); } catch (e) {
      this.onError?.(new Error('Invalid frame: ' + text));
      return;
    }
    const hasId = 'id' in frame;
    const hasMethod = 'method' in frame;
    if (hasId && !hasMethod) {
      this.handleResponse(frame);
    } else if (hasMethod) {
      this.handleNotification(frame);
    }
  }

  private handleResponse(frame: Record<string, Object>): void {
    const id = String(frame['id']);
    const pending = this.pending.get(id);
    if (!pending) return;
    this.pending.delete(id);
    if ('error' in frame && frame['error'] !== undefined && frame['error'] !== null) {
      const err = frame['error'] as Record<string, Object>;
      pending.reject(new Error('[Rpc ' + err['code'] + '] ' + String(err['message'])));
    } else {
      pending.resolve((frame['result'] as Record<string, Object>) || {});
    }
  }

  private handleNotification(frame: Record<string, Object>): void {
    const method = String(frame['method']);
    const params = (frame['params'] as Record<string, Object>) || {};
    this.notifyHandlers.get(method)?.(method, params);
    for (const h of this.globalNotifyHandlers) {
      try { h(method, params); } catch (_) { /* swallow handler errors */ }
    }
  }
}
