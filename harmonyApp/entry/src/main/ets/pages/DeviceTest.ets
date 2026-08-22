import { common } from '@kit.AbilityKit';
import { router, promptAction } from '@kit.ArkUI';
import { ThemeColors, darkTheme } from '../theme/Theme';
import { KEY_THEME } from '../service/AppearanceService';
import { HarnessNative } from '../service/HarnessNative';
import { LocalEngine } from '../service/LocalEngine';
import { ConfigService } from '../service/ConfigService';

/** 自测用例：name + op/args（直连模式）或 full:true（全链路经 QuickJS 桥） */
class DeviceCase {
  name: string;
  op: string;
  argsJson: string;
  state: string = '待测'; // 待测 | 运行中 | 通过 | 失败
  detail: string = '';

  constructor(name: string, op: string, argsJson: string) {
    this.name = name;
    this.op = op;
    this.argsJson = argsJson;
  }
}

/**
 * 设备能力自测页（开发用）：逐项驱动 DeviceBridge 的 12 类 op。
 * 两种模式：
 *   直连 — deviceBridge.callOp()，不经 QuickJS（引擎未启动也可测）
 *   全链路 — callFunc('deviceSelfTest') → __deviceCall → __harnessDeviceCall →
 *            C++ onDevice → napi → DeviceBridge.dispatch → deviceResult →
 *            __harnessOnDeviceResult → Promise settle（需引擎已启动）
 */
