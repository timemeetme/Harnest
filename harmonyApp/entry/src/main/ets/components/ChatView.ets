import { ThemeColors, darkTheme } from '../theme/Theme';
import { KEY_THEME } from '../service/AppearanceService';
import { pasteboard } from '@kit.BasicServicesKit';
import {
  UiState, ChatMessage, MessageRole, SessionUi, LiveItem,
  PendingQuestionItem, PendingOption, BgJobUi,
} from '../model/UiModels';
import { AppViewModel, QuestionPick } from '../viewmodel/AppViewModel';
import { ProviderConfig } from '../service/ConfigService';
import { TodoSnapshotItem } from '../service/HarnessNative';
import { EffortOption } from '../common/Constants';
import { MarkdownView } from './MarkdownView';

/**
 * 对话页：会话抽屉 + 消息流 + 模型选择器（TRAE 式）。
 * 模型选择按对话粒度保存；选择器展示已配置 key 的 provider 及其模型 + 思考模式钻取。
 * 实时活动面板（思考/工具/待办）对标 Trae/Codex：层级折叠，完成后默认收起。
 * k 系列 UI：排队续发 / ⚡转向 / 停止 / 提问卡 / 🧭Plan / 🗜压缩 / 后台任务卡 / fork·复制·评分 / Markdown 渲染。
 */
@Component
export struct ChatView {
  @ObjectLink @Watch('onStateChanged') state: UiState;
  viewModel: AppViewModel = new AppViewModel();
  onGoSettings: () => void = () => {};
  @StorageProp(KEY_THEME) theme: ThemeColors = darkTheme;
  @State inputText: string = '';
  @State showSessions: boolean = false;
  @State showModelPicker: boolean = false;
  @State providerList: ProviderConfig[] = [];
  @State liveExpanded: Record<string, boolean> = {};
  /** k1 模型选择器二级钻取（'provider/model' 非空时展示思考模式行） */
  @State drillModel: string = '';
  @State pickerTab: number = 0; // 0=模型, 1=思考模式
  /** k5 提问卡选择态（questionId → 选中 label 列表） */
  @State qSel: Record<string, string[]> = {};
  /** k5 提问卡自由文本（questionId → 输入） */
  @State qCustom: Record<string, string> = {};
  /** 会话抽屉行内重命名（非空 id = 正在编辑该会话标题） */
  @State renameId: string | null = null;
  @State renameText: string = '';
  /** B1 编辑重发：长按用户气泡 → 对话框预填原文 → 走标准发送链路（历史不删不截断） */
  @State editTarget: ChatMessage | null = null;
  @State editText: string = '';
  private scroller: Scroller = new Scroller();
  /** 滚动位置追踪：距底部 ≤2 项视为"贴底"，贴底才自动跟随流式更新；离开后显示"回到底部"悬浮按钮。 */
  @State nearBottom: boolean = true;
  /** 上次会话 id：检测会话切换，切换时延迟跳底（等列表重建完） */
  private lastSessionId: string | null = null;

  onStateChanged(): void {
    const sid = this.state.activeSessionId;
    if (sid !== this.lastSessionId) {
      this.lastSessionId = sid;
      this.nearBottom = true;
      this.scrollToBottomDelayed(180);
      return;
    }
    if (this.nearBottom) {
      this.scroller.scrollEdge(Edge.Bottom);
    }
  }

  aboutToAppear(): void {
    this.lastSessionId = this.state.activeSessionId;
    this.scrollToBottomDelayed(180);
  }

