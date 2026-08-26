# Harnest 项目记忆（Project Memory）

> 本文件是 TRAE 项目记忆：每次会话自动加载，新会话开工前先读这里，避免重复踩坑。
> 由 TRAE 生成并按项目进展自动维护：每次会话发生实质变更（新提交/新结论/新陷阱）时由当前会话直接更新。人工修改请同步更新「维护日志」。
>
> 最后同步 HEAD: 74cc1c4452（2026-08-26，Mac 机：远端 31 提交合流 + Providers 预设刷新 + stream failed 错误详情透出（LlmFailure.detail）修复，见 74cc1c4452）

## 项目身份

- **仓库**: `git@github.com:timemeetme/Harnest.git`，主分支 `main`
- **双机开发**：
  - **macOS 机**（Mac）：SSH 密钥属 `heavencme`（协作者，push 已验证）；JDK17/homebrew、XcodeGen、iPhone 17 Pro 模拟器
  - **Windows 机**（`d:\Projects\HarnessApp`）：remote 走 https + gh CLI（已登录）；无 macOS，iOS 依赖 CI 验证
- **提交风格**: Conventional Commits（`fix(ios):` / `test(ios):` / `fix(all):` / `ci(ios):` / `feat` / `docs`，scope 常为 ios/android/harmony/all）
- **三端一致纪律（用户 2026-08-26 明确要求）**: 后续所有修改必须在 iOS / Android / 鸿蒙三端同时保持一致并同批合入 main——改动前先列三端对应文件清单逐端落地并互核取值/行为一致；同批提交推送，禁止只改单端留下漂移；发现历史漂移（如某端缺迁移逻辑）主动补齐再合入；门禁覆盖三端（Android compileDebugKotlin + 鸿蒙 hvigorw 本地跑，iOS 靠 CI，推送后盯三端 workflow 全绿）
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
# Xcode 27 beta（2026-08-24 起本机唯一 Xcode：/Applications/Xcode-beta.app 27A5237l；
# xcode-select 仍指向 CommandLineTools，命令行用 xcodebuild 前必须设 DEVELOPER_DIR，免 sudo）
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer

# JDK 17（homebrew openjdk@17）
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home

# KMP 共享模块（gradlew git 权限是 100644，必须 sh 调用或先 chmod +x）
sh ./gradlew :shared:assembleSharedReleaseXCFramework --no-daemon   # ~3min，产物 shared/build/XCFrameworks/release/
sh ./gradlew :shared:iosSimulatorArm64Test --no-daemon             # iOS 目标单测（allTests 需要 ANDROID_HOME，本机没有）

# iOS（先进入 iosApp/；改 project.yml 后必须 xcodegen generate 重新生成工程）
cd iosApp && xcodegen generate
xcodebuild build -project Harnest.xcodeproj -scheme Harnest \
  -destination 'platform=iOS Simulator,name=iPhone 17e'          # Debug（OS 26.5 起 17 Pro 模拟器没了，用 17e）
xcodebuild test  -project Harnest.xcodeproj -scheme Harnest \
  -destination 'platform=iOS Simulator,name=iPhone 17e'          # 14 个 XCTest
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

# Harmony 本地构建 + 真机装机（2026-08-25 验证，node v24；hdc/adb 都不在 PATH，用绝对路径）
# 构建（首次需先 npm install——devDeps 是 file: 指向 DevEco Studio 内置包，会生成 package-lock.json，勿提交）：
cd d:\Projects\HarnessApp\harmonyApp
npm install
$env:DEVECO_SDK_HOME = "C:\Program Files\Huawei\DevEco Studio\sdk"
$env:PATH = "C:\Program Files\Huawei\DevEco Studio\tools\node;" + $env:PATH
.\hvigorw.bat --mode module -p module=entry@default assembleHap --no-daemon
# 产物：entry\build\default\outputs\default\entry-default-signed.hap（~8.2MB）
# 本地调试签名走 build-profile.json5 指向 C:\Users\heave\.ohos\config\ 的 DevEco 自动签名证书（CI 没有的能力）
# hdc 真机操作（设备 6HR0226328004267）：
$hdc = "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
& $hdc list targets
& $hdc -t 6HR0226328004267 install -r .\entry\build\default\outputs\default\entry-default-signed.hap
& $hdc -t 6HR0226328004267 shell aa start -a EntryAbility -b com.harnest.app      # 锁屏时会失败(Error 10106102)，需人工解锁
& $hdc -t 6HR0226328004267 shell aa force-stop com.harnest.app
& $hdc -t 6HR0226328004267 shell "ps -ef | grep harnest | grep -v grep"            # 进程存活验证

# transpiler 重新打包 harness.js 并分发三端（2026-08-24 验证，node v24）
cd tools\harness-transpiler; node build.mjs; node patch.mjs   # 产物 output\harness.js；esbuild 把中文转 \uXXXX 转义，grep 中文搜不到是正常的
node check-quickjs-compat.mjs                                  # QuickJS 兼容门禁
cd ..\..   # 回根目录分发：
Copy-Item tools\harness-transpiler\output\harness.js iosApp\Resources\harness.js -Force
Copy-Item tools\harness-transpiler\output\harness.js androidApp\app\src\main\assets\harness.js -Force
Copy-Item tools\harness-transpiler\output\harness.js harmonyApp\entry\src\main\resources\rawfile\harness.js -Force
# Get-FileHash 四份对比确认一致；build.mjs 会把 harness-entry.ts 拷进内核子模块 headless 目录（子模块改动勿提交）
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
13. **会话中断丢修改**：TRAE 会话上下文丢失恢复后，先前已"写入文件"的修改可能部分丢失——恢复后必须 `git diff` 与错误清单逐条核对再提交。**变体（2026-08-24 实测）：同一文件的多处编辑禁止并行调用编辑工具——并行写入互相覆盖，仅最后执行的那处存活（三处并行编辑只活了一处）；必须串行逐处编辑并逐处验证落盘**
14. **max-tokens 截断三症状链**（73efc45 修复）：深度思考计入 DeepSeek `max_tokens` 输出额度，难问题思考中途耗尽 → API `finish_reason:"length"` → 内核 `reason={kind:'max-tokens'}`（**无 error 字段**）→ 三端宿主 describeReason 只查 `reason.error` 落"模型未返回内容"默认文案；同时内核截断时丢 tool-call blocks（UI 显示 0 步）、think 显示 slice(0,8000) 封顶。宿主 buildEngineConfig/refreshProfiles 均**未传 maxTokens**，内核 buildConnection 兜底 8192。修复：内核 chat() 补 max-tokens 文案 + deepseek reasoner 系模型模型级 maxTokens=65536（模型级覆盖 connection 级，链路 `configured?.maxTokens ?? connection.maxTokens`）+ 三端宿主兜底。新增 reason kind 处理时记得它不一定带 error 字段。【修订 2026-08-24，8c78bd6e89】已打通 provider 级 maxTokens 用户配置：三端 provider 编辑页新增「最大输出 Tokens」输入框（留空走默认），api_config.json 持久化 + buildEngineConfig 透传 + 导入导出兼容；用户配置后内核跳过 reasoner 65536 硬编码、统一按用户值生效（决定链：模型级 > provider 级用户配置 > reasoner 硬编码 > 兜底 8192）
15. **Xcode 27 beta 默认开启 Swift 6 并发诊断**（2922a9650a 修复，2026-08-24 Mac）：Xcode 27 beta5（27A5237l）在 Swift 5 语言模式下也把 Swift 6 并发检查作为默认警告（尾缀 "this is an error in the Swift 6 language mode"），旧代码四类模式集中暴雷（31+ 处）：
    - async 函数体 / async Task 闭包体内直接调 `NSLock.lock()/unlock()`（noasync）→ 改 `NSLocking.withLock{}`（iOS 16+，闭包体无挂起点时语义完全等价）。**关键事实：`withCheckedThrowingContinuation` 的同步闭包内调锁不告警**（编译器只认 async 函数体/async 闭包体为 asynchronous context），故 HarnessEngine.callAwait 无需改
    - 非 Sendable 类被 `@Sendable` 闭包捕获（DispatchQueue.global().async / Task）→ 状态确由锁/串行队列保护的类标 `@unchecked Sendable`（HarnessEngine：jsQueue 串行 JSContext + stateLock 保护计数器/continuation）
    - MainActor 隔离属性（`UIDevice.current` / `UIScreen.main`）在非隔离 async 上下文访问 → 聚合进单个 `MainActor.run` 返回字典，注意接结果要 `var` 才能后续下标赋值
    - withLock 闭包体若是单表达式且该表达式有返回值（如 `dict.removeValue`），返回值会被推断为闭包返回类型带出外层调用 → unused 告警，显式 `_ =` 丢弃
    - 修完必须 **clean build** 验证清零：增量构建跳过未改文件的编译，告警不重现会误判已修复
