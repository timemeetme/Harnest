import { picker, fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ThemeColors, darkTheme } from '../theme/Theme';
import {
  APPEARANCE_MODES,
  AppearanceMode,
  AppearanceService,
  KEY_APPEARANCE,
  KEY_THEME,
  appearanceLabel
} from '../service/AppearanceService';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { UiState, LogLineUi } from '../model/UiModels';
import { ConfigService, ProviderConfig, ImportOutcome } from '../service/ConfigService';
import { ALL_PROVIDERS, PROVIDER_META } from '../common/Constants';

/**
 * 设置页：大模型 API 配置（EMM 式）+ 局域网服务入口 + 关于。
 */
@Component
export struct SettingsView {
  viewModel: AppViewModel = new AppViewModel();
  onConfigSaved: () => void = () => {};
  /** A4 打开运行日志查看器（由 Index 宿主承载全屏覆盖层） */
  onOpenLogs: () => void = () => {};
  @StorageProp(KEY_THEME) theme: ThemeColors = darkTheme;
  @StorageProp(KEY_APPEARANCE) appearanceMode: string = 'system';
  /** 正在编辑的 provider（null = 列表页） */
  @State editingProvider: string | null = null;
  @State editApiKey: string = '';
  @State editBaseUrl: string = '';
  @State editModels: string = '';
  @State editMaxTokens: string = '';
  @State showImport: boolean = false;
  @State importText: string = '';
  @State importResult: string = '';

  build() {
    Column() {
      this.titleBar()
      if (this.editingProvider === null) {
        this.mainPage()
      } else {
        this.editorPage()
      }
    }
    .width('100%').height('100%')
    .backgroundColor(this.theme.background)
  }

  @Builder
  titleBar() {
    Row() {
      if (this.editingProvider !== null) {
        Text('‹').fontSize('22fp').fontColor(this.theme.textPrimary)
          .padding({ left: 12, right: 8 })
          .onClick(() => {
            this.editingProvider = null;
          })
      } else {
        Text('⚙').fontSize('18fp').fontColor(this.theme.textPrimary)
          .padding({ left: 14, right: 8 })
      }
      Text(this.editingProvider !== null
        ? this.viewModel.providerLabel(this.editingProvider) : '设置')
        .fontSize('17fp').fontColor(this.theme.textPrimary)
      Blank()
    }
    .width('100%')
    .height(52)
    .backgroundColor(this.theme.surface)
    .alignItems(VerticalAlign.Center)
    .border({ width: { bottom: 0.5 }, color: this.theme.divider })
  }

  // ── 主页面 ──────────────────────────────────────────────────

