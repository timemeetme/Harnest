import { AppViewModel } from '../viewmodel/AppViewModel';
import { Theme } from '../theme/Theme';
import { ConnectionStatus } from '../model/UiModels';

@Component
export struct ConnectionSheet {
  @ObjectLink viewModel: AppViewModel;
  @State host: string = '192.168.1.100';
  @State port: string = '3080';
  @State provider: string = 'deepseek';
  @State model: string = 'deepseek-chat';
  @State cwd: string = '/tmp';
  @State useTls: boolean = false;

  aboutToAppear(): void {
    const c = this.viewModel.state.connection;
    this.host = c.host;
    this.port = String(c.port);
    this.provider = c.provider;
    this.model = c.model;
    this.useTls = c.useTls;
    this.cwd = this.viewModel.state.workspace.path || '/tmp';
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        Text('🔌').fontSize(22)
        Text('连接 DSH 内核')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.Dark.textPrimary)
      }
      .width('100%')
      .padding({ top: 16, bottom: 14, left: 16, right: 16 })

      Divider().color(Theme.Dark.divider)

      Scroll() {
        Column({ space: 12 }) {
          this.field('Host', this.host, 'IP 或主机名', (v: string) => { this.host = v; })
          this.field('Port', this.port, '3080', (v: string) => { this.port = v; }, InputType.Number)
          this.field('Provider', this.provider, 'deepseek', (v: string) => { this.provider = v; })
          this.field('Model', this.model, 'deepseek-chat', (v: string) => { this.model = v; })
          this.field('CWD', this.cwd, '/tmp', (v: string) => { this.cwd = v; })

          Row({ space: 8 }) {
            Checkbox().select(this.useTls).onChange((v: boolean) => { this.useTls = v; })
            Text('使用 TLS / wss://')
              .fontSize(13)
              .fontColor(Theme.Dark.textSecondary)
              .layoutWeight(1)
          }
          .padding({ left: 4 })
        }
        .width('100%')
        .padding(16)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)

      Divider().color(Theme.Dark.divider)

      Row({ space: 10 }) {
        Button('取消')
          .layoutWeight(1)
          .type(ButtonType.Normal)
          .backgroundColor(Theme.Dark.surfaceElevated)
          .fontColor(Theme.Dark.textPrimary)
          .onClick(() => { /* caller 控制关闭 */ })
        Button(this.viewModel.state.connection.status === ConnectionStatus.Connected
          ? '断开' : '连接')
          .layoutWeight(1)
          .backgroundColor(
            this.viewModel.state.connection.status === ConnectionStatus.Connected
              ? Theme.Dark.error : Theme.Dark.primary,
          )
          .fontColor(Theme.Dark.textPrimary)
          .onClick(() => { this.submit(); })
      }
      .width('100%')
      .padding(16)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.Dark.surface)
  }

  @Builder
  field(label: string, value: string, placeholder: string,
    onChange: (v: string) => void, inputType: InputType = InputType.Normal) {
    Column({ space: 4 }) {
      Text(label)
        .fontSize(12)
        .fontColor(Theme.Dark.textSecondary)
      TextInput({ text: value, placeholder })
        .width('100%')
        .height(40)
        .fontSize(14)
        .backgroundColor(Theme.Dark.surfaceElevated)
        .borderRadius(8)
        .padding({ left: 12, right: 12 })
        .type(inputType)
        .onChange((v: string) => { onChange(v); })
    }
    .width('100%')
  }

  private async submit(): Promise<void> {
    const portNum = parseInt(this.port, 10) || 3080;
    if (this.viewModel.state.connection.status === ConnectionStatus.Connected) {
      await this.viewModel.disconnectKernel();
    } else {
      await this.viewModel.connectKernel(
        this.host, portNum, this.useTls,
        this.provider, this.model, this.cwd,
      );
    }
  }
}