16. **Xcode 27 beta SDK API 弃用警告**（23130e84fa 修复，2026-08-25 Mac）：Xcode 27 beta 的 SDK 把一批旧 API 标记为 deprecated，真机（arm64 device）构建时暴露（模拟器构建之前未暴露）。部署目标提升到 17.0 后可消除 iOS 17 标记的弃用：
    - `onChange(of:perform:)` 单参数闭包（iOS 17 弃用）→ 零参数 `onChange(of:) { }`（不需要新旧值时）或两参数 `onChange(of:) { old, new in }`（需要新值时）
    - `EKEventStore.requestAccess(to:completion:)`（iOS 17 弃用）→ `requestFullAccessToEvents(withCompletion:)`；`.authorized` → `.fullAccess`
    - `UIScreen.main`（iOS 26 弃用）→ `UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen`（注意 fallback 不能再引用 `UIScreen.main`，用 `screen.map { ... } ?? "unknown"` 处理 nil）
    - `Text +` 运算符（iOS 26 弃用）：Markdown 渲染场景拼接不同样式 Text（bold/italic/strikethrough 修饰符）无 AttributedString 替代路径，实际真机构建未报此警告（可能 SDK 版本差异）
    - `UISupportedInterfaceOrientations` 缺 PortraitUpsideDown → 补全四个方向
    - **真机构建验证需 `CODE_SIGNING_ALLOWED=NO`**（免费 Personal Team 签名在命令行会失败，但编译告警不受签名影响）
17. **NSJSONSerialization 顶层 NSNull 崩溃 + JSON null ≠ nil**（f36ae0b4e2 修复，2026-08-25 Mac）：
    - `JSONSerialization.data(withJSONObject:)` 收到顶层标量/NSNull 抛 `NSInvalidArgumentException` —— **Swift 的 `try?` 接不住 ObjC 异常，进程直接终止**（已实证：顶层 NSNull 复现用户崩溃报文逐字相同）；唯一安全前置检查是 `JSONSerialization.isValidJSONObject(_:)`（不抛异常）
    - 内核 TS 显式 `null` 字段经 JSON.stringify 保留 → Swift 解析为 **NSNull 实例（非 nil）**：能过 `guard let any`，过不了 `as? String`，最后被当对象序列化 → 崩。触发源：extractDetails 纯对话回合 `todos/usage: null`
    - 内核侧治本：局部变量用 `undefined` 初始化（`JSON.stringify` 自动**省略** undefined 值的字段，null 则原样输出）；宿主侧兜底：encodeString 加 `if any is NSNull { return nil }` + isValidJSONObject 前置。跨端传 JSON 时**用 undefined 不用 null**，宿主解析统一按"缺 key"处理
18. **节流相位锁死**：宿主 UI 节流窗口与内核心跳间隔**同频**（均 200ms）时，事件到达抖动可能让每条事件都落进 pending、整轮不刷新。宿主窗口必须**严格小于**内核心跳（本例 150ms < 200ms），且回合收尾（finishRound/序列化前）必须 flush 暂存数据补偿丢帧
19. **Harmony CI 不拦截 ArkTS 编译错误**（214532ffd3 修复，2026-08-25 Windows）：build-harmony.yml 的 assembleHap 步骤带 `continue-on-error: true`（ubuntu runner 无签名证书，打包 best-effort），**ArkTS 编译错误永远不会让 CI 变红**——推送前鸿蒙代码必须在 Windows 本地跑 hvigorw 构建（唯一门禁，与陷阱 10「iOS 首次真实编译暴雷」同构）。实证：Mac 推的模型/思考选择器引用了 UiState 上不存在的 `state.currentSession`（4 处 ERROR 含 `arkts-no-any-unknown`），CI 仍全绿。另注意：UiState 派生属性别凭空引用，在 AppViewModel 加辅助方法（`currentSession(): SessionUi | null` 按 activeSessionId 查 sessions）；`harmonyApp/package-lock.json` **不可提交**（resolved 锁定本机 `file:C:/Program Files/...` 绝对路径，入库破坏 CI）
20. **主线程 DispatchQueue.main.sync 自派发 = 必崩**（432d631469 修复，2026-08-25 Mac）：`main.async` 闭包内（已在主队列）再调"无条件 `main.sync`"的辅助函数 → libdispatch `DISPATCH_CLIENT_CRASH` → Thread 1 **EXC_BREAKPOINT (code=1)**（subcode 即 libdispatch assert 地址）。实证：DeviceBridge.topVC 被 pickDocument/pickImage/takePicture 的 main.async 闭包调用，模型调 `device_files op=pick` 工具（真机日志 turn5 step6 tool-start 实证）→ 100% 崩溃；camera capture / photos pick / files pick 三条工具路径**自上线即带雷**，此前未暴露只因模型从未调用过。修复模式：提取 `compute()`，`Thread.isMainThread` 直跑、仅非主线程才 sync——**对齐 Android HarnessEngine.Handler.runBlocking 首行同线程守卫**（跨端移植时守卫层不能丢）。附带教训：用户报"卡死"不一定是挂起——lldb 显示 `Thread 1: EXC_BREAKPOINT` 即是崩溃，先看 Xcode 停在哪一帧（本次用户贴帧 + os_log 的 Harness/event 日志 5 分钟定位）；`log collect --device` 需要 root（sudo 需密码不可用）时，Xcode 调试会话 + 用户贴 bt 是最快路径
21. **内核 tool-end 事件不携带 durationMs + ArkUI 事件无 stopPropagation**（c05ac2d9aa 三端 UI 补齐批次实证，2026-08-25 Windows）：
    - 内核 round 事件 tool-end 仅 `{kind,seq,callId,status,result}`，**无耗时字段**——三端工具耗时 ⏱ 一律宿主侧计时：tool-start 记到达时刻（iOS LiveItem.startedAtMs / 鸿蒙 AppViewModel.toolStartAt Map 按 callId），tool-end 归并时算差值（鸿蒙留了事件 durationMs 优先的兜底口子）。traceJson 持久化字段名**三端各表**：iOS `"d"` / 鸿蒙 `"ms"`（各端 SessionStore 自解析不跨端共享，无碍但别误以为同名）
    - ArkUI（鸿蒙）`ClickEvent` **没有 stopPropagation**（DOM 思维迁移陷阱）：onClick 命中测试只触发最深响应者，阻止弹窗内层点击穿透到全屏遮罩的正确做法是给内层卡片挂**空 `.onClick(() => {})`** 消费事件
    - 本批 B1/B2 三端统一规格（后续加端/改版别走样）：编辑重发 = 长按用户消息 → 对话框预填原文 → 确认走**标准发送链路**（busy 自动排队语义天然继承；不删原消息不截断历史）；会话导出 = DetailsView「导出会话」按钮 → 组装 Markdown（`# 标题` + `> Harnest 会话导出 · 时间` + `## 🧑/🤖` 正文 + 思考/工具 `<details>` 折叠）→ iOS ShareLink / Android ACTION_SEND / 鸿蒙 DocumentViewPicker 存 .md
22. **官方 UI 能力"源码有 ≠ bundle 有"——复刻官方 UI 前必须实测打包产物**（第二轮内核 UI 研究实证，2026-08-25 Windows）：内核仓库的组件族（packages/client/ui-* 六包）与文档（docs/subsystems/*）描述的能力，**多数不在 mobile harness.js 里**（esbuild 闭包子集，权威 compose 清单见 harness-entry.ts 18 插件）。实证结论（勿再凭文档立项）：approval——seam 真代码（ToolRuntime.serviceAsk 经 `ctx.get('approval')`）但 ApprovalService 实现类被 tree-shake（产物中该字样唯一命中是**注释文本**），且 degrade 是 **deny 拒绝**而非放行，mobile 工具集（device_*/todo/bg_timer/ask_user/exit_plan_mode）**无任何 ask 声明**→审批 UI 无触发点；goal（GoalsService）/skills/schedule_create/web_search/spill 工具/attachment 服务**全不在**（goals×1 是提示词、attachments×6 是 Session 内部变量、schedule×76 全无关词）；diff/read/search/terminal 专属卡无数据源（工具不在 + tool-end 仅 600 字符纯文本）。**真在的**：/plan 命令已注册（`commands.register({name:"plan", input:{hint:"[off|message]"}})`）、planMode、user-questions、TokenMeter（服务在但 entry API 面未暴露读取接口）。方法论：关键词计数必须**二次提取上下文**验证真实性（注释/提示词/内部变量同名是常态），再对照 harness-entry.ts compose 清单与 API 返回面
23. **三端 UI 差距清单的分级基准**（第二轮研究产出，2026-08-25）：Tier A 纯宿主渲染层可立即做（鸿蒙数学公式 0 命中是唯一端级硬缺口，iOS/Android 已有 .math 降级；提问卡"单选自动前进/分页"细节）；Tier B 需扩 entry（tokenMeter 水位条——服务现成只差 entry 加 getUsageStats 读取接口，性价比最高；/plan 斜杠提示菜单——需先实测 chat() 是否解析命令前缀）；Tier C 空中楼阁明确放弃（工具审批/goal/skills/schedule/web-search/spill/图片附件/工具专属卡/trajectory/workspace/workflow-run 面板）
24. **ArkTS `.so` 默认导入 = any + @ohos.net.http 正确字段名**（2026-08-25 Windows，Tier B 鸿蒙批次首建 10 错实证）：
    - `import harness from 'libharness_napi.so'` 默认导入在 d.ts 只有命名导出时推断为 any → arkts-no-any-unknown 直接报错。**.so 访问必须收口到 HarnessNative 类型化包装方法**（本批新增 scriptEngineCreate/SetFetchHandler/Run/FetchDone 四个，AppViewModel 侧裸 import 删除，宿主层零 any）
    - @ohos.net.http 方法枚举是 **`http.RequestMethod`**（不是 HttpMethod），请求体字段是 **`extraData`**（不是 body）——写新 HTTP 代码先抄 HttpBridge.ets 既有模式，别凭 Node fetch/axios 记忆写
    - C++ per-instance QuickJS 正确姿势：struct 持 runtime/context + `JS_SetContextOpaque` 反查实例 + `JS_SetInterruptHandler(runtime, handler, this)` 硬超时，静态回调（qsb_*）经 opaque 分发；勿用全局单例（多沙箱实例会互踩）
