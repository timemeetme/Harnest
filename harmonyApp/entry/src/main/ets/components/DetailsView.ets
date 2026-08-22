import { ThemeColors, darkTheme } from '../theme/Theme';
import { KEY_THEME } from '../service/AppearanceService';
import { UiState, ChatMessage, MessageRole, LiveItem } from '../model/UiModels';
import { TodoSnapshotItem } from '../service/HarnessNative';
import { parseTrace } from './ChatView';

/**
 * 详情页：回合执行轨迹（Trajectory）。
 * 对齐官方 GUI 的 Trajectory 视图 — 按时间序列出当前会话的全部工具调用
 * （含 todo_write 快照），与消息流内联气泡同源同数据。
 */
@Component
export struct DetailsView {
  @ObjectLink @Watch('onStateChanged') state: UiState;
  @StorageProp(KEY_THEME) theme: ThemeColors = darkTheme;
  private scroller: Scroller = new Scroller();

  onStateChanged(): void {
    this.scroller.scrollEdge(Edge.Bottom);
  }

  build() {
    Column() {
      this.header()
      if (this.trajItems().length === 0) {
        this.emptyState()
      } else {
        this.trajList()
      }
    }
    .width('100%').height('100%')
    .backgroundColor(this.theme.background)
  }

  @Builder
  header() {
    Column({ space: 4 }) {
      Row() {
        Text('轨迹').fontSize('17fp').fontColor(this.theme.textPrimary).layoutWeight(1)
      }
      .width('100%').height(48)
      .padding({ left: 16 })
      .alignItems(VerticalAlign.Center)

      Row({ space: 12 }) {
        Text('调用 ' + this.totalCalls().toString()).fontSize('11fp')
          .fontColor(this.theme.textSecondary)
        Text('失败 ' + this.errorCalls().toString()).fontSize('11fp')
          .fontColor(this.errorCalls() > 0 ? this.theme.error : this.theme.textHint)
        Text('待办 ' + this.totalTodos().toString()).fontSize('11fp')
          .fontColor(this.theme.textSecondary)
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })
    }
    .width('100%')
    .backgroundColor(this.theme.surface)
    .border({ width: { bottom: 0.5 }, color: this.theme.divider })
  }

  @Builder
  emptyState() {
    Column() {
      Text('🧭').fontSize('34fp')
      Text('暂无执行轨迹').fontSize('15fp')
        .fontColor(this.theme.textSecondary).margin({ top: 8 })
      Text('AI 使用工具（如 todo_write）后，调用轨迹将在此汇总展示').fontSize('11fp')
        .fontColor(this.theme.textHint).margin({ top: 4 })
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ left: 32, right: 32 })
  }

  @Builder
  trajList() {
    List({ scroller: this.scroller, space: 8 }) {
      ForEach(this.trajItems(), (m: ChatMessage) => {
        ListItem() {
          this.trajCard(m)
        }
      }, (m: ChatMessage) => m.id)
    }
    .layoutWeight(1)
    .width('100%')
    .padding({ left: 12, right: 12, top: 12, bottom: 12 })
    .scrollBar(BarState.Off)
  }

  @Builder
  trajCard(m: ChatMessage) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text('⚙').fontSize('13fp')
          .fontColor(m.toolStatus === 'error' ? this.theme.error : this.theme.primary)
        Text(m.toolName).fontSize('13fp')
          .fontColor(this.theme.textPrimary)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.statusLabel(m.toolStatus)).fontSize('10fp')
          .fontColor(this.statusColor(m.toolStatus))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(9)
          .backgroundColor(this.theme.surfaceElevated)
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
    .width('100%')
    .padding(12)
    .borderRadius(10)
    .backgroundColor(this.theme.surface)
    .border({
      width: { left: 2 },
      color: m.toolStatus === 'error' ? this.theme.error
        : (m.toolStatus === 'running' ? this.theme.warning : this.theme.divider)
    })
  }

  // ── 辅助 ──────────────────────────────────────────────────

  /**
   * 工具轨迹来源：旧数据为独立 Tool 消息；新架构归并进 assistant 消息的 traceJson，此处展开还原。
   */
  private trajItems(): ChatMessage[] {
    const out: ChatMessage[] = [];
    for (const m of this.state.messages) {
      if (m.role === MessageRole.Tool) {
        out.push(m);
      } else if (m.role === MessageRole.Assistant && m.traceJson.length > 0) {
        for (const t of parseTrace(m.traceJson)) {
          if (t.kind !== 'tool') {
            continue;
          }
          const v = new ChatMessage();
          v.id = m.id + '_t_' + (t.callId.length > 0 ? t.callId : t.name);
          v.role = MessageRole.Tool;
          v.createdAt = m.createdAt;
          v.toolName = t.name;
          v.toolStatus = t.status;
          v.toolResult = t.result.length > 0 ? t.result : t.args;
          out.push(v);
        }
      }
    }
    return out;
  }

  private totalCalls(): number {
    return this.trajItems().length;
  }

  private errorCalls(): number {
    return this.trajItems().filter((m: ChatMessage) => m.toolStatus === 'error').length;
  }

  /** 最新 todo 快照的条目数（优先 traceJson 内 Todos 项，兜底旧 todosJson；无快照为 0） */
  private totalTodos(): number {
    let count = 0;
    for (const m of this.state.messages) {
      if (m.traceJson.length > 0) {
        let found = false;
        for (const it of parseTrace(m.traceJson)) {
          if (it.kind === 'todos') {
            found = true;
            count = it.todos.length;
          }
        }
        if (found) {
          continue;
        }
      }
      if (m.todosJson.length > 0) {
        count = this.parseTodos(m.todosJson).length;
      }
    }
    return count;
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

  private statusLabel(status: string): string {
    if (status === 'error') return '失败';
    if (status === 'running') return '运行中';
    return '完成';
  }

  private statusColor(status: string): string {
    if (status === 'error') return this.theme.error;
    if (status === 'running') return this.theme.warning;
    return this.theme.textHint;
  }
}
