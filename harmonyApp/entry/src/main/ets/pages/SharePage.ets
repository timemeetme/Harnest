import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { darkTheme, ThemeColors } from '../theme/Theme';
import { KEY_THEME } from '../service/AppearanceService';

@Entry
@Component
struct SharePage {
  @StorageLink('sharedText') sharedText: string = ''
  @StorageLink('sharedFilePath') sharedFilePath: string = ''
  @StorageProp(KEY_THEME) theme: ThemeColors = darkTheme;

  build() {
    Column() {
      Text('分享内容已接收')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.theme.textPrimary)
        .margin({ top: 20, bottom: 20 })

      if (this.sharedText) {
        Text('文本内容:')
          .fontSize(14)
          .fontColor(this.theme.textSecondary)
          .margin({ bottom: 8 })
        Text(this.sharedText)
          .fontSize(16)
          .fontColor(this.theme.textPrimary)
          .width('90%')
          .padding(12)
          .backgroundColor(this.theme.surface)
          .borderRadius(8)
          .margin({ bottom: 16 })
      }

      if (this.sharedFilePath) {
        Text('文件路径:')
          .fontSize(14)
          .fontColor(this.theme.textSecondary)
          .margin({ bottom: 8 })
        Text(this.sharedFilePath)
          .fontSize(14)
          .fontColor(this.theme.textPrimary)
          .width('90%')
          .padding(12)
          .backgroundColor(this.theme.surface)
          .borderRadius(8)
          .margin({ bottom: 16 })
      }

      Button('发送到对话')
        .width('60%')
        .height(44)
        .backgroundColor(this.theme.primary)
        .onClick(() => {
          promptAction.showToast({ message: '已发送到对话' });
          router.back();
        })

      Button('关闭')
        .width('60%')
        .height(44)
        .margin({ top: 12 })
        .backgroundColor(this.theme.surface)
        .fontColor(this.theme.textPrimary)
        .onClick(() => {
          router.back();
        })
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor(this.theme.background)
  }
}
