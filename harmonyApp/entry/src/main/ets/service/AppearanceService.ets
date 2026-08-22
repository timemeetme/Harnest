import { common, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { resourceManager } from '@kit.LocalizationKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ThemeColors, darkTheme, lightTheme } from '../theme/Theme';

const TAG = 'AppearanceService';
const DOMAIN = 0x0306;

export type AppearanceMode = 'system' | 'light' | 'dark';

export const APPEARANCE_MODES: AppearanceMode[] = ['system', 'light', 'dark'];

export function appearanceLabel(m: AppearanceMode): string {
  return m === 'system' ? '跟随系统' : m === 'light' ? '浅色' : '深色';
}

/** AppStorage keys（组件经 @StorageProp 订阅，实现全 UI 即时换肤） */
export const KEY_THEME = 'harnestTheme';
export const KEY_APPEARANCE = 'harnestAppearance';

/**
 * 外观服务（单例，EMM 式）：深色 / 浅色 / 跟随系统。
 * - ApplicationContext.setColorMode 驱动系统资源与深浅色配置；
 * - AppStorage 发布当前 ThemeColors，组件 @StorageProp 订阅换肤；
 * - filesDir 文本文件持久化（key 语义与 iOS harnest.appearance 一致）。
 */
export class AppearanceService {
  private static inst: AppearanceService | null = null;
  private ctx: common.Context | null = null;
  private file: string = '';
  private systemDark: boolean = true;
  private win: window.Window | null = null;
  mode: AppearanceMode = 'system';
  useDark: boolean = true;

  static get(): AppearanceService {
    if (AppearanceService.inst === null) {
      AppearanceService.inst = new AppearanceService();
    }
    return AppearanceService.inst;
  }

  /** EntryAbility.onWindowStageCreate 中、loadContent 之前调用 */
  init(ctx: common.Context): void {
    this.ctx = ctx;
    this.file = ctx.filesDir + '/harnest_appearance.txt';
    // 必须在 setColorMode 之前读系统深浅色，否则读到的是本应用覆盖值
    this.systemDark = this.readSystemDark();
    try {
      if (fileIo.accessSync(this.file)) {
        const raw: string = fileIo.readTextSync(this.file).trim();
        this.mode = (APPEARANCE_MODES as string[]).indexOf(raw) >= 0 ? raw as AppearanceMode : 'system';
      }
    } catch (_e) {
      // 读取失败回退跟随系统
    }
    this.apply();
    hilog.info(DOMAIN, TAG, 'init mode=%{public}s useDark=%{public}s', this.mode, this.useDark.toString());
  }

  set(mode: AppearanceMode): void {
    if (this.mode === mode) {
      return;
    }
    this.mode = mode;
    try {
      const f = fileIo.openSync(this.file, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, mode);
      fileIo.closeSync(f);
    } catch (_e) {
      // 持久化失败不影响本次会话生效
    }
    this.apply();
  }

  /** 系统深浅色变化（EntryAbility.onConfigurationUpdate 转发） */
  onSystemColorMode(colorMode: number): void {
    this.systemDark = colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    if (this.mode === 'system' && this.systemDark !== this.useDark) {
      this.useDark = this.systemDark;
      this.publish();
    }
  }

  private apply(): void {
    const wanted: number = this.mode === 'dark'
      ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
      : this.mode === 'light'
        ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
        : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    try {
      const appCtx = this.ctx !== null ? this.ctx.getApplicationContext() : undefined;
      if (appCtx !== undefined && appCtx.setColorMode !== undefined) {
        appCtx.setColorMode(wanted);
      }
    } catch (_e) {
      hilog.warn(DOMAIN, TAG, 'setColorMode failed');
    }
    this.useDark = this.mode === 'dark'
      ? true
      : this.mode === 'light'
        ? false
        : this.systemDark;
    this.publish();
  }

  /** 经 resourceManager 读系统当前深浅色（与 setColorMode 覆盖值无关） */
  private readSystemDark(): boolean {
    try {
      if (this.ctx === null) {
        return true;
      }
      const conf: resourceManager.Configuration = this.ctx.resourceManager.getConfigurationSync();
      return conf.colorMode === resourceManager.ColorMode.DARK;
    } catch (_e) {
      return true;
    }
  }

  private publish(): void {
    AppStorage.setOrCreate(KEY_THEME, this.useDark ? darkTheme : lightTheme);
    AppStorage.setOrCreate(KEY_APPEARANCE, this.mode);
    this.syncWindow();
  }

  /**
   * 窗口底色与状态栏前景色跟随当前主题。
   * 非全屏布局下状态栏区域露出的是窗口默认底色（系统黑白），须显式刷成主题色板。
   * EntryAbility loadContent 完成后请再调用一次，保证冷启动首帧即正确。
   */
  syncWindow(): void {
    if (this.ctx === null) {
      return;
    }
    const apply = (w: window.Window): void => {
      const t: ThemeColors = this.useDark ? darkTheme : lightTheme;
      try {
        w.setWindowBackgroundColor(t.background);
        w.setWindowSystemBarProperties({ statusBarContentColor: t.textPrimary })
          .catch(() => hilog.warn(DOMAIN, TAG, 'setWindowSystemBarProperties failed'));
      } catch (_e) {
        hilog.warn(DOMAIN, TAG, 'syncWindow apply failed');
      }
    };
    if (this.win !== null) {
      apply(this.win);
      return;
    }
    window.getLastWindow(this.ctx)
      .then((w: window.Window) => {
        this.win = w;
        apply(w);
      })
      .catch(() => hilog.warn(DOMAIN, TAG, 'getLastWindow failed (window not ready)'));
  }
}

/** 供 EntryAbility.onConfigurationUpdate 使用 */
export function isDarkConfiguration(conf: Configuration): boolean {
  return conf.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
}
