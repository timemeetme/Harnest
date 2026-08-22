import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import fs from '@ohos.file.fs';
import util from '@ohos.util';

const TAG = 'ShareAbility';
const DOMAIN = 0x0000;

export default class ShareAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'ShareAbility onCreate');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'ShareAbility onWindowStageCreate');
    windowStage.loadContent('pages/SharePage', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
      }
    });
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'ShareAbility onNewWant');
    this.handleShare(want);
  }

  private handleShare(want: Want): void {
    try {
      const uri = want.uri;
      const params = want.parameters as Record<string, Object> | undefined;
      let text = '';
      let filePath = '';

      if (params && params['ohos.ability.params.share.text']) {
        text = params['ohos.ability.params.share.text'] as string;
      }
      if (params && params['ohos.ability.params.share.title']) {
        text = (params['ohos.ability.params.share.title'] as string) + '\n' + text;
      }

      if (uri) {
        const cacheDir = this.context.cacheDir;
        const fileName = 'share_' + Date.now() + '.tmp';
        filePath = cacheDir + '/' + fileName;
        try {
          const srcFd = fs.openSync(uri, fs.OpenMode.READ_ONLY);
          const dstFd = fs.openSync(filePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
          fs.copyFileSync(srcFd.fd, dstFd.fd);
          fs.closeSync(srcFd);
          fs.closeSync(dstFd);
        } catch (e) {
          hilog.error(DOMAIN, TAG, 'copy shared file failed: %{public}s', JSON.stringify(e));
        }
      }

      AppStorage.setOrCreate('sharedText', text);
      AppStorage.setOrCreate('sharedFilePath', filePath);
      hilog.info(DOMAIN, TAG, 'share handled, text: %{public}s, file: %{public}s', text, filePath);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'handleShare failed: %{public}s', JSON.stringify(e));
    }
  }
}
