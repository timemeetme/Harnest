import { AppViewModel } from '../viewmodel/AppViewModel';
import { Theme } from '../theme/Theme';
import { ConnectionStatus } from '../model/UiModels';

@Component
export struct Sidebar {
  @ObjectLink viewModel: AppViewModel;

  build() {
    Column() {
      this.header();
      Divider().color(Theme.Dark.divider);
      this.sessionList();
      Divider().color(Theme.Dark.divider);
      this.footer();
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.Dark.surface)
  }

  @Builder
  header() {
    Row({ space: 8 }) {
      Text('DSH')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.Dark.primary);
      Text('Harness')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.Dark.textPrimary);
    }
    .width('100%')
    .padding({ left: 16, right: 12, top: 16, bottom: 12 })
    .justifyContent(FlexAlign.Start)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  sessionList() {
    Column() {
      Row() {
        Text('会话')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.Dark.textSecondary)
        Blank()
        Button('+ 新建')
          .type(ButtonType.Normal)
          .fontSize(12)
          .height(28)
          .padding({ left: 10, right: 10 })
          .backgroundColor(Theme.Dark.primary)
          .fontColor(Theme.Dark.primaryOn)
          .onClick(() => { this.viewModel.newSession(); })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 6 })

      List({ space: 2 }) {
        ForEach(this.viewModel.state.sessions, (s, i) => {
          ListItem() {
            this.sessionItem(i)
          }
        }, (s) => s.id)
      }
      .listDirection(Axis.Vertical)
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 8, right: 8 })
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  sessionItem(index: number) {
    const session = this.viewModel.state.sessions[index];
    Row({ space: 8 }) {
      Column() {
        Text(session.title || '未命名会话')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.viewModel.state.activeSessionId === session.id
            ? Theme.Dark.primary : Theme.Dark.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(session.messageCount + ' 条消息')
          .fontSize(11)
          .fontColor(Theme.Dark.textHint)
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (session.isRunning) {
        Text('●')
          .fontSize(10)
          .fontColor(Theme.Dark.primary)
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .borderRadius(8)
    .backgroundColor(
      this.viewModel.state.activeSessionId === session.id
        ? Theme.Dark.surfaceElevated
        : Color.Transparent,
    )
    .onClick(() => { this.viewModel.selectSession(session.id); })
  }

  @Builder
  footer() {
    Row({ space: 8 }) {
      Circle()
        .width(8)
        .height(8)
        .fill(this.connectionColor())
      Text(this.connectionText())
        .fontSize(12)
        .fontColor(Theme.Dark.textSecondary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 14 })
    .alignItems(VerticalAlign.Center)
  }

  private connectionColor(): string {
    switch (this.viewModel.state.connection.status) {
      case ConnectionStatus.Connected: return Theme.Dark.success;
      case ConnectionStatus.Connecting: return Theme.Dark.warning;
      case ConnectionStatus.Error: return Theme.Dark.error;
      default: return Theme.Dark.textHint;
    }
  }

  private connectionText(): string {
    const c = this.viewModel.state.connection;
    if (c.status === ConnectionStatus.Connected) {
      const ver = c.serverVersion ? ' v' + c.serverVersion : '';
      return (c.serverName ?? '内核') + ver;
    }
    if (c.status === ConnectionStatus.Connecting) return '连接中…';
    if (c.status === ConnectionStatus.Error) return '连接失败';
    return '未连接';
  }
}
