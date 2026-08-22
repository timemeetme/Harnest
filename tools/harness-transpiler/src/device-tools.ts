/**
 * Device capability tools for the embedded QuickJS harness.
 *
 * Registers the `device_*` tool family (contacts / calendar / clipboard /
 * files / photos / mail / call / camera / recorder / app-launch) backed by the
 * host `DeviceBridge` over the async device channel:
 *
 *   execute(args) → global.__deviceCall(op, args) → __harnessDeviceCall
 *   → native → ArkTS DeviceBridge → deviceResult(callId, ok, json)
 *   → __harnessOnDeviceResult → promise settles.
 *
 * When the host bridge is absent (e.g. the Node smoke-test environment) the
 * plugin skips registration entirely, so the bundle stays loadable everywhere.
 * @module device-tools
 */

import type { Context } from '@deepseek-ai/cordis'
import { defineTool } from '@deepseek-ai/dsh-tools'
// 本机能力手册（P0：仅随包内置 / 索引+按需查询 / Top 20 人工维护）
import {
  MANUAL_APP_IDS,
  buildCapabilityIndexText,
  renderSection,
  searchSections,
  sectionById,
} from './capability-manual'

/** Host-bridge globals installed by polyfills/device-bridge.js before the bundle runs. */
interface DeviceBridgeGlobals {
  __deviceAvailable?: () => boolean
  __deviceCall?: (op: string, args: Record<string, unknown>) => Promise<Record<string, unknown>>
}

type Args = Record<string, unknown>

const DESCRIPTION = {
  status: 'Inspect the device capability bridge: platform, bridge version, and per-capability permission states. Call this FIRST in a new conversation before using any other device tool.',
  permissions: 'Query or request runtime permissions for device capabilities. Scopes: contacts, calendar, microphone, camera. Requesting triggers the OS permission dialog (the user may deny).',
  contacts: 'Query, create or delete contacts in the device address book (requires the contacts permission; call device_permissions with scope "contacts" first if not granted).',
  calendar: 'Query, create or delete calendar events (requires the calendar permission; call device_permissions with scope "calendar" first if not granted). Creating supports title, start/end times (epoch ms), location, notes and reminders (minutes before).',
  clipboard: 'Read or write the system clipboard text.',
  files: 'Pick documents via the system picker, read/write picked document URIs (text or base64), or list/read/write files inside the app sandbox (paths relative to the sandbox root, e.g. "data/a.txt").',
  photos: 'Pick photos/videos from the gallery via the system picker (no permission needed), or save an image to a user-chosen location (base64).',
  mail: 'Compose an email: opens the system mail app with to/cc/subject/body pre-filled; the user sends it.',
  call: 'Open the dialer with a number pre-filled (dial) or the SMS app with body pre-filled (sms). The user confirms — nothing is sent without them. op=calllog returns availability: on HarmonyOS reading the call log is NOT possible for third-party apps — never try to open the system call-log page via uri (it has no handler and shows an error dialog); ask the user to read/paste it instead.',
  sms: 'Read recent SMS messages from the device inbox (op: query; filter by days, limit, address substring). Android only — requires the sms permission (call device_permissions with scope "sms" first). On HarmonyOS/iOS reading the SMS history is restricted to system apps and unavailable; explain this and ask the user to forward or export the messages instead.',
  camera: "Take a photo and return the saved file path/size. op=capture: silent background shot with no user interaction \u2014 supports facing 'front'|'back' (default back), so tasks like 'switch to the front camera and take a photo' should call this directly with facing:'front'; the captured photo is auto-attached for vision analysis on the next model call. op=manual: opens the system camera app and waits for the user to press the shutter (max 120s) \u2014 only when the user explicitly wants to shoot by hand. Preferred order: capture first, manual as fallback, gui taps on the camera app as last resort.",
  recorder: 'Record audio: start (optionally maxSeconds, default 60) then stop; returns the recorded m4a file path and duration seconds.',
  app: 'Interact with installed apps: open by bundleName/uri, list launchable apps, or drive the UI on Android (gui action: tap/swipe/type/back/home \u2014 requires the accessibility service to be enabled).',
  reminder: 'Create and manage scheduled reminders: timer (delayMinutes), calendar (hour/minute/year/month/day), list, and remove.',
  gui: 'GUI automation via the Accessibility service: read the screen UI tree, find elements by text, click/swipe/input, or trigger global actions (back/home). Requires the user to enable "Harness GUI" in Settings > Accessibility first.',
  scheduler: 'Schedule background tasks via WorkScheduler: start a repeating task (intervalMinutes, optional network/charging/idle constraints), stop by workId, stopAll, or list all scheduled works. Actual trigger timing depends on system power management.',
  network: 'Inspect the current network: connection type (wifi/cellular/none), online state, and estimated bandwidth class.',
  deviceinfo: 'Read device info: model, manufacturer, OS name and version, screen size/density, battery level and charging state.',
  vibrate: 'Vibrate the device for a short duration (duration in ms, 1-2000, default 300).',
  location: 'Get the current GPS location (requires the location permission; call device_permissions with scope "location" first if not granted). Returns latitude/longitude/accuracy.',
  settings: 'Open a system settings page: main settings, wifi, bluetooth, location, notification, or app-manager.',
  probe: 'Probe this device: OS version, model, battery, and the installed apps matched against the built-in capability manual (Top 20). Returns suggested manual sections. Run this when unsure what this device/OS can do.',
  capabilities: 'Search the built-in device capability manual by keywords (Chinese or English) and get exact tool invocations, examples, and limits; or fetch one section by id. Consult this BEFORE attempting device tasks you are unsure about (e.g. front-camera selfie, app deep links, GUI recipes).',
}

