# Harnest 项目记忆（Project Memory）

> 本文件是 TRAE 项目记忆：每次会话自动加载，新会话开工前先读这里，避免重复踩坑。
> 由 TRAE 生成并按项目进展自动维护：每次会话发生实质变更（新提交/新结论/新陷阱）时由当前会话直接更新。人工修改请同步更新「维护日志」。
>
> 最后同步 HEAD: 7500cc0924 （2026-08-23，双机融合）

## 项目身份

- **仓库**: `git@github.com:timemeetme/Harnest.git`，主分支 `main`
- **双机开发**：
  - **macOS 机**（Mac）：SSH 密钥属 `heavencme`（协作者，push 已验证）；JDK17/homebrew、XcodeGen、iPhone 17 Pro 模拟器
  - **Windows 机**（`d:\Projects\HarnessApp`）：remote 走 https + gh CLI（已登录）；无 macOS，iOS 依赖 CI 验证
- **提交风格**: Conventional Commits（`fix(ios):` / `test(ios):` / `fix(all):` / `ci(ios):` / `feat` / `docs`，scope 常为 ios/android/harmony/all）
- **产品**: 跨平台 AI Agent 对话前端（harness 客户端），多 LLM provider、本地配置存储，四端（iOS/Android/鸿蒙/共享内核）

## 架构地图

**内核链路（先理解这条线）**：
```
kernel/deepseek-harness (git 子模块，上游 deepseek-ai/deepseek-harness)
        │  kernel.sh / kernel.ps1 同步（需 pnpm@11，本地起服务默认端口 3080，profile=mobile）
        ▼
tools/harness-transpiler (TS 转译器，pnpm；含 quickjs-compat 检查，配置在 kernel/configs/*.cordis.yml)
        ▼
各端打包 harness.js：iosApp/Resources/harness.js、harmonyApp/.../rawfile/harness.js
```

**端侧**：
- `iosApp/` — SwiftUI App；内核 = harness.js 经 **JavaScriptCore** 桥接执行（`HarnessEngine.swift`）。**XCFramework 是 CI 对齐产物，App 本身不链接它**。工程由 project.yml 经 **XcodeGen** 生成（xcodeproj 已 gitignore）
- `androidApp/` — Kotlin 镜像实现（gradle 模块 `:androidApp:app`）
- `harmonyApp/` — ArkTS + **QuickJS C++ 内核**（`harness_engine.cpp`），hvigor 构建（不在 gradle 内）
- `shared/` — KMP 共享模块（gradle `:shared`），iOS 产物为 XCFramework
- CI: `.github/workflows/` — build-ios / build-android / build-harmony / kernel-sync / release

**iOS 关键源码**（都在 `iosApp/Sources/`）：
- `Service/HarnessEngine.swift` — JS 桥：`boot(cwd:)` / `callFunc`(同步) / `callAwait`(异步) / `jsStringLiteral`；错误类型 `EngineError`
- `Service/LocalEngine.swift` — 单例封装：`ensureStarted()`（无可配置 provider 抛 `.notConfigured`）/ `mountSession` / `chat` / `listProviders`
- `Service/ConfigService.swift` — `api_config.json` 持久化 + 内存缓存；空 apiKey = disabled
- `Service/Providers.swift` — 9 个预设 provider（deepseek baseUrl `https://api.deepseek.com`、默认模型 `deepseek-chat`）
- `AppStore.swift` — 状态中枢；**引擎懒启动**：首次发消息才 `ensureStarted`，App 启动不 boot；`fallBackUnavailableProvider(&:)` 挂载前校验（见陷阱 9）
- `Tests/HarnestTests/` — XCTest 套件（见下）

## 已验证命令

### macOS 机（全部跑通过）

```bash
# JDK 17（homebrew openjdk@17）
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home

# KMP 共享模块（gradlew git 权限是 100644，必须 sh 调用或先 chmod +x）
sh ./gradlew :shared:assembleSharedReleaseXCFramework --no-daemon   # ~3min，产物 shared/build/XCFrameworks/release/
sh ./gradlew :shared:iosSimulatorArm64Test --no-daemon             # iOS 目标单测（allTests 需要 ANDROID_HOME，本机没有）

# iOS（先进入 iosApp/；改 project.yml 后必须 xcodegen generate 重新生成工程）
cd iosApp && xcodegen generate
xcodebuild build -project Harnest.xcodeproj -scheme Harnest \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'         # Debug
xcodebuild test  -project Harnest.xcodeproj -scheme Harnest \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'         # 14 个 XCTest
# Release 验证：加 -configuration Release

# 内核子模块（首次克隆后需要）
git submodule update --init --recursive
```

### Windows 机（全部跑通过）

