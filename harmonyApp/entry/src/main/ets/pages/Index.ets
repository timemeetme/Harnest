import { common } from '@kit.AbilityKit';
import { mediaquery } from '@kit.ArkUI';
import { ThemeColors, darkTheme } from '../theme/Theme';
import { KEY_THEME } from '../service/AppearanceService';
import { StorageService } from '../service/StorageService';
import { ConfigService } from '../service/ConfigService';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { ChatView } from '../components/ChatView';
import { DetailsView } from '../components/DetailsView';
import { SettingsView } from '../components/SettingsView';

const TAB_CHAT = 0;
const TAB_DETAILS = 1;
const TAB_SETTINGS = 2;

/**
 * 应用主壳（EMM 式）：手机底部导航 / 宽屏横屏侧边导航。
 * 三 Tab：对话 / 详情 / 设置。Stack 显隐保活，切换不销毁。
 */
@Entry
@Component
struct Index {
  @State viewModel: AppViewModel = new AppViewModel();
  @State tab: number = TAB_CHAT;
  @State isWide: boolean = false;
  @State isLandscape: boolean = false;
  @StorageProp(KEY_THEME) theme: ThemeColors = darkTheme;
  private listener: mediaquery.MediaQueryListener | null = null;
  private landscapeListener: mediaquery.MediaQueryListener | null = null;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    StorageService.get().init(ctx.filesDir);
    ConfigService.get().load();
    this.viewModel.init(ctx);

    // 宽度断点：>=600vp 宽屏；横屏（宽>高）且宽屏才用侧边栏
    this.listener = mediaquery.matchMediaSync('(min-width: 600vp)');
    this.isWide = this.listener.matches;
    this.listener.on('change', (result: mediaquery.MediaQueryResult) => {
      this.isWide = result.matches;
    });
    this.landscapeListener = mediaquery.matchMediaSync('(min-aspect-ratio: 1/1)');
    this.isLandscape = this.landscapeListener.matches;
    this.landscapeListener.on('change', (result: mediaquery.MediaQueryResult) => {
      this.isLandscape = result.matches;
    });
  }

  aboutToDisappear(): void {
    if (this.listener !== null) {
      this.listener.off('change');
    }
    if (this.landscapeListener !== null) {
      this.landscapeListener.off('change');
    }
  }

  build() {
    if (this.isWide && this.isLandscape) {
      Row() {
        this.sideRail()
        Column() {
          this.contentView()
        }
        .layoutWeight(1)
        .height('100%')
      }
      .width('100%').height('100%').backgroundColor(this.theme.background)
    } else {
      Column() {
        Column() {
          this.contentView()
        }
        .layoutWeight(1).width('100%')
        this.bottomNav()
      }
      .width('100%').height('100%').backgroundColor(this.theme.background)
    }
  }

  @Builder
  contentView() {
    Stack() {
      ChatView({
        viewModel: this.viewModel,
        state: this.viewModel.state,
        onGoSettings: () => {
          this.tab = TAB_SETTINGS;
        }
      })
        .visibility(this.tab === TAB_CHAT ? Visibility.Visible : Visibility.Hidden)
        .hitTestBehavior(this.tab === TAB_CHAT ? HitTestMode.Default : HitTestMode.None)

      DetailsView({ state: this.viewModel.state })
        .visibility(this.tab === TAB_DETAILS ? Visibility.Visible : Visibility.Hidden)
        .hitTestBehavior(this.tab === TAB_DETAILS ? HitTestMode.Default : HitTestMode.None)

      SettingsView({
        viewModel: this.viewModel,
        onConfigSaved: () => {
          this.viewModel.onConfigChanged();
        }
      })
        .visibility(this.tab === TAB_SETTINGS ? Visibility.Visible : Visibility.Hidden)
        .hitTestBehavior(this.tab === TAB_SETTINGS ? HitTestMode.Default : HitTestMode.None)
    }
    .width('100%').height('100%')
  }

  @Builder
  sideRail() {
    Column({ space: 4 }) {
      Column() {
        Text('⌘').fontSize('28fp')
        Text('Harness').fontSize('11fp').fontColor(this.theme.textHint).margin({ top: 4 })
      }
      .width('100%').padding({ top: 20, bottom: 20 })

      this.navItem('对话', TAB_CHAT)
      this.navItem('详情', TAB_DETAILS)
      this.navItem('设置', TAB_SETTINGS)

      Blank()

      Text('Harnest App').fontSize('10fp').fontColor(this.theme.textHint).padding({ bottom: 16 })
    }
    .width(96)
    .height('100%')
    .backgroundColor(this.theme.surface)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  bottomNav() {
    Row() {
      this.navItemWide('对话', TAB_CHAT)
      this.navItemWide('详情', TAB_DETAILS)
      this.navItemWide('设置', TAB_SETTINGS)
    }
    .width('100%')
    .height(58)
    .backgroundColor(this.theme.surface)
    .justifyContent(FlexAlign.SpaceAround)
    .border({ width: { top: 0.5 }, color: this.theme.divider })
  }

  @Builder
  navItem(label: string, idx: number) {
    Column() {
      Text(this.glyph(idx)).fontSize('22fp')
        .fontColor(this.tab === idx ? this.theme.primary : this.theme.textHint)
      Text(label).fontSize('11fp')
        .fontColor(this.tab === idx ? this.theme.primary : this.theme.textHint)
        .margin({ top: 2 })
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .borderRadius({ topLeft: 14, topRight: 14 })
    .backgroundColor(this.tab === idx ? this.theme.background : Color.Transparent)
    .onClick(() => {
      this.tab = idx;
    })
  }

  @Builder
  navItemWide(label: string, idx: number) {
    Column() {
      Text(this.glyph(idx)).fontSize('20fp')
        .fontColor(this.tab === idx ? this.theme.primary : this.theme.textHint)
      Text(label).fontSize('11fp')
        .fontColor(this.tab === idx ? this.theme.primary : this.theme.textHint)
        .margin({ top: 3 })
    }
    .padding({ top: 8, bottom: 8 })
    .onClick(() => {
      this.tab = idx;
    })
  }

  private glyph(idx: number): string {
    if (idx === TAB_CHAT) return '💬';
    if (idx === TAB_DETAILS) return '📊';
    return '⚙';
  }
}