  private scrollToBottomDelayed(ms: number): void {
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, ms);
  }

  build() {
    Column() {
      this.topBar()

      // 模型选择器（顶栏下拉，对标 ChatGPT）
      if (this.showModelPicker) {
        this.modelPicker()
      }

      if (this.state.needsConfig) {
        this.configBanner()
      }

      // k 系列一次性提示条（2.6s 自动消失）
      if (this.state.toast.length > 0) {
        this.toastBar()
      }

      Stack({ alignContent: Alignment.Bottom }) {
        Column() {
          this.messageList()
          this.inputArea()
        }
        .width('100%').height('100%')

        // 离开底部后显示：一键回底继续跟随流式输出（对标 ChatGPT/Trae）
        if (!this.nearBottom && this.state.messages.length > 0) {
          Text(this.state.isSending ? '⌄ 回到底部 · 跟随最新' : '⌄ 回到底部')
            .fontSize('11fp')
            .fontColor(this.state.isSending ? this.theme.primary : this.theme.textPrimary)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(14)
            .backgroundColor(this.theme.surfaceElevated)
            .border({ width: 0.5, color: this.theme.divider })
            .margin({ bottom: 96 })
            .onClick(() => {
              this.nearBottom = true;
              this.scroller.scrollEdge(Edge.Bottom);
            })
        }
      }
      .layoutWeight(1)
      .width('100%')

      // 会话抽屉（全屏遮罩）
      if (this.showSessions) {
        this.sessionsDrawer()
      }

      // B1 编辑重发对话框（全屏遮罩，点遮罩关闭）
      if (this.editTarget !== null) {
        this.editDialog()
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
        // 模型 chip（点击弹出选择器，对标 ChatGPT 顶栏）
        Row({ space: 2 }) {
          Text(this.activeModelLabel()).fontSize('11fp').fontColor(this.theme.textHint)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 160 })
          Text('▾').fontSize('10fp').fontColor(this.theme.textHint)
        }
        .padding({ left: 10, right: 10, top: 2, bottom: 2 })
        .borderRadius(10)
        .backgroundColor(this.theme.surfaceElevated)
        .margin({ top: 1 })
        .onClick(() => {
          this.providerList = this.viewModel.usableProviders();
          this.showModelPicker = !this.showModelPicker;
        })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // k3 手动压缩上下文（回合空闲时可用）
      Text('🗜').fontSize('16fp')
        .fontColor(!this.state.isSending && this.state.messages.length > 0
          ? this.theme.textPrimary : this.theme.textHint)
        .padding({ left: 6, right: 6, top: 8, bottom: 8 })
        .onClick(() => {
          this.viewModel.runCompact();
        })

      // k8 Plan 模式开关（开启时高亮；🧭 与复制按钮 📋 区分）
      Text('🧭').fontSize('16fp')
        .fontColor(this.state.planActive ? this.theme.primary : this.theme.textHint)
        .padding({ left: 6, right: 6, top: 8, bottom: 8 })
        .onClick(() => {
          this.viewModel.togglePlan();
        })

      // 清空当前会话消息（回合空闲且有消息时可用；保留会话壳与模型选择）
      Text('🗑').fontSize('15fp')
        .fontColor(!this.state.isSending && this.state.messages.length > 0
          ? this.theme.textPrimary : this.theme.textHint)
        .padding({ left: 6, right: 6, top: 8, bottom: 8 })
        .onClick(() => {
          this.viewModel.clearCurrentMessages();
        })

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

        // 发送中的实时活动面板（思考/工具/待办），对标 Trae/Codex。
        // @Builder 多参数按值快照不会随 state.liveItems 重赋值刷新，
        // 外包内容签名 ForEach 强制追踪数组引用，逐字到达时重建面板子树。
        if (this.state.isSending && this.state.liveItems.length > 0) {
          ForEach([this.state.liveItems], (snap: LiveItem[]) => {
            ListItem() {
              this.liveActivityPanel(snap, true, 'live_now')
            }
          }, (snap: LiveItem[]) => 'live_host_' + snap.length + '_' + this.liveGroupSig(snap))
        }

        // k7e 后台任务镜像卡（running/stopping + 终止按钮）
        if (this.state.bgJobs.length > 0) {
          ListItem() {
            this.bgJobsCard()
          }
        }
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 12, right: 12, top: 12 })
      .scrollBar(BarState.Off)
      .onScrollIndex((_first: number, last: number) => {
        let total = this.state.messages.length;
        if (this.state.isSending && this.state.liveItems.length > 0) {
          total++;
        }
        if (this.state.bgJobs.length > 0) {
          total++;
        }
        this.nearBottom = last >= total - 2;
      })
    }
  }

  /** 响应耗时格式化：832ms / 3.4s / 2分13秒 */
  private fmtDuration(ms: number): string {
    if (ms < 1000) {
      return ms + 'ms';
    }
    const s = ms / 1000;
    if (s < 60) {
      return s.toFixed(1) + 's';
    }
    const m = Math.floor(s / 60);
    return m + '分' + Math.round(s % 60) + '秒';
  }

  /** A2 busy 行文本：阶段文案（含实时字数）+ 回合耗时跳动（12s / 2:05，与 Android 同格式） */
  private busyText(): string {
    const base = this.state.busyHint.length > 0 ? this.state.busyHint : '回复中…';
    const sec = this.state.busySec;
    if (sec <= 0) {
      return base;
    }
    if (sec >= 60) {
      const m = Math.floor(sec / 60);
      const s = sec % 60;
      return base + ' · ' + m + ':' + (s < 10 ? '0' + s : '' + s);
    }
    return base + ' · ' + sec + 's';
  }

  /** token 用量格式化：↑1.2k ↓3.4k · 12 tok/s（outTok/durationMs 换算） */
  private fmtUsage(m: ChatMessage): string {
    let s = '↑' + this.fmtTok(m.inTok) + ' ↓' + this.fmtTok(m.outTok);
    if (m.outTok > 0 && m.durationMs > 1000) {
      const tps = m.outTok * 1000 / m.durationMs;
      s += ' · ' + tps.toFixed(0) + ' tok/s';
    }
    return s;
  }

  /** token 数格式化：1234 → 1.2k */
  private fmtTok(n: number): string {
    if (n >= 1000) {
      return (n / 1000).toFixed(1) + 'k';
    }
    return n.toString();
  }

  @Builder
  messageBubble(m: ChatMessage) {
    if (m.role === MessageRole.User) {
      Column() {
      Column({ space: 3 }) {
        if (m.steered) {
            Text('⚡ 转向注入（下一边界生效）').fontSize('9fp').fontColor(this.theme.warning)
        }
          Text(m.content).fontSize('15fp').fontColor(this.theme.textPrimary)
        }
        .constraintSize({ maxWidth: '80%' })
        .padding(12)
        .borderRadius(12)
        .backgroundColor(this.theme.userBubble)
        .gesture(LongPressGesture().onAction(() => {
          this.editTarget = m;
          this.editText = m.content;
        }))
      }
      .width('100%')
      .alignItems(HorizontalAlign.End)
    } else if (m.role === MessageRole.Tool) {
      this.toolBubble(m)
    } else {
      Column({ space: 4 }) {
        // 历史回合轨迹回放（思考/工具步骤），折叠默认收起
        if (m.traceJson.length > 0) {
          this.liveActivityPanel(parseTrace(m.traceJson), false, m.id)
        }
        Column({ space: 4 }) {
          if ((m.model !== null && m.model !== undefined && m.model.length > 0) || m.durationMs > 0
            || m.inTok > 0 || m.outTok > 0) {
            Row({ space: 6 }) {
              if (m.isError) {
                Text('⚠ 失败').fontSize('10fp').fontColor(this.theme.error)
              }
              if (m.model !== null && m.model !== undefined && m.model.length > 0) {
                Text(this.viewModel.providerLabel(m.provider ?? '') + ' · ' + m.model)
                  .fontSize('10fp')
                  .fontColor(m.isError ? this.theme.error : this.theme.textHint)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .flexShrink(1)
              }
              if (m.durationMs > 0) {
                Text('⏱ ' + this.fmtDuration(m.durationMs))
                  .fontSize('10fp')
                  .fontColor(m.isError ? this.theme.error : this.theme.textHint)
              }
              if (m.inTok > 0 || m.outTok > 0) {
                Text(this.fmtUsage(m))
                  .fontSize('10fp')
                  .fontColor(this.theme.textHint)
              }
            }
          }
          // k8 接线：Markdown 渲染（标题/粗斜/码块/表格/链接/数学降级/@提及）
          if (m.isError) {
            Text(m.content).fontSize('15fp').fontColor(this.theme.error)
          } else {
            MarkdownView({ text: m.content, theme: this.theme })
          }
        }
        .constraintSize({ maxWidth: '86%' })
        .padding(12)
        .borderRadius(12)
        .backgroundColor(this.theme.assistantBubble)

        // k6 消息尾部操作：正常消息评分/复制/fork；错误消息 🔄重试 + 📋复制
        if (m.isError) {
          Row({ space: 4 }) {
            Text('🔄 重试').fontSize('11fp')
              .fontColor(this.theme.error)
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .borderRadius(10)
              .backgroundColor(this.theme.surfaceElevated)
              .border({ width: 0.5, color: this.theme.error })
              .onClick(() => {
                this.viewModel.retryFromMessage(m.id);
              })
            Text('📋').fontSize('12fp')
              .padding(4)
              .onClick(() => {
                this.copyText(m.content);
              })
          }
          .padding({ left: 4 })
        } else {
          Row({ space: 4 }) {
            Text(m.rating === 1 ? '👍' : '👍🏻').fontSize('12fp')
              .padding(4)
              .onClick(() => {
                this.viewModel.setRating(m.id, 1);
              })
            Text(m.rating === -1 ? '👎' : '👎🏻').fontSize('12fp')
              .padding(4)
              .onClick(() => {
                this.viewModel.setRating(m.id, -1);
              })
            Text('🔄').fontSize('12fp')
              .padding(4)
              .onClick(() => {
                this.viewModel.retryFromMessage(m.id);
              })
            Text('📋').fontSize('12fp')
              .padding(4)
              .onClick(() => {
                this.copyText(m.content);
              })
            Text('🍴').fontSize('12fp')
              .padding(4)
              .onClick(() => {
                this.viewModel.forkFromMessage(m.id);
              })
          }
          .padding({ left: 4 })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 工具消息气泡：工具名 + 状态 +（todo_write 整表快照 | 结果预览） */
  @Builder
  toolBubble(m: ChatMessage) {
    Column() {
      Column({ space: 6 }) {
        Row({ space: 6 }) {
          Text(this.toolGlyph(m.toolName)).fontSize('12fp')
            .fontColor(m.toolStatus === 'error' ? this.theme.error : this.theme.primary)
          Text(m.toolName).fontSize('12fp')
            .fontColor(this.theme.textPrimary)
            .flexShrink(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.toolStatusLabel(m.toolStatus)).fontSize('10fp')
            .fontColor(this.toolStatusColor(m.toolStatus))
        }

        if (m.todosJson.length > 0) {
          Column({ space: 5 }) {
            ForEach(this.parseTodos(m.todosJson), (t: TodoSnapshotItem, idx: number) => {
              Row({ space: 7 }) {
                Text(this.todoGlyph(t.status)).fontSize('12fp')
                  .fontColor(t.status === 'completed' ? this.theme.success
                    : (t.status === 'in_progress' ? this.theme.primary : this.theme.textHint))
                Text(t.content).fontSize('12fp')
                  .fontColor(t.status === 'completed' ? this.theme.textHint : this.theme.textPrimary)
                  .flexShrink(1)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .alignItems(VerticalAlign.Top)
            }, (t: TodoSnapshotItem, idx: number) => m.id + '_' + idx)
          }
        } else if (m.toolResult.length > 0) {
          if (this.mcpImageUri(m, m.toolResult).length > 0) {
            Image(this.mcpImageUri(m, m.toolResult))
              .objectFit(ImageFit.Cover)
              .interpolation(ImageInterpolation.High)
              .width('100%')
              .constraintSize({ maxHeight: 280 })
              .borderRadius(8)
              .backgroundColor(this.theme.surface)
              .margin({ top: 2 })
          } else {
            Text(m.toolResult).fontSize('11fp')
              .fontColor(m.toolStatus === 'error' ? this.theme.error : this.theme.textHint)
              .maxLines(4)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
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
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // ── 输入区 ──────────────────────────────────────────────────

  @Builder
  inputArea() {
    Column({ space: 6 }) {
      // k5 提问卡（等待用户回答 — 悬浮于输入区上方，不随列表滚动）
      if (this.state.pendingQuestion !== null) {
        this.questionCard()
      }

      // 忙时提示 + k4 排队气泡
      if (this.state.isSending || this.state.busyHint.length > 0) {
        Row({ space: 8 }) {
          Text(this.busyText())
            .fontSize('10fp').fontColor(this.theme.textHint)
            .layoutWeight(1)
            .maxLines(1)
          ForEach(this.state.queuedMessages, (q: string, idx: number) => {
            Text('⏳ ' + q)
              .fontSize('9fp')
              .fontColor(this.theme.textSecondary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: 120 })
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(8)
              .backgroundColor(this.theme.surfaceElevated)
          }, (q: string, idx: number) => 'q_' + idx + '_' + q)
        }
        .width('100%')
      }

      Row({ space: 8 }) {
        TextArea({ text: this.inputText, placeholder: this.state.isSending ? '输入 ⚡ 转向指令或排队消息…' : '发送消息…' })
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

        // k4 回合进行中：⚡ 转向（下一 step 边界改道）
        if (this.state.isSending) {
          Text('⚡').fontSize('18fp')
            .fontColor(this.inputText.trim().length > 0 ? this.theme.warning : this.theme.textHint)
            .padding({ left: 4, right: 4 })
            .onClick(() => {
              this.steer();
            })
        }

        // k6 发送 / 停止双态按钮
        if (this.state.isSending) {
          Button('⏹')
            .fontSize('14fp')
            .fontColor('#ffffff')
            .backgroundColor(this.theme.error)
            .borderRadius(10)
            .height(42)
            .padding({ left: 16, right: 16 })
            .onClick(() => {
              this.viewModel.stopRound();
            })
        } else {
          Button('发送')
            .fontSize('14fp')
            .fontColor(this.theme.primaryOn)
            .backgroundColor(this.inputText.trim().length === 0
              ? this.theme.divider : this.theme.primary)
            .borderRadius(10)
            .height(42)
            .padding({ left: 14, right: 14 })
            .enabled(this.inputText.trim().length > 0)
            .onClick(() => {
              this.send();
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 10 })
    .backgroundColor(this.theme.surface)
    .border({ width: { top: 0.5 }, color: this.theme.divider })
  }

  /** k4 ⚡ 转向发送 */
  private steer(): void {
    const text = this.inputText;
    if (text.trim().length === 0) {
      return;
    }
    this.inputText = '';
    this.viewModel.steerMessage(text);
  }

  @Builder
  modelPicker() {
    Column({ space: 0 }) {
      // 顶部 Tab 切换：模型 / 思考模式
      Row({ space: 0 }) {
        Text('模型')
          .fontSize('14fp')
          .fontColor(this.pickerTab === 0 ? this.theme.primary : this.theme.textHint)
          .fontWeight(this.pickerTab === 0 ? FontWeight.Medium : FontWeight.Regular)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 10, bottom: 10 })
          .onClick(() => { this.pickerTab = 0; })
        Text('思考模式')
          .fontSize('14fp')
          .fontColor(this.pickerTab === 1 ? this.theme.primary : this.theme.textHint)
          .fontWeight(this.pickerTab === 1 ? FontWeight.Medium : FontWeight.Regular)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 10, bottom: 10 })
          .onClick(() => { this.pickerTab = 1; })
      }
      .width('100%')

      Divider().color(this.theme.divider)

      if (this.pickerTab === 0) {
        // ── 模型列表 ──
        Scroll() {
          Column({ space: 2 }) {
            ForEach(this.providerList, (p: ProviderConfig) => {
              Column({ space: 2 }) {
                Text(this.viewModel.providerLabel(p.provider)).fontSize('11fp')
                  .fontColor(this.theme.textHint)
                  .padding({ top: 8, bottom: 4, left: 12 })
                ForEach(p.models, (model: string) => {
                  Row() {
                    Column({ space: 1 }) {
                      Text(model).fontSize('14fp')
                        .fontColor(this.isActiveModel(p.provider, model)
                          ? this.theme.primary : this.theme.textPrimary)
                      Text(this.viewModel.providerLabel(p.provider)).fontSize('10fp')
                        .fontColor(this.theme.textHint)
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                    if (this.isActiveModel(p.provider, model)) {
                      Text('✓').fontSize('14fp').fontColor(this.theme.primary)
                    }
                  }
                  .width('100%')
                  .padding({ left: 20, right: 12, top: 9, bottom: 9 })
                  .borderRadius(8)
                  .onClick(() => {
                    // 选模型即生效，effort 保留当前值，收起面板
                    this.viewModel.setSessionModel(p.provider, model,
                      this.viewModel.currentSession()?.effort ?? '');
                    this.showModelPicker = false;
                  })
                }, (model: string) => p.provider + '/' + model)
              }
              .width('100%')
            }, (p: ProviderConfig) => p.provider)
          }
          .width('100%')
          .padding({ bottom: 8, top: 2 })
        }
        .scrollBar(BarState.Off)
        .width('100%')
        .constraintSize({ maxHeight: 300 })
      } else {
        // ── 思考模式列表（独立于模型选择，基于当前会话） ──
        Scroll() {
          Column({ space: 2 }) {
            ForEach(this.viewModel.effortOptions(), (opt: EffortOption) => {
              Row({ space: 6 }) {
                Column({ space: 1 }) {
                  Text(opt.label).fontSize('14fp')
                    .fontColor(this.isActiveEffort(opt.value)
                      ? this.theme.primary : this.theme.textPrimary)
                  Text(opt.hint).fontSize('10fp').fontColor(this.theme.textHint)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                if (this.isActiveEffort(opt.value)) {
                  Text('✓').fontSize('14fp').fontColor(this.theme.primary)
                }
              }
              .width('100%')
              .padding({ left: 20, right: 12, top: 10, bottom: 10 })
              .borderRadius(8)
              .onClick(() => {
                // 思考模式独立切换，保留当前模型不变
                const s = this.viewModel.currentSession();
                if (s) {
                  this.viewModel.setSessionModel(s.provider, s.model, opt.value ?? '');
                }
                this.showModelPicker = false;
              })
            }, (opt: EffortOption) => String(opt.value ?? 'default'))
          }
          .width('100%')
          .padding({ bottom: 8, top: 2 })
        }
        .scrollBar(BarState.Off)
        .width('100%')
        .constraintSize({ maxHeight: 300 })
      }
    }
    .width('100%')
    .constraintSize({ maxHeight: 340 })
    .borderRadius({ bottomLeft: 16, bottomRight: 16 })
    .backgroundColor(this.theme.surfaceElevated)
    .border({ width: { bottom: 0.5, left: 0.5, right: 0.5 }, color: this.theme.divider })
    .margin({ left: 8, right: 8 })
  }

  // ── B1 编辑重发对话框 ───────────────────────────────────────

  @Builder
  editDialog() {
    Column() {
      Column({ space: 10 }) {
        Text('编辑后重新发送').fontSize('15fp')
          .fontColor(this.theme.textPrimary).fontWeight(FontWeight.Medium)
          .width('100%')
        Text('以新内容走输入框同链路发送；原消息保留在历史中')
          .fontSize('10fp').fontColor(this.theme.textHint).width('100%')
        TextArea({ text: this.editText, placeholder: '编辑消息内容…' })
          .fontSize('14fp')
          .fontColor(this.theme.textPrimary)
          .placeholderColor(this.theme.textHint)
          .backgroundColor(this.theme.surface)
          .borderRadius(8)
          .constraintSize({ minHeight: 72, maxHeight: 200 })
          .width('100%')
          .padding({ left: 10, right: 10, top: 10, bottom: 10 })
          .onChange((v: string) => {
            this.editText = v;
          })
        Row({ space: 8 }) {
          Blank()
          Text('取消').fontSize('14fp').fontColor(this.theme.textHint)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .onClick(() => {
              this.editTarget = null;
            })
          Text('发送').fontSize('14fp').fontColor(this.theme.primary)
            .fontWeight(FontWeight.Medium)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .onClick(() => {
              const t = this.editText.trim();
              this.editTarget = null;
              if (t.length > 0) {
                this.nearBottom = true;
                this.viewModel.sendMessage(t);
                this.scrollToBottomDelayed(180);
              }
            })
        }
        .width('100%')
      }
      .padding(16)
      .borderRadius(14)
      .backgroundColor(this.theme.surfaceElevated)
      .width(300)
      .onClick(() => {
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.editTarget = null;
    })
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
                  if (this.renameId === s.id) {
                    TextInput({ text: this.renameText, placeholder: '会话名称…' })
                      .fontSize('13fp')
                      .fontColor(this.theme.textPrimary)
                      .placeholderColor(this.theme.textHint)
                      .backgroundColor(this.theme.surfaceElevated)
                      .borderRadius(8)
                      .height(32)
                      .layoutWeight(1)
                      .onChange((v: string) => {
                        this.renameText = v;
                      })
                    Text('✓').fontSize('14fp').fontColor(this.theme.primary)
                      .padding({ left: 6, right: 2, top: 6, bottom: 6 })
                      .onClick(() => {
                        this.viewModel.renameSession(s.id, this.renameText);
                        this.renameId = null;
                      })
                    Text('✕').fontSize('12fp').fontColor(this.theme.textHint)
                      .padding({ left: 2, right: 2, top: 6, bottom: 6 })
                      .onClick(() => {
                        this.renameId = null;
                      })
                  } else {
                    Text(s.title).fontSize('14fp')
                      .fontColor(s.id === this.state.activeSessionId
                        ? this.theme.primary : this.theme.textPrimary)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    Text('✎').fontSize('12fp').fontColor(this.theme.textHint)
                      .padding(6)
                      .onClick(() => {
                        this.renameId = s.id;
                        this.renameText = s.title;
                      })
                    Text('✕').fontSize('12fp').fontColor(this.theme.textHint)
                      .padding({ left: 2, right: 6, top: 6, bottom: 6 })
                      .onClick(() => {
                        this.viewModel.deleteSession(s.id);
                      })
                  }
                }
                .width('100%')
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
                this.scrollToBottomDelayed(180);
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
    this.liveExpanded = {};
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

  /** A3 MCP 图片工具结果记忆化缓存：行对象 → data URI（''=非图片）。base64 结果 JSON.parse
   *  昂贵，live 面板 150ms 节流重渲染不能每次解析；行对象身份稳定可作键，容量保护防会话内累积 */
  private mcpUriCache: Map<Object, string> = new Map();

  private mcpImageUri(owner: Object, result: string): string {
    if (this.mcpUriCache.has(owner)) {
      return this.mcpUriCache.get(owner) ?? '';
    }
    const uri = this.parseMcpImage(result);
    if (this.mcpUriCache.size > 200) {
      this.mcpUriCache.clear();
    }
    this.mcpUriCache.set(owner, uri);
    return uri;
  }

  /** A3 解析 MCP 图片工具结果：{"content":[{"type":"image","data":"<base64>"}]} → data URI
   *  （ArkUI Image 原生支持，免异步 PixelMap）。仅认 image/* mime（缺省按 png）；
   *  非图片/解析失败 → ''（回退纯文本展示）。与 Android decodeMcpImage 同构。 */
  private parseMcpImage(result: string): string {
    if (result.length === 0 || result.charCodeAt(0) !== 123) {
      return '';
    }
    try {
      const root = JSON.parse(result) as Record<string, Object>;
      const arr = root['content'] as Array<Record<string, Object>>;
      if (!Array.isArray(arr)) {
        return '';
      }
      for (let i = 0; i < arr.length; i++) {
        const item = arr[i];
        if (item['type'] !== 'image') {
          continue;
        }
        const data = item['data'];
        if (typeof data !== 'string' || data.length === 0) {
          continue;
        }
        const rawMime = item['mimeType'];
        let mime = typeof rawMime === 'string' ? (rawMime as string) : '';
        if (mime.length === 0) {
          const altMime = item['mime'];
          mime = typeof altMime === 'string' ? (altMime as string) : '';
        }
        if (mime.length === 0) {
          mime = 'image/png';
        }
        if (mime.indexOf('image/') !== 0) {
          continue;
        }
        return 'data:' + mime + ';base64,' + data;
      }
      return '';
    } catch (_e) {
      return '';
    }
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

  /** 工具名 → 分类图标（轨迹卡片视觉分类，对齐 Android ToolCard） */
  private toolGlyph(name: string): string {
    const n = name.toLowerCase();
    if (n.indexOf('search') >= 0 || n.indexOf('web') >= 0 || n.indexOf('fetch') >= 0) return '🌐';
    if (n.indexOf('grep') >= 0 || n.indexOf('glob') >= 0) return '🔎';
    if (n.indexOf('bash') >= 0 || n.indexOf('shell') >= 0 || n.indexOf('exec') >= 0
      || n.indexOf('terminal') >= 0 || n.indexOf('command') >= 0) return '💻';
    if (n.indexOf('artifact') >= 0) return '📦';
    if (n.indexOf('todo') >= 0) return '🗒';
    if (n.indexOf('task') >= 0 || n.indexOf('agent') >= 0 || n.indexOf('dispatch') >= 0) return '🤖';
    if (n.indexOf('read') >= 0 || n.indexOf('write') >= 0 || n.indexOf('edit') >= 0
      || n.indexOf('file') >= 0 || n.indexOf('patch') >= 0) return '📄';
    return '⚙️';
  }

  /** k6 复制消息全文到系统剪贴板 */
  private copyText(text: string): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.state.toast = '已复制';
      }).catch(() => {
        this.state.toast = '复制失败';
      });
    } catch (_e) {
      this.state.toast = '复制失败';
    }
  }

  /** k1 当前会话思考强度匹配（null=默认 ↔ effort 空串） */
  private isActiveEffort(value: string | null): boolean {
    const s = this.activeSession();
    if (s === null) {
      return false;
    }
    if (value === null) {
      return s.effort.length === 0;
    }
    return s.effort === value;
  }

  /** k 系列一次性提示条（2.6s 自动消失；点击立即关闭；内容比对防连发竞态） */
  @Builder
  toastBar() {
    Row() {
      Text(this.state.toast).fontSize('12fp').fontColor(this.theme.textPrimary)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text('✕').fontSize('11fp').fontColor(this.theme.textHint).padding(4)
    }
    .width('100%')
    .padding({ left: 12, right: 6, top: 6, bottom: 6 })
    .backgroundColor(this.theme.surfaceElevated)
    .border({ width: { bottom: 0.5 }, color: this.theme.divider })
    .onClick(() => {
      this.state.toast = '';
    })
    .onAppear(() => {
      const cur = this.state.toast;
      setTimeout(() => {
        if (this.state.toast === cur) {
          this.state.toast = '';
        }
      }, 2600);
    })
  }

  /** k7e 后台任务镜像卡（running/stopping + 终止按钮） */
  @Builder
  bgJobsCard() {
    Column({ space: 4 }) {
      ForEach(this.state.bgJobs, (j: BgJobUi) => {
        Row({ space: 6 }) {
          Text(j.status === 'stopping' ? '⏹' : '⏳').fontSize('12fp')
            .fontColor(j.status === 'stopping' ? this.theme.warning : this.theme.primary)
          Text(j.label).fontSize('12fp').fontColor(this.theme.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (j.status === 'running') {
            Text('终止').fontSize('10fp').fontColor(this.theme.error)
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .borderRadius(8)
              .backgroundColor(this.theme.surface)
              .onClick(() => {
                this.viewModel.killBgJob(j.id);
              })
          } else {
            Text('终止中…').fontSize('10fp').fontColor(this.theme.textHint)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }, (j: BgJobUi) => j.id + '_' + j.status)
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(12)
    .backgroundColor(this.theme.surfaceElevated)
    .alignSelf(ItemAlign.Start)
  }

  /** k5 提问卡：qid 下若干问题（单选/多选 + 自由输入），提交组包 answerPendingQuestion */
  @Builder
  questionCard() {
    Column({ space: 8 }) {
      Text(this.state.pendingQuestion?.planReview === true ? '🧭 计划待审批' : '❓ 等待你的回答')
        .fontSize('13fp').fontColor(this.theme.warning).fontWeight(FontWeight.Medium)

      ForEach(this.state.pendingQuestion?.questions ?? [], (q: PendingQuestionItem) => {
        Column({ space: 5 }) {
          Row({ space: 6 }) {
            Text(q.header.length > 0 ? q.header : '问题 ' + (q.id + 1))
              .fontSize('11fp').fontColor(this.theme.textHint)
            if (q.multiSelect) {
              Text('可多选').fontSize('9fp').fontColor(this.theme.textHint)
                .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                .borderRadius(6)
                .backgroundColor(this.theme.surface)
            }
          }
          .width('100%')

          Text(q.question).fontSize('13fp').fontColor(this.theme.textPrimary)
            .width('100%')

          if (q.detail.length > 0) {
            Text(q.detail).fontSize('10fp').fontColor(this.theme.textSecondary)
              .width('100%')
          }

          ForEach(q.options, (opt: PendingOption, oi: number) => {
            Row({ space: 6 }) {
              Text(this.qSel[q.id.toString()]?.indexOf(opt.label) >= 0 ? '☑' : '☐')
                .fontSize('13fp')
                .fontColor(this.qSel[q.id.toString()]?.indexOf(opt.label) >= 0
                  ? this.theme.primary : this.theme.textHint)
              Column({ space: 1 }) {
                Row({ space: 4 }) {
                  Text(opt.label).fontSize('12fp')
                    .fontColor(this.qSel[q.id.toString()]?.indexOf(opt.label) >= 0
                      ? this.theme.primary : this.theme.textPrimary)
                  if (opt.isApprove) {
                    Text('批准').fontSize('8fp').fontColor(this.theme.primaryOn)
                      .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                      .borderRadius(4)
                      .backgroundColor(this.theme.primary)
                  }
                }
                if (opt.description.length > 0) {
                  Text(opt.description).fontSize('9fp').fontColor(this.theme.textHint)
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .borderRadius(8)
            .backgroundColor(this.qSel[q.id.toString()]?.indexOf(opt.label) >= 0
              ? this.theme.surface : Color.Transparent)
            .onClick(() => {
              this.togglePick(q, opt.label);
            })
          }, (opt: PendingOption, oi: number) => q.id + '_' + opt.label)

          TextArea({ text: this.qCustom[q.id.toString()] ?? '', placeholder: '补充说明（可选）…' })
            .fontSize('12fp')
            .fontColor(this.theme.textPrimary)
            .placeholderColor(this.theme.textHint)
            .backgroundColor(this.theme.surface)
            .borderRadius(8)
            .constraintSize({ minHeight: 34, maxHeight: 72 })
            .width('100%')
            .onChange((v: string) => {
              this.setCustom(q.id, v);
            })
        }
        .width('100%')
        .padding({ top: 4, bottom: 4 })
      }, (q: PendingQuestionItem) => 'pq_' + q.id)

      Row({ space: 8 }) {
        Button('跳过')
          .fontSize('13fp')
          .fontColor(this.theme.textSecondary)
          .backgroundColor(this.theme.surface)
          .borderRadius(8)
          .height(36)
          .layoutWeight(1)
          .onClick(() => {
            this.viewModel.skipPendingQuestion();
          })
        Button('提交回答')
          .fontSize('13fp')
          .fontColor(this.theme.primaryOn)
          .backgroundColor(this.theme.primary)
          .borderRadius(8)
          .height(36)
          .layoutWeight(1)
          .onClick(() => {
            this.submitAnswers();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(12)
    .borderRadius(12)
    .backgroundColor(this.theme.surfaceElevated)
    .border({ width: 0.5, color: this.theme.divider })
  }

  /** k5 选项点选（单选互斥 / 多选切换），整体替换 qSel 触发刷新 */
  private togglePick(q: PendingQuestionItem, label: string): void {
    const key = q.id.toString();
    const cur: string[] = this.qSel[key] ?? [];
    let next: string[];
    if (q.multiSelect) {
      next = cur.indexOf(label) >= 0
        ? cur.filter((l: string) => l !== label)
        : cur.concat([label]);
    } else {
      next = cur.indexOf(label) >= 0 ? [] : [label];
    }
    const map: Record<string, string[]> = {};
    const keys = Object.keys(this.qSel);
    for (const k of keys) {
      map[k] = this.qSel[k];
    }
    map[key] = next;
    this.qSel = map;
  }

  /** k5 自由输入写入，整体替换 qCustom 触发刷新 */
  private setCustom(qid: number, v: string): void {
    const map: Record<string, string> = {};
    const keys = Object.keys(this.qCustom);
    for (const k of keys) {
      map[k] = this.qCustom[k];
    }
    map[qid.toString()] = v;
    this.qCustom = map;
  }

  /** k5 组包提交（键=问题 id；selected + custom），提交后清空选择态 */
  private submitAnswers(): void {
    const pq = this.state.pendingQuestion;
    if (pq === null) {
      return;
    }
    const picks: Record<string, QuestionPick> = {};
    for (const q of pq.questions) {
      const sel: string[] = this.qSel[q.id.toString()] ?? [];
      const cust = this.qCustom[q.id.toString()] ?? '';
      const pick: QuestionPick = { selected: sel };
      if (cust.trim().length > 0) {
        pick.custom = cust.trim();
      }
      picks[q.id.toString()] = pick;
    }
    this.qSel = {};
    this.qCustom = {};
    this.viewModel.answerPendingQuestion(picks);
  }

  // ── 实时活动面板（对标 Trae/Codex 的执行过程展示） ─────────

  private activeModelLabel(): string {
    const s = this.activeSession();
    if (s !== null && s.model.length > 0) {
      return s.model;
    }
    return '选择模型';
  }

  /** 折叠状态读取：key 未记录时用默认值（发送中跟随展开 / 完成后收起）。 */
  private isLiveOpen(key: string, def: boolean): boolean {
    return this.liveExpanded[key] === undefined ? def : this.liveExpanded[key] === true;
  }

  /** 折叠状态写入：def 为该 key 的默认态（首次点击时取反当前有效状态），整体替换触发刷新。 */
  private toggleLive(key: string, def: boolean): void {
    const cur = this.isLiveOpen(key, def);
    const next: Record<string, boolean> = {};
    const keys = Object.keys(this.liveExpanded);
    for (let i = 0; i < keys.length; i++) {
      next[keys[i]] = this.liveExpanded[keys[i]] === true;
    }
    next[key] = !cur;
    this.liveExpanded = next;
  }

  /** 相邻思考段归为一组，其余条目独立成组，供面板分层渲染。 */
  private groupLiveItems(items: LiveItem[]): LiveItem[][] {
    const groups: LiveItem[][] = [];
    let i = 0;
    while (i < items.length) {
      if (items[i].kind === 'think') {
        let j = i;
        while (j < items.length && items[j].kind === 'think') {
          j++;
        }
        groups.push(items.slice(i, j));
        i = j;
      } else {
        groups.push([items[i]]);
        i++;
      }
    }
    return groups;
  }

  /** 组内容签名：流式归并为同索引原位替换，索引 key 会被 ArkUI 复用而跳过重渲染，签名入 key 强制刷新。 */
  private liveGroupSig(group: LiveItem[]): string {
    const parts: string[] = [];
    for (const it of group) {
      if (it.kind === 'tool') {
        parts.push(it.kind + it.callId + '_' + it.status + '_' + it.result.length);
      } else if (it.kind === 'todos') {
        parts.push(it.kind + '_' + it.todos.length + '_' + this.doneCount(it));
      } else if (it.kind === 'subagent') {
        parts.push(it.kind + it.name + '_' + it.status + '_' + it.result.length);
      } else {
        parts.push(it.kind + it.seq + '_' + it.turn + '_' + it.step + '_' + it.text.length);
      }
    }
    return parts.join('-');
  }

  private toolCount(items: LiveItem[]): number {
    let n = 0;
    for (const it of items) {
      if (it.kind === 'tool') {
        n++;
      }
    }
    return n;
  }

  private thinkCharCount(items: LiveItem[]): number {
    let n = 0;
    for (const it of items) {
      if (it.kind === 'think') {
        n += it.text.length;
      }
    }
    return n;
  }

  private doneCount(item: LiveItem): number {
    let n = 0;
    for (const t of item.todos) {
      if (t.status === 'completed') {
        n++;
      }
    }
    return n;
  }

  /**
   * 实时活动面板：面板级折叠 + 组级折叠，控制信息密度。
   * isSending=true 默认展开跟随；结束后收成单行摘要，点击展开回看。
   */
  @Builder
  liveActivityPanel(items: LiveItem[], isSending: boolean, panelKey: string) {
    Column({ space: 6 }) {
      Row() {
        Text(isSending ? '●' : '✦')
          .fontSize('10fp')
          .fontColor(isSending ? this.theme.primary : this.theme.textHint)
        Text(isSending ? '正在执行…' : '执行轨迹')
          .fontSize('13fp')
          .fontColor(this.theme.textPrimary)
          .fontWeight(FontWeight.Medium)
          .margin({ left: 8 })
          .layoutWeight(1)
          .maxLines(1)
        Text(this.toolCount(items) + ' 步 · ' + this.thinkCharCount(items) + ' 字思考')
          .fontSize('10fp')
          .fontColor(this.theme.textHint)
          .maxLines(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.toggleLive(panelKey + '_panel', isSending);
      })

      if (this.isLiveOpen(panelKey + '_panel', isSending)) {
        Scroll() {
          Column({ space: 2 }) {
            ForEach(this.groupLiveItems(items), (group: LiveItem[], idx: number) => {
              Column() {
                if (group[0].kind === 'think') {
                  this.thinkGroup(group, isSending && idx === this.groupLiveItems(items).length - 1,
                    panelKey + '_tg' + idx)
                } else if (group[0].kind === 'tool') {
                  this.toolLiveRow(group[0], panelKey + '_tl' + idx)
                } else if (group[0].kind === 'answer') {
                  this.answerLiveBlock(group, isSending, panelKey + '_ab' + idx)
                } else if (group[0].kind === 'steer') {
                  this.steerLiveRow(group[0], panelKey + '_st' + idx)
                } else if (group[0].kind === 'subagent') {
                  this.subagentLiveRow(group[0], panelKey + '_sa' + idx)
                } else {
                  this.todosLiveBlock(group[0], panelKey + '_td' + idx)
                }
              }
            }, (group: LiveItem[], idx: number) => panelKey + '_g' + idx + '_' + this.liveGroupSig(group))
          }
          .width('100%')
        }
        .scrollBar(BarState.Off)
        .width('100%')
        .constraintSize({ maxHeight: 280 })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .borderRadius(12)
    .backgroundColor(this.theme.surfaceElevated)
    .alignSelf(ItemAlign.Start)
  }

  /** 思考组（一级折叠）：标题行汇总段数/字数，展开后逐段渲染（段内二级折叠）。 */
  @Builder
  thinkGroup(segments: LiveItem[], autoExpand: boolean, key: string) {
    Column() {
      Row() {
        Text(this.isLiveOpen(key, autoExpand) ? '▾' : '▸')
          .fontSize('11fp')
          .fontColor(this.theme.textHint)
        Text('💭').fontSize('12fp').margin({ left: 7 })
        Text((autoExpand ? '思考中' : '思考过程') + (segments.length > 1 ? ' · ' + segments.length + ' 段' : ''))
          .fontSize('13fp')
          .fontColor(this.theme.textPrimary)
          .margin({ left: 6 })
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.thinkCharCount(segments) + ' 字')
          .fontSize('10fp')
          .fontColor(this.theme.textHint)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 5, bottom: 5 })
      .onClick(() => {
        this.toggleLive(key, autoExpand);
      })

      if (this.isLiveOpen(key, autoExpand)) {
        ForEach(segments, (seg: LiveItem, idx: number) => {
          Column() {
            if (idx > 0) {
              Divider()
                .color(this.theme.divider)
                .strokeWidth(0.5)
                .margin({ top: 2, bottom: 2 })
            }
            this.thinkSegment(seg, key + '_s' + idx,
              segments.length > 1 ? '第 ' + (idx + 1) + ' 段' : '',
              autoExpand && idx === segments.length - 1)
          }
        }, (seg: LiveItem, idx: number) => key + '_seg' + idx + '_' + seg.seq + '_' + seg.text.length)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 单段思考（三级折叠 L3）：默认折叠只渲染单行摘要——性能关键，内核每 200ms 发段内累积全量，
   *  万字全文常驻重排会卡死 UI（对齐 iOS/Android 同名组件）。点击展开全文（>4000 字尾部截断）。 */
  @Builder
  thinkSegment(seg: LiveItem, key: string, label: string, running: boolean) {
    Column() {
      Row() {
        if (label.length > 0) {
          Text(label).fontSize('11fp').fontColor(this.theme.textPrimary)
        }
        Text(this.thinkSummaryLine(seg.text, running))
          .fontSize('11fp')
          .fontColor(this.theme.textHint)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: label.length > 0 ? 6 : 0 })
        Text(seg.text.length + ' 字')
          .fontSize('10fp')
          .fontColor(this.theme.textHint)
          .margin({ left: 6 })
          .maxLines(1)
        Text(this.isLiveOpen(key, false) ? '▾' : '▸')
          .fontSize('10fp')
          .fontColor(this.theme.textHint)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 4, bottom: 4 })
      .onClick(() => {
        this.toggleLive(key, false);
      })

      if (this.isLiveOpen(key, false)) {
        Text(seg.text.length > 4000 ? '…' + seg.text.substring(seg.text.length - 4000) : seg.text)
          .fontSize('12fp')
          .fontColor(this.theme.textHint)
          .lineHeight(17)
          .width('100%')
          .padding({ top: 2, bottom: 2 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** ReasoningRow 摘要语义（对齐内核/iOS/Android）：running 跟尾最新非空行（尾部 60 字滑动窗），定稿回首行。 */
  private thinkSummaryLine(text: string, running: boolean): string {
    const lines = text.split('\n');
    let picked = '';
    if (running) {
      for (let i = lines.length - 1; i >= 0; i--) {
        if (lines[i].trim().length > 0) {
          picked = lines[i].trim();
          break;
        }
      }
    } else {
      for (let i = 0; i < lines.length; i++) {
        if (lines[i].trim().length > 0) {
          picked = lines[i].trim();
          break;
        }
      }
    }
    if (picked.length === 0) {
      return '';
    }
    return picked.length > 60 ? '…' + picked.substring(picked.length - 60) : picked;
  }

  /** 分段文本归并（answer 段按序拼接；@Builder 体内只允许 UI 组件语法，提取为方法） */
  private joinLiveText(segments: LiveItem[]): string {
    let text = '';
    for (const s of segments) {
      text += s.text;
    }
    return text;
  }

  /** 流式答案块：按 (turn,step) 分段归并后整组拼接渲染 + 折叠（流式展开跟随、结束默认收起）；
   *  展开正文 maxLines 封顶防万字重排卡顿；round 结束后由正式消息气泡接管。 */
  @Builder
  answerLiveBlock(segments: LiveItem[], isSending: boolean, key: string) {
    Column() {
      Row() {
        Text('✍️').fontSize('12fp')
        Text(isSending ? '回答' : '回复预览')
          .fontSize('13fp')
          .fontColor(this.theme.textPrimary)
          .fontWeight(FontWeight.Medium)
          .margin({ left: 6 })
          .layoutWeight(1)
          .maxLines(1)
        Text(this.joinLiveText(segments).length + ' 字')
          .fontSize('10fp')
          .fontColor(this.theme.textHint)
          .maxLines(1)
          .margin({ left: 6 })
        Text(this.isLiveOpen(key, isSending) ? '▾' : '▸')
          .fontSize('10fp')
          .fontColor(this.theme.textHint)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 5, bottom: 5 })
      .onClick(() => {
        this.toggleLive(key, isSending);
      })

      if (this.isLiveOpen(key, isSending)) {
        Text(isSending ? this.joinLiveText(segments) + '▍' : this.joinLiveText(segments))
          .fontSize('13fp')
          .fontColor(this.theme.textPrimary)
          .lineHeight(19)
          .width('100%')
          .maxLines(20)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ top: 6, bottom: 2 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 工具步骤行（一级折叠）：状态色边条 + 名称 + 状态标签，展开看参数与结果。 */
  @Builder
  toolLiveRow(tool: LiveItem, key: string) {
    Column({ space: 4 }) {
      Row() {
        Text('⚙️').fontSize('11fp')
        Text(tool.name)
          .fontSize('12fp')
          .fontColor(this.theme.textPrimary)
          .fontWeight(FontWeight.Medium)
          .margin({ left: 6 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (tool.status === 'running') {
          Text('●').fontSize('8fp').fontColor(this.theme.warning).margin({ left: 4 })
          Text('▾').fontSize('10fp').fontColor(this.theme.textHint)
        } else {
          if (tool.durationMs > 0) {
            Text('⏱ ' + this.fmtDuration(tool.durationMs))
              .fontSize('10fp')
              .fontColor(this.theme.textHint)
              .margin({ left: 6 })
          }
          Text(this.toolStatusLabel(tool.status))
            .fontSize('10fp')
            .fontColor(this.toolStatusColor(tool.status))
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.isLiveOpen(key, false)) {
        if (tool.args.length > 0) {
          Text(tool.args)
            .fontSize('10fp')
            .fontColor(this.theme.textHint)
            .maxLines(4)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        if (tool.result.length > 0) {
          if (this.mcpImageUri(tool, tool.result).length > 0) {
            Image(this.mcpImageUri(tool, tool.result))
              .objectFit(ImageFit.Cover)
              .interpolation(ImageInterpolation.High)
              .width('100%')
              .constraintSize({ maxHeight: 280 })
              .borderRadius(8)
              .backgroundColor(this.theme.surface)
              .margin({ top: 2 })
          } else {
            Text(tool.result)
              .fontSize('10fp')
              .fontColor(tool.status === 'error' ? this.theme.error : this.theme.textHint)
              .maxLines(8)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 8, right: 2, top: 5, bottom: 5 })
    .border({
      width: { left: 2 },
      color: this.toolStatusColor(tool.status)
    })
    .onClick(() => {
      this.toggleLive(key, false);
    })
  }

  /** k4 转向条目：⚡ 橙色高亮行，点击展开注入全文（下一 step 边界生效）。 */
  @Builder
  steerLiveRow(item: LiveItem, key: string) {
    Row() {
      Row()
        .width(3)
        .height(16)
        .borderRadius(1)
        .backgroundColor(this.theme.warning)
        .margin({ right: 8 })
      Text('⚡').fontSize('11fp')
      Text('中途转向')
        .fontSize('12fp')
        .fontColor(this.theme.warning)
        .fontWeight(FontWeight.Medium)
        .margin({ left: 6 })
      Text(this.isLiveOpen(key, false) ? (item.text.length > 400 ? '…' + item.text.substring(item.text.length - 400) : item.text) : item.text)
        .fontSize('11fp')
        .fontColor(this.theme.textHint)
        .maxLines(this.isLiveOpen(key, false) ? 6 : 1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .margin({ left: 6 })
      Text(this.isLiveOpen(key, false) ? '▾' : '▸')
        .fontSize('10fp')
        .fontColor(this.theme.textHint)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 4, bottom: 4 })
    .onClick(() => {
      this.toggleLive(key, false);
    })
  }

  /** k7 子代理/workflow 树节点：缩进边条 + 🤖 标签 + 阶段 + 运行中脉冲点 / 完成态 outcome。 */
  @Builder
  subagentLiveRow(item: LiveItem, key: string) {
    Row() {
      Row()
        .width(3)
        .height(16)
        .borderRadius(1)
        .backgroundColor(this.subagentStatusColor(item))
        .margin({ right: 8 })
      Text('🤖').fontSize('11fp')
      Text(item.name)
        .fontSize('12fp')
        .fontColor(this.theme.textPrimary)
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ left: 6 })
      if (item.status !== 'done' && item.status !== 'error') {
        Text(item.status)
          .fontSize('10fp')
          .fontColor(this.theme.textHint)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 6 })
          .flexShrink(1)
      }
      Blank()
      if (item.result.length === 0) {
        Text('●').fontSize('8fp').fontColor(this.theme.warning).margin({ left: 4 })
        Text('运行中').fontSize('10fp').fontColor(this.theme.warning)
      } else {
        Text(this.subagentOutcomeText(item))
          .fontSize('10fp')
          .fontColor(this.subagentStatusColor(item))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 6 })
          .constraintSize({ maxWidth: '40%' })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 8, right: 2, top: 4, bottom: 4 })
    .onClick(() => {
      this.toggleLive(key, false);
    })
  }

  /** 子代理状态色：运行中=warning / 失败=error / 完成=success。 */
  private subagentStatusColor(item: LiveItem): string {
    if (item.result.length === 0) {
      return this.theme.warning;
    }
    const o = item.result.toLowerCase();
    if (o.indexOf('error') >= 0 || o.indexOf('fail') >= 0) {
      return this.theme.error;
    }
    return this.theme.success;
  }

  private subagentOutcomeText(item: LiveItem): string {
    if (item.result.trim().length === 0) {
      return '完成';
    }
    return item.result.length > 60 ? item.result.substring(0, 60) : item.result;
  }

  /** 待办快照（一级折叠）：标题显示进度 done/total，展开为状态图标列表。 */
  @Builder
  todosLiveBlock(item: LiveItem, key: string) {
    Column() {
      Row() {
        Text(this.isLiveOpen(key, true) ? '▾' : '▸')
          .fontSize('11fp')
          .fontColor(this.theme.textHint)
        Text('✅ 任务清单')
          .fontSize('13fp')
          .fontColor(this.theme.textPrimary)
          .margin({ left: 7 })
          .layoutWeight(1)
          .maxLines(1)
        Text(this.doneCount(item) + '/' + item.todos.length)
          .fontSize('10fp')
          .fontColor(this.theme.textHint)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 5, bottom: 5 })
      .onClick(() => {
        this.toggleLive(key, true);
      })

      if (this.isLiveOpen(key, true)) {
        ForEach(item.todos, (t: TodoSnapshotItem, idx: number) => {
          Row({ space: 8 }) {
            Text(this.todoGlyph(t.status))
              .fontSize('12fp')
              .fontColor(t.status === 'completed' ? this.theme.success
                : (t.status === 'in_progress' ? this.theme.primary : this.theme.textHint))
            Text(t.content)
              .fontSize('12fp')
              .fontColor(t.status === 'completed' ? this.theme.textHint : this.theme.textPrimary)
              .layoutWeight(1)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .padding({ left: 16 })
        }, (t: TodoSnapshotItem, idx: number) => key + '_' + idx)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/**
 * 从持久化 traceJson 还原活动轨迹（历史消息回看，与 Android parseTrace 同格式）。
 * 格式：[{"k":"think","t":".."},{"k":"tool","n":"..","a":"..","s":"ok","r":".."},{"k":"todos","l":[[content,status],..]}]
 */
export function parseTrace(json: string): LiveItem[] {
  const out: LiveItem[] = [];
  try {
    const parsed = JSON.parse(json) as Record<string, Object>[];
    if (!Array.isArray(parsed)) {
      return out;
    }
    for (const o of parsed) {
      const k = o['k'] as string;
      if (k === 'think') {
        const item = new LiveItem();
        item.kind = 'think';
        item.text = (o['t'] as string) ?? '';
        item.step = (o['s'] as number) ?? 0;
        item.turn = (o['u'] as number) ?? 0;
        out.push(item);
      } else if (k === 'tool') {
        const item = new LiveItem();
        item.kind = 'tool';
        item.name = (o['n'] as string) ?? '';
        item.args = (o['a'] as string) ?? '';
        item.status = (o['s'] as string) ?? 'ok';
        item.result = (o['r'] as string) ?? '';
        item.durationMs = (o['ms'] as number) ?? 0;
        out.push(item);
      } else if (k === 'todos') {
        const l = o['l'] as Object[];
        if (l !== undefined && l !== null) {
          const item = new LiveItem();
          item.kind = 'todos';
          const arr: TodoSnapshotItem[] = [];
          for (const pair of l) {
            const p = pair as string[];
            arr.push({ content: p[0] ?? '', status: p[1] ?? 'pending' });
          }
          item.todos = arr;
          out.push(item);
        }
      }
    }
  } catch (_e) {
    // 解析失败按无轨迹处理
  }
  return out;
}