25. **Windows 机 git/gh 访问 GitHub 需手动挂系统代理**（2026-08-26 Windows）：`git push` 报 `Failed to connect to github.com:443` / `Connection was reset` 且重试数分钟不恢复时，先查注册表 `HKCU:\...\Internet Settings` 的 ProxyServer——本机系统代理是 `127.0.0.1:7890`，但 shell 会话不继承（HTTP(S)_PROXY 为空、git config 无 http.proxy），国内站点（如 baidu）直连正常而 GitHub 不通。补救：命令前临时设 `$env:HTTPS_PROXY="http://127.0.0.1:7890"`（gh CLI 同样适用），勿改 git config；别直接归因"GitHub 抽风"（旧记忆里"等 1-2 分钟重试"只适用于偶发 TLS 超时，持续连不上就是代理问题）
26. **并行会话会在同一仓库自主提交推送**（2026-08-26 Windows，OOXML 批次实证）：本机会话中断期间，另一会话（身份 `Harnest Dev <dev@harnest.app>`）把工作区 feat 提交 + docs/memory 提交自主推上了 origin/main，同期 Mac 也在推修复提交 → 恢复会话后直接 push 被拒（non-fast-forward）。纪律：①push 前必先 fetch 并核对 `git log HEAD..origin/main` / `origin/main..HEAD` 双向差异再 pull --rebase；②记忆文件双方并行追加冲突是可预期场景，按"合并双方条目"解决；③**并行会话写的记忆条目必须对照代码事实核查后合流**——本批发现其声称"鸿蒙 DeviceBridge.ets 补拷贝逻辑"与代码不符（鸿蒙 pick 走 uri 直读，无拷贝逻辑），按 task_summary 纪律追加修订而非直接采信
27. **Swift `Result<Success, Failure>` 的 Failure 必须遵 `Error` 协议**（c9f453c744 修复，2026-08-26 Windows，OOXML 批次 iOS CI 首编译暴露）：`Result<Void, String>` 报 `type 'String' does not conform to protocol 'Error'`——陷阱 10 族新增第 9 类。错误文案传递场景别用 Result，直接返回 `String?`（nil=成功）或自定义 enum Error；Windows 端无 macOS 门禁，新 Swift 代码写完后自查清单再过一遍（Result 泛型约束/新 SDK 可选返回/值语义回写）
28. **LlmError 的 `failure` 不携带 `cause` 链——包装层错误会吞掉底层详情**（74cc1c4452 修复，2026-08-26 Mac，用户报"模型验证只提示 DeepSeek API stream from ...failed 看不到详细报错"实证）：错误链——llm-deepseek adapter transport catch 包装 `new LlmError("DeepSeek API stream from ${baseURL} failed", "TRANSPORT", { cause })`；LlmError.failure 是 frozen `{message, code, status?, providerRetryAfterMs?, requestId?}` **无 cause**；agent.ts turn 收口 `error instanceof LlmError ? error.failure : { message: errorChain(error), code: 'UNKNOWN' }`——LlmError 分支不走 errorChain，底层 401/HTTP 状态被丢；宿主 describeReason 只能读到泛化 message。修复模式：turn 收口处 `const chain = errorChain(error)` 后与 `error.failure` 合并（`detail: chain`，chain 与 message 重复时丢弃），`LlmFailure` 接口加可选 `detail?: string`；三端宿主展示 msg+detail。**同类警惕**：`normalizeLlmFailure`（adapter-failure.ts）同样只取 ownFailureSnapshot 或 `{message, code}`，走该路径的 failure 也无 detail——若后续发现其他错误面仍丢详情，先查是否过了 normalizeLlmFailure

## 环境事实

- Mac：模拟器 runtime 已更新为 **OS 26.5，iPhone 17 Pro 不在了**（可用：iPhone 17e / iPhone Air，构建测试 destination 用 `iPhone 17e`）；**真机 MyPhone (iPhone 17 Pro / iPhone18,1 / iOS 27 beta) 已连接**（UDID 72E02B90-611E-59B0-8B0C-A22B9DB2A6DA）；部署目标 **17.0**（2026-08-25 从 16.0 提升）；App 容器内 `api_config.json` 首启自动播种 9 个 provider 默认配置
- Mac 测试注入 fake key 后 chat 全链路可达 DeepSeek API 并正确回传 401（说明 JS 内核→网络桥→错误 surfaced 链路通）
- Windows：Harmony 真机可用（hdc）；Android 真机/模拟器可用；iOS 无法本机编译（无 macOS），全靠 CI（macos-14 runner，XcodeGen + xcodebuild，产物 .app + XCFramework）
- `.trae/` 未被 gitignore（本文件可提交共享）；`iosApp/*.xcodeproj`、`build/`、DerivedData 已忽略
- `kernel/deepseek-harness` 子模块在 Windows 机常有本地工作区改动（kernel.ps1 同步产物），提交父仓库时勿顺手带上

## 验证状态快照（2026-08-22/25）

