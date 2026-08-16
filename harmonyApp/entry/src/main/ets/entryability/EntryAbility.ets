import { UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const TAG = 'HarnessApp';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want): void {
    hilog.info(0, TAG, 'EntryAbility onCreate');
  }

  onDestroy(): void {
    hilog.info(0, TAG, 'EntryAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err) {
        hilog.error(0, TAG, 'Failed to load content: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(0, TAG, 'Main page loaded successfully');
    });

    try {
      const mainWindow = windowStage.getMainWindow();
      if (mainWindow) {
        mainWindow.setWindowLayoutFullScreen(true);
        const mode = window.ColorMode.COLOR_MODE_DARK;
        mainWindow.setWindowColorMode(mode);
      }
    } catch (e) {
      hilog.warn(0, TAG, 'setWindowColorMode failed: %{public}s', JSON.stringify(e));
    }
  }
}
