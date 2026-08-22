import { UIAbility, Configuration } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window, KeyboardAvoidMode } from '@kit.ArkUI';
import { AppearanceService } from '../service/AppearanceService';

const TAG = 'HarnessApp';

export default class EntryAbility extends UIAbility {
  onCreate() {
    hilog.info(0x0000, TAG, 'EntryAbility onCreate');
  }

  onDestroy() {
    hilog.info(0x0000, TAG, 'EntryAbility onDestroy');
  }

  /** 系统深浅色切换：转发给外观服务（仅“跟随系统”模式响应） */
  onConfigurationUpdate(newConfig: Configuration): void {
    hilog.info(0x0000, TAG, 'onConfigurationUpdate colorMode=%{public}d',
      newConfig.colorMode === undefined ? -1 : newConfig.colorMode);
    if (newConfig.colorMode !== undefined) {
      AppearanceService.get().onSystemColorMode(newConfig.colorMode);
    }
  }

  async onWindowStageCreate(windowStage: window.WindowStage) {
    hilog.info(0x0000, TAG, 'onWindowStageCreate');
    // 外观初始化必须在 loadContent 之前：首帧即用正确色板
    AppearanceService.get().init(this.context);
    // 注意：setWindowLayoutFullScreen(true) 会导致首个子组件被安全区避让压缩测量，
    // 状态栏子树静默不渲染（x7/Pura90 两台模拟器复现）。如需沉浸式需另行验证。
    try {
      const mainWindow = windowStage.getMainWindowSync();
      await mainWindow.setWindowLayoutFullScreen(false);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'window setup failed: %{public}s', JSON.stringify(e));
    }
    hilog.info(0x0000, TAG, 'calling loadContent pages/Index...');
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, TAG, 'loadContent FAILED code=%{public}d msg=%{public}s name=%{public}s', err.code, err.message, err.name);
        hilog.error(0x0000, TAG, 'loadContent FAILED full: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(0x0000, TAG, 'Main page loaded successfully');
      // 键盘避让必须在 loadContent 之后设置才生效（参考 EyeMouthMind §8.1 踩坑）
      try {
        const win = windowStage.getMainWindowSync();
        win.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
        hilog.info(0x0000, TAG, 'KeyboardAvoidMode.RESIZE set');
      } catch (e) {
        hilog.warn(0x0000, TAG, 'setKeyboardAvoidMode failed: %{public}s', JSON.stringify(e));
      }
      // 窗口就绪后重刷底色/状态栏，覆盖 init 阶段 getLastWindow 未就绪的情况
      AppearanceService.get().syncWindow();
    });
  }
}