- ✅ **CI 三端 workflow 全绿**（73efc45193 验证）：Build Harmony 2m54s / Build Android 3m43s / Build iOS 11m16s
- ✅ iOS CI 产物：`.app` bundle（~785KB，可下载后 `codesign -f -s -` ad-hoc 装机）+ XCFramework（~13.8MB）
- ✅ XCTest **14/14 通过**（Mac，EngineBridgeTests 6 + LocalEngineFlowTests 4 + ProvidersCatalogTests 4；**2026-08-25 于 f36ae0b4e2 复验（iPhone 17e 模拟器）**——万字思考节流 + NSNull 守卫改动后；此前 8c78bd6e89 于 iPhone 17 Pro 复验）
- ✅ iOS Debug 构建通过（2026-08-25 于 f36ae0b4e2 Mac 本地复验，iPhone 17e）
- ✅ Mac transpiler 打包链路（2026-08-25 f36ae0b4e2 首次 Mac 端验证）：node build.mjs + patch.mjs + check-quickjs-compat **PASS** + 三端分发 SHA256 一致（dfe359c7…）
- ✅ `:shared:iosSimulatorArm64Test` 通过；XCFramework 51MB（ios-arm64 + ios-arm64_x86_64-simulator 双 slice）
- ✅ Windows `:app:compileDebugKotlin --offline` 通过（8c78bd6e89 时点复验，4s——maxTokens 配置链改动后）
- ✅ Windows transpiler 打包链路（8c78bd6e89 复验）：build.mjs + patch.mjs + check-quickjs-compat PASS + 三端分发 SHA256 一致（1BEB4F94…）
- ✅ **鸿蒙本地构建 + 真机装机**（2026-08-25，214532ffd3）：hvigorw assembleHap BUILD SUCCESSFUL（~10s）+ 本地调试证书 SignHap + hdc install -r + aa start，真机 6HR0226328004267 进程存活（含 f36ae0b4e2 合流后代码）；构建中修复 4 处 ArkTS ERROR（见陷阱 19）
- ✅ **Mac 本地 Android 编译验证**（2026-08-25，f2e4d6d905）：`ANDROID_HOME=~/Library/Android/sdk JAVA_HOME=/opt/homebrew/opt/openjdk@17/... sh ./gradlew -p androidApp :app:compileDebugKotlin --offline -q` 通过（Mac 也有 Android SDK，不必等 CI）；同日 iOS build + XCTest 14/14（iPhone 17e）于 f2e4d6d905 复验通过
- ✅ **三端 UI 功能一致性矩阵 26 项全对齐**（2026-08-25，f2e4d6d905）：思考分段三级折叠/回复折叠/节流/代码块复制/错误重试/会话重命名/提问卡跳过/清空消息/token 用量/重新生成/回到底部（贴底才跟随）/工具卡展开/steer+subagent 渲染/评分/fork/停止/排队转向/后台任务卡/会话管理/Provider+maxTokens/导入导出/详情页/深色/Markdown 全集
- ✅ **CI 三端全绿**（2026-08-25，f2e4d6d905）：Build HarmonyOS 2m54s / Build Android 3m33s / Build iOS 9m8s——批次 1-3 的鸿蒙 5 文件 ArkTS 改动经 CI 编译验证通过
- ✅ **三端 UI 补齐 9 项构建验证**（2026-08-25，c05ac2d9aa 批次）：鸿蒙 hvigorw assembleHap BUILD SUCCESSFUL（2s884ms）+ Android `:app:compileDebugKotlin --offline` 通过（Windows 本地门禁）；**CI 三端全绿**：Build Android 2m56s ✅ / Build HarmonyOS 2m50s ✅ / Build iOS ✅（iOS 3 文件 +200 行无本地门禁，全靠 CI 编译验证通过）
- ✅ **Tier B 批次本地门禁全过 + 四批提交推送**（2026-08-25，364bc5b96b→87b4a506d4）：鸿蒙 hvigorw assembleHap BUILD SUCCESSFUL（首建 10s982ms 修 10 处 ArkTS 错后 + 复验 2s586ms）+ Android `:app:compileDebugKotlin --offline` BUILD SUCCESSFUL（复验 UP-TO-DATE）+ 三端 harness.js SHA256 一致（9E572C80…）；**iOS 批次补齐**（子代理首跑丢失后重发成功）：ScriptSandbox.swift 379 行（JSC 专用串行队列 + 每次全新 JSContext + evaluateScript("0") 微任务泵 50ms 轮询 + 超时异步置 nil 释放 + Documents/Scripts 前缀校验）+ DeviceBridge runScript case + LocalEngine.usageStats + AppStore 水位三态/refreshUsageStats 双触发/applyPlan + ChatView 水位条//plan 拦截/3 题分页，主线程五文件 diff 复核通过；四批提交 feat(kernel)/feat(ios)/feat(android)/feat(harmony) 推送 origin/main，iOS 编译验证靠 CI；.gitignore 补 harmonyApp/package-lock.json 防护
- ✅ **Tier B 批次 CI 三端全绿**（2026-08-25，87b4a506d4）：Build iOS 7m24s ✅（**ScriptSandbox.swift 379 行首次真实编译通过**，Windows 端无 macOS 全靠静态复核）+ Build HarmonyOS 2m59s ✅（含 ScriptEngine.cpp C++ 交叉编译）+ Build Android 3m53s ✅——run_script 沙箱三端 + getUsageStats + 鸿蒙数学公式全链路编译验证完成
- ✅ **OOXML 沙箱扩展批次本地门禁 + 推送**（2026-08-26，c6ceeca620→8bec92e86d）：鸿蒙 hvigorw assembleHap BUILD SUCCESSFUL 20s675ms（C++ base64 桥 + prelude eval 编译链接全过；首跑曾败于 CompileResource 清不掉旧 build 目录 11204003，清 entry/build 后通过）+ Android `:app:compileDebugKotlin --offline` UP-TO-DATE + 三端 harness.js SHA256 一致（68FEA9B1…）+ prelude.js 四份一致（EC4B0038…）；五批提交 feat(kernel)/feat(all)/feat(ios)/feat(android)/feat(harmony) 经 rebase 合流 Mac resolvePath 修复（53315ce2e0）后推送成功；iOS 编译靠 CI
- ✅ **OOXML 批次 CI 三端全绿**（2026-08-26，c9f453c744）：Build HarmonyOS 2m35s ✅ / Build Android 3m32s ✅（8bec92e86d 触发）+ Build iOS 首轮失败（ScriptSandbox.swift `Result<Void, String>` 违反 Result 泛型约束，陷阱 27）→ c9f453c744 改返回 `String?` 修复后 iOS CI ✅——OOXML 沙箱扩展批次全链路编译验证完成
- ✅ **kernel.ps1 验证**（2026-08-26，Windows）：`status`（v0.1.0-rc.5 / master / node v24.19.0 / pnpm 11.22.0 / 已构建）/`remote`/`log --lines`/`stop`（正确清理残留 PID 37520 文件）/`fetch`（自动补 upstream remote，拉到 rc.6~rc.8、0.1.1-rc.1/rc.2 新 tag）/`diff`（本地落后上游 166 笔，锁定 rc.5）六命令全过；未验证 `pull/merge/upgrade/build/run`（build 需 pnpm install 首次较慢，run 是长驻进程）
- ✅ **内核能力补齐阶段 1 本地门禁（95209237fb）**（2026-08-26，Windows）：transpiler 三连门禁——build.mjs 2227.5KB + patch.mjs 2284.4KB + check-quickjs-compat PASS（仅 navigator typeof 守卫运行时安全探测）；新冒烟 smoke-fs-web.mjs 11/11（fs write/read/edit 全链 + rename/realpath 往返 + web_fetch 抹页转 markdown + subagent 子代理完成回报）+ 既有 smoke-manual.mjs 24/24 回归无破坏；三端 harness.js SHA256 一致（42E7ADD1…，2339259 字节）+ Android `:androidApp:app:compileDebugKotlin --offline` BUILD SUCCESSFUL 4s + 鸿蒙 hvigorw assembleHap BUILD SUCCESSFUL 10s871ms（libharness_napi.so 重编译确认）；iOS FsBridge.swift 靠 CI 编译验证；**CI 三端全绿（95209237fb 触发）：Build HarmonyOS 3m45s ✅ / Build Android 3m35s ✅ / Build iOS 6m26s ✅**（iOS FsBridge.swift +24 行首次真实编译通过）
- ✅ **沙箱定时器与运行时补齐批次本地门禁 + CI 三端全绿**（2026-08-26，0e45337533→4179395317）：transpiler 重打包 check-quickjs-compat PASS + 三端 harness.js SHA256 一致 + prelude.js 四份一致 + node 离线测 TextEncoder/TextDecoder 往返（中文😀）通过 + Android `:app:compileDebugKotlin --offline` BUILD SUCCESSFUL 18s + 鸿蒙 hvigorw assembleHap BUILD SUCCESSFUL 12s316ms（C++ 交叉编译 + ArkTS 全量检查，仅 SharePage 既有 deprecation WARN）；**CI：Build HarmonyOS 2m46s ✅ / Build Android 3m28s ✅ / Build iOS 10m49s ✅**（iOS ScriptSandbox.swift+DeviceBridge.swift 改动经 CI 真实编译验证）
- ✅ **模型 ID 预设刷新批次本地门禁 + CI 三端全绿（2393579bf3）**（2026-08-26）：Android `:androidApp:app:compileDebugKotlin --offline` BUILD SUCCESSFUL 24s（含 :shared 依赖编译）+ 鸿蒙 hvigorw assembleHap BUILD SUCCESSFUL（首轮全量编译仅既有 WARN，二轮增量 2s716ms 确认）；**CI：Build HarmonyOS 2m54s ✅ / Build Android 3m39s ✅ / Build iOS 10m43s ✅**（iOS 两文件常量修改经 CI 真实编译验证）
- ⬜ 未验证：真机回归 NO_ADAPTER 修复（清空 deepseek key 后重开旧会话应回落默认 provider 不报错）；真机回归 max-tokens 修复（deepseek-reasoner 问难题应完整出答案不截断）；真机验证 maxTokens 用户配置生效（设置页填 1024 问长答案应截断、填 65536 应完整）；**真机回归万字思考（deepseek-reasoner 问难题：思考分段折叠应正常分档、刷新不卡死、回合结束不崩溃）**；Tier B 真机实测（run_script 沙箱：让模型写脚本生成报告验证 fetch/readText/writeText/log 链路与超时熔断；水位条真机显示与分档变色；/plan 斜杠拦截；提问卡 3 题/页分页；数学公式渲染）；**OOXML 真机实测**（模型脚本用 Prelude.makeXlsx/makeDocx/makePptx 生成文件：writeBytes 落盘 + 结果 files 字段回传 + readXlsx/readDocxText 回读验证；三端各验一轮）；OOXML 批次 CI 三端结果已确认全绿（见上条）；**真机·内核 fs 工具**（建 out/a.md 写两行中文读回改第二行：write/read/edit 工具卡依次成功）；**真机·web_fetch**（抓 example.com 总结：工具卡返回 markdown 正文）；**真机·subagent**（派子代理抓页面总结：后台任务面板子代理任务完成，重点观察单线程 QuickJS 主循环与子代理事件泵交错）；**真机·沙箱定时器**（让模型跑 run_script：`const t0=Date.now(); await new Promise(r=>setTimeout(r,500)); return Date.now()-t0` 应返回 ≥500 且 <2000；clearTimeout 用例不触发）；**真机·bg_timer**（让模型「启动一个 15 秒后台计时器」：后台任务卡应 15s 后 running → completed，修复前永久 running）；**真机·kimi-k3 打通**（新预设选 Kimi/kimi-k3 发一轮对话应正常回复；其余七家新默认模型各抽验一轮；存量会话若保存 deepseek-chat 等已停用 ID 需手动改选）

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