```powershell
# Android Kotlin 编译验证（离线复用依赖缓存，~1min）
cd androidApp; .\gradlew.bat :app:compileDebugKotlin --offline

# CI 状态查询（gh 已登录；偶发 TLS handshake timeout，等 1-2 分钟重试即可，非代理问题）
gh run list --limit 3
gh run view <run-id> --log-failed | Select-String 'error:' | Sort-Object -Unique   # 抓编译错误清单

# Harmony/真机：hdc（Harmony 设备）在 PATH；装机用 HarmonyOS Studio 侧的 DevEco 工具链
```

## 已知陷阱（重要，勿重复踩）

1. **gradlew 无执行位**（git mode 100644）→ macOS 用 `sh ./gradlew ...`（Windows 用 `.\gradlew.bat`，无此问题）；CI 里已自带 `chmod +x`，非仓库 bug，勿"修复"
2. **`:shared:allTests` 在 Mac 必失败**（无 Android SDK）→ 用 `:shared:iosSimulatorArm64Test`
3. **Swift 值语义移植陷阱**：Kotlin `JSONObject` 是可变引用（原地 put 即更新缓存），Swift 字典是值类型（改副本必须显式回写）。已因此修过 ConfigService 缓存不回写 bug（c5d5d82e71），移植 Kotlin 代码时警惕同类模式
4. **引擎懒启动**：App 冷启动无引擎日志是正常的，别在启动期找 boot 输出；测试想触发 boot 必须走 `ensureStarted` 或发消息
5. **xcodeproj 是生成物**（gitignore）：工程改动一律改 `project.yml` 再 `xcodegen generate`，别手改 xcodeproj
6. **JSONSerialization 解析顶层标量**（如裸字符串字面量）必须加 `.fragmentsAllowed`
7. **osascript 无辅助功能权限**（-1719）→ 坐标点击式 UI 自动化不可用；UI 验证用 XCTest/XCUITest（已有 accessibilityLabel 锚点：Tab「设置」、SecureField「sk-…」、按钮「保存」「发送」、TextField「发送消息…」）
8. **裸 boot 的内核 `listProviders` 返回空数组**：必须先 `init` 注入 provider 档案才非空（AppStore 的 providerCatalog 有 fallback）
9. **挂载旧会话报 `no adapter registered for provider "deepseek"`（NO_ADAPTER）**：会话记录持久化了 provider，但该 provider 的 apiKey 事后被清空（重装/换设备/部分导入配置）后，内核 `init` 不会为它注册 adapter，而内核 `setModel` **不做任何校验**直接写入。三端已在挂载前校验 apiKey 为空则回落默认可用选择并改写会话记录（393558f：Android MainActivity.sendNow / Harmony AppViewModel.doSend / iOS AppStore.fallBackUnavailableProvider + rebootEngine 重挂载点）。新增挂载路径时记得带同样校验
10. **iOS Swift 首次真实编译暴露的 8 类错误**（CI 第 6 轮 31 处，544cb0a 修复；Mac 本地当时未暴露是因为本地工程在修复后才重新生成）。写新 Swift 代码时警惕：
    - PHPicker 全家（`PHPickerViewController/Delegate/Result/Configuration`）需 `import PhotosUI`，仅 `import Photos` 不够
    - EventKit 枚举是单数：`EKEventStore.authorizationStatus(for: .event)`，不存在 `.events`
    - 新 SDK `JSContext.globalObject` 返回 `JSValue?`（非隐式拆包），必须 guard let 后才能 `.setObject`
    - `@ViewBuilder` 函数里不能 `return` 早退，改 if / else if / else 结构
    - `UnevenRoundedRectangle` 是 iOS 16.4+ API，部署目标是 16.0 → 用项目自带 `TopRoundedShape`（就是为此写的）
    - 参数为 `Substring` 的函数接 `String` 调用会错 → 泛型化 `<S: StringProtocol>`
    - struct 有 `id` 字段不够，`ForEach`/`List` 需显式声明 `Identifiable`（需要 `==` 比较时加 `Equatable`）
    - 实例方法闭包里调静态方法必须 `Self.` 前缀；`Button(action:)` 签名是 `() -> Void`，带默认参方法要写 `Button(action: { submit() })`
11. **xcodegen 工程名链**：project.yml `name: Harnest` → 生成 `Harnest.xcodeproj`。CI 里 `xcodebuild -project`、`-archivePath`、artifact 路径必须全部匹配该名；archive 后 .app 位于 `build/<name>.xcarchive/Products/Applications/`，**不是** `build/Release-iphoneos/`
12. **Harmony CI 三坑**（418e7df/19a355b 修复）：Node 20 会挂需 22；`capability-manual.ts` 是 transpiler 构建源必须 git track（.gitignore 误伤过）；hvigor 打包步骤 best-effort（无签名证书，失败不阻塞）
13. **会话中断丢修改**：TRAE 会话上下文丢失恢复后，先前已"写入文件"的修改可能部分丢失——恢复后必须 `git diff` 与错误清单逐条核对再提交

