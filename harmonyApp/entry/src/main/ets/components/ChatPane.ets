import { AppViewModel } from '../viewmodel/AppViewModel';
import { Theme } from '../theme/Theme';
import { MessageRole } from '../model/UiModels';

@Component
export struct ChatPane {
  @ObjectLink viewModel: AppViewModel;
  scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    setTimeout(() => { this.scroller.scrollEdge(Edge.Bottom); }, 50);
  }

  build() {
    Column() {
      this.goalBar();
      Divider().color(Theme.Dark.divider);
      this.messageList();
      Divider().color(Theme.Dark.divider);
      this.inputBarSlot();
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.Dark.background)
  }

  @Builder
  goalBar() {
    Row({ space: 8 }) {
      Text('🎯')
        .fontSize(16)
      Text(this.viewModel.state.goal.active
        ? this.viewModel.state.goal.text
        : '设置你的目标，让 DSH 为你工作…')
        .fontSize(13)
        .fontColor(this.viewModel.state.goal.active
          ? Theme.Dark.textPrimary : Theme.Dark.textHint)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 10 })
    .backgroundColor(Theme.Dark.surface)
  }

  @Builder
  messageList() {
    Scroll(this.scroller) {
      Column({ space: 10 }) {
        if (this.viewModel.state.messages.length === 0) {
          this.emptyState()
        }
        ForEach(this.viewModel.state.messages, (msg, i) => {
          this.messageItem(i)
        }, (msg) => msg.id)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 16 })
    }
    .layoutWeight(1)
    .width('100%')
    .scrollBar(BarState.Off)
    .onScroll(() => {
      // no-op, just expose scroller
    })
  }

  @Builder
  emptyState() {
    Column({ space: 12 }) {
      Text('🤖')
        .fontSize(48)
      Text('DSH Harness')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.Dark.textPrimary)
      Text('连接到 DSH 内核，开始你的第一个任务')
        .fontSize(13)
        .fontColor(Theme.Dark.textSecondary)
      Text('点击左侧未连接状态 → 输入 Host / Port / Model 连接')
        .fontSize(12)
        .fontColor(Theme.Dark.textHint)
    }
    .width('100%')
    .margin({ top: 40 })
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  messageItem(index: number) {
    const msg = this.viewModel.state.messages[index];
    const isUser = msg.role === MessageRole.User;
    Row() {
      if (isUser) { Blank(); }
      Column() {
        Text(msg.content || ' ')
          .fontSize(14)
          .fontColor(Theme.Dark.textPrimary)
          .padding(12)
          .borderRadius(12)
          .backgroundColor(isUser ? Theme.Dark.userBubble : Theme.Dark.assistantBubble)
          .constraintSize({ maxWidth: '85%' })
          .markDirty()
        if (msg.isStreaming) {
          Text('✦ 生成中…')
            .fontSize(11)
            .fontColor(Theme.Dark.textHint)
            .margin({ top: 4, left: isUser ? 0 : 4 })
        }
      }
      .alignItems(isUser ? HorizontalAlign.End : HorizontalAlign.Start)
      if (!isUser) { Blank(); }
    }
    .width('100%')
    .justifyContent(isUser ? FlexAlign.End : FlexAlign.Start)
  }

  @Builder
  inputBarSlot() {
    // 留空 —— InputBar 由 AppShell 组合决定。
    // 这里的 messageList 下方已经可以直接放 InputBar。
  }
}
