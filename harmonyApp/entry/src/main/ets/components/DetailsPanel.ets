import { AppViewModel } from '../viewmodel/AppViewModel';
import { Theme } from '../theme/Theme';
import { DetailsTab, SubagentStatus, PlanStatus } from '../model/UiModels';

@Component
export struct DetailsPanel {
  @ObjectLink viewModel: AppViewModel;

  build() {
    Column() {
      this.tabs();
      Divider().color(Theme.Dark.divider);
      this.tabContent();
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.Dark.surface)
  }

  @Builder
  tabs() {
    Row({ space: 4 }) {
      this.tabButton('工具', DetailsTab.Tools, '🛠');
      this.tabButton('计划', DetailsTab.Plan, '📋');
      this.tabButton('Todo', DetailsTab.Todo, '✅');
      this.tabButton('子代理', DetailsTab.Subagents, '🤝');
      this.tabButton('设置', DetailsTab.Settings, '⚙️');
    }
    .width('100%')
    .padding(10)
    .justifyContent(FlexAlign.Start)
  }

  @Builder
  tabButton(label: string, tab: DetailsTab, icon: string) {
    const active = this.viewModel.state.detailsTab === tab;
    Button(icon + ' ' + label)
      .type(ButtonType.Normal)
      .fontSize(12)
      .height(32)
      .padding({ left: 10, right: 10 })
      .backgroundColor(active ? Theme.Dark.surfaceElevated : Color.Transparent)
      .fontColor(active ? Theme.Dark.primary : Theme.Dark.textSecondary)
      .borderRadius(8)
      .onClick(() => { this.viewModel.selectDetailsTab(tab); })
  }

  @Builder
  tabContent() {
    Scroll() {
      Column() {
        if (this.viewModel.state.detailsTab === DetailsTab.Tools) {
          this.toolsContent();
        } else if (this.viewModel.state.detailsTab === DetailsTab.Plan) {
          this.planContent();
        } else if (this.viewModel.state.detailsTab === DetailsTab.Todo) {
          this.todoContent();
        } else if (this.viewModel.state.detailsTab === DetailsTab.Subagents) {
          this.subagentsContent();
        } else {
          this.settingsContent();
        }
      }
      .width('100%')
      .padding(12)
    }
    .layoutWeight(1)
    .width('100%')
    .scrollBar(BarState.Auto)
  }

  @Builder
  toolsContent() {
    this.sectionHeader('工具调用');
    Text('暂无工具调用记录')
      .fontSize(12)
      .fontColor(Theme.Dark.textHint)
      .padding({ top: 6 })
  }

  @Builder
  planContent() {
    this.sectionHeader('执行计划');
    if (this.viewModel.state.plan.length === 0) {
      Text('暂无计划')
        .fontSize(12)
        .fontColor(Theme.Dark.textHint)
        .padding({ top: 6 })
    } else {
      ForEach(this.viewModel.state.plan, (p) => {
        this.planRow(p.title, p.status);
      }, (p) => p.id)
    }
  }

  @Builder
  planRow(title: string, status: PlanStatus) {
    const color = this.planColor(status);
    Row({ space: 8 }) {
      Circle().width(8).height(8).fill(color)
      Text(title)
        .fontSize(13)
        .fontColor(Theme.Dark.textPrimary)
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 6, bottom: 6 })
  }

  private planColor(status: PlanStatus): string {
    switch (status) {
      case PlanStatus.Done: return Theme.Dark.success;
      case PlanStatus.InProgress: return Theme.Dark.primary;
      case PlanStatus.Blocked: return Theme.Dark.error;
      default: return Theme.Dark.textHint;
    }
  }

  @Builder
  todoContent() {
    this.sectionHeader('待办事项');
    if (this.viewModel.state.todos.length === 0) {
      Text('暂无待办')
        .fontSize(12)
        .fontColor(Theme.Dark.textHint)
        .padding({ top: 6 })
    } else {
      ForEach(this.viewModel.state.todos, (t, i) => {
        Row({ space: 8 }) {
          Checkbox()
            .select(t.done)
            .onChange((v: boolean) => {
              this.viewModel.toggleTodo(this.viewModel.state.todos[i].id);
            })
          Text(t.content)
            .fontSize(13)
            .fontColor(t.done ? Theme.Dark.textHint : Theme.Dark.textPrimary)
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ top: 4, bottom: 4 })
      }, (t) => t.id)
    }
  }

  @Builder
  subagentsContent() {
    this.sectionHeader('子代理');
    if (this.viewModel.state.subagents.length === 0) {
      Text('当前没有运行中的子代理')
        .fontSize(12)
        .fontColor(Theme.Dark.textHint)
        .padding({ top: 6 })
    } else {
      ForEach(this.viewModel.state.subagents, (s) => {
        Row({ space: 8 }) {
          Circle()
            .width(8)
            .height(8)
            .fill(s.status === SubagentStatus.Running
              ? Theme.Dark.primary
              : Theme.Dark.textHint)
          Column() {
            Text(s.name)
              .fontSize(13)
              .fontColor(Theme.Dark.textPrimary)
            Text('parent: ' + (s.parentSessionId ?? '-'))
              .fontSize(11)
              .fontColor(Theme.Dark.textHint)
          }
          .layoutWeight(1)
        }
        .width('100%')
        .padding({ top: 6, bottom: 6 })
      }, (s) => s.id)
    }
  }

  @Builder
  settingsContent() {
    this.sectionHeader('连接设置');
    Column({ space: 8 }) {
      Row() {
        Text('Provider').width(80).fontSize(13).fontColor(Theme.Dark.textSecondary)
        Text(this.viewModel.state.connection.provider)
          .fontSize(13)
          .fontColor(Theme.Dark.textPrimary)
          .layoutWeight(1)
      }
      Row() {
        Text('Model').width(80).fontSize(13).fontColor(Theme.Dark.textSecondary)
        Text(this.viewModel.state.connection.model)
          .fontSize(13)
          .fontColor(Theme.Dark.textPrimary)
          .layoutWeight(1)
      }
      Row() {
        Text('Host').width(80).fontSize(13).fontColor(Theme.Dark.textSecondary)
        Text(this.viewModel.state.connection.host + ':' + this.viewModel.state.connection.port)
          .fontSize(13)
          .fontColor(Theme.Dark.textPrimary)
          .layoutWeight(1)
      }
    }
    .width('100%')
    .padding(8)
    .backgroundColor(Theme.Dark.surfaceElevated)
    .borderRadius(8)

    Button('断开连接')
      .width('100%')
      .margin({ top: 12 })
      .backgroundColor(Theme.Dark.error)
      .fontColor(Theme.Dark.textPrimary)
      .onClick(() => { this.viewModel.disconnectKernel(); })
  }

  @Builder
  sectionHeader(title: string) {
    Text(title)
      .fontSize(11)
      .fontWeight(FontWeight.Medium)
      .fontColor(Theme.Dark.textHint)
      .width('100%')
      .padding({ top: 6, bottom: 4, left: 4 })
  }
}