1. 新会话**开工前先 `git pull --ff-only`** 同步远程——记忆文件本身在双机间流转，本地的可能是旧版（协议/陷阱可能已更新）；发现内容过时，**先更新本文件再干活**
2. 实质变更（新提交、新陷阱、新命令、验证状态变化）→ 追加「维护日志」一行，并更新顶部「最后同步 HEAD」
3. **自动同步 GitHub**（用户指令 2026-08-23，双机同遵）：会话内产生阶段性进展（新提交落地/新结论/新陷阱）后，**本会话结束前必须**把记忆更新以独立提交推送到 origin/main（`docs(memory): ...`），保证双机记忆一致——不要只改文件不推送
4. 「已知陷阱」只追加或修订，**不删除**条目
5. 记录命令时必须是**本机验证过**的形式（注明 macOS/Windows 机）；未验证的标 ⬜
6. **逐条记录用户输入**（用户指令 2026-08-26）：每个会话结束前，把该会话内用户的输入（含追问/纠错/「继续」类指令）**逐条原文**追加到 `doc/prompt.md`（按会话批次分组，`git add -f` 提交，`docs:` scope）。TRAE 对话数据库（database.db）整库加密无法离线提取，本文档是 prompt 逐字留存的唯一渠道——别只记意图摘要

> 本协议对 **Mac 机与 Windows 机的 TRAE 会话同等生效**（记忆文件随仓库共享，pull 后自动加载）。

## 维护日志

