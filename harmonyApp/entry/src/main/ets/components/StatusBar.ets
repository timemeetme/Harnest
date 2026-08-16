import { AppViewModel } from '../viewmodel/AppViewModel';
import { Theme } from '../theme/Theme';
import { ConnectionStatus, WindowWidthClass } from '../model/UiModels';

@Component
export struct StatusBar {
  @ObjectLink viewModel: AppViewModel;

  build() {
    Row({ space: 12 }) {
      this.statusDot();
      Text(this.statusLabel())
        .fontSize(12)
        .fontColor(Theme.Dark.textSecondary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Blank()

      if (this.viewModel.state.isStreaming) {
        Text('● 生成中')
          .fontSize(11)
          .fontColor(Theme.Dark.primary)
      }
      if (this.viewModel.state.widthClass === WindowWidthClass.Expanded ||
          this.viewModel.state.widthClass === WindowWidthClass.Medium) {
        Text('📊')
          .fontSize(14)
          .onClick(() => { this.viewModel.toggleDetails(); })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 6, bottom: 6 })
    .backgroundColor(Theme.Dark.surface)
  }

  @Builder
  statusDot() {
    Circle()
      .width(8)
      .height(8)
      .fill(this.dotColor())
  }

  private dotColor(): string {
    switch (this.viewModel.state.connection.status) {
      case ConnectionStatus.Connected: return Theme.Dark.success;
      case ConnectionStatus.Connecting: return Theme.Dark.warning;
      case ConnectionStatus.Error: return Theme.Dark.error;
      default: return Theme.Dark.textHint;
    }
  }

  private statusLabel(): string {
    const c = this.viewModel.state.connection;
    switch (c.status) {
      case ConnectionStatus.Connected:
        const ver = c.serverVersion ? 'v' + c.serverVersion : '';
        return (c.serverName ?? '内核') + ' ' + ver + ' · ws://' + c.host + ':' + c.port;
      case ConnectionStatus.Connecting: return '正在连接 ws://' + c.host + ':' + c.port + ' …';
      case ConnectionStatus.Error: return '连接失败';
      default: return '未连接';
    }
  }
}
