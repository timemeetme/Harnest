import { AppViewModel } from '../viewmodel/AppViewModel';
import { Theme } from '../theme/Theme';
import { WindowWidthClass } from '../model/UiModels';
import { Sidebar } from './Sidebar';
import { ChatPane } from './ChatPane';
import { InputBar } from './InputBar';
import { DetailsPanel } from './DetailsPanel';
import { StatusBar } from './StatusBar';

/**
 * AppShell — 根据 widthClass 自适应的骨架组件。
 *
 * 响应式策略：
 *   Compact (< 600px) → 单栏：聊天 + 底部 Tabs 图标切换 Sidebar / Details
 *   Medium  (600-840)  → 双栏：Sidebar 固定 + Chat；Details 作为抽屉
 *   Expanded (> 840)   → 三栏常驻：Sidebar + Chat + Details
 *
 * 所有子组件通过 @ObjectLink 共享同一个 AppViewModel 实例。
 */
@Component
export struct AppShell {
  @ObjectLink viewModel: AppViewModel;
  @State showConnection: boolean = false;

  build() {
    Column() {
      Row({ space: 0 }) {
        this.sidebarSlot();
        Column() {
          StatusBar({ viewModel: this.viewModel });
          this.chatSlot();
          this.inputSlot();
        }
        .layoutWeight(1)
        .height('100%')
        this.detailsSlot();
      }
      .layoutWeight(1)
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.Dark.background)
  }

  @Builder
  sidebarSlot() {
    const cls = this.viewModel.state.widthClass;
    if (cls === WindowWidthClass.Expanded) {
      Sidebar({ viewModel: this.viewModel })
        .width(300)
        .height('100%')
    } else if (cls === WindowWidthClass.Medium) {
      if (this.viewModel.state.sidebarOpen) {
        Sidebar({ viewModel: this.viewModel })
          .width(240)
          .height('100%')
      }
    } else {
      // Compact: sidebar 以 Drawer 形式按需弹出。这里不常驻。
      // Index.ets 负责用 bindSheet/Overlay 弹出。
    }
  }

  @Builder
  chatSlot() {
    Column() {
      ChatPane({ viewModel: this.viewModel })
        .layoutWeight(1)
        .width('100%')
    }
    .layoutWeight(1)
    .width('100%')
    .height('100%')
  }

  @Builder
  inputSlot() {
    InputBar({ viewModel: this.viewModel })
      .width('100%')
  }

  @Builder
  detailsSlot() {
    const cls = this.viewModel.state.widthClass;
    if (cls === WindowWidthClass.Expanded) {
      if (this.viewModel.state.detailsOpen) {
        DetailsPanel({ viewModel: this.viewModel })
          .width(360)
          .height('100%')
          .border({ width: { left: 1 }, color: Theme.Dark.divider })
      }
    } else {
      // Medium/Compact: 作为抽屉由 Index.ets 的 bindSheet 控制
    }
  }
}
