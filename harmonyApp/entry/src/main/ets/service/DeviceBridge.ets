/**
 * DeviceBridge.ets — 设备能力桥（device_* 工具的宿主实现）
 *
 * 上行：QuickJS __deviceCall(op,args) → C++ onDevice → HarnessNative.onDevice → dispatch()
 * 下行：执行完成 → sink(deviceId, ok, json) → harness.deviceResult → __harnessOnDeviceResult
 *
 * 能力矩阵（op）：
 *   status / permissions / contacts / calendar / clipboard / files / photos /
 *   mail / call / camera / recorder / app
 * 权限设计：全部为 normal/user_grant 级（module.json5 声明），
 *   涉隐私操作一律拉起系统 UI（拨号盘/邮件/相机/选择器），由用户确认。
 */
import { common, Want, abilityAccessCtrl, Permissions, bundleManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { contact } from '@kit.ContactsKit';
import { calendarManager } from '@kit.CalendarKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { picker } from '@kit.CoreFileKit';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import media from '@ohos.multimedia.media';
import { cameraPicker, camera } from '@kit.CameraKit';
import { connection } from '@kit.NetworkKit';
import { batteryInfo } from '@kit.BasicServicesKit';
import { vibrator } from '@kit.SensorServiceKit';
import { geoLocationManager } from '@kit.LocationKit';
import deviceInfo from '@ohos.deviceInfo';
import reminderAgentManager from '@ohos.reminderAgentManager';
import workScheduler from '@ohos.resourceschedule.workScheduler';

export type DeviceResultSink = (deviceId: number, ok: boolean, resultJson: string) => void;

const DEVICE_BRIDGE_VERSION = '1.0.0';

/** 能力域 → 权限清单（module.json5 已声明，均为 normal/user_grant） */
const SCOPE_PERMISSIONS: Record<string, Array<Permissions>> = {
  'contacts': ['ohos.permission.READ_CONTACTS', 'ohos.permission.WRITE_CONTACTS'],
  'calendar': ['ohos.permission.READ_CALENDAR', 'ohos.permission.WRITE_CALENDAR'],
  'microphone': ['ohos.permission.MICROPHONE'],
  'camera': ['ohos.permission.CAMERA'],
  'sms': ['ohos.permission.READ_MESSAGES'],
  'location': ['ohos.permission.LOCATION', 'ohos.permission.APPROXIMATELY_LOCATION'],
};

export class DeviceBridge {
  private sink: DeviceResultSink;
  private ctx: common.UIAbilityContext | null = null;

  // 录音状态（单实例；start/stop 之间由 agent 控制）
  private recorder: media.AVRecorder | null = null;
  private recFd: number = -1;
  private recPath: string = '';
  private recStartMs: number = 0;
  private recTimer: number = -1;

  constructor(sink: DeviceResultSink) {
    this.sink = sink;
  }

  setContext(ctx: common.Context): void {
    this.ctx = ctx as common.UIAbilityContext;
  }

  /** 引擎销毁时清理（停止录音等持有资源） */
  dispose(): void {
    this.stopRecordingInternal(false).then(() => {});
  }

  /** 入口：C++ onDevice 转发；无论成败必须 sink 一次，防止 QuickJS Promise 悬挂 */
  dispatch(deviceId: number, requestJson: string): void {
    this.handle(deviceId, requestJson);
  }

  /** 直连测试口：不经 QuickJS 桥直接执行一个 op（自测页使用；与 dispatch 走同一 execute） */
  async callOp(op: string, args: Record<string, Object>): Promise<Record<string, Object>> {
    return await this.execute(op, args);
  }

  private async handle(deviceId: number, requestJson: string): Promise<void> {
    let op = '';
    let args: Record<string, Object> = {};
    try {
      const req = JSON.parse(requestJson) as Record<string, Object>;
      const opVal = req['op'];
      if (typeof opVal === 'string') {
        op = opVal;
      }
      const argsVal = req['args'];
      if (argsVal !== undefined && argsVal !== null) {
        args = argsVal as Record<string, Object>;
      }
      if (op === '') {
        throw new Error('missing op');
      }
      const data = await this.execute(op, args);
      console.info('[DeviceBridge] op=' + op + ' ok: ' + JSON.stringify(data).substring(0, 200));
      this.sink(deviceId, true, JSON.stringify(data));
    } catch (e) {
      const msg = e instanceof Error ? e.message : JSON.stringify(e);
      console.error('[DeviceBridge] op=' + op + ' failed: ' + msg);
      const err: Record<string, Object> = {};
      err['error'] = msg;
      this.sink(deviceId, false, JSON.stringify(err));
    }
  }

  // ── op 分发 ────────────────────────────────────────────────

  private async execute(op: string, args: Record<string, Object>): Promise<Record<string, Object>> {
    switch (op) {
      case 'status':
        return this.opStatus();
      case 'permissions':
        return this.opPermissions(args);
      case 'contacts':
        return this.opContacts(args);
      case 'calendar':
        return this.opCalendar(args);
      case 'clipboard':
        return this.opClipboard(args);
      case 'files':
        return this.opFiles(args);
      case 'photos':
        return this.opPhotos(args);
      case 'mail':
        return this.opMail(args);
      case 'call':
        return this.opCall(args);
      case 'sms':
        return this.opSms();
      case 'camera':
        return this.opCamera();
      case 'recorder':
        return this.opRecorder(args);
      case 'app':
        return this.opApp(args);
      case 'network':
        return this.opNetwork();
      case 'deviceinfo':
        return this.opDeviceInfo();
      case 'vibrate':
        return this.opVibrate(args);
      case 'location':
        return this.opLocation();
      case 'settings':
        return this.opSettings(args);
      case 'reminder':
        return this.opReminder(args);
      case 'gui':
        return this.opGui(args);
      case 'scheduler':
        return this.opScheduler(args);
      case 'runScript':
        return this.opRunScript(args);
      default:
        throw new Error('unknown device op: ' + op);
    }
  }

  // ── runScript（脚本沙箱 — 执行器由 AppViewModel 注入，App 级引擎复用） ──

  private runScriptExecutor: ((source: string, timeoutMs: number) => Promise<Record<string, Object>>) | null = null;

  setRunScriptExecutor(fn: (source: string, timeoutMs: number) => Promise<Record<string, Object>>): void {
    this.runScriptExecutor = fn;
  }

  private async opRunScript(args: Record<string, Object>): Promise<Record<string, Object>> {
    const source = strArg(args, 'source', '');
    if (source === '') {
      throw new Error('runScript: source required');
    }
    const timeoutMs = numArg(args, 'timeoutMs', 60000);
    if (this.runScriptExecutor === null) {
      throw new Error('runScript: sandbox not initialized');
    }
    return await this.runScriptExecutor(source, timeoutMs);
  }

  // ── status / permissions ───────────────────────────────────

  private async opStatus(): Promise<Record<string, Object>> {
    const perms: Record<string, Object> = {};
    const scopes = ['contacts', 'calendar', 'microphone', 'camera', 'sms', 'location'];
    for (const scope of scopes) {
      perms[scope] = await this.scopeState(scope);
    }
    const out: Record<string, Object> = {};
    out['platform'] = 'harmonyos';
    out['bridge'] = DEVICE_BRIDGE_VERSION;
    out['capabilities'] = ['contacts', 'calendar', 'clipboard', 'files', 'photos', 'mail', 'call', 'camera', 'recorder', 'app-open', 'network', 'deviceinfo', 'vibrate', 'location', 'settings', 'reminder', 'gui', 'scheduler', 'runScript'];
    out['permissions'] = perms;
    out['note'] = 'gui automation requires enabling Accessibility service in Settings';
    return out;
  }

  private async opPermissions(args: Record<string, Object>): Promise<Record<string, Object>> {
    const action = strArg(args, 'action', 'query');
    let scopes = strArrayArg(args, 'scopes');
    if (scopes.length === 0) {
      scopes = ['contacts', 'calendar', 'microphone', 'camera'];
    }
    if (action === 'request') {
      await this.ensureScopes(scopes);
    }
    const states: Record<string, Object> = {};
    for (const scope of scopes) {
      states[scope] = await this.scopeState(scope);
    }
    const out: Record<string, Object> = {};
    out['action'] = action;
    out['states'] = states;
    return out;
  }

  private async scopeState(scope: string): Promise<string> {
    const perms = SCOPE_PERMISSIONS[scope];
    if (!perms || !this.ctx) {
      return 'unknown';
    }
    try {
      let granted = true;
      for (const p of perms) {
        const st = await this.checkPermission(p);
        if (st !== 0) {
          granted = false;
          break;
        }
      }
      return granted ? 'granted' : 'not-granted';
    } catch (e) {
      return 'unknown';
    }
  }

  private async checkPermission(perm: Permissions): Promise<number> {
    const ctx = this.requireCtx();
    const info = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
    const tokenId = info.appInfo.accessTokenId;
    const at = abilityAccessCtrl.createAtManager();
    return at.checkAccessToken(tokenId, perm);
  }

  /** 申请权限；任一被拒绝则抛错（含被拒权限名） */
  private async ensureScopes(scopes: string[]): Promise<void> {
    const permList: Array<Permissions> = [];
    for (const scope of scopes) {
      const perms = SCOPE_PERMISSIONS[scope];
      if (perms) {
        for (const p of perms) {
          permList.push(p);
        }
      }
    }
    if (permList.length === 0) {
      return;
    }
    const ctx = this.requireCtx();
    const at = abilityAccessCtrl.createAtManager();
    const r = await at.requestPermissionsFromUser(ctx, permList);
    let denied = '';
    r.authResults.forEach((st: number, i: number) => {
      if (st !== 0 && denied === '') {
        denied = r.permissions[i];
      }
    });
    if (denied !== '') {
      throw new Error('permission denied: ' + denied + ' (ask the user to allow it in Settings, or continue without this capability)');
    }
  }

  // ── contacts ───────────────────────────────────────────────

  private async opContacts(args: Record<string, Object>): Promise<Record<string, Object>> {
    const ctx = this.requireCtx();
    const op = strArg(args, 'op', 'query');
    if (op === 'query') {
      await this.ensureScopes(['contacts']);
      const limit = numArg(args, 'limit', 50);
      const query = strArg(args, 'query', '');
      const all = await contact.queryContacts(ctx);
      const q = query.toLowerCase();
      let filtered = all;
      if (q !== '') {
        filtered = all.filter((c: contact.Contact): boolean => {
          const n = c.name;
          const fullName = n && n.fullName ? n.fullName : '';
          return fullName.toLowerCase().includes(q);
        });
      }
      const list = filtered.slice(0, Math.min(Math.max(limit, 1), 200));
      const outList: Array<Record<string, Object>> = [];
      for (const c of list) {
        const item: Record<string, Object> = {};
        item['id'] = c.id ?? -1;
        item['key'] = c.key ?? '';
        const nameVal = c.name;
        if (nameVal) {
          item['name'] = nameVal.fullName ?? nameVal.familyName ?? '';
        } else {
          item['name'] = '';
        }
        const phones: string[] = [];
        const phoneVal = c.phoneNumbers;
        if (phoneVal) {
          for (const ph of phoneVal) {
            phones.push(ph.phoneNumber ?? '');
          }
        }
        item['phones'] = phones;
        const emails: string[] = [];
        const emailVal = c.emails;
        if (emailVal) {
          for (const em of emailVal) {
            emails.push(em.email ?? '');
          }
        }
        item['emails'] = emails;
        outList.push(item);
      }
      const out: Record<string, Object> = {};
      out['contacts'] = outList;
      out['count'] = outList.length;
      return out;
    }
    if (op === 'create') {
      await this.ensureScopes(['contacts']);
      const name = strArg(args, 'name', '');
      if (name === '') {
        throw new Error('create requires name');
      }
      const phones = strArrayArg(args, 'phones');
      const phoneObjs: Array<contact.PhoneNumber> = [];
      for (const p of phones) {
        const ph: contact.PhoneNumber = { phoneNumber: p };
        phoneObjs.push(ph);
      }
      const email = strArg(args, 'email', '');
      const emailObjs: Array<contact.Email> = [];
      if (email !== '') {
        const em: contact.Email = { email: email };
        emailObjs.push(em);
      }
      const toAdd: contact.Contact = { name: { fullName: name } };
      if (phoneObjs.length > 0) {
        toAdd.phoneNumbers = phoneObjs;
      }
      if (emailObjs.length > 0) {
        toAdd.emails = emailObjs;
      }
      const note = strArg(args, 'note', '');
      if (note !== '') {
        toAdd.note = { noteContent: note };
      }
      const id = await contact.addContact(ctx, toAdd);
      const out: Record<string, Object> = {};
      out['created'] = true;
      out['id'] = id;
      return out;
    }
    if (op === 'delete') {
      await this.ensureScopes(['contacts']);
      const key = strArg(args, 'key', '');
      const id = numArg(args, 'id', -1);
      if (key === '' && id < 0) {
        throw new Error('delete requires id or key');
      }
      let contactKey = key;
      if (contactKey === '') {
        const all = await contact.queryContacts(ctx);
        const hit = all.find((c: contact.Contact): boolean => c.id === id);
        if (!hit || !hit.key) {
          throw new Error('contact not found: ' + id);
        }
        contactKey = hit.key;
      }
      await contact.deleteContact(ctx, contactKey);
      const out: Record<string, Object> = {};
      out['deleted'] = true;
      return out;
    }
    throw new Error('unknown contacts op: ' + op);
  }

  // ── calendar ───────────────────────────────────────────────

  private async opCalendar(args: Record<string, Object>): Promise<Record<string, Object>> {
    const ctx = this.requireCtx();
    const op = strArg(args, 'op', 'query');
    const mgr = calendarManager.getCalendarManager(ctx);
    const cal = await mgr.getCalendar();
    if (op === 'query') {
      await this.ensureScopes(['calendar']);
      const now = Date.now();
      const start = numArg(args, 'start', now - 7 * 24 * 3600 * 1000);
      const end = numArg(args, 'end', now + 7 * 24 * 3600 * 1000);
      const events = await cal.getEvents(
        calendarManager.EventFilter.filterByTime(Math.floor(start / 1000), Math.ceil(end / 1000)),
      );
      const outList: Array<Record<string, Object>> = [];
      for (const ev of events) {
        const item: Record<string, Object> = {};
        item['id'] = ev.id ?? -1;
        item['title'] = ev.title ?? '';
        item['start'] = ev.startTime;
        item['end'] = ev.endTime;
        item['allDay'] = ev.isAllDay ?? false;
        item['location'] = ev.location?.location ?? '';
        outList.push(item);
      }
      const out: Record<string, Object> = {};
      out['events'] = outList;
      out['count'] = outList.length;
      return out;
    }
    if (op === 'create') {
      await this.ensureScopes(['calendar']);
      const title = strArg(args, 'title', '');
      if (title === '') {
        throw new Error('create requires title');
      }
      const now = Date.now();
      const startMs = numArg(args, 'start', now + 3600 * 1000);
      const endMs = numArg(args, 'end', startMs + 3600 * 1000);
      const allDay = boolArg(args, 'allDay', false);
      const ev: calendarManager.Event = {
        type: calendarManager.EventType.NORMAL,
        title: title,
        startTime: Math.floor(startMs / 1000),
        endTime: Math.floor(endMs / 1000),
        isAllDay: allDay,
      };
      const location = strArg(args, 'location', '');
      if (location !== '') {
        ev.location = { location: location };
      }
      const notes = strArg(args, 'notes', '');
      if (notes !== '') {
        ev.description = notes;
      }
      const reminderMinutes = numArg(args, 'reminderMinutes', -1);
      if (reminderMinutes >= 0) {
        ev.reminderTime = [reminderMinutes];
      }
      const id = await cal.addEvent(ev);
      const out: Record<string, Object> = {};
      out['created'] = true;
      out['id'] = id;
      out['start'] = ev.startTime;
      out['end'] = ev.endTime;
      return out;
    }
    if (op === 'delete') {
      await this.ensureScopes(['calendar']);
      const id = numArg(args, 'id', -1);
      if (id < 0) {
        throw new Error('delete requires id');
      }
      await cal.deleteEvent(id);
      const out: Record<string, Object> = {};
      out['deleted'] = true;
      return out;
    }
    throw new Error('unknown calendar op: ' + op);
  }

  // ── clipboard ──────────────────────────────────────────────

  private async opClipboard(args: Record<string, Object>): Promise<Record<string, Object>> {
    const op = strArg(args, 'op', 'read');
    const pb = pasteboard.getSystemPasteboard();
    if (op === 'read') {
      const data = await pb.getData();
      const text = data.getPrimaryText();
      const out: Record<string, Object> = {};
      out['text'] = text;
      return out;
    }
    if (op === 'write') {
      const text = strArg(args, 'text', '');
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pb.setData(data);
      const out: Record<string, Object> = {};
      out['written'] = true;
      return out;
    }
    throw new Error('unknown clipboard op: ' + op);
  }

  // ── files ──────────────────────────────────────────────────

  private async opFiles(args: Record<string, Object>): Promise<Record<string, Object>> {
    const ctx = this.requireCtx();
    const op = strArg(args, 'op', 'pick');
    if (op === 'pick') {
      const maxNumber = numArg(args, 'maxNumber', 1);
      const dp = new picker.DocumentViewPicker(ctx);
      const opts: picker.DocumentSelectOptions = { maxSelectNumber: Math.min(Math.max(maxNumber, 1), 10) };
      const uris = await dp.select(opts);
      const out: Record<string, Object> = {};
      out['uris'] = uris;
      out['count'] = uris.length;
      return out;
    }
    if (op === 'read') {
      const uri = strArg(args, 'uri', '');
      if (uri === '') {
        throw new Error('read requires uri');
      }
      const f = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      try {
        const stat = fs.statSync(f.fd);
        const buf = new ArrayBuffer(stat.size);
        fs.readSync(f.fd, buf);
        const text = decodeUtf8(buf);
        const out: Record<string, Object> = {};
        out['uri'] = uri;
        out['size'] = stat.size;
        out['text'] = text;
        return out;
      } finally {
        fs.closeSync(f);
      }
    }
    if (op === 'write') {
      let uri = strArg(args, 'uri', '');
      if (uri === '') {
        // 无 uri → 走系统保存对话框（用户选择位置与文件名）
        const fileName = strArg(args, 'fileName', 'harnest.txt');
        const dp = new picker.DocumentViewPicker(ctx);
        const opts: picker.DocumentSaveOptions = { newFileNames: [fileName] };
        const uris = await dp.save(opts);
        if (uris.length === 0) {
          throw new Error('save cancelled');
        }
        uri = uris[0];
      }
      const text = strArg(args, 'text', '');
      const f = fs.openSync(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, text);
      } finally {
        fs.closeSync(f);
      }
      const out: Record<string, Object> = {};
      out['uri'] = uri;
      out['written'] = true;
      out['size'] = text.length;
      return out;
    }
    if (op === 'sandboxList') {
      const rel = strArg(args, 'path', '');
      const dirPath = this.sandboxPath(rel, false);
      const names = fs.listFileSync(dirPath);
      const outList: Array<Record<string, Object>> = [];
      for (const name of names) {
        const item: Record<string, Object> = {};
        item['name'] = name;
        let isDir = false;
        try {
          const st = fs.statSync(dirPath + '/' + name);
          isDir = st.isDirectory();
        } catch (e) {
          isDir = false;
        }
        item['isDir'] = isDir;
        outList.push(item);
      }
      const out: Record<string, Object> = {};
      out['path'] = rel;
      out['root'] = this.requireCtx().filesDir;
      out['entries'] = outList;
      return out;
    }
    if (op === 'sandboxRead') {
      const rel = strArg(args, 'path', '');
      const path = this.sandboxPath(rel, false);
      const text = decodeUtf8(readAll(path));
      const out: Record<string, Object> = {};
      out['path'] = rel;
      out['text'] = text;
      return out;
    }
    if (op === 'sandboxWrite') {
      const rel = strArg(args, 'path', '');
      const text = strArg(args, 'text', '');
      const path = this.sandboxPath(rel, true);
      const f = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, text);
      } finally {
        fs.closeSync(f);
      }
      const out: Record<string, Object> = {};
      out['path'] = rel;
      out['written'] = true;
      out['size'] = text.length;
      return out;
    }
    throw new Error('unknown files op: ' + op);
  }

  // ── photos ─────────────────────────────────────────────────

  private async opPhotos(args: Record<string, Object>): Promise<Record<string, Object>> {
    const ctx = this.requireCtx();
    const op = strArg(args, 'op', 'pick');
    if (op === 'pick') {
      const maxNumber = numArg(args, 'maxNumber', 1);
      const ph = new picker.PhotoViewPicker();
      const opts: picker.PhotoSelectOptions = {
        maxSelectNumber: Math.min(Math.max(maxNumber, 1), 20),
        MIMEType: picker.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE,
      };
      const r = await ph.select(opts);
      const out: Record<string, Object> = {};
      out['uris'] = r.photoUris;
      out['count'] = r.photoUris.length;
      return out;
    }
    if (op === 'save') {
      const base64Str = strArg(args, 'base64', '');
      if (base64Str === '') {
        throw new Error('save requires base64');
      }
      const fileName = strArg(args, 'fileName', 'photo.jpg');
      // 直写系统相册需 ACL 权限（WRITE_IMAGEVIDEO），刻意避开 → 系统保存对话框（用户确认）
      const dp = new picker.DocumentViewPicker(ctx);
      const opts: picker.DocumentSaveOptions = { newFileNames: [fileName] };
      const uris = await dp.save(opts);
      if (uris.length === 0) {
        throw new Error('save cancelled');
      }
      const bytes = base64Decode(base64Str);
      const f = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, bytes);
      } finally {
        fs.closeSync(f);
      }
      const out: Record<string, Object> = {};
      out['uri'] = uris[0];
      out['saved'] = true;
      out['size'] = bytes.byteLength;
      return out;
    }
    throw new Error('unknown photos op: ' + op);
  }

  // ── mail / call（拉起系统应用，由用户确认发送） ────────────

  private async opMail(args: Record<string, Object>): Promise<Record<string, Object>> {
    const ctx = this.requireCtx();
    const to = strArg(args, 'to', '');
    if (to === '') {
      throw new Error('send requires to');
    }
    const uri = 'mailto:' + to;
    const params: Record<string, Object> = {};
    const cc = strArg(args, 'cc', '');
    if (cc !== '') {
      params['cc'] = cc;
    }
    const subject = strArg(args, 'subject', '');
    if (subject !== '') {
      params['subject'] = subject;
    }
    const body = strArg(args, 'body', '');
    if (body !== '') {
      params['body'] = body;
    }
    const w: Want = { action: 'ohos.want.action.sendData', uri: uri };
    if (Object.keys(params).length > 0) {
      w.parameters = params;
    }
    await ctx.startAbility(w);
    const out: Record<string, Object> = {};
    out['launched'] = true;
    out['note'] = 'mail composer opened; the user sends it';
    return out;
  }

  private async opCall(args: Record<string, Object>): Promise<Record<string, Object>> {
    const ctx = this.requireCtx();
    const op = strArg(args, 'op', 'dial');
    const number = strArg(args, 'number', '');
    if (op === 'calllog' || op === 'history' || op === 'query') {
      // HarmonyOS 无三方通话记录 API（READ_CALL_LOG 为系统级 ACL 权限）——
      // 优雅降级：明确告知不可用 + 替代方案，防止模型尝试打开系统页面
      const out: Record<string, Object> = {};
      out['readable'] = false;
      out['reason'] = 'HarmonyOS does not expose a call-log API to third-party apps. ' +
        'READ_CALL_LOG is a system-level ACL permission reserved for system apps. ' +
        'Do NOT try to open the system call-log page via device_app — it has no public handler and will fail.';
      out['alternatives'] = [
        'Ask the user to open the Phone app and read the history themselves',
        'Ask the user to screenshot the call log and share it via device_photos pick',
        'Ask the user to paste/type the relevant entries into chat',
      ];
      return out;
    }
    if (number === '') {
      throw new Error('dial/sms requires number');
    }
    if (op === 'dial') {
      const w: Want = { action: 'ohos.want.action.callData', uri: 'tel:' + number };
      try {
        await ctx.startAbility(w);
      } catch (e) {
        const msg = e instanceof Error ? e.message : JSON.stringify(e);
        throw new Error('failed to open dialer for ' + number + ': ' + msg +
          ' (this device may have no dialer app, e.g. a tablet)');
      }
      const out: Record<string, Object> = {};
      out['launched'] = true;
      out['note'] = 'dialer opened with number pre-filled; the user presses call';
      return out;
    }
    if (op === 'sms') {
      const w: Want = { action: 'ohos.want.action.sendData', uri: 'smsto:' + number };
      const body = strArg(args, 'body', '');
      if (body !== '') {
        const params: Record<string, Object> = {};
        params['sms_body'] = body;
        w.parameters = params;
      }
      try {
        await ctx.startAbility(w);
      } catch (e) {
        const msg = e instanceof Error ? e.message : JSON.stringify(e);
        throw new Error('failed to open SMS composer for ' + number + ': ' + msg);
      }
      const out: Record<string, Object> = {};
      out['launched'] = true;
      out['note'] = 'sms composer opened; the user sends it';
      return out;
    }
    throw new Error('unknown call op: ' + op + ' (supported: dial, sms, calllog)');
  }

  // ── sms（收件箱读取：尝试申请权限并读取，失败才降级） ──────

  private async opSms(): Promise<Record<string, Object>> {
    // HarmonyOS @ohos.telephony.sms 公开 API 仅提供发送能力，无收件箱读取接口。
    // 但 READ_MESSAGES 权限仍值得尝试申请（部分设备/企业场景可能放行），
    // 且尝试过程本身能给出用户可操作的反馈。
    let permState = 'unknown';
    try {
      await this.ensureScopes(['sms']);
      permState = 'granted';
    } catch (e) {
      const msg = e instanceof Error ? e.message : JSON.stringify(e);
      permState = 'denied: ' + msg;
    }

    if (permState === 'granted') {
      // 权限获批（罕见），但仍无公开读取 API → 尝试 dataShare 读取系统短信数据库
      try {
        const result = await this.tryReadSmsViaDataShare();
        if (result !== null) {
          return result;
        }
      } catch (e) {
        const msg = e instanceof Error ? e.message : JSON.stringify(e);
        console.error('[DeviceBridge] sms dataShare read failed: ' + msg);
      }
    }

    // 权限被拒或无读取 API → 返回详细状态，让模型向用户说明真实原因
    const out: Record<string, Object> = {};
    out['readable'] = false;
    out['permission'] = permState;
    out['reason'] = 'HarmonyOS does not expose a public SMS inbox API to third-party apps. ' +
      '@ohos.telephony.sms only supports sending (sendMessage/sendShortMessage). ' +
      'No query/read interface exists in the public SDK. ' +
      'READ_MESSAGES is a system_basic+ACL permission typically reserved for system apps, ' +
      'and even with permission granted, there is no public API to read the inbox.';
    out['alternatives'] = [
      'Ask the user to forward the messages to this app via system Share',
      'Ask the user to export messages from the system Messages app and share the file',
      'Ask the user to paste the message content directly into chat',
      'Use device_call op=sms to open the SMS composer for sending (user confirms)',
    ];
    return out;
  }

  /** 尝试通过 dataShare 读取系统短信数据库（需 READ_MESSAGES 权限，且系统未禁用） */
  private async tryReadSmsViaDataShare(): Promise<Record<string, Object> | null> {
    // Stage Model 下无公开 dataShareHelper API（DataAbilityHelper 为 FA Model Only）。
    // HarmonyOS 短信数据存储在系统数据库中，但三方应用无公开访问路径。
    // 此处返回 null 表示"无法通过 dataShare 读取"，让上层走降级逻辑。
    return null;
  }

  // ── camera ─────────────────────────────────────────────────

  private async opCamera(): Promise<Record<string, Object>> {
    const ctx = this.requireCtx();
    // cameraPicker 为系统级拍照 UI，无需 CAMERA 权限声明即可拉起（用户在 UI 上确认）
    const profile: cameraPicker.PickerProfile = { cameraPosition: camera.CameraPosition.CAMERA_POSITION_BACK };
    const res = await cameraPicker.pick(ctx, [cameraPicker.PickerMediaType.PHOTO], profile);
    if (res === undefined || res === null) {
      // 模拟器等无相机设备上 pick 直接 resolve undefined
      throw new Error('camera picker unavailable on this device (no camera service)');
    }
    if (!res.resultUri) {
      throw new Error('camera capture cancelled — the user closed the camera without taking a photo. ' +
        'Tell the user: the shutter must be pressed manually in the system camera UI (third-party apps cannot auto-capture)');
    }
    const out: Record<string, Object> = {};
    out['uri'] = res.resultUri;
    out['captured'] = true;
    out['note'] = 'Photo confirmed by the user in the system camera UI. ' +
      'The shutter is always pressed manually by the user — third-party apps cannot auto-capture on HarmonyOS.';
    return out;
  }

  // ── recorder ───────────────────────────────────────────────

  private async opRecorder(args: Record<string, Object>): Promise<Record<string, Object>> {
    const ctx = this.requireCtx();
    const op = strArg(args, 'op', 'status');
    if (op === 'start') {
      if (this.recorder !== null) {
        throw new Error('already recording');
      }
      await this.ensureScopes(['microphone']);
      const maxSeconds = numArg(args, 'maxSeconds', 60);
      this.recPath = ctx.cacheDir + '/rec-' + Date.now() + '.m4a';
      const file = fs.openSync(this.recPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      this.recFd = file.fd;
      const rec = await media.createAVRecorder();
      const cfg: media.AVRecorderConfig = {
        audioSourceType: media.AudioSourceType.AUDIO_SOURCE_TYPE_MIC,
        profile: {
          fileFormat: media.ContainerFormatType.CFT_MPEG_4A,
          audioBitrate: 48000,
          audioChannels: 1,
          audioCodec: media.CodecMimeType.AUDIO_AAC,
          audioSampleRate: 44100,
        },
        url: 'fd://' + this.recFd,
      };
      await rec.prepare(cfg);
      await rec.start();
      this.recorder = rec;
      this.recStartMs = Date.now();
      if (maxSeconds > 0 && maxSeconds <= 600) {
        this.recTimer = setTimeout(() => {
          this.stopRecordingInternal(true).then(() => {});
        }, maxSeconds * 1000);
      }
      const out: Record<string, Object> = {};
      out['recording'] = true;
      out['maxSeconds'] = maxSeconds;
      return out;
    }
    if (op === 'stop' || op === 'status') {
      if (this.recorder === null) {
        const out: Record<string, Object> = {};
        out['recording'] = false;
        return out;
      }
      const path = await this.stopRecordingInternal(false);
      const out: Record<string, Object> = {};
      out['recording'] = false;
      out['path'] = path;
      out['durationSeconds'] = Math.round((Date.now() - this.recStartMs) / 100) / 10;
      let size = 0;
      try {
        const st = fs.statSync(path);
        size = st.size;
      } catch (e) {
        size = 0;
      }
      out['size'] = size;
      out['note'] = 'Audio file saved to sandbox. For transcription, use the device_files op to read this file and send it to an ASR-capable model API.';
      return out;
    }
    throw new Error('unknown recorder op: ' + op);
  }

  private async stopRecordingInternal(autoStopped: boolean): Promise<string> {
    const rec = this.recorder;
    if (rec === null) {
      return this.recPath;
    }
    this.recorder = null;
    if (this.recTimer >= 0) {
      clearTimeout(this.recTimer);
      this.recTimer = -1;
    }
    try {
      await rec.stop();
      await rec.release();
    } catch (e) {
      const msg = e instanceof Error ? e.message : JSON.stringify(e);
      console.error('[DeviceBridge] recorder stop failed: ' + msg);
    }
    if (this.recFd >= 0) {
      try {
        fs.closeSync(this.recFd);
      } catch (e) {
      }
      this.recFd = -1;
    }
    if (autoStopped) {
      console.info('[DeviceBridge] recording auto-stopped: ' + this.recPath);
    }
    return this.recPath;
  }

  // ── app ────────────────────────────────────────────────────

  private async opApp(args: Record<string, Object>): Promise<Record<string, Object>> {
    const ctx = this.requireCtx();
    const op = strArg(args, 'op', 'open');
    if (op === 'open') {
      const bundleName = strArg(args, 'bundleName', '');
      const uri = strArg(args, 'uri', '');
      if (bundleName === '' && uri === '') {
        throw new Error('open requires bundleName or uri');
      }
      let w: Want;
      if (bundleName !== '') {
        w = { bundleName: bundleName };
        const abilityName = strArg(args, 'abilityName', '');
        if (abilityName !== '') {
          w.abilityName = abilityName;
        }
        if (uri !== '') {
          w.uri = uri;
        }
      } else {
        w = { action: 'ohos.want.action.viewData', uri: uri };
      }
      try {
        await ctx.startAbility(w);
      } catch (e) {
        const msg = e instanceof Error ? e.message : JSON.stringify(e);
        throw new Error('failed to open target (no handler on this device): ' + msg +
          '. Note: system data pages (call log, SMS inbox) have no public URI handlers — ' +
          'do not try to open them via uri; read the tool docs instead.');
      }
      const out: Record<string, Object> = {};
      out['launched'] = true;
      return out;
    }
    if (op === 'list') {
      // 此 SDK 未提供应用枚举 API（queryAbilityInfos 已移除），且包可见性策略本就限制枚举；
      // 降级为空列表 + 说明；已知 bundleName/uri 的拉起走 open
      const out: Record<string, Object> = {};
      out['apps'] = [] as Array<Record<string, Object>>;
      out['count'] = 0;
      out['note'] = 'app enumeration unavailable on this harmonyos sdk; use device_app open with a known bundleName/uri';
      return out;
    }
    if (op === 'gui') {
      throw new Error('gui automation on harmonyos is phase-3 (accessibility extension); use device_app open to launch apps');
    }
    throw new Error('unknown app op: ' + op);
  }

  // ── network ────────────────────────────────────────────────

  private async opNetwork(): Promise<Record<string, Object>> {
    const out: Record<string, Object> = {};
    try {
      const handle = connection.getDefaultNetSync();
      if (!handle || handle.netId === 0) {
        out['connected'] = false;
        return out;
      }
      const caps = connection.getNetCapabilitiesSync(handle);
      out['connected'] = true;
      out['netId'] = handle.netId;
      const types: string[] = [];
      if (caps.bearerTypes) {
        for (const t of caps.bearerTypes) {
          if (t === connection.NetBearType.BEARER_WIFI) {
            types.push('wifi');
          } else if (t === connection.NetBearType.BEARER_CELLULAR) {
            types.push('cellular');
          } else if (t === connection.NetBearType.BEARER_ETHERNET) {
            types.push('ethernet');
          } else {
            types.push('other(' + t + ')');
          }
        }
      }
      out['types'] = types;
      if (caps.linkUpBandwidthKbps !== undefined) {
        out['upKbps'] = caps.linkUpBandwidthKbps;
      }
      if (caps.linkDownBandwidthKbps !== undefined) {
        out['downKbps'] = caps.linkDownBandwidthKbps;
      }
      const props = connection.getConnectionPropertiesSync(handle);
      if (props && props.linkAddresses) {
        const addrs: string[] = [];
        for (const a of props.linkAddresses) {
          if (a && a.address) {
            addrs.push(a.address.address);
          }
        }
        out['addresses'] = addrs;
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : JSON.stringify(e);
      out['connected'] = false;
      out['error'] = msg;
    }
    return out;
  }

  // ── deviceinfo ─────────────────────────────────────────────

  private async opDeviceInfo(): Promise<Record<string, Object>> {
    const out: Record<string, Object> = {};
    out['manufacture'] = deviceInfo.manufacture;
    out['brand'] = deviceInfo.brand;
    out['marketName'] = deviceInfo.marketName;
    out['productModel'] = deviceInfo.productModel;
    out['deviceType'] = deviceInfo.deviceType;
    out['osFullName'] = deviceInfo.osFullName;
    out['displayVersion'] = deviceInfo.displayVersion;
    out['securityPatchTag'] = deviceInfo.securityPatchTag;
    out['batterySOC'] = batteryInfo.batterySOC;
    let chargeState = 'unknown';
    if (batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.ENABLE) {
      chargeState = 'charging';
    } else if (batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.DISABLE) {
      chargeState = 'not-charging';
    } else if (batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.FULL) {
      chargeState = 'full';
    }
    out['chargeState'] = chargeState;
    return out;
  }

  // ── vibrate ────────────────────────────────────────────────

  private async opVibrate(args: Record<string, Object>): Promise<Record<string, Object>> {
    const duration = numArg(args, 'duration', 300);
    const ms = Math.min(Math.max(duration, 1), 2000);
    const effect: vibrator.VibrateTime = { type: 'time', duration: ms };
    await vibrator.startVibration(effect, { id: 0, usage: 'touch' });
    const out: Record<string, Object> = {};
    out['vibrated'] = true;
    out['duration'] = ms;
    return out;
  }

  // ── location ───────────────────────────────────────────────

  private async opLocation(): Promise<Record<string, Object>> {
    await this.ensureScopes(['location']);
    if (!geoLocationManager.isLocationEnabled()) {
      throw new Error('location is disabled at system level (user can enable it in Settings > Location)');
    }
    const req: geoLocationManager.SingleLocationRequest = {
      locatingPriority: geoLocationManager.LocatingPriority.PRIORITY_ACCURACY,
      locatingTimeoutMs: 10000,
    };
    const loc = await geoLocationManager.getCurrentLocation(req);
    const out: Record<string, Object> = {};
    out['latitude'] = loc.latitude;
    out['longitude'] = loc.longitude;
    out['altitude'] = loc.altitude;
    out['accuracy'] = loc.accuracy;
    out['timeStamp'] = loc.timeStamp;
    return out;
  }

  // ── settings ───────────────────────────────────────────────

  private async opSettings(args: Record<string, Object>): Promise<Record<string, Object>> {
    const ctx = this.requireCtx();
    const target = strArg(args, 'target', 'settings');
    const uriMap: Record<string, string> = {
      'settings': 'settings://settings',
      'wifi': 'settings://wifi',
      'bluetooth': 'settings://bluetooth',
      'location': 'settings://location',
      'notification': 'settings://notification',
      'app-manager': 'settings://application_settings',
    };
    const uri = uriMap[target];
    if (!uri) {
      throw new Error('unknown settings target: ' + target + ' (supported: settings, wifi, bluetooth, location, notification, app-manager)');
    }
    const w: Want = { action: 'ohos.want.action.viewData', uri: uri };
    await ctx.startAbility(w);
    const out: Record<string, Object> = {};
    out['launched'] = true;
    out['target'] = target;
    return out;
  }

  // ── reminder ───────────────────────────────────────────────

  private async opReminder(args: Record<string, Object>): Promise<Record<string, Object>> {
    const op = strArg(args, 'op', 'add');
    if (op === 'add') {
      return this.reminderAdd(args);
    }
    if (op === 'list') {
      return this.reminderList();
    }
    if (op === 'remove') {
      return this.reminderRemove(args);
    }
    throw new Error('unknown reminder op: ' + op);
  }

  private async reminderAdd(args: Record<string, Object>): Promise<Record<string, Object>> {
    const title = strArg(args, 'title', '');
    const content = strArg(args, 'content', '');
    const delayMinutes = numArg(args, 'delayMinutes', -1);
    const hour = numArg(args, 'hour', -1);
    const minute = numArg(args, 'minute', -1);
    const year = numArg(args, 'year', -1);
    const month = numArg(args, 'month', -1);
    const day = numArg(args, 'day', -1);

    let reminderReq: reminderAgentManager.ReminderRequest;

    if (delayMinutes >= 0) {
      // Timer reminder: trigger after N minutes
      const now = new Date();
      const trigger = new Date(now.getTime() + delayMinutes * 60 * 1000);
      const timerReq: reminderAgentManager.ReminderRequestTimer = {
        reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_TIMER,
        triggerTimeInSeconds: delayMinutes * 60,
        title: title,
        content: content,
        wantAgent: {
          pkgName: this.requireCtx().applicationInfo.name,
          abilityName: 'EntryAbility',
        },
      };
      reminderReq = timerReq;
    } else if (hour >= 0 && minute >= 0) {
      // Calendar reminder at specific time today or specified date
      const now = new Date();
      const y = year >= 0 ? year : now.getFullYear();
      const m = month >= 0 ? month : now.getMonth() + 1;
      const d = day >= 0 ? day : now.getDate();
      const calReq: reminderAgentManager.ReminderRequestCalendar = {
        reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
        dateTime: {
          year: y,
          month: m,
          day: d,
          hour: hour,
          minute: minute,
          second: 0,
        },
        title: title,
        content: content,
        wantAgent: {
          pkgName: this.requireCtx().applicationInfo.name,
          abilityName: 'EntryAbility',
        },
      };
      reminderReq = calReq;
    } else {
      throw new Error('reminder add requires either delayMinutes (timer) or hour+minute (calendar)');
    }

    const reminderId = await reminderAgentManager.publishReminder(reminderReq);
    const out: Record<string, Object> = {};
    out['added'] = true;
    out['reminderId'] = reminderId;
    out['title'] = title;
    out['content'] = content;
    return out;
  }

  private async reminderList(): Promise<Record<string, Object>> {
    const reminders = await reminderAgentManager.getValidReminders();
    const out: Record<string, Object> = {};
    const items: Array<Record<string, Object>> = [];
    for (const r of reminders) {
      const item: Record<string, Object> = {};
      item['reminderType'] = r.reminderType;
      item['title'] = r.title ?? '';
      item['content'] = r.content ?? '';
      items.push(item);
    }
    out['reminders'] = items;
    out['count'] = items.length;
    return out;
  }

  private async reminderRemove(args: Record<string, Object>): Promise<Record<string, Object>> {
    const reminderId = numArg(args, 'reminderId', -1);
    if (reminderId < 0) {
      throw new Error('reminder remove requires reminderId');
    }
    await reminderAgentManager.cancelReminder(reminderId);
    const out: Record<string, Object> = {};
    out['removed'] = true;
    out['reminderId'] = reminderId;
    return out;
  }

  // ── gui（Accessibility Extension 跨进程命令桥）─────────────

  private guiCmdId: number = 0;

  private async opGui(args: Record<string, Object>): Promise<Record<string, Object>> {
    const ctx = this.requireCtx();
    const cmd = strArg(args, 'cmd', 'tree');
    const cmdArgs: Record<string, string | number | boolean> = {};
    for (const key of Object.keys(args)) {
      if (key === 'cmd') { continue; }
      const v = args[key];
      if (typeof v === 'string' || typeof v === 'number' || typeof v === 'boolean') {
        cmdArgs[key] = v;
      }
    }
    const id = ++this.guiCmdId;
    const cmdObj: Record<string, Object> = {};
    cmdObj['id'] = id;
    cmdObj['cmd'] = cmd;
    cmdObj['args'] = cmdArgs;

    // 清除旧结果，写新命令
    const cmdPath = ctx.filesDir + '/gui_cmd.json';
    const resPath = ctx.filesDir + '/gui_result.json';
    try { if (fs.accessSync(resPath)) { fs.unlinkSync(resPath); } } catch (e) { /* ignore */ }
    writeTextFileSync(cmdPath, JSON.stringify(cmdObj));

    // 轮询等待结果（最长 10 秒）
    const deadline = Date.now() + 10000;
    while (Date.now() < deadline) {
      await sleep(300);
      try {
        if (!fs.accessSync(resPath)) { continue; }
        const raw = fs.readTextSync(resPath);
        const result = JSON.parse(raw) as Record<string, Object>;
        const resultId = Number(result['id'] ?? -1);
        if (resultId !== id) { continue; }
        fs.unlinkSync(resPath);
        const ok = result['ok'] === true;
        if (!ok) {
          const errMsg = String(result['error'] ?? 'unknown gui error');
          if (errMsg.includes('accessibility') || errMsg.includes('9300003')) {
            throw new Error(
              'Accessibility service not enabled. Please enable it in Settings > Accessibility > ' +
              'Installed services > HarnessApp. Error: ' + errMsg
            );
          }
          throw new Error(errMsg);
        }
        const dataStr = String(result['data'] ?? '{}');
        try {
          return JSON.parse(dataStr) as Record<string, Object>;
        } catch (e) {
          const out: Record<string, Object> = {};
          out['result'] = dataStr;
          return out;
        }
      } catch (e) {
        if (e instanceof Error && e.message.includes('Accessibility service not enabled')) {
          throw e;
        }
        // 结果文件读写竞争，继续轮询
      }
    }
    throw new Error(
      'GUI command timed out (10s). The Accessibility Extension may not be running. ' +
      'Please enable it in Settings > Accessibility > Installed services.'
    );
  }

  // ── scheduler（WorkScheduler 后台定时任务）─────────────────

  private static readonly WORK_ID_BASE = 1000;
  private workIdCounter: number = 0;

  private async opScheduler(args: Record<string, Object>): Promise<Record<string, Object>> {
    const ctx = this.requireCtx();
    const op = strArg(args, 'op', 'start');

    if (op === 'start') {
      const task = strArg(args, 'task', 'scheduled task');
      const intervalMinutes = numArg(args, 'intervalMinutes', 30);
      const networkType = strArg(args, 'networkType', 'any');
      const requireCharging = boolArg(args, 'requireCharging', false);
      const requireIdle = boolArg(args, 'requireIdle', false);
      const workId = DeviceBridge.WORK_ID_BASE + (++this.workIdCounter);

      const workInfo: workScheduler.WorkInfo = {
        workId: workId,
        bundleName: ctx.applicationInfo.name,
        abilityName: 'WorkSchedulerExtAbility',
        isPersisted: true,
        isRepeat: true,
        repeatCycleTime: intervalMinutes * 60 * 1000,
        parameters: { 'task': task },
      };

      if (networkType === 'wifi') {
        workInfo.networkType = workScheduler.NetworkType.NETWORK_TYPE_WIFI;
      } else if (networkType === 'mobile') {
        workInfo.networkType = workScheduler.NetworkType.NETWORK_TYPE_MOBILE;
      } else {
        workInfo.networkType = workScheduler.NetworkType.NETWORK_TYPE_ANY;
      }

      if (requireCharging) {
        workInfo.isCharging = true;
        workInfo.chargerType = workScheduler.ChargingType.CHARGING_PLUGGED_ANY;
      }

      if (requireIdle) {
        workInfo.isDeepIdle = true;
      }

      workScheduler.startWork(workInfo);
      const out: Record<string, Object> = {};
      out['started'] = true;
      out['workId'] = workId;
      out['task'] = task;
      out['intervalMinutes'] = intervalMinutes;
      out['note'] = 'Work will trigger when conditions are met. Actual interval may be longer than requested due to system power management.';
      return out;
    }

    if (op === 'stop') {
      const workId = numArg(args, 'workId', -1);
      if (workId < 0) {
        throw new Error('scheduler stop requires workId');
      }
      const workInfo: workScheduler.WorkInfo = {
        workId: workId,
        bundleName: ctx.applicationInfo.name,
        abilityName: 'WorkSchedulerExtAbility',
      };
      workScheduler.stopWork(workInfo, true);
      const out: Record<string, Object> = {};
      out['stopped'] = true;
      out['workId'] = workId;
      return out;
    }

    if (op === 'stopAll') {
      workScheduler.stopAndClearWorks();
      const out: Record<string, Object> = {};
      out['stoppedAll'] = true;
      return out;
    }

    if (op === 'list') {
      const works = await workScheduler.obtainAllWorks();
      const items: Array<Record<string, Object>> = [];
      for (const w of works) {
        const item: Record<string, Object> = {};
        item['workId'] = w.workId;
        item['task'] = w.parameters?.['task'] as string ?? '';
        item['isRepeat'] = w.isRepeat ?? false;
        item['repeatCycleTime'] = w.repeatCycleTime ?? 0;
        item['isPersisted'] = w.isPersisted ?? false;
        items.push(item);
      }
      const out: Record<string, Object> = {};
      out['works'] = items;
      out['count'] = items.length;
      return out;
    }

    throw new Error('unknown scheduler op: ' + op);
  }

  // ── 工具 ───────────────────────────────────────────────────

  private requireCtx(): common.UIAbilityContext {
    if (!this.ctx) {
      throw new Error('device bridge not initialized (no UIAbility context)');
    }
    return this.ctx;
  }

  /** 沙箱路径守卫：禁止 .. 逃逸；ensureParent=true 时自动建父目录 */
  private sandboxPath(rel: string, ensureParent: boolean): string {
    const ctx = this.requireCtx();
    if (rel.includes('..')) {
      throw new Error('path traversal is not allowed');
    }
    const clean = rel.replace(/^\/+/, '');
    const full = ctx.filesDir + '/' + clean;
    if (ensureParent) {
      const idx = full.lastIndexOf('/');
      const dir = full.substring(0, idx);
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
    }
    return full;
  }
}

// ── 模块级工具函数 ───────────────────────────────────────────

function strArg(args: Record<string, Object>, key: string, dflt: string): string {
  const v = args[key];
  if (typeof v === 'string') {
    return v;
  }
  return dflt;
}

function numArg(args: Record<string, Object>, key: string, dflt: number): number {
  const v = args[key];
  if (typeof v === 'number') {
    return v;
  }
  if (typeof v === 'string' && v.trim() !== '' && !isNaN(Number(v))) {
    return Number(v);
  }
  return dflt;
}

function boolArg(args: Record<string, Object>, key: string, dflt: boolean): boolean {
  const v = args[key];
  if (typeof v === 'boolean') {
    return v;
  }
  return dflt;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

function writeTextFileSync(path: string, content: string): void {
  const fd = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
  try {
    fs.writeSync(fd.fd, content);
  } finally {
    fs.closeSync(fd);
  }
}

function strArrayArg(args: Record<string, Object>, key: string): string[] {
  const v = args[key];
  const out: string[] = [];
  if (Array.isArray(v)) {
    const arr = v as Array<Object>;
    for (const item of arr) {
      if (typeof item === 'string') {
        out.push(item);
      }
    }
  }
  return out;
}

function readAll(path: string): ArrayBuffer {
  const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
  try {
    const stat = fs.statSync(f.fd);
    const buf = new ArrayBuffer(stat.size);
    fs.readSync(f.fd, buf);
    return buf;
  } finally {
    fs.closeSync(f);
  }
}

function decodeUtf8(buf: ArrayBuffer): string {
  const decoder = util.TextDecoder.create('utf-8');
  return decoder.decodeWithStream(new Uint8Array(buf), { stream: false });
}

function base64Decode(text: string): ArrayBuffer {
  const helper = new util.Base64Helper();
  const bytes = helper.decodeSync(text);
  return bytes.buffer as ArrayBuffer;
}
