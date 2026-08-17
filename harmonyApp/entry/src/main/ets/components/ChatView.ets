import { ThemeColors, darkTheme } from '../theme/Theme';
import { UiState, ChatMessage, MessageRole, SessionUi } from '../model/UiModels';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { ProviderConfig } from '../service/ConfigService';
import { TodoSnapshotItem } from '../service/HarnessNative';

/**
 * 对话页：会话抽屉 + 消息流 + 模型选择器（TRAE 式）。
 * 模型选择按对话粒度保存；选择器展示已配置 key 的 provider 及其模型。
 */
@Component
export struct ChatView {
  @ObjectLink @Watch('onStateChanged') state: UiState;
  viewModel: AppViewModel = new AppViewModel();
  onGoSettings: () => void = () => {};
  private theme: ThemeColors = darkTheme;
  @State inputText: string = '';
  @State showSessions: boolean = false;
  @State showModelPicker: boolean = false;
  @State providerList: ProviderConfig[] = [];
  private scroller: Scroller = new Scroller();

  onStateChanged(): void {
    this.scroller.scrollEdge(Edge.Bottom);
  }

  build() {
    Column() {
      this.topBar()
      if (this.state.needsConfig) {
        this.configBanner()
      }
      Stack({ alignContent: Alignment.Bottom }) {
        Column() {
          this.messageList()
          this.inputArea()
        }
        .width('100%').height('100%')

        // 模型选择器（输入区上方弹出）
        if (this.showModelPicker) {
          this.modelPicker()
        }
      }
      .layoutWeight(1)
      .width('100%')

      // 会话抽屉（全屏遮罩）
      if (this.showSessions) {
        this.sessionsDrawer()
      }
    }
    .width('100%').height('100%')
    .backgroundColor(this.theme.background)
  }

  // ── 顶栏 ────────────────────────────────────────────────────