  @Builder
  mainPage() {
    Scroll() {
      Column() {
        this.sectionHeader('外观', '深色 / 浅色 / 跟随系统，即时生效')
        Row() {
          ForEach(APPEARANCE_MODES, (m: AppearanceMode) => {
            Column({ space: 6 }) {
              Radio({ group: 'appearance', value: m })
                .checked(this.appearanceMode === m)
                .width(20).height(20)
                .radioStyle({ checkedBackgroundColor: this.theme.primary })
                .onChange((checked: boolean) => {
                  if (checked) {
                    AppearanceService.get().set(m);
                  }
                })
              Text(appearanceLabel(m))
                .fontSize('12fp')
                .fontColor(this.appearanceMode === m ? this.theme.textPrimary : this.theme.textSecondary)
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          }, (m: AppearanceMode) => m)
        }
        .width('100%')
        .padding({ top: 14, bottom: 14 })
        .borderRadius(10)
        .backgroundColor(this.theme.surface)
        .margin({ left: 16, right: 16 })

        this.sectionHeader('大模型 API', '配置服务商的 API Key（OpenAI 兼容端点，全部在本机内核中调用）')
        ForEach(ALL_PROVIDERS, (p: string) => {
          this.providerRow(p)
        }, (p: string) => p)

        this.sectionHeader('数据', '导入 / 导出模型配置')
        Row({ space: 10 }) {
          Button('导入')
            .fontSize('13fp').fontColor(this.theme.textPrimary)
            .backgroundColor(this.theme.surfaceElevated).borderRadius(8)
            .layoutWeight(1).height(38)
            .onClick(() => {
              this.importResult = '';
              this.showImport = true;
            })
          Button('导出')
            .fontSize('13fp').fontColor(this.theme.textPrimary)
            .backgroundColor(this.theme.surfaceElevated).borderRadius(8)
            .layoutWeight(1).height(38)
            .onClick(() => {
              this.exportConfig();
            })
        }
        .width('100%').padding({ left: 16, right: 16, top: 4 })

        this.sectionHeader('局域网服务', '连接同局域网内其他 deepseek-harness 服务')
        Row() {
          Column({ space: 2 }) {
            Text('发现并连接局域网内核').fontSize('14fp').fontColor(this.theme.textPrimary)
            Text('高级功能 · 后续版本支持').fontSize('11fp').fontColor(this.theme.textHint)
          }
          .alignItems(HorizontalAlign.Start).layoutWeight(1)
          Text('›').fontSize('16fp').fontColor(this.theme.textHint)
        }
        .width('100%')
        .padding(14)
        .borderRadius(10)
        .backgroundColor(this.theme.surface)
        .margin({ left: 16, right: 16 })
        .opacity(0.6)
        .onClick(() => {
          this.viewModel.state.engineStatus = this.viewModel.state.engineStatus;
        })

        this.sectionHeader('开发者', '设备能力桥（通讯录/日历/剪贴板/文件/相册/邮件/拨号/相机/录音/应用）')
        Row() {
          Column({ space: 2 }) {
            Text('设备能力自测').fontSize('14fp').fontColor(this.theme.textPrimary)
            Text('逐项驱动 12 类 device_* 能力，支持直连 / 全链路两种模式').fontSize('11fp').fontColor(this.theme.textHint)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start).layoutWeight(1)
          Text('›').fontSize('16fp').fontColor(this.theme.textHint).margin({ left: 8 })
        }
        .width('100%')
        .padding(14)
        .borderRadius(10)
        .backgroundColor(this.theme.surface)
        .margin({ left: 16, right: 16 })
        .onClick(() => {
          router.pushUrl({ url: 'pages/DeviceTest' });
        })

        Row() {
          Column({ space: 2 }) {
            Text('运行日志').fontSize('14fp').fontColor(this.theme.textPrimary)
            Text('内核与桥接日志（最近 300 行）').fontSize('11fp').fontColor(this.theme.textHint)
          }
          .alignItems(HorizontalAlign.Start).layoutWeight(1)
          Text('›').fontSize('16fp').fontColor(this.theme.textHint).margin({ left: 8 })
        }
        .width('100%')
        .padding(14)
        .borderRadius(10)
        .backgroundColor(this.theme.surface)
        .margin({ left: 16, right: 16 })
        .onClick(() => {
          this.onOpenLogs();
        })

        this.sectionHeader('关于', '')
        Column({ space: 6 }) {
          this.aboutRow('应用', 'Harnest App · 0.2.0')
          this.aboutRow('本地内核', 'deepseek-harness（内置，开箱即用）')
          this.aboutRow('JS 引擎', 'QuickJS (MIT)')
          this.aboutRow('开源许可', 'deepseek-harness / cordis / QuickJS 等项目许可证见源码仓库')
        }
        .width('100%')
        .padding(14)
        .borderRadius(10)
        .backgroundColor(this.theme.surface)
        .margin({ left: 16, right: 16, bottom: 24 })
      }
      .width('100%')
    }
    .layoutWeight(1)
    .width('100%')
    .scrollBar(BarState.Off)

    if (this.showImport) {
      this.importDialog()
    }
  }

  @Builder
  providerRow(p: string) {
    Row() {
      Column({ space: 2 }) {
        Text(PROVIDER_META[p].label).fontSize('14fp').fontColor(this.theme.textPrimary)
        Text(this.rowSubtitle(p)).fontSize('11fp').fontColor(this.theme.textHint)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text(this.viewModel.state.needsConfig && ConfigService.get().getConfig(p).enabled ? '●' : '')
        .fontSize('10fp').fontColor(this.theme.success)
      Text('›').fontSize('16fp').fontColor(this.theme.textHint).margin({ left: 8 })
    }
    .width('100%')
    .padding(14)
    .borderRadius(10)
    .backgroundColor(this.theme.surface)
    .margin({ left: 16, right: 16, top: 6 })
    .onClick(() => {
      this.openEditor(p);
    })
  }

  @Builder
  sectionHeader(title: string, subtitle: string) {
    Column({ space: 2 }) {
      Text(title).fontSize('13fp').fontColor(this.theme.textSecondary)
      if (subtitle.length > 0) {
        Text(subtitle).fontSize('10fp').fontColor(this.theme.textHint)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 18, top: 18, bottom: 6 })
  }

  @Builder
  aboutRow(k: string, v: string) {
    Row() {
      Text(k).fontSize('12fp').fontColor(this.theme.textHint).layoutWeight(1)
      Text(v).fontSize('12fp').fontColor(this.theme.textSecondary)
    }
    .width('100%')
  }

  // ── 编辑页 ──────────────────────────────────────────────────

  @Builder
  editorPage() {
    Scroll() {
      Column({ space: 10 }) {
        Column({ space: 6 }) {
          Text('API Key').fontSize('12fp').fontColor(this.theme.textSecondary)
          TextArea({ text: this.editApiKey, placeholder: 'sk-…' })
            .fontSize('14fp').fontColor(this.theme.textPrimary)
            .placeholderColor(this.theme.textHint)
            .backgroundColor(this.theme.surface)
            .borderRadius(10)
            .constraintSize({ minHeight: 42, maxHeight: 90 })
            .onChange((v: string) => {
              this.editApiKey = v;
            })
        }
        .width('100%').alignItems(HorizontalAlign.Start)

        Column({ space: 6 }) {
          Text('Base URL（OpenAI 兼容端点）').fontSize('12fp').fontColor(this.theme.textSecondary)
          TextInput({ text: this.editBaseUrl, placeholder: 'https://…/v1' })
            .fontSize('14fp').fontColor(this.theme.textPrimary)
            .placeholderColor(this.theme.textHint)
            .backgroundColor(this.theme.surface)
            .borderRadius(10)
            .height(42)
            .onChange((v: string) => {
              this.editBaseUrl = v;
            })
        }
        .width('100%').alignItems(HorizontalAlign.Start)

        Column({ space: 6 }) {
          Text('模型列表（每行一个 ID）').fontSize('12fp').fontColor(this.theme.textSecondary)
          TextArea({ text: this.editModels, placeholder: 'deepseek-chat\ndeepseek-reasoner' })
            .fontSize('13fp').fontColor(this.theme.textPrimary)
            .placeholderColor(this.theme.textHint)
            .backgroundColor(this.theme.surface)
            .borderRadius(10)
            .constraintSize({ minHeight: 80, maxHeight: 200 })
            .onChange((v: string) => {
              this.editModels = v;
            })
        }
        .width('100%').alignItems(HorizontalAlign.Start)

        Column({ space: 6 }) {
          Text('最大输出 Tokens（留空用默认）').fontSize('12fp').fontColor(this.theme.textSecondary)
          TextInput({ text: this.editMaxTokens, placeholder: '如 8192' })
            .fontSize('14fp').fontColor(this.theme.textPrimary)
            .placeholderColor(this.theme.textHint)
            .backgroundColor(this.theme.surface)
            .borderRadius(10)
            .height(42)
            .type(InputType.Number)
            .onChange((v: string) => {
              this.editMaxTokens = v;
            })
        }
        .width('100%').alignItems(HorizontalAlign.Start)

        Button('保存')
          .fontSize('15fp')
          .fontColor(this.theme.primaryOn)
          .backgroundColor(this.theme.primary)
          .borderRadius(10)
          .width('100%')
          .height(44)
          .margin({ top: 8 })
          .onClick(() => {
            this.saveEditor();
          })
      }
      .width('100%')
      .padding(16)
    }
    .layoutWeight(1)
    .width('100%')
    .scrollBar(BarState.Off)
  }

  @Builder
  importDialog() {
    Column({ space: 10 }) {
      Text('导入模型配置').fontSize('16fp').fontColor(this.theme.textPrimary)
      Button('📂 从文件导入\n（EyeMouthMind 导出的 JSON）')
        .fontSize('15fp').fontWeight(FontWeight.Medium)
        .fontColor(this.theme.primaryOn)
        .backgroundColor(this.theme.primary).borderRadius(10)
        .width('100%').height(56)
        .onClick(() => {
          this.importFromFile();
        })
      Text('或粘贴 JSON 文本：').fontSize('12fp').fontColor(this.theme.textHint)
      TextArea({ text: this.importText, placeholder: '{ "type": "emm_model_config", … }' })
        .fontSize('13fp').fontColor(this.theme.textPrimary)
        .placeholderColor(this.theme.textHint)
        .backgroundColor(this.theme.background)
        .borderRadius(10)
        .constraintSize({ minHeight: 72, maxHeight: 140 })
        .width('100%')
        .onChange((v: string) => {
          this.importText = v;
        })
      if (this.importResult.length > 0) {
        Text(this.importResult).fontSize('12fp').fontColor(this.theme.textSecondary)
      }
      Row({ space: 10 }) {
        Button('取消')
          .fontSize('14fp').fontColor(this.theme.textPrimary)
          .backgroundColor(this.theme.surfaceElevated).borderRadius(8)
          .layoutWeight(1).height(38)
          .onClick(() => {
            this.showImport = false;
          })
        Button('导入')
          .fontSize('14fp').fontColor(this.theme.primaryOn)
          .backgroundColor(this.theme.primary).borderRadius(8)
          .layoutWeight(1).height(38)
          .onClick(() => {
            this.doImport();
          })
      }
      .width('100%')
    }
    .width('86%')
    .padding(16)
    .borderRadius(14)
    .backgroundColor(this.theme.surface)
    .position({ x: '7%', y: '18%' })
  }

  // ── 逻辑 ────────────────────────────────────────────────────

  private rowSubtitle(p: string): string {
    const cfg = ConfigService.get().getConfig(p);
    if (cfg.apiKey.trim().length > 0) {
      return '已配置 · ' + cfg.defaultModel;
    }
    return PROVIDER_META[p].baseUrl.length > 0 ? PROVIDER_META[p].baseUrl : '自定义端点';
  }

  private openEditor(p: string): void {
    const cfg = ConfigService.get().getConfig(p);
    this.editingProvider = p;
    this.editApiKey = cfg.apiKey;
    this.editBaseUrl = cfg.baseUrl;
    this.editModels = cfg.models.join('\n');
    this.editMaxTokens = cfg.maxTokens !== undefined ? String(cfg.maxTokens) : '';
  }

  private saveEditor(): void {
    const p = this.editingProvider;
    if (p === null) {
      return;
    }
    const models = this.editModels
      .split('\n')
      .map((s: string) => s.trim())
      .filter((s: string) => s.length > 0);
    const meta = PROVIDER_META[p];
    const finalModels = models.length > 0 ? models : meta.models.slice();
    let defaultModel = ConfigService.get().getConfig(p).defaultModel;
    if (finalModels.indexOf(defaultModel) < 0) {
      defaultModel = finalModels.length > 0 ? finalModels[0] : meta.defaultModel;
    }
    const cfg: ProviderConfig = {
      provider: p,
      apiKey: this.editApiKey.trim(),
      baseUrl: this.editBaseUrl.trim().length > 0 ? this.editBaseUrl.trim() : meta.baseUrl,
      models: finalModels,
      defaultModel: defaultModel,
      enabled: this.editApiKey.trim().length > 0
    };
    const mt = parseInt(this.editMaxTokens.trim(), 10);
    if (!isNaN(mt) && mt > 0) {
      cfg.maxTokens = mt;
    }
    ConfigService.get().setConfig(cfg);
    this.viewModel.refreshNeedsConfig();
    this.onConfigSaved();
    this.editingProvider = null;
  }

  /** 导出：文件保存（EMM 兼容格式，文件名 model_config_日期时间.json） */
  private async exportConfig(): Promise<void> {
    try {
      const json = ConfigService.get().exportConfigJson();
      const ts = new Date();
      const fname = 'model_config_' + ts.getFullYear() + this.pad2(ts.getMonth() + 1) + this.pad2(ts.getDate())
        + '_' + this.pad2(ts.getHours()) + this.pad2(ts.getMinutes());
      const ctx = getContext(this) as common.UIAbilityContext;
      const docPicker = new picker.DocumentViewPicker(ctx);
      const saveOpts: picker.DocumentSaveOptions = { newFileNames: [fname + '.json'] } as picker.DocumentSaveOptions;
      const uris: string[] = await docPicker.save(saveOpts);
      if (uris.length === 0) {
        return;
      }
      const fd = fileIo.openSync(uris[0], 0o100 | 0o2);
      fileIo.writeSync(fd.fd, json);
      fileIo.closeSync(fd);
      promptAction.showToast({ message: '导出成功' });
    } catch (_e) {
      promptAction.showToast({ message: '导出失败' });
    }
  }

  /** 导入：从文件选择器读取 JSON（EMM 导出文件直接可选） */
  private async importFromFile(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const docPicker = new picker.DocumentViewPicker(ctx);
      const uris: string[] = await docPicker.select({
        maxSelectNumber: 1,
        fileSuffixFilters: ['.json']
      });
      if (uris.length === 0) {
        return;
      }
      const content = this.readDocFile(uris[0]);
      if (content.length === 0) {
        promptAction.showToast({ message: '文件内容为空' });
        return;
      }
      this.importText = content;
      // 文件导入成功即生效：提示结果并关闭对话框（避免二次点击“导入”读到空文本误报失败）
      if (this.doImport()) {
        promptAction.showToast({ message: this.importResult });
        this.showImport = false;
      }
    } catch (_e) {
      promptAction.showToast({ message: '选择文件已取消' });
    }
  }

  /** 读取 picker 选择的文本文件（UTF-8，跳过 BOM） */
  private readDocFile(uri: string): string {
    try {
      const f = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const st = fileIo.statSync(uri);
      const buf = new ArrayBuffer(st.size);
      fileIo.readSync(f.fd, buf);
      fileIo.closeSync(f);
      const decoder = util.TextDecoder.create('utf-8');
      let text = decoder.decodeWithStream(new Uint8Array(buf));
      if (text.length > 0 && text.charCodeAt(0) === 0xFEFF) {
        text = text.substring(1);
      }
      hilog.info(0x0306, 'SettingsView', 'readDocFile ok: size=%{public}d textLen=%{public}d head=%{public}s',
        st.size, text.length, text.substring(0, 80));
      return text;
    } catch (e) {
      const msg = e instanceof Error ? e.message : JSON.stringify(e);
      hilog.error(0x0306, 'SettingsView', 'readDocFile fail: %{public}s', msg);
      return '';
    }
  }

  private pad2(n: number): string {
    return n < 10 ? '0' + n : '' + n;
  }

  /** @return true=导入成功（含“无新配置”）；false=空输入或格式错误 */
  private doImport(): boolean {
    const text = this.importText.trim();
    if (text.length === 0) {
      this.importResult = '请粘贴 JSON，或点击上方「从文件导入」';
      return false;
    }
    const outcome: ImportOutcome = ConfigService.get().importConfigJson(text);
    if (outcome.error) {
      this.importResult = '导入失败：格式错误或体积过大';
      return false;
    }
    let msg = outcome.imported > 0 ? '已导入 ' + outcome.imported + ' 项配置' : '无新配置（已存在相同配置）';
    if (outcome.skipped.length > 0) {
      msg += '；跳过 ' + outcome.skipped.join('、') + '（原生协议暂不支持）';
    }
    this.importResult = msg;
    this.viewModel.refreshNeedsConfig();
    this.onConfigSaved();
    this.importText = '';
    return true;
  }
}

/**
 * A4 运行日志查看器：全屏覆盖层（Android LogsOverlay 同构）。
 * 标题 + 行数 + 清空/关闭；等宽字体滚动列表，LogLineUi.seq 稳定键防环形截断全列表重渲染。
 */
@Component
export struct LogsOverlay {
  viewModel: AppViewModel = new AppViewModel();
  @ObjectLink state: UiState;
  @StorageProp(KEY_THEME) theme: ThemeColors = darkTheme;
  onClose: () => void = () => {};

  build() {
    Column() {
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text('运行日志').fontSize('16fp').fontColor(this.theme.textPrimary)
          Text(this.state.logLines.length + ' 行').fontSize('10fp').fontColor(this.theme.textHint)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('清空')
          .fontSize('13fp')
          .fontColor(this.theme.textSecondary)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .onClick(() => {
            this.viewModel.clearLogs();
          })
        Text('关闭')
          .fontSize('13fp')
          .fontColor(this.theme.primary)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')
      .height(52)
      .padding({ left: 16, right: 16 })
      .backgroundColor(this.theme.surface)
      .alignItems(VerticalAlign.Center)

      List({ space: 2 }) {
        ForEach(this.state.logLines, (line: LogLineUi) => {
          ListItem() {
            Text(line.text)
              .fontSize('10fp')
              .fontFamily('monospace')
              .fontColor(this.theme.textSecondary)
              .width('100%')
          }
        }, (line: LogLineUi) => 'log_' + line.seq)
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.background)
  }
}
