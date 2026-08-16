import { AppViewModel } from '../viewmodel/AppViewModel';
import { AppShell } from '../components/AppShell';
import { ConnectionSheet } from '../components/ConnectionSheet';
import { DetailsPanel } from '../components/DetailsPanel';
import { Theme } from '../theme/Theme';
import { WindowWidthClass } from '../model/UiModels';

/**
 * Index — DSH Mobile 入口页面。
 *
 * 职责：
 *   1. 创建并持有唯一的 AppViewModel（@ObjectLink 传递给子组件）。
 *   2. 在根 Column 上监听 onAreaChange，把实际像素宽度传给 ViewModel。
 *   3. 用 bindSheet 管理连接设置、抽屉面板。
 *   4. Compact 断点下提供底部 TabBar 切换侧边功能。
 */
@Entry
@Component
struct Index {
  @State viewModel: AppViewModel = new AppViewModel();
  @State showConnectionSheet: boolean = true;
  @State showSidebarSheet: boolean = false;
  @State showDetailsSheet: boolean = false;

  aboutToDisappear(): void {
    this.viewModel.dispose();
  }

  build() {
    Stack() {
      Column() {
        AppShell({ viewModel: this.viewModel })
          .layoutWeight(1)
          .width('100%')

        this.bottomBar()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.Dark.background)
      .onAreaChange((oldVal: Area, newVal: Area) => {
        const w = Number(newVal.width);
        if (!Number.isNaN(w) && w > 0) {
          this.viewModel.onWindowSizeChanged(w);
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.Dark.background)
    .bindSheet(this.showConnectionSheet, () => {
      ConnectionSheet({ viewModel: this.viewModel })
    }, {
      height: '90%',
      dragBar: true,
      showInSubWindow: false,
      onDisappear: () => { this.showConnectionSheet = false; },
    })
    .bindSheet(this.showSidebarSheet, () => {
      Column() {
        Row({ space: 8 }) {
          Text('会话').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.Dark.textPrimary)
          Blank()
          Button('关闭')
            .type(ButtonType.Normal)
            .height(32)
            .backgroundColor(Theme.Dark.surfaceElevated)
            .fontColor(Theme.Dark.textPrimary)
            .onClick(() => { this.showSidebarSheet = false; })
        }
        .width('100%')
        .padding(12)
        .backgroundColor(Theme.Dark.surface)
        Divider().color(Theme.Dark.divider)
        List() {
          ForEach(this.viewModel.state.sessions, (s) => {
            ListItem() {
              Row({ space: 8 }) {
                Text(s.title || '未命名会话')
                  .fontSize(14)
                  .fontColor(Theme.Dark.textPrimary)
                  .layoutWeight(1)
                if (s.isRunning) {
                  Text('●').fontSize(10).fontColor(Theme.Dark.primary)
                }
              }
              .width('100%')
              .padding(14)
              .backgroundColor(
                this.viewModel.state.activeSessionId === s.id
                  ? Theme.Dark.surfaceElevated
                  : Color.Transparent,
              )
              .onClick(() => {
                this.viewModel.selectSession(s.id);
                this.showSidebarSheet = false;
              })
            }
          }, (s) => s.id)
        }
        .listDirection(Axis.Vertical)
        .layoutWeight(1)
        .width('100%')
        .padding(4)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.Dark.surface)
    }, {
      height: '90%',
      dragBar: true,
      showInSubWindow: false,
      onDisappear: () => { this.showSidebarSheet = false; },
    })
    .bindSheet(this.showDetailsSheet, () => {
      Column() {
        Row({ space: 8 }) {
          Text('详情').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.Dark.textPrimary)
          Blank()
          Button('关闭')
            .type(ButtonType.Normal)
            .height(32)
            .backgroundColor(Theme.Dark.surfaceElevated)
            .fontColor(Theme.Dark.textPrimary)
            .onClick(() => { this.showDetailsSheet = false; })
        }
        .width('100%')
        .padding(12)
        .backgroundColor(Theme.Dark.surface)
        Divider().color(Theme.Dark.divider)
        DetailsPanel({ viewModel: this.viewModel })
          .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.Dark.surface)
    }, {
      height: '90%',
      dragBar: true,
      showInSubWindow: false,
      onDisappear: () => { this.showDetailsSheet = false; },
    })
  }

  @Builder
  bottomBar() {
    const cls = this.viewModel.state.widthClass;
    if (cls === WindowWidthClass.Compact) {
      Row({ space: 0 }) {
        this.bottomBarItem('☰', '会话')
          .layoutWeight(1)
          .onClick(() => { this.showSidebarSheet = true; })
        this.bottomBarItem('🔌', '连接')
          .layoutWeight(1)
          .onClick(() => { this.showConnectionSheet = true; })
        this.bottomBarItem('📊', '详情')
          .layoutWeight(1)
          .onClick(() => { this.showDetailsSheet = true; })
      }
      .width('100%')
      .height(52)
      .backgroundColor(Theme.Dark.surface)
      .border({ width: { top: 1 }, color: Theme.Dark.divider })
      .justifyContent(FlexAlign.SpaceAround)
      .alignItems(VerticalAlign.Center)
    }
  }

  @Builder
  bottomBarItem(icon: string, label: string) {
    Column({ space: 2 }) {
      Text(icon).fontSize(20)
      Text(label).fontSize(11).fontColor(Theme.Dark.textSecondary)
    }
    .padding(6)
    .alignItems(HorizontalAlign.Center)
  }
}
