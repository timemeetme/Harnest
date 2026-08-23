# Harnest 项目记忆（Project Memory）

> 本文件是 TRAE 项目记忆：每次会话自动加载，新会话开工前先读这里，避免重复踩坑。
> 由 TRAE 生成并按项目进展自动维护：每次会话发生实质变更（新提交/新结论/新陷阱）时由当前会话直接更新。人工修改请同步更新「维护日志」。
>
> 最后同步 HEAD: 6ae91064a3 （2026-08-23）

## 项目身份

- **仓库**: `git@github.com:timemeetme/Harnest.git`，主分支 `main`
- **推送身份**: 本机 SSH 密钥属 `heavencme`（已被加为协作者，push 已验证可用）
- **提交风格**: Conventional Commits（`fix(ios):` / `test(ios):` / `fix(all):` / `feat` / `docs`，scope 常为 ios/android/harmony/all）
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
- `AppStore.swift` — 状态中枢；**引擎懒启动**：首次发消息才 `ensureStarted`，App 启动不 boot
- `Tests/HarnestTests/` — XCTest 套件（见下）

## 已验证命令（本机全部跑通过）

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

## 已知陷阱（重要，勿重复踩）

1. **gradlew 无执行位**（git mode 100644）→ 用 `sh ./gradlew ...`；CI 里已自带 `chmod +x`，非仓库 bug，勿"修复"
2. **`:shared:allTests` 在本机必失败**（无 Android SDK）→ 用 `:shared:iosSimulatorArm64Test`
3. **Swift 值语义移植陷阱**：Kotlin `JSONObject` 是可变引用（原地 put 即更新缓存），Swift 字典是值类型（改副本必须显式回写）。已因此修过 ConfigService 缓存不回写 bug（c5d5d82e71），移植 Kotlin 代码时警惕同类模式
4. **引擎懒启动**：App 冷启动无引擎日志是正常的，别在启动期找 boot 输出；测试想触发 boot 必须走 `ensureStarted` 或发消息
5. **xcodeproj 是生成物**（gitignore）：工程改动一律改 `project.yml` 再 `xcodegen generate`，别手改 xcodeproj
6. **JSONSerialization 解析顶层标量**（如裸字符串字面量）必须加 `.fragmentsAllowed`
7. **osascript 无辅助功能权限**（-1719）→ 坐标点击式 UI 自动化不可用；UI 验证用 XCTest/XCUITest（已有 accessibilityLabel 锚点：Tab「设置」、SecureField「sk-…」、按钮「保存」「发送」、TextField「发送消息…」）
8. **裸 boot 的内核 `listProviders` 返回空数组**：必须先 `init` 注入 provider 档案才非空（AppStore 的 providerCatalog 有 fallback）

## 环境事实

- 模拟器：iPhone 17 Pro（iOS 模拟器）；App 容器内 `api_config.json` 首启自动播种 9 个 provider 默认配置
- 测试注入 fake key 后 chat 全链路可达 DeepSeek API 并正确回传 401（说明 JS 内核→网络桥→错误 surfaced 链路通）
- `.trae/` 未被 gitignore（本文件可提交共享）；`iosApp/*.xcodeproj`、`build/`、DerivedData 已忽略

## 验证状态快照（2026-08-22/23）

- ✅ XCTest **14/14 通过**（EngineBridgeTests 6 + LocalEngineFlowTests 4 + ProvidersCatalogTests 4，iPhone 17 Pro 模拟器）
- ✅ iOS Debug + Release 构建通过
- ✅ `:shared:iosSimulatorArm64Test` 通过；XCFramework 51MB（ios-arm64 + ios-arm64_x86_64-simulator 双 slice）
- ✅ 已推送 origin/main：`c5d5d82e71`（fix: ConfigService 缓存回写）、`6ae91064a3`（test: XCTest 套件）
- ⬜ 未验证：harmonyApp 构建（需 DevEco/hvigor）、androidApp 构建（需 Android SDK）、kernel.sh 转译全流程

## 维护协议（后续会话遵循）

1. 新会话先读本文件；发现内容过时，**先更新本文件再干活**
2. 实质变更（新提交、新陷阱、新命令、验证状态变化）→ 追加「维护日志」一行，并更新顶部「最后同步 HEAD」
3. 「已知陷阱」只追加或修订，**不删除**条目
4. 记录命令时必须是**本机验证过**的形式；未验证的标 ⬜

## 维护日志

- 2026-08-23 初始生成（HEAD 6ae91064a3）。沉淀：iOS 全链路验证结论（14/14 测试、Debug+Release 构建、XCFramework、模拟器 E2E）、ConfigService 值语义 bug 根因与修复、8 条陷阱、四端架构与内核子模块链路