/** Shared parameter fragment for op-style tools. */
function opParam(ops: string[], description: string) {
  return { type: 'string' as const, required: true, enum: [...ops], description }
}

/** Shared result schema: permissive object (host-defined per op). */
const RESULT_SCHEMA = { type: 'object' as const, additionalProperties: true }

function renderResult(label: string) {
  return (_args: unknown, value: unknown) => [{
    type: 'text' as const,
    text: `${label}: ${JSON.stringify(value)}`,
  }]
}

function presentCall(title: string, rawInput: unknown) {
  return { card: 'generic', title, kind: 'other', rawInput }
}

/** Register the device tool family on the tool registry. */
export function apply(ctx: Context): void {
  const bridge = globalThis as unknown as DeviceBridgeGlobals
  if (typeof bridge.__deviceAvailable !== 'function' || !bridge.__deviceAvailable()) return
  // c5 工具失败升级：同 op 连续失败 ≥2 次后，在错误信息里追加「先查手册」引导；
  // 成功或模型调用 device_capabilities_query（读了手册）即清零。
  const failStreak = new Map<string, number>()
  const call = async (op: string, args: Args = {}): Promise<Record<string, unknown>> => {
    const fn = bridge.__deviceCall
    if (typeof fn !== 'function') throw new Error('device: bridge unavailable')
    try {
      const result = await fn(op, args)
      failStreak.delete(op)
      return result
    } catch (err) {
      const n = (failStreak.get(op) ?? 0) + 1
      failStreak.set(op, n)
      if (n >= 2) {
        const hint = `\n\n[Harness] device op "${op}" has now failed ${n} times in a row. Do NOT retry blindly: call device_capabilities_query with keywords describing the task (e.g. "${op}") to check what this device/OS supports and the recommended approach, or run device_probe to inspect the environment.`
        throw new Error(`${(err as Error).message ?? String(err)}${hint}`)
      }
      throw err
    }
  }
  // 平台探测缓存（deviceinfo.os 形如 "Android 15" / "HarmonyOS 5.0" / "iOS 18"）
  let cachedPlatform: string | undefined
  const detectPlatform = async (): Promise<string | undefined> => {
    if (cachedPlatform) return cachedPlatform
    try {
      const info = await call('deviceinfo', {})
      const os = String(info.os ?? '').toLowerCase()
      if (os.includes('harmony')) cachedPlatform = 'harmony'
      else if (os.includes('ios')) cachedPlatform = 'ios'
      else if (os.includes('android')) cachedPlatform = 'android'
    } catch { /* 探测失败不阻断 — query 会退化为全平台检索 */ }
    return cachedPlatform
  }
  // c4 能力索引注入系统提示：只放目录（~25 行），正文经 device_capabilities_query 按需取。
  //    text 用惰性函数 — 每次组装提示时取最新平台缓存；注入失败不影响工具注册。
  //    注意：cordis fork 上下文的属性代理只暴露 inject 声明过的服务，
  //    所以 DeviceToolsPlugin 必须 inject 'systemPrompt'（见文件底部插件对象）。
  try {
    ctx.effect(() => {
      const sp = (ctx as unknown as {
        systemPrompt?: { section: (s: { name: string; order: number; text: () => string }) => (() => void) | void }
      }).systemPrompt
      if (!sp) return () => {}
      return sp.section({
        name: 'device:capability-index',
        order: 150,
        text: () => buildCapabilityIndexText(cachedPlatform),
      }) ?? (() => {})
    })
  } catch { /* 注入失败不影响工具注册 */ }

  ctx.tools.register(defineTool({
    name: 'device_status',
    description: DESCRIPTION.status,
    parameters: {},
    output: { schema: RESULT_SCHEMA, render: renderResult('Device status') },
    execute() { return call('status') },
    presentCall: args => presentCall('Device status', args),
  }))

  ctx.tools.register(defineTool({
    name: 'device_permissions',
    description: DESCRIPTION.permissions,
    parameters: {
      action: opParam(['query', 'request'], 'query = check states, request = trigger the OS dialogs'),
      scopes: {
        type: 'array',
        description: 'Capability scopes: contacts, calendar, microphone, camera. Defaults to all.',
        items: { type: 'string' },
      },
    },
    output: { schema: RESULT_SCHEMA, render: renderResult('Device permissions') },
    execute(args) { return call('permissions', args) },
    presentCall: args => presentCall('Device permissions', args),
  }))

  ctx.tools.register(defineTool({
    name: 'device_contacts',
    description: DESCRIPTION.contacts,
    parameters: {
      op: opParam(['query', 'create', 'delete'], 'Sub-operation on the address book.'),
      query: { type: 'string', description: 'query: name/phone substring filter.' },
      limit: { type: 'integer', description: 'query: max items (default 50).' },
      id: { type: 'string', description: 'delete: contact id from a previous query.' },
      name: { type: 'string', description: 'create: display name.' },
      phones: { type: 'array', items: { type: 'string' }, description: 'create: phone numbers.' },
      email: { type: 'string', description: 'create: email address.' },
      note: { type: 'string', description: 'create: free-form note.' },
    },
    output: { schema: RESULT_SCHEMA, render: renderResult('Contacts') },
    execute(args) { return call('contacts', args) },
    presentCall: args => presentCall('Contacts', args),
  }))

  ctx.tools.register(defineTool({
    name: 'device_calendar',
    description: DESCRIPTION.calendar,
    parameters: {
      op: opParam(['query', 'create', 'delete'], 'Sub-operation on calendar events.'),
      start: { type: 'integer', description: 'query/create: range or event start, epoch milliseconds.' },
      end: { type: 'integer', description: 'query/create: range or event end, epoch milliseconds.' },
      id: { type: 'string', description: 'delete: event id from a previous query/create.' },
      title: { type: 'string', description: 'create: event title.' },
      allDay: { type: 'boolean', description: 'create: all-day event.' },
      location: { type: 'string', description: 'create: location.' },
      notes: { type: 'string', description: 'create: description.' },
      reminderMinutes: { type: 'integer', description: 'create: reminder minutes before start.' },
    },
    output: { schema: RESULT_SCHEMA, render: renderResult('Calendar') },
    execute(args) { return call('calendar', args) },
    presentCall: args => presentCall('Calendar', args),
  }))

  ctx.tools.register(defineTool({
    name: 'device_clipboard',
    description: DESCRIPTION.clipboard,
    parameters: {
      op: opParam(['read', 'write'], 'Sub-operation on the clipboard.'),
      text: { type: 'string', description: 'write: the text to put on the clipboard.' },
    },
    output: { schema: RESULT_SCHEMA, render: renderResult('Clipboard') },
    execute(args) { return call('clipboard', args) },
    presentCall: args => presentCall('Clipboard', args),
  }))

  ctx.tools.register(defineTool({
    name: 'device_files',
    description: DESCRIPTION.files,
    parameters: {
      op: opParam(['pick', 'read', 'write', 'sandboxList', 'sandboxRead', 'sandboxWrite'], 'Sub-operation. pick/read/write target user-chosen document URIs; sandbox* target app-sandbox paths.'),
      uri: { type: 'string', description: 'read/write: document uri returned by pick.' },
      text: { type: 'string', description: 'write: text content to write.' },
      base64: { type: 'string', description: 'read/write: binary content as base64 (takes precedence over text on write).' },
      mimeType: { type: 'string', description: 'pick: filter, e.g. text/plain application/pdf (default: all).' },
      maxNumber: { type: 'integer', description: 'pick: max selectable files (default 1).' },
      path: { type: 'string', description: 'sandbox*: path relative to the sandbox root.' },
      fileName: { type: 'string', description: 'pick/write: suggested file name for save dialogs.' },
    },
    output: { schema: RESULT_SCHEMA, render: renderResult('Files') },
    execute(args) { return call('files', args) },
    presentCall: args => presentCall('Files', args),
  }))

  ctx.tools.register(defineTool({
    name: 'device_photos',
    description: DESCRIPTION.photos,
    parameters: {
      op: opParam(['pick', 'save'], 'Sub-operation on the gallery.'),
      maxNumber: { type: 'integer', description: 'pick: max selectable items (default 1).' },
      base64: { type: 'string', description: 'save: image bytes as base64.' },
      fileName: { type: 'string', description: 'save: suggested file name (default photo.jpg).' },
      mimeType: { type: 'string', description: 'save: mime type (default image/jpeg).' },
    },
    output: { schema: RESULT_SCHEMA, render: renderResult('Photos') },
    execute(args) { return call('photos', args) },
    presentCall: args => presentCall('Photos', args),
  }))

  ctx.tools.register(defineTool({
    name: 'device_mail',
    description: DESCRIPTION.mail,
    parameters: {
      op: opParam(['send'], 'Compose and hand off to the system mail app.'),
      to: { type: 'string', required: true, description: 'Recipient address(es), comma-separated.' },
      cc: { type: 'string', description: 'Cc address(es), comma-separated.' },
      subject: { type: 'string', description: 'Subject line.' },
      body: { type: 'string', description: 'Plain-text body.' },
    },
    output: { schema: RESULT_SCHEMA, render: renderResult('Mail') },
    execute(args) { return call('mail', args) },
    presentCall: args => presentCall('Mail', args),
  }))

  ctx.tools.register(defineTool({
    name: 'device_call',
    description: DESCRIPTION.call,
    parameters: {
      op: opParam(['dial', 'sms', 'calllog'], 'dial = open the dialer; sms = open the SMS composer; calllog = check call-log availability (not readable on HarmonyOS).'),
      number: { type: 'string', description: 'Phone number (required for dial/sms; not needed for calllog).' },
      body: { type: 'string', description: 'sms: pre-filled message body.' },
    },
    output: { schema: RESULT_SCHEMA, render: renderResult('Call') },
    execute(args) { return call('call', args) },
    presentCall: args => presentCall('Call', args),
  }))

  ctx.tools.register(defineTool({
    name: 'device_sms',
    description: DESCRIPTION.sms,
    parameters: {
      op: opParam(['query'], 'Read messages from the SMS inbox.'),
      days: { type: 'integer', description: 'Only messages newer than this many days (default 30).' },
      limit: { type: 'integer', description: 'Max messages to return (default 50).' },
      address: { type: 'string', description: 'Optional sender/recipient number substring filter.' },
    },
    output: { schema: RESULT_SCHEMA, render: renderResult('Sms') },
    execute(args) { return call('sms', args) },
    presentCall: args => presentCall('Sms', args),
  }))

  ctx.tools.register(defineTool({
    name: 'device_camera',
    description: DESCRIPTION.camera,
    parameters: {
      op: opParam(['capture', 'manual'], 'capture = agent shoots automatically in the background, no user interaction (default; photo auto-attached for vision); manual = open the system camera UI so the user can compose and press the shutter (max 120s).'),
      facing: { type: 'string', enum: ['front', 'back'], description: "capture: which camera to shoot with, 'front' or 'back' (default 'back'). Use this to switch cameras, e.g. 'take a selfie'." },
    },
    output: { schema: RESULT_SCHEMA, render: renderResult('Camera') },
    execute(args) { return call('camera', args) },
    presentCall: args => presentCall('Camera', args),
  }))

  ctx.tools.register(defineTool({
    name: 'device_recorder',
    description: DESCRIPTION.recorder,
    parameters: {
      op: opParam(['start', 'stop'], 'start = begin recording; stop = finish and get the file.'),
      maxSeconds: { type: 'integer', description: 'start: auto-stop after this many seconds (default 60).' },
    },
    output: { schema: RESULT_SCHEMA, render: renderResult('Recorder') },
    execute(args) { return call('recorder', args) },
    presentCall: args => presentCall('Recorder', args),
  }))

  ctx.tools.register(defineTool({
    name: 'device_app',
    description: DESCRIPTION.app,
    parameters: {
      op: opParam(['open', 'list', 'gui'], 'open = launch an app; list = launchable apps; gui = UI automation (Android only).'),
      bundleName: { type: 'string', description: 'open: target bundle/package name.' },
      abilityName: { type: 'string', description: 'open: explicit ability/activity name (optional).' },
      uri: { type: 'string', description: 'open: uri/scheme/deeplink (alternative to bundleName).' },
      action: { type: 'string', description: 'gui: tap | swipe | type | back | home.', enum: ['tap', 'swipe', 'type', 'back', 'home'] },
      x: { type: 'integer', description: 'gui tap/swipe: start x.' },
      y: { type: 'integer', description: 'gui tap/swipe: start y.' },
      dx: { type: 'integer', description: 'gui swipe: horizontal delta.' },
      dy: { type: 'integer', description: 'gui swipe: vertical delta.' },
      text: { type: 'string', description: 'gui type: text to input.' },
    },
    output: { schema: RESULT_SCHEMA, render: renderResult('App') },
    execute(args) { return call('app', args) },
    presentCall: args => presentCall('App', args),
  }))

  ctx.tools.register(defineTool({
    name: 'device_network',
    description: DESCRIPTION.network,
    parameters: {},
    output: { schema: RESULT_SCHEMA, render: renderResult('Network') },
    execute() { return call('network') },
    presentCall: args => presentCall('Network', args),
  }))

  ctx.tools.register(defineTool({
    name: 'device_deviceinfo',
    description: DESCRIPTION.deviceinfo,
    parameters: {},
    output: { schema: RESULT_SCHEMA, render: renderResult('Device info') },
    execute() { return call('deviceinfo') },
    presentCall: args => presentCall('Device info', args),
  }))

  ctx.tools.register(defineTool({
    name: 'device_vibrate',
    description: DESCRIPTION.vibrate,
    parameters: {
      duration: { type: 'integer', description: 'Vibration duration in milliseconds (1-2000, default 300).' },
    },
    output: { schema: RESULT_SCHEMA, render: renderResult('Vibrate') },
    execute(args) { return call('vibrate', args) },
    presentCall: args => presentCall('Vibrate', args),
  }))

  ctx.tools.register(defineTool({
    name: 'device_location',
    description: DESCRIPTION.location,
    parameters: {},
    output: { schema: RESULT_SCHEMA, render: renderResult('Location') },
    execute() { return call('location') },
    presentCall: args => presentCall('Location', args),
  }))

  ctx.tools.register(defineTool({
    name: 'device_settings',
    description: DESCRIPTION.settings,
    parameters: {
      target: { type: 'string', description: 'Settings page to open.', enum: ['settings', 'wifi', 'bluetooth', 'location', 'notification', 'app-manager'] },
    },
    output: { schema: RESULT_SCHEMA, render: renderResult('Settings') },
    execute(args) { return call('settings', args) },
    presentCall: args => presentCall('Settings', args),
  }))

  ctx.tools.register(defineTool({
    name: 'device_reminder',
    description: DESCRIPTION.reminder,
    parameters: {
      op: { type: 'string', description: 'Reminder operation.', enum: ['add', 'list', 'remove'] },
      title: { type: 'string', description: 'Reminder title (required for add).' },
      content: { type: 'string', description: 'Reminder content.' },
      delayMinutes: { type: 'integer', description: 'Trigger after N minutes (timer mode).' },
      hour: { type: 'integer', description: 'Hour 0-23 (calendar mode).' },
      minute: { type: 'integer', description: 'Minute 0-59 (calendar mode).' },
      year: { type: 'integer', description: 'Year (optional, defaults to current).' },
      month: { type: 'integer', description: 'Month 1-12 (optional, defaults to current).' },
      day: { type: 'integer', description: 'Day 1-31 (optional, defaults to current).' },
      reminderId: { type: 'integer', description: 'Reminder ID (required for remove).' },
    },
    output: { schema: RESULT_SCHEMA, render: renderResult('Reminder') },
    execute(args) { return call('reminder', args) },
    presentCall: args => presentCall('Reminder', args),
  }))

  ctx.tools.register(defineTool({
    name: 'device_gui',
    description: DESCRIPTION.gui,
    parameters: {
      cmd: { type: 'string', description: 'GUI command.', enum: ['tree', 'find', 'click', 'swipe', 'back', 'home', 'input'] },
      text: { type: 'string', description: 'Text to find/click/input.' },
      x: { type: 'integer', description: 'Click X coordinate.' },
      y: { type: 'integer', description: 'Click Y coordinate.' },
      startX: { type: 'integer', description: 'Swipe start X.' },
      startY: { type: 'integer', description: 'Swipe start Y.' },
      endX: { type: 'integer', description: 'Swipe end X.' },
      endY: { type: 'integer', description: 'Swipe end Y.' },
      duration: { type: 'integer', description: 'Swipe/gesture duration ms (default 300).' },
    },
    output: { schema: RESULT_SCHEMA, render: renderResult('GUI') },
    execute(args) { return call('gui', args) },
    presentCall: args => presentCall('GUI automation', args),
  }))

  ctx.tools.register(defineTool({
    name: 'device_scheduler',
    description: DESCRIPTION.scheduler,
    parameters: {
      op: { type: 'string', description: 'Scheduler operation.', enum: ['start', 'stop', 'stopAll', 'list'] },
      task: { type: 'string', description: 'Task description (required for start).' },
      intervalMinutes: { type: 'integer', description: 'Repeat interval in minutes (default 30). Actual interval may be longer due to system power management.' },
      networkType: { type: 'string', description: 'Network constraint.', enum: ['any', 'wifi', 'mobile'] },
      requireCharging: { type: 'boolean', description: 'Only run when charging.' },
      requireIdle: { type: 'boolean', description: 'Only run when device is idle.' },
      workId: { type: 'integer', description: 'Work ID (required for stop).' },
    },
    output: { schema: RESULT_SCHEMA, render: renderResult('Scheduler') },
    execute(args) { return call('scheduler', args) },
    presentCall: args => presentCall('Scheduler', args),
  }))

  // ── device_probe：探测系统版本 + 已装应用，交叉匹配手册 Top20 ──
  ctx.tools.register(defineTool({
    name: 'device_probe',
    description: DESCRIPTION.probe,
    parameters: {},
    output: { schema: RESULT_SCHEMA, render: renderResult('Probe') },
    async execute() {
      const out: Record<string, unknown> = {}
      try {
        const info = await call('deviceinfo', {})
        out.system = {
          os: info.os, brand: info.brand, model: info.model,
          apiLevel: info.apiLevel, batteryLevel: info.batteryLevel, charging: info.charging,
        }
      } catch (err) {
        out.system = `unavailable: ${(err as Error).message}`
      }
      out.platform = (await detectPlatform()) ?? 'unknown'
      let apps: Array<{ package?: unknown; bundleName?: unknown; name?: unknown }> = []
      try {
        const r = await call('app', { op: 'list' })
        apps = Array.isArray(r.apps) ? (r.apps as typeof apps) : []
        // 平台不支持枚举（如 HarmonyOS SDK 已移除 queryAbilityInfos）时空列表+note，透传给模型
        if (apps.length === 0 && typeof r.note === 'string') out.installedApps = { total: 0, note: r.note }
      } catch (err) {
        out.installedApps = `unavailable: ${(err as Error).message}`
      }
      if (apps.length > 0) {
        const pkgs = new Set(apps.map(a => String(a.package ?? a.bundleName ?? '')))
        const matched = MANUAL_APP_IDS.filter(x => (x.appId.android && pkgs.has(x.appId.android)) || (x.appId.harmony && pkgs.has(x.appId.harmony)) || (x.appId.ios && pkgs.has(x.appId.ios)))
        out.installedApps = { total: apps.length, manualMatches: matched.map(x => ({ id: x.id, title: x.title })) }
      }
      out.next = 'For each matched app call device_capabilities_query(id:"apps.xxx"); for device features query keywords like "camera front", "gui", "navigation".'
      return out
    },
    presentCall: () => 'Probe device environment',
  }))

  // ── device_capabilities_query：按需查手册章节（索引+按需查询）──
  ctx.tools.register(defineTool({
    name: 'device_capabilities_query',
    description: DESCRIPTION.capabilities,
    parameters: {
      query: { type: 'string', description: 'Search keywords (Chinese or English), e.g. "前置自拍", "微信 发消息", "navigation", "clipboard".' },
      id: { type: 'string', description: 'Optional: fetch one section by exact id, e.g. "camera", "apps.wechat", "gui-automation".' },
      category: { type: 'string', description: 'Optional: restrict to a category: system | media | communication | automation | apps.' },
    },
    output: { schema: RESULT_SCHEMA, render: renderResult('Capabilities') },
    async execute(args) {
      failStreak.clear() // 模型已读手册 → 清失败升级计数
      if (args.id) {
        const s = sectionById(String(args.id))
        return s
          ? { text: renderSection(s) }
          : { error: `unknown section id "${args.id}" — use query= instead. Known ids: camera, gui-automation, app-launch, contacts, calendar, clipboard, messaging, photos, files, audio, reminders, device-status, share, ${MANUAL_APP_IDS.map(x => x.id).join(', ')}` }
      }
      const hits = searchSections(String(args.query ?? ''), {
        platform: await detectPlatform(),
        category: args.category ? String(args.category) : undefined,
        limit: 4,
      })
      if (hits.length === 0) {
        return {
          text: 'No matching section. Try other keywords (Chinese or English) or run device_probe first.',
          allIds: MANUAL_APP_IDS.map(x => x.id),
        }
      }
      return {
        text: hits.map(h => renderSection(h.section)).join('\n\n'),
        matchedIds: hits.map(h => h.section.id),
      }
    },
    presentCall: args => presentCall('Capabilities', args),
  }))
}

/** Structural plugin object consumed by harness-entry (cordis object-plugin shape). */
export const DeviceToolsPlugin = {
  name: 'device-tools',
  inject: ['tools', 'systemPrompt'],
  apply,
}
