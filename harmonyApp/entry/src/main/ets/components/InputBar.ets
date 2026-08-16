import { AppViewModel } from '../viewmodel/AppViewModel';
import { Theme } from '../theme/Theme';
import { ConnectionStatus } from '../model/UiModels';

@Component
export struct InputBar {
  @ObjectLink viewModel: AppViewModel;
  @State goalInput: string = '';
  @State messageInput: string = '';

  build() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        TextInput({
          text: this.goalInput,
          placeholder: '目标（可选）：告诉 DSH 你要做什么…',
        })
          .layoutWeight(1)
          .height(36)
          .fontSize(13)
          .backgroundColor(Theme.Dark.surfaceElevated)
          .borderRadius(10)
          .padding({ left: 12, right: 12 })
          .onChange((v: string) => {
            this.goalInput = v;
            this.viewModel.setGoal(v);
          })
      }
      .width('100%')

      Row({ space: 8 }) {
        TextInput({
          text: this.messageInput,
          placeholder: '输入消息…',
        })
          .layoutWeight(1)
          .height(44)
          .fontSize(14)
          .backgroundColor(Theme.Dark.surfaceElevated)
          .borderRadius(10)
          .padding({ left: 14, right: 14 })
          .maxLines(4)
          .onChange((v: string) => { this.messageInput = v; })
          .submitLabel(SubmitLabel.Send)
          .onSubmit(() => { this.onSend(); })

        Button(this.viewModel.state.isStreaming ? '停止' : '发送')
          .height(44)
          .padding({ left: 18, right: 18 })
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .backgroundColor(
            this.viewModel.state.isStreaming
              ? Theme.Dark.error
              : Theme.Dark.primary,
          )
          .fontColor(
            this.viewModel.state.isStreaming
              ? Theme.Dark.textPrimary
              : Theme.Dark.primaryOn,
          )
          .enabled(this.canSend())
          .onClick(() => { this.onSend(); })
      }
      .width('100%')
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Theme.Dark.surface)
  }

  private canSend(): boolean {
    if (this.viewModel.state.connection.status !== ConnectionStatus.Connected) return false;
    if (this.viewModel.state.isStreaming) return true;
    return this.messageInput.trim().length > 0;
  }

  private onSend(): void {
    if (this.viewModel.state.isStreaming) {
      // stop
      this.viewModel.state.isStreaming = false;
      return;
    }
    const text = this.messageInput.trim();
    if (!text) return;
    this.messageInput = '';
    this.viewModel.sendMessage(text);
  }
}