@Entry
@Component
struct DeviceTest {
  @State cases: DeviceCase[] = [];
  @State running: boolean = false;
  @State fullChain: boolean = false;
  @State engineReady: boolean = false;
  @StorageProp(KEY_THEME) theme: ThemeColors = darkTheme;
  private engine: LocalEngine = new LocalEngine();
  private seq: number = 0;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    HarnessNative.getInstance().deviceBridge().setContext(ctx);
    this.engineReady = HarnessNative.getInstance().isReady();
    this.buildCases();
  }

  private buildCases(): void {
    const list: DeviceCase[] = [];
    list.push(new DeviceCase('状态 — capabilities + 权限概览', 'status', '{}'));
    list.push(new DeviceCase('权限查询 — 四域状态', 'permissions', '{"action":"query"}'));
    list.push(new DeviceCase('权限申请 — 弹系统授权框', 'permissions', '{"action":"request"}'));
    list.push(new DeviceCase('剪贴板写入', 'clipboard', '{"op":"write","text":"harnest-device-test"}'));
    list.push(new DeviceCase('剪贴板读取 — 校验回读', 'clipboard', '{"op":"read"}'));
    list.push(new DeviceCase('沙箱写文件', 'files', '{"op":"sandboxWrite","path":"device-test/hello.txt","text":"hello from device bridge"}'));
    list.push(new DeviceCase('沙箱读文件 — 校验回读', 'files', '{"op":"sandboxRead","path":"device-test/hello.txt"}'));
    list.push(new DeviceCase('沙箱列目录', 'files', '{"op":"sandboxList","path":"device-test"}'));
    list.push(new DeviceCase('文件选择器 — 系统文档选择', 'files', '{"op":"pick"}'));
    list.push(new DeviceCase('相册选择器 — 系统照片选择', 'photos', '{"op":"pick"}'));
    list.push(new DeviceCase('通讯录查询 — 前 20 条', 'contacts', '{"op":"query","limit":20}'));
    list.push(new DeviceCase('通讯录新建 — 测试联系人', 'contacts', '{"op":"create","name":"Harnest 测试","phones":["13800000000"]}'));
    list.push(new DeviceCase('通讯录删除 — 按查询结果', 'contacts', '{"op":"delete","id":"__LAST__"}'));
    list.push(new DeviceCase('日历查询 — 前后 7 天', 'calendar', '{"op":"query"}'));
    list.push(new DeviceCase('日历新建 — 1 小时后事件', 'calendar', '{"op":"create","title":"Harnest 测试事件","notes":"device bridge self test"}'));
    list.push(new DeviceCase('日历删除 — 按新建结果', 'calendar', '{"op":"delete","id":"__LAST__"}'));
    list.push(new DeviceCase('拨号盘 — 预填号码', 'call', '{"op":"dial","number":"13800138000"}'));
    list.push(new DeviceCase('短信 — 预填收件人与内容', 'call', '{"op":"sms","number":"13800138000","body":"harnest test"}'));
    list.push(new DeviceCase('短信读取 — 受限降级说明', 'sms', '{"op":"query","days":30}'));
    list.push(new DeviceCase('邮件 — 拉起撰写界面', 'mail', '{"to":"test@example.com","subject":"Harnest 测试","body":"from device bridge"}'));
    list.push(new DeviceCase('相机 — 系统拍照 UI', 'camera', '{}'));
    list.push(new DeviceCase('录音开始 — 5 秒上限', 'recorder', '{"op":"start","maxSeconds":5}'));
    list.push(new DeviceCase('录音停止 — 返回文件', 'recorder', '{"op":"stop"}'));
    list.push(new DeviceCase('应用列表 — 可启动应用', 'app', '{"op":"list"}'));
    list.push(new DeviceCase('应用打开 — 系统设置', 'app', '{"op":"open","bundleName":"com.huawei.hmos.settings","abilityName":"com.huawei.hmos.settings.MainAbility"}'));
    this.cases = list;
  }

  /** __LAST__ 占位：把上一条 create 返回的 id 填进 delete 用例 */
  private lastId: string = '';

  private async runCase(c: DeviceCase): Promise<void> {
    c.state = '运行中';
    this.notify();
    const started = Date.now();
    try {
      let argsJson = c.argsJson;
      if (argsJson.includes('__LAST__')) {
        if (this.lastId === '') {
          throw new Error('no previous create result to delete');
        }
        argsJson = argsJson.replace('__LAST__', this.lastId);
      }
      const args: Record<string, Object> = argsJson === '{}' ? {} : JSON.parse(argsJson) as Record<string, Object>;
      let result: Record<string, Object>;
      if (this.fullChain) {
        const payload: Record<string, Object> = {};
        payload['op'] = c.op;
        payload['args'] = args;
        const outcome = await HarnessNative.getInstance().call<Record<string, Object>>('deviceSelfTest', payload);
        result = outcome;
      } else {
        result = await HarnessNative.getInstance().deviceBridge().callOp(c.op, args);
      }
      const idVal = result['id'];
      if (typeof idVal === 'string' && idVal !== '') {
        this.lastId = idVal;
      } else if (typeof idVal === 'number') {
        this.lastId = String(idVal);
      }
      c.state = '通过';
      let detail = JSON.stringify(result);
      if (detail.length > 240) {
        detail = detail.substring(0, 240) + '…';
      }
      c.detail = detail + ' (' + (Date.now() - started) + 'ms)';
    } catch (e) {
      c.state = '失败';
      const msg = e instanceof Error ? e.message : JSON.stringify(e);
      c.detail = msg;
    }
    this.notify();
  }

  private async runAll(): Promise<void> {
    if (this.running) {
      return;
    }
    this.running = true;
    if (this.fullChain && !this.engineReady) {
      try {
        const ctx = getContext(this) as common.Context;
        await this.engine.ensureStarted(ctx);
        this.engineReady = true;
      } catch (e) {
        this.running = false;
        const msg = e instanceof Error ? e.message : JSON.stringify(e);
        promptToast('引擎启动失败：' + msg);
        return;
      }
    }
    for (const c of this.cases) {
      await this.runCase(c);
      if (c.name.includes('录音开始')) {
        // 录 3 秒再停，产出非空文件
        await sleep(3000);
      }
    }
    this.running = false;
  }

  private async runOne(c: DeviceCase): Promise<void> {
    if (this.running) {
      return;
    }
    this.running = true;
    if (this.fullChain && !this.engineReady) {
      try {
        const ctx = getContext(this) as common.Context;
        await this.engine.ensureStarted(ctx);
        this.engineReady = true;
      } catch (e) {
        this.running = false;
        const msg = e instanceof Error ? e.message : JSON.stringify(e);
        promptToast('引擎启动失败：' + msg);
        return;
      }
    }
    await this.runCase(c);
    this.running = false;
  }

  private notify(): void {
    this.seq++;
    this.cases = this.cases.slice();
  }

  @Builder
  titleBar() {
    Row() {
      Text('‹').fontSize('22fp').fontColor(this.theme.textPrimary)
        .padding({ left: 12, right: 8 })
        .onClick(() => {
          router.back();
        })
      Text('设备能力自测').fontSize('17fp').fontColor(this.theme.textPrimary)
      Blank()
      Row({ space: 6 }) {
        Text(this.fullChain ? '全链路' : '直连').fontSize('11fp')
          .fontColor(this.fullChain ? this.theme.primary : this.theme.textHint)
        Toggle({ type: ToggleType.Switch, isOn: this.fullChain })
          .onChange((on: boolean) => {
            this.fullChain = on;
          })
      }
    }
    .width('100%')
    .height(52)
    .backgroundColor(this.theme.surface)
    .alignItems(VerticalAlign.Center)
    .border({ width: { bottom: 0.5 }, color: this.theme.divider })
  }

  @Builder
  caseRow(c: DeviceCase, idx: number) {
    Column({ space: 4 }) {
      Row() {
        Text((idx + 1) + '. ' + c.name).fontSize('14fp').fontColor(this.theme.textPrimary)
          .layoutWeight(1)
        Text(c.state).fontSize('12fp')
          .fontColor(c.state === '通过' ? this.theme.success : (c.state === '失败' ? this.theme.error : this.theme.textHint))
          .padding({ left: 8 })
        if (c.state === '待测' && !this.running) {
          Text('▶').fontSize('14fp').fontColor(this.theme.primary)
            .padding({ left: 10 })
            .onClick(() => {
              this.runOne(c);
            })
        }
      }
      .width('100%')

      if (c.detail !== '') {
        Text(c.detail).fontSize('11fp').fontColor(this.theme.textHint)
          .width('100%')
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .borderRadius(10)
    .backgroundColor(this.theme.surface)
    .margin({ left: 16, right: 16, top: 8 })
    .onClick(() => {
      if (!this.running && c.state !== '待测') {
        this.runOne(c);
      }
    })
  }

  build() {
    Column() {
      this.titleBar()
      Row({ space: 10 }) {
        Text(this.fullChain
          ? '全链路：callFunc → QuickJS 桥 → native → DeviceBridge → 回包（需引擎）'
          : '直连：deviceBridge.callOp（免引擎；QuickJS 桥层由全链路覆盖）')
          .fontSize('11fp').fontColor(this.theme.textHint)
          .layoutWeight(1)
          .maxLines(2)
        Button(this.running ? '运行中…' : '全部运行')
          .fontSize('13fp').fontColor(this.theme.textPrimary)
          .backgroundColor(this.theme.surfaceElevated).borderRadius(8)
          .height(36)
          .enabled(!this.running)
          .onClick(() => {
            this.runAll();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 4 })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column() {
          ForEach(this.cases, (c: DeviceCase, idx: number) => {
            this.caseRow(c, idx)
          }, (c: DeviceCase) => c.name + c.state + this.seq)
        }
        .width('100%')
        .padding({ bottom: 24 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%').height('100%')
    .backgroundColor(this.theme.background)
  }
}

function promptToast(msg: string): void {
  promptAction.showToast({ message: msg, duration: 2500 });
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}
