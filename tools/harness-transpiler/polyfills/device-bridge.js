/**
 * device-bridge.js — 设备能力桥（device.* 工具 → 宿主 DeviceBridge）
 *
 * 注入顺序：在 host-bridge.js 之后、bundle 主体之前。
 *
 * 上行：__deviceCall(op, args) → __harnessDeviceCall(requestJson) → 宿主
 *       request = { op: string, args: object }
 * 下行：宿主 HarnessNative.deviceResult(callId, ok, resultJson)
 *       → native 调用本文件注册的 __harnessOnDeviceResult(callId, ok, json)
 *       → pending Map settle，工具 execute 返回结果
 *
 * 宿主契约（native 侧必须提供，eval 前注册）：
 *   __harnessDeviceCall(requestJson: string) → number(callId)
 * 宿主将调用本文件注册的全局函数：
 *   __harnessOnDeviceResult(id, ok, resultJson)
 *
 * Node 冒烟测试环境（无 __harnessDeviceCall）：
 *   __deviceAvailable() 返回 false，DeviceTools 插件据此跳过工具注册。
 */
(function (global) {
  'use strict';

  const pendingDevices = new Map();
  let deviceSeq = 1;

  global.__harnessOnDeviceResult = function (id, ok, resultJson) {
    const entry = pendingDevices.get(id);
    if (!entry) return;
    pendingDevices.delete(id);
    let payload = null;
    if (resultJson) {
      try { payload = JSON.parse(resultJson); } catch (_) { payload = null; }
    }
    if (ok) {
      entry.resolve(payload == null ? {} : payload);
    } else {
      const message = payload && payload.error ? String(payload.error) : 'device call failed';
      entry.reject(new Error('device: ' + message));
    }
  };

  global.__deviceAvailable = function () {
    return typeof global.__harnessDeviceCall === 'function';
  };

  global.__deviceCall = function (op, args) {
    return new Promise((resolve, reject) => {
      if (typeof global.__harnessDeviceCall !== 'function') {
        reject(new Error('device: bridge unavailable (no __harnessDeviceCall)'));
        return;
      }
      let id;
      try {
        id = global.__harnessDeviceCall(JSON.stringify({ op: String(op), args: args || {} }));
      } catch (e) {
        reject(new Error('device: ' + (e && e.message ? e.message : String(e))));
        return;
      }
      pendingDevices.set(id, { resolve, reject });
    });
  };
})(typeof globalThis !== 'undefined' ? globalThis : this);
