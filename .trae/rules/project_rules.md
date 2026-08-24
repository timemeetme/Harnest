# Harnest 项目记忆（Project Memory）

> 本文件是 TRAE 项目记忆：每次会话自动加载，新会话开工前先读这里，避免重复踩坑。
> 由 TRAE 生成并按项目进展自动维护：每次会话发生实质变更（新提交/新结论/新陷阱）时由当前会话直接更新。人工修改请同步更新「维护日志」。
>
> 最后同步 HEAD: f2e4d6d905 （2026-08-25，Mac 机：思考/回复分段三级折叠 + 150ms 节流 + 三端 UI 功能补齐与一致性对齐（批次 1-3），见 1fbdcfdba7/b3f694e194/f2e4d6d905；前一基线 214532ffd3 为 Windows 鸿蒙 ArkTS 修复 + 真机装机）

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
- ⬜ 未验证：kernel.sh/kernel.ps1 内核子模块管理命令；真机回归 NO_ADAPTER 修复（清空 deepseek key 后重开旧会话应回落默认 provider 不报错）；真机回归 max-tokens 修复（deepseek-reasoner 问难题应完整出答案不截断）；真机验证 maxTokens 用户配置生效（设置页填 1024 问长答案应截断、填 65536 应完整）；**真机回归万字思考（deepseek-reasoner 问难题：思考过程应流畅刷新不卡死、回合结束不崩溃）**；**Harmony 端 f2e4d6d905 编译验证（靠 CI；批次 1-3 共 5 文件 ArkTS 改动未本地构建）**

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
- 2026-08-25 Mac 端三连提交（1fbdcfdba7 → b3f694e194 → f2e4d6d905）：①**思考/回复分段三级折叠**（内核 extractDetails 按 (turn,step) 切段 + 概览/分段/全文三级 UI，对标 trae/workbuddy）；②**三端统一 150ms 节流**（think+answer 双缓冲，修复万字思考卡死——iOS 11584 字卡住后一次性蹦出的根因是宿主窗口与内核心跳同频 200ms 相位锁死 + 主线程逐字渲染压力）；③**三端 UI 功能补齐批次 1-3**（代码块复制/错误重试/会话重命名/提问卡跳过/清空消息/token 用量 in+out/🔄 重新生成/回到底部悬浮按钮（贴底判定：iOS PreferenceKey minY<400、Android derivedStateOf last≥total-3、Harmony onScrollIndex last≥total-2，贴底才自动跟随）/工具卡点击展开/steer 展开行/subagent 专属行）+ 一致性终检 26 项全对齐。验证：iOS build+XCTest 14/14、Android Mac 本地 compileDebugKotlin（**Mac 也有 Android SDK ~/Library/Android/sdk，带 ANDROID_HOME 即可本地编译不必等 CI**）、Harmony 落盘待 CI；会话两次中断恢复均按陷阱 13 diff 核对（Android 🔄 按钮本体丢失一次、记忆文件核对一次）