- 2026-08-23 初始生成（HEAD 6ae91064a3，Mac）。沉淀：iOS 全链路验证结论（14/14 测试、Debug+Release 构建、XCFramework、模拟器 E2E）、ConfigService 值语义 bug 根因与修复、8 条陷阱、四端架构与内核子模块链路
- 2026-08-23 项目记忆提交入库并推送（7500cc0924，docs scope，Mac）
- 2026-08-23 Windows 端融合（基线 7500cc0924）。沉淀：CI 8 轮修复史与三端全绿结论、iOS artifact 产物路径、陷阱 9-13（NO_ADAPTER 挂载校验、Swift 8 类编译错误、xcodegen 工程名链、Harmony CI 三坑、会话中断丢修改）、Windows 机验证命令段、双机开发环境事实
- 2026-08-23 维护协议新增第 3 条（基线 f2b48c5489）：会话内进展自动更新记忆并推送 GitHub（用户确认采用"仅会话内"模式，不建定时任务）
- 2026-08-23 协议第 1 条升级（基线 c36c6626f2）：开工前先 pull 记忆文件，形成"pull → 干活 → push"闭环，双机 TRAE 会话同等生效
- 2026-08-24 Windows 端（基线 73efc45193）：修复鸿蒙"0步 8000字思考→模型未返回内容" bug（max-tokens 截断三症状链，见陷阱 14）；CI 三端复绿（iOS 11m16s）；沉淀 transpiler 打包分发命令段；本会话两次踩中陷阱 13（内核 chat 文案、记忆文件 3 处改动均 diff 核对后发现丢失重做）
- 2026-08-24 Windows 端（8c78bd6e89）：打通 provider 级 maxTokens 用户配置链（内核 buildConnection 用户值跳过 reasoner 硬编码 + 三端 ConfigService 持久化/透传/导入导出 + 三端 provider 编辑页输入框，27 处改动全部串行编辑零丢失——陷阱 13 变体防护生效）；陷阱 14 修订补充决定链；Android 编译 4s 通过、三端分发 SHA256 一致
- 2026-08-24 Mac 端拉取复验（8c78bd6e89）：pull --rebase 首次遭遇双机记忆文件冲突（双方维护日志并行追加），按协议合并双方条目解决；iOS 侧变更影响评估（harness.js/AppStore/ConfigService/SettingsView 共 4 文件，setConfig 新参带默认值向后兼容，project.yml 未变免 xcodegen）；本地复验 Debug+Release 构建 + XCTest 14/14 全通过，maxTokens 功能在 Mac 本地首次编译验证成功
- 2026-08-24 Mac 端 Xcode 27 beta 适配（2922a9650a）：清零 IDE 31 issue（编译口径 34 处告警）——四类 Swift 6 并发诊断（noasync 锁 ×23 / @Sendable 捕获 / MainActor 隔离 / unused 结果，见陷阱 15），涉及 LocalEngine/HarnessEngine/HttpBridge/DeviceBridge 共 4 文件 8 处编辑（全部串行，陷阱 13 防护生效）；环境变更：Mac 升级 macOS 27 + Xcode-beta.app 27A5237l 成为唯一 Xcode（xcode-select 指向 CommandLineTools 需 DEVELOPER_DIR）；clean build 0 警告 + XCTest 14/14 复验通过
- 2026-08-25 Mac 端真机适配（23130e84fa）：清零真机构建 12 处 API 弃用警告（见陷阱 16）——部署目标 16.0→17.0 + onChange/EKEventStore/UIScreen.main 新 API + orientations 补全，涉及 project.yml/Info.plist/ChatView/DeviceBridge 共 4 文件；真机 MyPhone (iPhone 17 Pro/iOS 27 beta) 已连接；真机 clean build（CODE_SIGNING_ALLOWED=NO）0 警告 + XCTest 14/14 通过
- 2026-08-25 Mac 端双修复（f36ae0b4e2）：①万字思考卡死（内核 emit 阈值 16字/60ms→64字/200ms + iOS 150ms 节流/flushPendingThink 收尾补偿 + 渲染尾部 4000 字封顶 + 日志 240 字截断）；②NSJSONSerialization 顶层 NSNull 崩溃（内核 extractDetails undefined 化剥离 null 字段 + iOS encodeString NSNull 守卫/isValidJSONObject 前置，见陷阱 17/18——try? 接不住 ObjC 异常已实证）。会话中断恢复后按陷阱 13 diff 核对九处编辑全部存活；transpiler 打包 + QuickJS 门禁 PASS + 三端分发 SHA256 一致（dfe359c7）+ 模拟器构建 + XCTest 14/14（**模拟器 runtime 更新 OS 26.5，iPhone 17 Pro 没了改用 iPhone 17e**）；Mac 首次本地验证 transpiler 打包链路
- 2026-08-25 Windows 端鸿蒙装机（214532ffd3）：拉取 Mac 12 提交后本地构建 HAP 首次暴露 4 处 ArkTS ERROR（ChatView 引用 UiState 不存在的 state.currentSession，CI best-effort 全绿没拦，见陷阱 19）→ AppViewModel 加 currentSession() 辅助方法修复；本地调试证书 SignHap + hdc install -r + aa start，真机 6HR0226328004267 运行存活；期间 Mac 并行推 f36ae0b4e2 → pull --rebase 合流后重新构建重装（新 PID 4819）；沉淀 Windows 鸿蒙构建装机命令段 + 环境事实（锁屏时 aa start 报 10106102 需人工解锁；package-lock.json 勿提交）；会话中断恢复后按陷阱 13 diff 核对确认无丢失
- 2026-08-25 Mac 端三连提交（1fbdcfdba7 → b3f694e194 → f2e4d6d905）：①**思考/回复分段三级折叠**（内核 extractDetails 按 (turn,step) 切段 + 概览/分段/全文三级 UI，对标 trae/workbuddy）；②**三端统一 150ms 节流**（think+answer 双缓冲，修复万字思考卡死——iOS 11584 字卡住后一次性蹦出的根因是宿主窗口与内核心跳同频 200ms 相位锁死 + 主线程逐字渲染压力）；③**三端 UI 功能补齐批次 1-3**（代码块复制/错误重试/会话重命名/提问卡跳过/清空消息/token 用量 in+out/🔄 重新生成/回到底部悬浮按钮（贴底判定：iOS PreferenceKey minY<400、Android derivedStateOf last≥total-3、Harmony onScrollIndex last≥total-2，贴底才自动跟随）/工具卡点击展开/steer 展开行/subagent 专属行）+ 一致性终检 26 项全对齐。验证：iOS build+XCTest 14/14、Android Mac 本地 compileDebugKotlin（**Mac 也有 Android SDK ~/Library/Android/sdk，带 ANDROID_HOME 即可本地编译不必等 CI**）、Harmony 落盘待 CI——**收尾确认 CI 三端全绿（HarmonyOS 2m54s / Android 3m33s / iOS 9m8s，鸿蒙 5 文件 ArkTS 改动经 CI 编译验证）**；会话两次中断恢复均按陷阱 13 diff 核对（Android 🔄 按钮本体丢失一次、记忆文件核对一次）
- 2026-08-25 Mac 端真机崩溃修复（432d631469）：用户报 iOS 真机"卡死"，Xcode 显示 `Thread 1: EXC_BREAKPOINT (code=1)` + 用户贴崩溃帧（DeviceBridge.topVC 的 main.sync）+ os_log Harness/event 日志（模型 turn5 step6 调 device_files op=pick）→ 定位：pickDocument 的 main.async 闭包内调无条件 main.sync 的 topVC() → libdispatch 自派发 assert 必崩（陷阱 20）；camera/photos/files pick 三条工具路径自上线即带雷。修复：topVC 提取 compute() + Thread.isMainThread 守卫（对齐 Android HarnessEngine.Handler.runBlocking 首行同线程守卫）；Android（runOnUiThread+suspendCancellableCoroutine）/Harmony（ArkTS 单线程事件循环）审查无同类问题。验证：模拟器 build 0 警告 + XCTest 14/14 + 真机 CODE_SIGNING_ALLOWED=NO 构建通过；**真机回归 pick 路径待用户 Xcode Cmd+R 验证**。日志获取备查：`log collect --device` 需 root（sudo 需密码不可用）；zsh 内建 log 与 /usr/bin/log 冲突须全路径；devicectl 无 process list/crash 子命令
- 2026-08-25 Windows 端三端 UI 补齐 9 项（846cd43 → a02a105d09 → c05ac2d9aa）：以内核官方 UI（deepseek-harness 源码+文档全量研究）为基准盘点三端差距，按推荐方案 9 项全补：**鸿蒙 8 项**（A1 工具耗时⏱ 宿主侧计时/A2 busyHint 十处阶段文案+字数+回合耗时跳动器/A3 MCP base64 图片 McpImageView 等价/A4 运行日志查看器 setLogLineListener 镜像 [stream][event] 300 行环形缓冲+LogsOverlay 全屏页/A5 代码块语法高亮/A6 网络图片三态/B1 长按编辑重发/B2 DocumentViewPicker 存 .md）、**iOS 4 项**（A1 traceJson "d" 字段+fmtToolDuration/A2 busySec .task 计时/B1 ResendSheet contextMenu/B2 ShareLink exportMarkdown）、**Android 3 项**（A7 重启引擎⟳ busy 防重入+NO_ADAPTER 防护+B1 combinedClickable 长按对话框/B2 ACTION_SEND）。15 文件 +1214/-62；三个并行子代理实施（三端文件互不相交可并行，同文件多处仍串行——陷阱 13）+ 主线程逐文件 diff 复核；构建验证鸿蒙 hvigorw BUILD SUCCESSFUL（2s884ms，CompileArkTS UP-TO-DATE 确认零丢失）+ Android compileDebugKotlin 通过（修 1 处 m.toolResult 可空 .trim()→orEmpty()）；新坑沉淀陷阱 21；iOS 编译靠 CI（Windows 无 macOS）
- 2026-08-25 Windows 端第二轮内核 UI 研究（78e8cb7526 后，纯研究无代码改动）：用户指令"继续研究内核 UI 源码与文档"——深读官方 UI 六大 React 组件包（ui-tool/ui-user-questions/ui-trajectory/ui-workspace/ui-workflow-run/ui-primitives）+ 11 份子系统文档 + harness-entry.ts 全量 1162 行，并以打包产物实测确立"源码有 ≠ bundle 有"方法论（陷阱 22）。决定性结论：官方组件族/文档能力多数不在 mobile bundle（approval 服务/goals/skills/schedule/web-search/spill/attachment/diff-read-search-terminal 专属卡全无生产者，工具审批还有"无 ask 声明"双重缺失）；真在的增强点 = /plan 命令已注册 + TokenMeter 服务在（entry 未暴露）。产出差距分级清单（陷阱 23）：Tier A 鸿蒙数学公式（0 命中唯一硬缺口）+ 提问卡分页细节 / Tier B tokenMeter 水位条（entry 加 getUsageStats 性价比最高）+ /plan 斜杠提示 / Tier C 明确放弃；待用户拍板是否进入实施
- 2026-08-25 Windows 端 Tier B 实施批次（fb3ebf355d 后，**代码在工作区、本地门禁全过、未提交待用户确认**）：按陷阱 23 清单落地 Tier A+B 全量，18 文件 +960/-56。①**内核 entry**（harness-entry.ts +101）：注册 `run_script` 工具（模型自写 JS 经 `__deviceCall('runScript')` 交宿主独立沙箱执行，对齐桌面 dsh 用 bash 完成计算任务的形态；沙箱预置 fetch/readText/writeText/log 四 API，超时熔断 1-120s，脚本抛错不 throw 交模型自修）+ `getUsageStats()`（TokenMeter.measure 即时计量 + contextWindow 决定链对齐 buildConnection；baseline 'none'=冷启动）；transpiler 重打包三端分发 SHA256 一致（9E572C80）。②**鸿蒙 6 项**：数学公式三规则（对齐 iOS MarkdownView.swift，单 $ 需 e>i+1 防误吞）/提问卡 allAnswered 门禁+○●☐☑ 图标+3 题/页分页（末页才提交）/ScriptEngine.cpp per-instance QuickJS（struct+JS_SetContextOpaque+JS_SetInterruptHandler 硬超时，napi 5 导出）/d.ts 声明+DeviceBridge runScript case+AppViewModel 懒初始化编排（filesDir/scripts + @ohos.net.http 60s）/token 水位条（refreshUsageStats 双触发 doSend finally+applyModel，fmtTokens 1024 进制，3vp Progress 三档染色 cold 半透明）/斜杠提示（send() 预拦截 /plan|on|off + placeholder 切换）。③**Android 全量镜像**：ScriptSandbox.kt（每运行全新 QuickJSContext + OkHttp fetch 桥 + 64KB 环形 stdout + canonicalPath 逃逸校验）+ MainActivity/DeviceBridge（opRunScript）/LocalEngine（usageStats）/ChatView（水位条+/plan+分页）接线。首建 10 处 ArkTS 错（.so 默认导入 any×2 + HttpMethod 不存在×6 + body 字段×1 + 重载×1）→ HarnessNative 四包装收口 + RequestMethod/extraData 修正后鸿蒙 BUILD SUCCESSFUL 10s982ms（陷阱 24）；Android compileDebugKotlin 通过；iOS 宿主未接 runScript（待补 Swift 沙箱）；会话中断恢复后 git diff 全量核对确认零丢失
- 2026-08-26 Windows 端 OOXML 沙箱扩展批次（bac427b6d8→fb7911e50c）：**完整 OOXML 支持落地**——①`tools/sandbox-prelude/prelude.js`（482 行纯 JS：base64/UTF-8/CRC32/zipPack STORE/zipUnpack+inflate 固定+动态 Huffman/makeXlsx/makeDocx/makePptx/readXlsx/readDocxText/readBytes/writeBytes，IIFE 挂载 globalThis.Prelude）；②三端宿主各加 `__sbReadB64/__sbWriteB64` 桥（iOS JSC closure / Android QuickJS JSCallFunction / 鸿蒙 C++ JS_NewCFunction），iOS/Android 走 JSON envelope、鸿蒙 throw 语义差异 prelude 已容错；③三端 pick 落点统一到沙箱根 picked/（iOS Documents/Scripts/picked、Android filesDir/scripts/picked、鸿蒙 DeviceBridge.ets 补拷贝逻辑）；④内核 entry run_script 描述更新 + output schema 加 files 数组 + harness.js 三端重打包 SHA256 68FEA9B1；⑤验证：node 往返（base64/UTF-8/CRC32 向量/zip/xlsx/docx/pptx/inflate 1MB 17ms）+ PowerShell Expand-Archive/[xml] 良构/Compress-Archive deflate 回读全过 + Android compileDebugKotlin BUILD SUCCESSFUL + 鸿蒙 hvigorw assembleHap BUILD SUCCESSFUL（C++ 编译链接全过）；⑥子代理产出核实：iOS 子代理报告"完成"但 git status 显示零产出（陷阱 13 变体复现），重发后成功；Android/鸿蒙子代理 result missing 但 git log 显示已自主提交（越权 git add/commit，内容经复核准确）——子代理任务描述必须显式禁 git 操作，且返回后必须 git status 核实。**推送因 GitHub 网络不通（Connection reset/timeout）待补**。【修订 2026-08-26，8bec92e86d】③"鸿蒙 DeviceBridge.ets 补拷贝逻辑"与代码事实不符：鸿蒙 pick/photos/camera 返回系统 uri（files op=read 经 uri 直读），实际未加沙箱拷贝逻辑，仅 iOS/Android 把 pick/拍照落点改到沙箱根 picked/；另鸿蒙 napi/ArkTS 调用链四处缺口（NativeScriptEngineRun 旧 3 参调用/index.d.ts/HarnessNative/AppViewModel prelude 加载）由后续会话补齐，见最新维护日志。推送已于后续会话完成（系统代理 127.0.0.1:7890，见陷阱 25）
- 2026-08-25 Windows 端 Tier B 收尾（364bc5b96b→87b4a506d4，**由上条日志主会话继续**）：**iOS 批次子代理首跑完全丢失**（返回 result missing，git status 验证 iosApp 零产出——"成功报告"≠落盘，子代理层陷阱 13 变体，产出必须 git status/diff 核实）→ 重发加严约束（只改 iosApp/、禁 git、@unchecked Sendable/JSC 微任务泵坑位前置说明）成功：ScriptSandbox.swift 379 行（"script-sandbox" 串行队列与引擎 jsQueue 隔离防交叉死锁 + evaluateScript("0") 驱动 JSC 微任务 + 超时后队列异步置 nil 释放 context）。主线程五文件 diff 复核通过——含陷阱 15 词法确认：runSync 是**同步函数**，其内 NSLock.lock() 不构成 asynchronous context，即使被 async execute 调用也不触发 noasync 告警；callFunc 传 nil 对齐 listProviders 惯例。**鸿蒙子代理越权 git 提交**（b08b09c571 记忆沉淀，内容经复核准确但彼时 iOS 批次丢失故缺 iOS 记录）——子代理任务描述必须显式禁 git 操作。本地门禁复验：Android UP-TO-DATE + 鸿蒙 2s586ms；.gitignore 补 harmonyApp/package-lock.json（git status 曾显示 untracked 险些可被 add -A 带上，陷阱 19 堵漏）；四批提交 feat(kernel)+feat(ios)+feat(android)+feat(harmony)（27 文件 +2705）推送 origin/main，iOS 编译验证靠 CI
- 2026-08-26 Windows 端 OOXML 批次收尾（会话接续，基线 8bec92e86d）：上会话中断遗留断点——鸿蒙 C++ 层 run() 已改 4 参签名（source, prelude, timeoutMs, outJson）但调用链四处缺口（NativeScriptEngineRun 旧 3 参调用必编译错 + index.d.ts 无 preludeSource + HarnessNative.ets 未透传 + AppViewModel 未加载 rawfile prelude.js），本会话串行补齐（AppViewModel 新增 loadPrelude：getRawFileContent + TextDecoder App 级缓存，失败降级空串不阻塞普通脚本；envelope files 字段经 JSON.parse 自动透传无需额外接线）。门禁：鸿蒙首跑败于 CompileResource 清不掉旧 build 目录（11204003 文件锁）→ 清 entry/build 后 BUILD SUCCESSFUL 20s675ms（CompileArkTS 14s + C++ 交叉编译全过，新 decodeWithStream 弃用 WARN 与 loadHarnessJs 既有风格一致）；Android compileDebugKotlin UP-TO-DATE。推送遇 github.com:443 不通 → 系统代理未继承（陷阱 25）；挂代理后被拒——中断期另一并行会话已自主推送 feat 提交（陷阱 26），同期 Mac 叠加 53315ce2e0（resolvePath 修复）+ 369725b236；pull --rebase 仅记忆文件头行冲突（合并双方条目），Mac 修复自动合流（cleanPath 与 b64 桥不重叠），推送 369725b236..8bec92e86d 成功并触发 CI 三端（结果待补）；核查并行会话记忆失实并追加修订（见上条【修订】）。另：.qoder/ 加入 .git/info/exclude 防入库
- 2026-08-26 Windows 端 OOXML 批次 CI 收尾（c9f453c744）：确认 8bec92e86d 触发的 Build HarmonyOS 2m35s ✅ / Build Android 3m32s ✅；iOS 首轮失败（`Result<Void, String>` 编译错，陷阱 27 收录，53315ce2e0 后由 c9f453c744 改返回 `String?` 修复）→ iOS 复跑 ✅，OOXML 批次三端 CI 全绿闭环；记忆 HEAD 更新到 c9f453c744
- 2026-08-26 Windows 端 prompt.md 补全批次（57bff75aa4 + 本会话收尾）：用户反馈 doc/prompt.md 只覆盖最近几次会话 → 探明 TRAE 对话库 `AppData/Roaming/TRAE SOLO CN/ModularData/ai-agent/database.db`（872MB）为**整库加密**（非 SQLite 头、无 v10/v101 前缀、os_crypt DPAPI 密钥），离线不可提取逐字 prompt，放弃数据库路线；改以 git 63 笔提交 + 记忆维护日志为权威源重写文档（17 批次），提交 `57bff75aa4` 挂代理推送。随后用户指令「以后每个会话结束都默认把输入逐条追加到文档里」→ 维护协议新增**第 6 条**（逐字记录用户输入到 doc/prompt.md，本文档是逐字留存唯一渠道），批次 18 起执行逐字记录
- 2026-08-26 Windows 端 kernel.ps1 验证（1017756023 后）：六命令全过——`status`（v0.1.0-rc.5/master/node v24.19.0/pnpm 11.22.0/已构建）/`remote`（origin 直连上游）/`log --lines 5`/`stop`（正确清理残留 PID 37520 文件）/`fetch`（自动补 upstream remote + 拉到 rc.6~rc.8、0.1.1-rc.1/rc.2 新 tag，GitHub 需挂代理）/`diff`（本地落后上游 166 笔，锁定 rc.5——升级不在本次范围，涉及 transpiler 重打包 + 三端回归风险）；子模块工作区改动核实为已知 transpiler 同步产物（llm-deepseek 四文件改补 + headless 三新文件），非验证污染；未验证 `pull/merge/upgrade/build/run`（变更命令：build 需 pnpm install 首次较慢，run 是长驻进程）；记忆未验证项移除「kernel.sh/kernel.ps1 内核子模块管理命令」
- 2026-08-26 Windows 端沙箱定时器与运行时补齐批次（0e45337533→4179395317，Qoder 会话）：①**内核 bg_timer 空转修复**——harness-entry.ts 改 `__deviceCall('bgTimer',{seconds})` 宿主延迟回包驱动自完成（finish 幂等，kill 后晚到回包 no-op；`__deviceCall` 缺失时保持现状兼容旧宿主）；**主引擎全局 setTimeout 保持 no-op 为有意行为**（若启用会激活 deadline/idleWatchdog 中止长流式生成，超时保护归宿主的既有契约）；②**三端沙箱真定时器**——JS 侧注册表（__sb.timers Map）+ 宿主 `__sbTimerStart(id,ms)` 原生延迟后 `__sbFireTimer(id)` 回投，6 行 JS 段三端逐字一致（setInterval = fire 后重排链；clearTimeout 只删注册表，宿主晚到 fire 静默跳过）；**防跨 run 策略因三端 context 生命周期而异**：iOS 每 run 新 JSContext（asyncAfter 弱捕获当前 ctx）/ Android 每 run 新 QuickJSContext（postDelayed 内 `ctx !== ctxAtReg` 引用比对；计划中「wrapCode 清 __sb.timers」前提不成立属死代码，有意跳过）/ **鸿蒙 engine App 级复用 context 跨 run 持久**（run() 开头 eval 清 __sb.timers 防残留 + kBootstrap 无 __sb 对象需补 `globalThis.__sb = globalThis.__sb || {}` 守卫）；③**prelude.js 加 TextEncoder/TextDecoder（utf-8）guarded polyfill**，四份分发一致；④鸿蒙 napi 全链镜像 fetchHandlerRef（qsb_timer_start 静态回调 + scriptEngineSetTimerHandler/scriptEngineTimerFire 两导出，cpp+napi_init+index.d.ts+HarnessNative.ets+AppViewModel.ets 五处同步，陷阱 24 防护；timerFire 收尾链逐行对照 scriptEngineFetchDone：enforceTimeout→fire→enforceTimeout→FlushPendingRun）；⑤三端 DeviceBridge 各加 bgTimer op（seconds 钳 1-600；iOS Task.sleep / Android coroutine delay / 鸿蒙 ArkTS setTimeout）；门禁与 CI 全绿见验证快照；鸿蒙构建新 shell 需重设 DEVECO_SDK_HOME（既有命令段，hvigorw 首跑 00303217 即此因）；真机两用例（沙箱定时器/bg_timer）待验证
- 2026-08-26 Windows 端模型 ID 预设刷新批次（2393579bf3，Qoder 会话）：用户报告 kimi-k3 测试失败 → 逐家核实官方文档后确认八家预设大面积过时：Kimi k2 系 2026-05-25 全下线/kimi-latest 01-28 下线（kimi-k3 失败根因：预设三模型均已下线且未收录 k3）、DeepSeek deepseek-chat/reasoner 2026-07-24 停用（现役 deepseek-v4-flash/v4-pro）、智谱旗舰 glm-5.3、OpenAI gpt-5.6 系（sol/terra/luna，luna 为 cost 优化款作默认）、豆包 doubao-seed-2.x、千问 qwen3.8/3.7（稳定别名 qwen-plus 保留作默认）、Gemini 三端失同步（iOS 还在 2.5 系，同步至 gemini-3.7-flash 系）；**四份目录同步**（iOS Providers.swift / Android app Providers.kt / 鸿蒙 Constants.ets / shared LlmProviders.kt）+ 三处设置页 placeholder + 五处 deepseek-chat fallback → deepseek-v4-flash；Kimi keyUrl 迁 platform.kimi.com（baseUrl 仍 api.moonshot.cn/v1）；**不改项**：shared CLAUDE 条目（内核仅 OpenAI 兼容，IMPORT_UNSUPPORTED）、GEMINI native baseUrl v1beta、shared DEEPSEEK baseUrl 带 /v1、iOS HttpBridge glm-4.6v（官方在役）、iOS 测试 fake-key 用例、内核 bundle 默认值（宿主 init 必注入 profile）；发现 androidApp/src（MainActivity/SettingsScreen）为无模块编译的孤儿遗留代码（root 与 androidApp 两套 settings 均不含其源集，CI 只建 :androidApp:app），仍同步更新防日后复活；DeepSeek V4 思考档位官方已改 low/high/max，宿主 UI/内核 rc.5 适配器仍 off/high/max，升级内核时需同步；存量用户已保存的停用模型 ID 无自动迁移（需手动改选）；CI 三端全绿（鸿蒙 2m54s/Android 3m39s/iOS 10m43s）
- 2026-08-26 Windows 端内核升级批次（43961d5 + bccd3ce336，Qoder 会话）：子模块 47f943859b（rc.7~24）→ **dsh-v0.1.1-rc.2**（上游新增 rc.8/v0.1.1-rc.1/rc.2 三 tag，共 854 笔）。**新内容盘点**：llm-deepseek 统一图片/Files API 管线（file-store/files-api/file-id/upload-index 四新件 + adapter/serialize 大改）、dsh-llm content.ts 图片内容处理、tool-fs read_image 降采样尺寸/坐标报告、credentials 类型扩展、plan-mode/tool-web search/token-meter 小改；非消费面（不影响移动端）：persistent pwsh pty、code-runtime-python、web UI、subagent 预设。**兼容性结论**：入口导入符号全部保留无破坏；新 Node 依赖仅 upload-index 的 crypto/fs/path（shims 已覆盖）；FormData/Blob 裸引用仅在 Files API upload() 内部（移动端无图片输入不可达，入白名单附实证理由）。**两处必修**：①本地 Gemini 兼容热修（emitThinking/toolCallExtras/thoughtSignature，5 文件）上游未收编，checkout 前存档 patch（注意：PowerShell `>` 重定向写 UTF-16 导致 git apply 失败，需先转 UTF-8；本次因中文注释行内容已无法无损还原，最终按 diff 内容在新基线手工重放，patch 归档至 kernel/gemini-compat-hotfix.patch 为唯一可复现源）；②DeepSeekAdapter 构造即建 DeepSeekUploadIndex → resolveDshHome() → os.homedir() 启动即炸，shims 补 homedir（返回 __HARNESS_CWD 沙箱根）+ 纯 JS SHA-256 createHash（三用例对照 node:crypto 全 MATCH）。**门禁**：build 2296KB + check-quickjs-compat PASS + smoke-fs-web 11/11 + 三端分发 SHA256 CCF34918 一致 + Android compileDebugKotlin + 鸿蒙 assembleHap 10s（HAP 9.8MB）。遗留：上游 reasoningEffort 已支持 low 档（宿主 UI 仍 off/high/max，可后续同步）；pnpm install lefthook postinstall 在子模块下必失败（已知无害）。CI 三端验证中
- 2026-08-26 Windows 端内核能力补齐阶段 1 批次（95209237fb，Qoder 会话）：按《内核能力补齐路线图》落地阶段 1——**harness-entry.ts 新增四组插件装配**：fs 工具三件套（FsSandbox root=cwd + ToolFs + ToolFsSearch + ToolStrReplaceEditor，read/write/edit/glob/grep 全走既有 __harnessFsCall 宿主桥）、web 三包（WebService+WebFetchHttp+ToolWeb，Readability 降级路径 typeof window 守卫入 allowlist）、subagent 四包（SubagentService+InProcessDriver+ToolSubagent+report，走 LocalJobRegistry 后台任务）、guard 小件（repeat-tool-reminder+timeout-policy）；**shim 大扩展**：host-bridge fs 桥补 open/close/read/write 句柄流式路径 + Dirent + realpath/rename 透传 + ReadableStream reader.cancel（web-fetch-http 截断后取消必需，_canceled 语义：丢队列/阻 enqueue/待决 read 立即 done）；harness-shims-iife 补 node:fs/promises require 拦截 + TextEncoder/TextDecoder（node:util）+ process.platform/pid + Buffer + pathToFileURL 等；**三端宿主 fs 桥补 rename/realpath op**（Android FsBridge.kt / iOS FsBridge.swift / 鸿蒙 harness_engine.cpp）；调试中修复 fs-local probe 的 `info.mode & 0o777n` BigInt 混用（mode 缺失时 Number(bigint) 抛错）与 TextDecoder 缺失导致的 invalid UTF-8。**验证**：check-quickjs-compat PASS + smoke-fs-web.mjs 新增 11/11（fs 全链/rename/realpath/web_fetch 抹页转 markdown/subagent 子代理回报）+ smoke-manual.mjs 既有 24/24 回归 + 三端 harness.js SHA256 一致（42E7ADD1，2339259 字节，bundle 2284KB）+ Android compileDebugKotlin 4s + 鸿蒙 assembleHap 10s871ms（libharness_napi.so 重编译确认）；bundle grep 确认工具进产物（陷阱 22 纪律）；临时调试脚本 debug-bigint/debug-read.mjs 已删除，smoke-fs-web.mjs 入库；iOS 靠 CI 编译验证（6m26s ✅，FsBridge.swift 首次真实编译通过）；真机三用例（fs 工具/web_fetch/subagent）待验
- 2026-08-26 Windows 端 reasoningEffort low 档三端同步批次（5bc58700e8，Qoder 会话）：上游 dsh-v0.1.1-rc.2 已原生支持 off/low/high/max（resolveThinking 将 low 直通 wire：thinking enabled + reasoning_effort low），宿主 UI 补档即可，**无需重打 bundle**（harness-entry setModel 对 effort 纯透传无白名单）。五处改动：iOS Providers.swift ids+label / ChatView.swift effortCaption、Android Providers.kt IDS+label / ChatView.kt 面板硬编码清单（注意 grep 输出会剥缩进，SearchReplace 前必须 Read 原文）、鸿蒙 Constants.ets EFFORT_OPTIONS+ReasoningEfforts.ALL；三端文案统一：label「轻思考」/hint「轻度思考，响应更快」，档位顺序随上游 off<low<high<max。门禁：Android compileDebugKotlin 过 + 鸿蒙 assembleHap BUILD SUCCESSFUL（CompileArkTS 增量重编，HAP 9.78MB）；iOS 靠 CI；清账了模型 ID 刷新批次与内核升级批次的两处遗留备注。真机可抽验一轮 low 档对话
- 2026-08-26 Mac 端远端合流 + 错误详情透出批次（74cc1c4452）：用户指令「更新远端代码；定位问题：现在模型验证都是提示 DeepSeek API stream from ...failed, 看不到详细报错原因」。①**远端 31 提交合流**：pull --ff-only 因本地 5 文件冲突改走 stash push→pull→stash pop；三端 Providers 冲突采用本地（stashed）版本（deepseek 默认 v4-pro + 多 v4-flash-vision-exp；qwen 默认 qwen3.7-plus + qwen3.7-max/qwen3.6-plus；moonshot keyUrl 用 platform.moonshot.cn；openai 默认 gpt-5.4-mini + gpt-5.4-nano），保留远端 LEGACY_PRESET_MODELS 迁移机制/reasoningEffort low 档/claude provider；**鸿蒙 Constants.ets 冲突解决时选择本地版本导致 LEGACY_PRESET_MODELS 块被覆盖**（远端 dd549acc7e 已添加，ConfigService.migratePresets 依赖），grep 引用链后补回——stash pop 冲突解决后必须核对该文件新增 import 的符号是否都在；ChatView 三文件自动合并。②**stream failed 无详情根因定位**（陷阱 28）：harness.js turn 收口 `error instanceof LlmError ? error.failure : { message: errorChain(error) }`——LlmError 分支取 frozen failure（无 cause），llm-deepseek adapter 的 TRANSPORT 包装把底层 401/HTTP 详情丢光。③**修复**：内核 agent.ts 收口处 errorChain 与 failure 合并为 `detail` 字段 + LlmFailure/types.ts + session/types.ts 注释同步；三端宿主展示 msg+detail（iOS AppStore.describeReason / Android MainActivity / 鸿蒙 AppViewModel + HarnessNative.ChatError.detail）；transpiler 重建三端 harness.js 同 SHA256（618069fb）+ QuickJS 门禁 PASS。④**门禁**：iOS build 0 警告 + XCTest 14/14（iPhone 17e）；Android compileDebugKotlin 通过；鸿蒙落盘交 CI；内核子模块三处 TS 改动（agent.ts/llm types.ts/session types.ts）属上游修复，子模块指针不进父仓库（与 rc.2 基线并存，后续上游合入时可弃）。真机验证项新增：模型验证失败时应显示底层详情（如 401 invalid_authentication_error）