## 环境事实

- Mac：iPhone 17 Pro 模拟器；App 容器内 `api_config.json` 首启自动播种 9 个 provider 默认配置
- Mac 测试注入 fake key 后 chat 全链路可达 DeepSeek API 并正确回传 401（说明 JS 内核→网络桥→错误 surfaced 链路通）
- Windows：Harmony 真机可用（hdc）；Android 真机/模拟器可用；iOS 无法本机编译（无 macOS），全靠 CI（macos-14 runner，XcodeGen + xcodebuild，产物 .app + XCFramework）
- `.trae/` 未被 gitignore（本文件可提交共享）；`iosApp/*.xcodeproj`、`build/`、DerivedData 已忽略
- `kernel/deepseek-harness` 子模块在 Windows 机常有本地工作区改动（kernel.ps1 同步产物），提交父仓库时勿顺手带上

## 验证状态快照（2026-08-22/23）

- ✅ **CI 三端 workflow 全绿**（第 8 轮 393558f 验证）：Build Harmony 2m47s / Build Android 3m7s / Build iOS 6m50s
- ✅ iOS CI 产物：`.app` bundle（~785KB，可下载后 `codesign -f -s -` ad-hoc 装机）+ XCFramework（~13.8MB）
- ✅ XCTest **14/14 通过**（Mac，EngineBridgeTests 6 + LocalEngineFlowTests 4 + ProvidersCatalogTests 4，iPhone 17 Pro 模拟器）
- ✅ iOS Debug + Release 构建通过（Mac 本地 + CI 双验证）
- ✅ `:shared:iosSimulatorArm64Test` 通过；XCFramework 51MB（ios-arm64 + ios-arm64_x86_64-simulator 双 slice）
- ✅ Windows `:app:compileDebugKotlin --offline` 通过（393558f 时点）
- ⬜ 未验证：kernel.sh/kernel.ps1 转译全流程；真机回归 NO_ADAPTER 修复（清空 deepseek key 后重开旧会话应回落默认 provider 不报错）

## CI 修复史（8 轮迭代，2026-08-22，Windows 端）

| 轮 | 结果 | 修复 |
|---|---|---|
| 1-2 | Android ✗ | 任务路径 `:app:assembleApp310Release`、artifact 路径修正 |
| 3 | Harmony ✗ | pnpm 缓存 + Node 20→22 |
| 4 | iOS ✗ | runner 付费问题、KMP commonMain 13 处 Kotlin 错误（04b05eb） |
| 5 | iOS ✗ | xcodegen 工程名不匹配（b622b1b，见陷阱 11） |
| 6 | iOS ✗ | 31 处 Swift 编译错误（544cb0a，见陷阱 10）——iOS 代码首次被真实编译 |
| 7 | 三端 ✅✅✅ | iOS 首绿（11m16s），产出 .app + XCFramework |
| 8 | 三端 ✅✅✅ | 393558f NO_ADAPTER 三端修复验证（iOS 6m50s 缓存加速） |

Mac 端后续（2026-08-23）：c5d5d82e71（ConfigService 缓存回写值语义 bug）、6ae91064a3（XCTest 套件）、7500cc0924（本记忆文件初始版）

## 维护协议（后续会话遵循）

1. 新会话先读本文件；发现内容过时，**先更新本文件再干活**
2. 实质变更（新提交、新陷阱、新命令、验证状态变化）→ 追加「维护日志」一行，并更新顶部「最后同步 HEAD」
3. **自动同步 GitHub**（用户指令 2026-08-23）：会话内产生阶段性进展（新提交落地/新结论/新陷阱）后，**本会话结束前必须**把记忆更新以独立提交推送到 origin/main（`docs(memory): ...`），保证双机记忆一致——不要只改文件不推送
4. 「已知陷阱」只追加或修订，**不删除**条目
5. 记录命令时必须是**本机验证过**的形式（注明 macOS/Windows 机）；未验证的标 ⬜

## 维护日志

- 2026-08-23 初始生成（HEAD 6ae91064a3，Mac）。沉淀：iOS 全链路验证结论（14/14 测试、Debug+Release 构建、XCFramework、模拟器 E2E）、ConfigService 值语义 bug 根因与修复、8 条陷阱、四端架构与内核子模块链路
- 2026-08-23 Windows 端融合（基线 7500cc0924）。沉淀：CI 8 轮修复史与三端全绿结论、iOS artifact 产物路径、陷阱 9-13（NO_ADAPTER 挂载校验、Swift 8 类编译错误、xcodegen 工程名链、Harmony CI 三坑、会话中断丢修改）、Windows 机验证命令段、双机开发环境事实
- 2026-08-23 维护协议新增第 3 条（基线 f2b48c5489）：会话内进展自动更新记忆并推送 GitHub（用户确认采用"仅会话内"模式，不建定时任务）