  @Builder
  topBar() {
    Row() {
      Text('☰').fontSize('20fp')
        .fontColor(this.theme.textPrimary)
        .padding({ left: 12, right: 8, top: 8, bottom: 8 })
        .onClick(() => {
          this.showSessions = true;
        })

      Column() {
        Text(this.activeTitle()).fontSize('16fp').fontColor(this.theme.textPrimary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.state.engineStatus).fontSize('10fp').fontColor(this.theme.textHint)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('＋').fontSize('20fp')
        .fontColor(this.theme.textPrimary)
        .padding({ left: 8, right: 12, top: 8, bottom: 8 })
        .onClick(() => {
          this.viewModel.newSession();
        })
    }
    .width('100%')
    .height(52)
    .backgroundColor(this.theme.surface)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  configBanner() {
    Row() {
      Text('未配置大模型 API，内核无法发起对话').fontSize('13fp')
        .fontColor(this.theme.warning).layoutWeight(1)
      Text('去设置').fontSize('13fp').fontColor(this.theme.primary)
        .padding(8)
        .onClick(() => {
          this.onGoSettings();
        })
    }
    .width('100%')
    .padding({ left: 12, right: 4, top: 8, bottom: 8 })
    .backgroundColor(this.theme.surface)
    .border({ width: { bottom: 0.5 }, color: this.theme.divider })
  }

  // ── 消息列表 ────────────────────────────────────────────────

  @Builder
  messageList() {
    if (this.state.messages.length === 0) {
      Column() {
        Text('🤖').fontSize('40fp').margin({ bottom: 8 })
        Text('开始新的对话').fontSize('15fp').fontColor(this.theme.textSecondary)
        Text('模型与 API 均在本机内核中运行').fontSize('11fp')
          .fontColor(this.theme.textHint).margin({ top: 4 })
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else {
      List({ scroller: this.scroller, space: 8 }) {
        ForEach(this.state.messages, (m: ChatMessage) => {
          ListItem() {
            this.messageBubble(m)
          }
        }, (m: ChatMessage) => m.id)
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 12, right: 12, top: 12 })
      .scrollBar(BarState.Off)
    }
  }

  @Builder
  messageBubble(m: ChatMessage) {
    if (m.role === MessageRole.User) {
      Column() {
        Text(m.content).fontSize('15fp').fontColor(this.theme.textPrimary)
      }
      .constraintSize({ maxWidth: '80%' })
      .padding(12)
      .borderRadius(12)
      .backgroundColor(this.theme.userBubble)
      .alignSelf(ItemAlign.End)
    } else if (m.role === MessageRole.Tool) {
      this.toolBubble(m)
    } else {
      Column({ space: 4 }) {
        if (m.model !== null && m.model !== undefined && m.model.length > 0) {
          Text(this.viewModel.providerLabel(m.provider ?? '') + ' · ' + m.model)
            .fontSize('10fp')
            .fontColor(m.isError ? this.theme.error : this.theme.textHint)
        }
        Text(m.content).fontSize('15fp')
          .fontColor(m.isError ? this.theme.error : this.theme.textPrimary)
      }
      .constraintSize({ maxWidth: '86%' })
      .padding(12)
      .borderRadius(12)
      .backgroundColor(this.theme.assistantBubble)
      .alignSelf(ItemAlign.Start)
    }
  }

  /** 工具消息气泡：工具名 + 状态 +（todo_write 整表快照 | 结果预览） */
  @Builder
  toolBubble(m: ChatMessage) {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Text('⚙').fontSize('12fp')
          .fontColor(m.toolStatus === 'error' ? this.theme.error : this.theme.primary)
        Text(m.toolName).fontSize('12fp')
          .fontColor(this.theme.textPrimary)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.toolStatusLabel(m.toolStatus)).fontSize('10fp')
          .fontColor(this.toolStatusColor(m.toolStatus))
      }
      .width('100%')

      if (m.todosJson.length > 0) {
        Column({ space: 5 }) {
          ForEach(this.parseTodos(m.todosJson), (t: TodoSnapshotItem, idx: number) => {
            Row({ space: 7 }) {
              Text(this.todoGlyph(t.status)).fontSize('12fp')
                .fontColor(t.status === 'completed' ? this.theme.success
                  : (t.status === 'in_progress' ? this.theme.primary : this.theme.textHint))
              Text(t.content).fontSize('12fp')
                .fontColor(t.status === 'completed' ? this.theme.textHint : this.theme.textPrimary)
                .layoutWeight(1)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          }, (t: TodoSnapshotItem, idx: number) => m.id + '_' + idx)
        }
        .width('100%')
      } else if (m.toolResult.length > 0) {
        Text(m.toolResult).fontSize('11fp')
          .fontColor(m.toolStatus === 'error' ? this.theme.error : this.theme.textHint)
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
    }
    .constraintSize({ maxWidth: '86%' })
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(10)
    .backgroundColor(this.theme.surfaceElevated)
    .border({
      width: { left: 2 },
      color: m.toolStatus === 'error' ? this.theme.error
        : (m.toolStatus === 'running' ? this.theme.warning : this.theme.divider)
    })
    .alignSelf(ItemAlign.Start)
  }

  // ── 输入区（含模型 chip） ────────────────────────────────────

  @Builder
  inputArea() {
    Column({ space: 6 }) {
      Row() {
        // 模型 chip：当前会话的模型选择（对话粒度保存）
        Row({ space: 4 }) {
          Text(this.viewModel.providerLabel(this.activeProvider()) + ' · ' + this.activeModel())
            .fontSize('12fp')
            .fontColor(this.theme.textPrimary)
            .maxLines(1)
            .constraintSize({ maxWidth: 220 })
          Text('▾').fontSize('10fp').fontColor(this.theme.textHint)
        }
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .borderRadius(14)
        .backgroundColor(this.theme.surfaceElevated)
        .onClick(() => {
          this.providerList = this.viewModel.usableProviders();
          this.showModelPicker = !this.showModelPicker;
        })

        if (this.state.isSending) {
          Text('回复中…').fontSize('11fp').fontColor(this.theme.textHint)
            .margin({ left: 8 })
        }
      }
      .width('100%')

      Row({ space: 8 }) {
        TextArea({ text: this.inputText, placeholder: '发送消息…' })
          .fontSize('15fp')
          .fontColor(this.theme.textPrimary)
          .placeholderColor(this.theme.textHint)
          .backgroundColor(this.theme.surface)
          .borderRadius(12)
          .constraintSize({ minHeight: 42, maxHeight: 120 })
          .layoutWeight(1)
          .onChange((v: string) => {
            this.inputText = v;
          })

        Button(this.state.isSending ? '…' : '发送')
          .fontSize('14fp')
          .fontColor(this.theme.primaryOn)
          .backgroundColor(this.state.isSending || this.inputText.trim().length === 0
            ? this.theme.divider : this.theme.primary)
          .borderRadius(10)
          .height(42)
          .padding({ left: 14, right: 14 })
          .enabled(!this.state.isSending && this.inputText.trim().length > 0)
          .onClick(() => {
            this.send();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 10 })
    .backgroundColor(this.theme.surface)
    .border({ width: { top: 0.5 }, color: this.theme.divider })
  }

  @Builder
  modelPicker() {
    Column() {
      // 空白区点击关闭
      Column()
        .width('100%')
        .layoutWeight(0)
        .onClick(() => {
          this.showModelPicker = false;
        })

      Scroll() {
        Column({ space: 2 }) {
          ForEach(this.providerList, (p: ProviderConfig) => {
            Column({ space: 2 }) {
              Text(this.viewModel.providerLabel(p.provider)).fontSize('11fp')
                .fontColor(this.theme.textHint)
                .padding({ top: 8, bottom: 4, left: 12 })
              ForEach(p.models, (model: string) => {
                Row() {
                  Text(model).fontSize('14fp')
                    .fontColor(this.isActiveModel(p.provider, model)
                      ? this.theme.primary : this.theme.textPrimary)
                    .layoutWeight(1)
                  if (this.isActiveModel(p.provider, model)) {
                    Text('✓').fontSize('14fp').fontColor(this.theme.primary)
                  }
                }
                .width('100%')
                .padding({ left: 20, right: 12, top: 9, bottom: 9 })
                .borderRadius(8)
                .onClick(() => {
                  this.viewModel.setSessionModel(p.provider, model);
                  this.showModelPicker = false;
                })
              }, (model: string) => p.provider + '/' + model)
            }
            .width('100%')
          }, (p: ProviderConfig) => p.provider)
        }
        .width('100%')
        .padding({ bottom: 8 })
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .constraintSize({ maxHeight: 340 })
      .borderRadius({ topLeft: 16, topRight: 16 })
      .backgroundColor(this.theme.surfaceElevated)
      .border({ width: { top: 0.5 }, color: this.theme.divider })
    }
    .width('100%')
  }

  // ── 会话抽屉 ────────────────────────────────────────────────

  @Builder
  sessionsDrawer() {
    Row() {
      Column() {
        Row() {
          Text('会话').fontSize('16fp').fontColor(this.theme.textPrimary).layoutWeight(1)
          Text('＋').fontSize('18fp').fontColor(this.theme.primary)
            .padding(8)
            .onClick(() => {
              this.viewModel.newSession();
              this.showSessions = false;
            })
        }
        .width('100%')
        .padding({ left: 16, right: 8, top: 12, bottom: 8 })

        List() {
          ForEach(this.state.sessions, (s: SessionUi) => {
            ListItem() {
              Column({ space: 3 }) {
                Row() {
                  Text(s.title).fontSize('14fp')
                    .fontColor(s.id === this.state.activeSessionId
                      ? this.theme.primary : this.theme.textPrimary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  Text('✕').fontSize('12fp').fontColor(this.theme.textHint)
                    .padding(6)
                    .onClick(() => {
                      this.viewModel.deleteSession(s.id);
                    })
                }
                Text(this.viewModel.providerLabel(s.provider) + ' · ' + s.model
                  + ' · ' + this.timeText(s.updatedAt))
                  .fontSize('10fp').fontColor(this.theme.textHint)
              }
              .width('100%')
              .padding({ left: 12, right: 6, top: 8, bottom: 8 })
              .borderRadius(10)
              .backgroundColor(s.id === this.state.activeSessionId
                ? this.theme.surfaceElevated : Color.Transparent)
              .onClick(() => {
                this.viewModel.selectSession(s.id);
                this.showSessions = false;
              })
            }
          }, (s: SessionUi) => s.id)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 8, right: 8 })
        .scrollBar(BarState.Off)
      }
      .width(300)
      .height('100%')
      .backgroundColor(this.theme.surface)

      // 遮罩
      Column()
        .layoutWeight(1)
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.45)')
        .onClick(() => {
          this.showSessions = false;
        })
    }
    .width('100%')
    .height('100%')
  }

  // ── 辅助 ────────────────────────────────────────────────────

  private send(): void {
    const text = this.inputText;
    if (text.trim().length === 0) {
      return;
    }
    this.inputText = '';
    this.viewModel.sendMessage(text);
  }

  private activeSession(): SessionUi | null {
    const id = this.state.activeSessionId;
    if (id === null) {
      return null;
    }
    const found = this.state.sessions.find((s: SessionUi) => s.id === id);
    return found !== undefined ? found : null;
  }

  private activeTitle(): string {
    const s = this.activeSession();
    return s !== null ? s.title : '对话';
  }

  private activeProvider(): string {
    const s = this.activeSession();
    return s !== null ? s.provider : 'deepseek';
  }

  private activeModel(): string {
    const s = this.activeSession();
    return s !== null ? s.model : '—';
  }

  private isActiveModel(provider: string, model: string): boolean {
    const s = this.activeSession();
    return s !== null && s.provider === provider && s.model === model;
  }

  private timeText(ts: number): string {
    const d = new Date(ts);
    const h = d.getHours();
    const min = d.getMinutes();
    const hh = h < 10 ? '0' + h : '' + h;
    const mm = min < 10 ? '0' + min : '' + min;
    return hh + ':' + mm;
  }

  private parseTodos(json: string): TodoSnapshotItem[] {
    try {
      const parsed = JSON.parse(json) as TodoSnapshotItem[];
      if (Array.isArray(parsed)) {
        return parsed;
      }
    } catch (_e) {
      // 解析失败按无清单处理
    }
    return [];
  }

  private todoGlyph(status: string): string {
    if (status === 'completed') return '✓';
    if (status === 'in_progress') return '◐';
    return '○';
  }

  private toolStatusLabel(status: string): string {
    if (status === 'error') return '失败';
    if (status === 'running') return '运行中';
    return '完成';
  }

  private toolStatusColor(status: string): string {
    if (status === 'error') return this.theme.error;
    if (status === 'running') return this.theme.warning;
    return this.theme.textHint;
  }
}
