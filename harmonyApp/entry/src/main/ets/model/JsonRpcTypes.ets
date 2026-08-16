/**
 * JSON-RPC 2.0 基础类型。
 * 对应 shared/dsh/core/JsonRpc.kt。
 */

export interface JsonRpcErrorObject {
  code: number;
  message: string;
  data?: Record<string, Object> | null;
}

export interface JsonRpcRequest {
  jsonrpc: '2.0';
  method: string;
  params?: Record<string, Object> | Object[] | null;
  id?: string | number | null;
}

export interface JsonRpcResponse {
  jsonrpc: '2.0';
  result?: Record<string, Object> | Object[] | null;
  error?: JsonRpcErrorObject | null;
  id?: string | number | null;
}

export interface JsonRpcNotification {
  jsonrpc: '2.0';
  method: string;
  params?: Record<string, Object> | Object[] | null;
}

export namespace JsonRpcCodes {
  export const PARSE_ERROR = -32700;
  export const INVALID_REQUEST = -32600;
  export const METHOD_NOT_FOUND = -32601;
  export const INVALID_PARAMS = -32602;
  export const INTERNAL_ERROR = -32603;
}
