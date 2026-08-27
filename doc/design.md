# Harnest 完整架构设计文档

> 本文档为未来的维护者或 AI 提供一份足够详细的架构蓝图，使其能够仅凭此文档理解并复现 Harnest 项目的代码结构、模块关系与核心实现逻辑。
>
> **版本**：v3（2026-08-27 全量重写）
> **对应代码**：HEAD `dc2e4a93f5`（内核 bundle 版本 dsh-v0.1.1-rc.2，三端 harness.js SHA256 一致）
> **旧版说明**：v2（2026-08-17）描述的 WebSocket/JSON-RPC 主链路架构已被废弃——当前三端均**内嵌 JS 引擎直接运行共享内核 bundle**，不再经过任何网络进程间通信。

---

## 目录

1. [项目定位与核心设计思想](#1-项目定位与核心设计思想)
2. [整体架构总览](#2-整体架构总览)
3. [仓库目录结构](#3-仓库目录结构)
4. [内核层：harness.js 与转译工具链](#4-内核层harnessjs-与转译工具链)
5. [桥协议：三端同构的宿主 ↔ 内核接口](#5-桥协议三端同构的宿主--内核接口)
6. [三端宿主实现](#6-三端宿主实现)
7. [设备能力工具（device_*）](#7-设备能力工具device_)
8. [配置与持久化](#8-配置与持久化)
9. [构建系统与工具链](#9-构建系统与工具链)
10. [功能矩阵](#10-功能矩阵)
11. [已解决的重大工程问题](#11-已解决的重大工程问题)
12. [演进方向](#12-演进方向)
13. [附录 A：关键文件速查](#附录-a关键文件速查)
14. [附录 B：AI 复现指南](#附录-bai-复现指南)

---

## 1. 项目定位与核心设计思想

### 1.1 项目定位

Harnest 是一个跨平台移动 AI 助手应用，将 **deepseek-harness**（AI 工具链执行内核，TypeScript/Node.js 项目）转译为单文件 JS bundle（`harness.js`），并在 **Android、iOS、HarmonyOS** 三大移动平台上各自内嵌 JS 引擎直接运行它，提供统一的用户体验与设备能力工具集。

### 1.2 核心设计思想

#### 思想一：Kernel/Shell 分层，单 bundle 三端复用

```
┌──────────────────────────────────────────────┐
│  Shell 层（平台原生 UI 与生命周期）            │
│  ├── Android:   Kotlin + Jetpack Compose     │
│  ├── iOS:       Swift + SwiftUI              │
│  └── HarmonyOS: ArkTS + ArkUI                │
├──────────────────────────────────────────────┤
│  Bridge 层（平台 JS 引擎 + 宿主桥符号）         │
│  ├── Android:   QuickJS（com.whl.quickjs）   │
│  ├── iOS:       JavaScriptCore               │
│  └── HarmonyOS: QuickJS（自编译 C++ NAPI）    │
├──────────────────────────────────────────────┤
│  Kernel 层（harness.js，三端字节级一致）        │
│  └── 会话管理、工具链、LLM Provider、沙箱       │
└──────────────────────────────────────────────┘
```

- **内核源码与 App 双仓独立**：内核（`kernel/deepseek-harness` 子模块 + `tools/harness-transpiler`）保持中立，不感知 App 存在；App 只消费构建产物 `harness.js`。
- **离线优先**：harness.js 及全部依赖在 App 打包期内置于资源目录，运行期无需下载任何内核代码。
- **一次转译、三端同字节**：三端资源目录中的 harness.js 由同一条构建链产出，SHA256 必须一致（当前为 `11B74F57…`，2,403,739 字节），这是发版前的硬性验证项。

#### 思想二：无服务端、无 WebSocket——JS 引擎即运行时

早期方案（v2 文档）曾设计"PC 侧 Node 内核 + WebSocket/JSON-RPC 中继 + 手机瘦客户端"。**该方案已完全废弃**。当前架构：

- 每台设备**本地完整运行**整个 agent 内核（LLM 循环、工具执行、会话持久化都在手机上）。
- 宿主与内核之间是**同进程跨语言函数调用**（Swift/Kotlin/ArkTS ↔ JS 引擎），不是网络协议。
- 网络仅用于 LLM API 请求（走宿主原生 HTTP 栈，见 §5 的 fetch 桥）。

#### 思想三：桥协议三端同构

三端向 JS 侧注入**完全相同的一组全局符号**（见 §5），内核 polyfill 层不感知平台差异。新增一个桥能力 = 三端各实现一次同名符号 + 内核 polyfill 调用一次。这是"三端同构"能够低成本维持的关键。

#### 思想四：声明式 UI 镜像

三端 UI 均使用声明式框架，组件树结构严格对齐：

| 组件 | Android (Compose) | iOS (SwiftUI) | HarmonyOS (ArkUI) |
|------|-------------------|---------------|-------------------|
| 根布局 | `AppRoot` | `ContentView` | `AppShell` |
| 侧边栏 | `Sidebar` | `SidebarView` | `Sidebar` |
| 聊天区 | `ChatPane` | `ChatView` | `ChatPane` |
| 输入栏 | `InputBar` | `InputBarView` | `InputBar` |
| 详情/工具面板 | `DetailsPanel` | `DetailsView` | `DetailsPanel` |
| 状态栏 | `StatusBar` | `StatusBarView` | `StatusBar` |

#### 思想五：KMP 角色收缩

Kotlin Multiplatform `shared/` 模块**仍在 Android 构建中**（`include(":shared")`），但 iOS 已移除全部 KMP 依赖（project.yml 标注"纯 Swift 本地引擎"）。新功能默认直接写在平台原生层，不再新增 commonMain 抽象。

---

## 2. 整体架构总览

### 2.1 真实数据流（以一次 chat 为例）

```
用户输入
  │
  ▼
Shell UI（Compose / SwiftUI / ArkUI）
  │  调用 LocalEngine 门面（平台语言）
  ▼
LocalEngine ──► HarnessEngine（JS 引擎封装）
  │              ① ensureStarted：加载 assets/rawfile 中的 harness.js 并执行
  │              ② __harnessCall("chat", jsonArgs) 驱动内核
  ▼
harness.js（内核，QuickJS/JSC 内运行）
  │  ┌─ LLM 请求 ──► __harnessFetchStart（上行桥符号）
  │  │                ▼
  │  │              宿主原生 HTTP 栈（流式）
  │  │                ▼
  │  │              __harnessOnFetchHeaders/Chunk/Done（下行回调）
  │  ├─ 工具调用 ──► 文件工具 __harnessFsCall / 设备工具 __harnessDeviceCall
  │  │                ▼
  │  │              宿主 DeviceBridge / 沙箱 FS ──► __harnessOnDeviceResult / __harnessCallSettle
  │  └─ 流式输出 ──► __harnessEmit（事件上行：answer/thinking/工具卡/水位…）
  │                    ▼
  │                  宿主事件泵 ──► UI 状态更新
  ▼
SessionStore：sessions.json + per-session .jsonl 事件日志（落盘持久化）
```

### 2.2 关键结论

- **没有** KernelManager、子进程、WebSocket 端口、JSON-RPC。这些概念只存在于已废弃的 v2 文档中。
- 宿主对内核的全部入口收敛为**一个函数**：`__harnessCall(funcName, jsonArgs)`，同步调用返回 `{sync, resultJson}`，异步调用返回 `callId` 后由 `__harnessCallSettle` 回填结果。
- 内核对宿主的全部出口收敛为**8 个上行全局符号**（见 §5.1）。

---

## 3. 仓库目录结构

```
HarnessApp/
├── kernel/
│   └── deepseek-harness/        # git 子模块：内核 TypeScript 源码（上游独立仓库）
├── tools/
│   └── harness-transpiler/      # 转译器：TS 内核 → 单文件 harness.js
│       ├── src/harness-entry.ts # 内核入口（1397 行）：插件 compose + 三端 API 面
│       ├── build.mjs            # 构建链三段式（见 §9.1）
│       └── polyfills/           # 宿主桥 polyfill（注入 bundle 头部）
│           ├── host-bridge.js   # 1057 行：fetch/emit/fs/device/stdout 桥实现
│           ├── device-bridge.js # 62 行：device_* 工具注册
│           └── harness-shims-iife.js  # node: 前缀模块 shim 等
├── androidApp/                  # Android 宿主（Kotlin + Compose）
│   └── app/src/main/
│       ├── assets/harness.js    # 构建产物分发点
│       └── java/.../
│           ├── engine/HarnessEngine.kt    # QuickJS 引擎封装（353 行）
│           ├── engine/ScriptSandbox.kt    # run_script 沙箱
│           ├── service/LocalEngine.kt     # 对 UI 的门面（398 行）
│           └── device/DeviceBridge.kt     # 设备工具 21 ops
├── iosApp/                      # iOS 宿主（纯 Swift，无 KMP）
│   └── Sources/
│       ├── Resources/harness.js # 构建产物分发点
│       └── Service/
│           ├── HarnessEngine.swift    # JavaScriptCore 封装（426 行）
│           ├── LocalEngine.swift      # 门面（399 行）
│           ├── ScriptSandbox.swift    # 沙箱（472 行，根 Documents/Scripts）
│           └── DeviceBridge.swift     # 设备工具（9/21 ops，见 §7）
├── harmonyApp/                  # HarmonyOS 宿主（ArkTS + C++ NAPI）
│   └── entry/src/main/
│       ├── resources/rawfile/harness.js  # 构建产物分发点
│       ├── cpp/napi_init.cpp             # QuickJS 自编译 + NAPI 导出
│       └── ets/service/
│           ├── HarnessNative.ets     # NAPI 调用封装（521 行）
│           ├── LocalEngine.ets       # 门面（269 行）
│           └── DeviceBridge.ets      # 设备工具 23 case（三端最全）
├── shared/                      # KMP 共享层（仅 Android 仍引用，角色收缩中）
├── doc/                         # 设计文档（本目录，.gitignore 内，需 git add -f）
├── kernel.ps1 / kernel.sh       # 子模块与 headless 服务管理脚本（不产 bundle）
└── .trae/rules/project_rules.md # 项目记忆（AI 会话的开工依据）
```

---

## 4. 内核层：harness.js 与转译工具链

### 4.1 入口：harness-entry.ts

`tools/harness-transpiler/src/harness-entry.ts`（1397 行）是 bundle 的唯一入口，负责两件事：

**① 插件 compose（L468-1001）**：按固定顺序组装内核能力。当前 compose 清单含：

- 内核基础：会话、provider 适配、工具运行时
- **fs 三件套**（read/write/edit 文件工具，经 `__harnessFsCall` 走宿主沙箱）
- **WebFetchHttp / ToolWeb**（web_fetch / web_search 工具）
- **SubagentRuntime / ToolSubagent**（子代理运行时 + task 工具，能力补齐阶段 1 新进件）
- 直注册工具：`bg_timer`（后台定时器）、`run_script`（沙箱脚本，见 §5.3）

**② 三端 API 面**（宿主经 `__harnessCall` 可调用的函数）：

| API | 说明 |
|---|---|
| `init` | 初始化内核（配置、持久化目录） |
| `setProviderProfile` / `listProviders` | 配置/列举 LLM 供应商与模型 |
| `createSession` | 创建会话 |
| `chat` | 发起一轮对话（流式） |
| `steer` | 对话进行中插入用户引导消息 |
| `answerQuestion` | 回答内核的提问卡（ask_user 工具闭环） |
| `setPlanMode` | 切换计划模式 |
| `abortActive` | 中断当前轮 |
| `compactNow` | 立即压缩上下文 |
| `getUsageStats` | token 用量统计 |
| `setModel` | 切换模型 / reasoningEffort（四档） |
| `listJobs` / `killJob` | 后台任务管理 |

**流式节流**：thinking 事件 64 字/200ms，answer 事件 16 字/60ms——防止桥回调洪峰打爆宿主 UI 线程。

### 4.2 polyfill 层

bundle 头部注入的 polyfill 把"Node 内核"适配到"宿主桥环境"：

- **host-bridge.js**（1057 行）：实现 fetch（流式 SSE，桥到宿主 HTTP）、stdout/stderr、进程退出、fs 调用、device 调用的 JS 侧封装与 pending-map 异步闭环。
- **device-bridge.js**（62 行）：把 23 个 `device_*` 工具注册进内核工具表，统一转发 `__harnessDeviceCall`。
- **harness-shims-iife.js**：`node:` 前缀内置模块（fs/path/crypto 等）的 shim 替换。

### 4.3 bundle 版本

当前产物：**dsh-v0.1.1-rc.2**，约 2.3 MB（esbuild IIFE，含阶段 1 新进件后 2284KB）。三端资源目录中的副本必须 SHA256 一致。

---

## 5. 桥协议：三端同构的宿主 ↔ 内核接口

### 5.1 主桥符号

**上行（JS → 宿主，宿主注入的全局函数，8 个）**：

| 符号 | 用途 |
|---|---|
| `__harnessFetchStart` | 发起流式 HTTP 请求（LLM API / web_fetch） |
| `__harnessEmit` | 内核事件上行（answer/thinking/工具卡/水位/错误…） |
| `__harnessFsCall` | 沙箱文件读写（fs 三件套的后端） |
| `__harnessDeviceCall` | 设备能力调用（device_* 工具的后端） |
| `__harnessStdout` / `__harnessStderr` | 内核日志 |
| `__harnessProcessExit` | 内核主动退出 |
| `__harnessCallSettle` | 异步 `__harnessCall` 的结果回填 |

**下行（宿主 → JS，bundle 暴露的全局函数）**：

- `__harnessOnFetchHeaders / __harnessOnFetchChunk / __harnessOnFetchDone / __harnessOnFetchFail / __harnessOnFetchStatus`：流式 HTTP 五段回调。
- `__harnessOnDeviceResult`：设备工具异步结果。
- `__harnessCall(funcName, jsonArgs)`：**宿主驱动内核的唯一入口**。同步函数返回 `{sync:true, resultJson}`；异步函数返回 `{callId}`，结果经 `__harnessCallSettle` 回填。

### 5.2 桥协议设计要点

- **字符串过河**：所有参数/返回值一律 JSON 字符串，规避三端 JS 引擎对复杂对象 marshalling 的差异。
- **pending-map 异步模式**：每个异步调用分配 callId，宿主侧挂起等待，JS 侧 settle 时按 callId 匹配——三端同一套模式，无平台分支。
- **串行保护**：iOS 侧用专用 `jsQueue` 串行化所有 JS 引擎访问；Android/HarmonyOS 同理在引擎封装内串行化。QuickJS/JSC 均非线程安全。

### 5.3 沙箱桥（run_script 工具）

`run_script` 让 agent 在设备本地沙箱中执行 JS 脚本，使用一组独立的 `__sb*` 符号：

`__sbLog`、`__sbFetch`、`__sbRead`、`__sbWrite`、`__sbReadB64`、`__sbWriteB64`、`__sbTimerStart`、`__sbFireTimer`、`__sbSettle`、`__sbSettleErr`

沙箱根目录为应用私有目录（iOS：`Documents/Scripts`）。bundle 内注入 **prelude.js**（四份副本随产物分发），向沙箱脚本提供：

- 编码工具：base64 / utf8 / crc32
- 压缩工具：zipPack / inflate
- **OOXML 生成器**：`makeXlsx` / `makeDocx` / `makePptx`——agent 可直接产出 Excel/Word/PPT 文件，这是"手机端办公自动化"的差异化能力。
- 沙箱定时器：bg_timer 工具与 `__sbTimerStart`/`__sbFireTimer` 配合，支持后台延时任务。

---

## 6. 三端宿主实现

### 6.1 iOS（Swift + JavaScriptCore，纯 Swift 无 KMP）

| 文件 | 行数 | 职责 |
|---|---|---|
| `Sources/Service/HarnessEngine.swift` | 426 | JSContext 封装：boot（加载 harness.js）、callFunc/callAwait、fetchEvent 下行、deviceResult 下行；专用 `jsQueue` 串行保护 |
| `Sources/Service/LocalEngine.swift` | 399 | UI 门面：ensureStarted/listProviders/usageStats/mountSession/chat/steer/compactNow/listJobs/abortActiveRound/setModel |
| `Sources/Service/ScriptSandbox.swift` | 472 | run_script 沙箱，根目录 Documents/Scripts |
| `Sources/Service/DeviceBridge.swift` | — | 设备工具，当前接通 9/21 ops（L205-207 列出 12 项"暂未接入"，见 §7） |

引擎为系统 **JavaScriptCore**（JSContext），无需打包第三方引擎。

### 6.2 Android（Kotlin + Compose + QuickJS）

| 文件 | 行数 | 职责 |
|---|---|---|
| `engine/HarnessEngine.kt` | 353 | QuickJS 引擎封装（`com.whl.quickjs.wrapper`，非 Hermes） |
| `service/LocalEngine.kt` | 398 | UI 门面，API 与 iOS 对齐 |
| `engine/ScriptSandbox.kt` | — | run_script 沙箱 |
| `device/DeviceBridge.kt` | — | 设备工具 21 ops（L119-147 dispatch 表） |

引擎为 **QuickJS**（第三方 wrapper 库，JNIEnv 桥接）。注意：v2 文档中的 "Hermes/JNI" 描述过时，实际选型是 QuickJS。

### 6.3 HarmonyOS（ArkTS + 自编译 QuickJS C++ NAPI）

| 文件 | 行数 | 职责 |
|---|---|---|
| `cpp/napi_init.cpp` | — | QuickJS C 源码直接编译进 NAPI 动态库；导出 `init/callFunc/fetchEvent/deviceResult/pumpJobs/dispose/isReady` + scriptEngine 七件套 |
| `ets/service/HarnessNative.ets` | 521 | ArkTS 侧 NAPI 调用封装 |
| `ets/service/LocalEngine.ets` | 269 | UI 门面 |
| `ets/service/DeviceBridge.ets` | — | 设备工具 **23 case 全覆盖**（三端最全） |

QuickJS（约 1MB C 源码）自编译进 `.so`，通过 NAPI 暴露给 ArkTS——三端中唯一自建引擎栈的端，也是桥能力最全的端。

---

## 7. 设备能力工具（device_*）

内核经 device-bridge.js 注册 **23 个 `device_*` 工具**，统一协议 `DeviceRequest{op,args} → DeviceResult{ok,data?,error?}`。覆盖：状态探测、权限申请、通讯录、日历、剪贴板、文件、相册、邮件、拨号/短信、相机、录音、打开应用等（详细设计见 [device-tools-design.md](device-tools-design.md)）。

**三端接通度**（当前真实状态）：

| 端 | 接通 ops | 说明 |
|---|---|---|
| HarmonyOS | **23/23** | 全覆盖，DeviceBridge.ets 每 case 均有实现 |
| Android | **21/21** | dispatch 表完整 |
| iOS | **9/21** | DeviceBridge.swift L205-207 显式列出 12 项"暂未接入" |

iOS 缺口是已知的最大端差异，补齐为后续重点（见 §12）。

---

## 8. 配置与持久化

### 8.1 api_config.json（三端同构）

LLM 供应商/模型配置存于应用私有目录的 `api_config.json`，三端同一份 schema：

- 供应商预设持续刷新（当前含 deepseek-v4 系列等八家）；
- `presetMigration` 字段（当前 `"2026-08b"`）实现配置版本迁移，旧配置自动升级；
- 支持 EMM 导入导出（企业分发场景）。

### 8.2 SessionStore（会话持久化）

- `sessions.json`：会话索引（标题、创建时间、模型、水位）。
- per-session `.jsonl` 事件日志：每个会话一份追加式事件流，支撑：
  - **k3b seed 重放**：冷启动后按事件日志重建内存会话；
  - **k6 fork**：从任意历史消息分叉新会话；
  - 编辑重发、导出对话。

---

## 9. 构建系统与工具链

### 9.1 harness.js 三段式构建链

```
kernel/deepseek-harness（TS 源码）
  │
  ▼ ① build.mjs
esbuild 打包为 IIFE 单文件
  │
  ▼ ② patch.mjs
- node: 前缀模块 shim 替换
- SSE flush 补丁（流式响应在 QuickJS 下的刷新修正）
- QuickJS 兼容补丁（语法/API 降级）
  │
  ▼ ③ check-quickjs-compat.mjs
acorn AST 静态门禁：拦截 QuickJS 不支持的语法特性，构建期失败而非运行期爆炸
  │
  ▼ 分发
iosApp/Sources/Resources/ + androidApp/app/src/main/assets/ + harmonyApp rawfile/
（三端 SHA256 必须一致）
```

### 9.2 kernel.ps1 / kernel.sh

管理内核子模块与 headless 服务的脚本（status/remote/log/stop/fetch/diff/pull/merge/upgrade/build/run），**不产出 bundle**——bundle 只由 harness-transpiler 构建链产出。内核上游当前已迭代至 0.1.1-rc.2 及更新 tag。

### 9.3 各端构建

- **Android**：Gradle，`compileDebugKotlin` 为本地快速门禁。
- **HarmonyOS**：需 `$env:DEVECO_SDK_HOME` 且 DevEco 自带 node 入 PATH；命令 `.\hvigorw.bat --mode module -p module=entry@default assembleHap --no-daemon`。
- **iOS**：xcodegen + xcodebuild（project.yml 声明式工程），无 KMP 依赖后构建链显著简化。
- **CI**：GitHub Actions 三端流水线（Build Android / Build iOS / Build HarmonyOS），发版前要求三端全绿。

---

## 10. 功能矩阵

### 10.1 三端全量具备

流式输出（含思考折叠）｜工具调用卡片｜提问卡（ask_user 闭环）｜上下文水位条｜编辑重发｜导出对话｜会话 fork｜消息评分｜steer 对话中引导｜后台任务（listJobs/killJob）｜run_script 沙箱脚本｜OOXML 办公文档生成（xlsx/docx/pptx）｜bg_timer 后台定时器｜代码高亮｜深色模式｜reasoningEffort 四档推理强度｜k3b 会话记忆重放｜compactNow 手动压缩｜相机附图｜web_fetch / web_search｜fs 文件三件套｜task 子代理｜模型验证失败详情透出（stream failed 时展示上游错误细节）

### 10.2 端差异

| 能力 | Android | iOS | HarmonyOS |
|---|---|---|---|
| 设备工具覆盖 | 21/21 | **9/21** | **23/23** |
| 消息排队（离线/切换会话时） | — | — | **独有** |
| 数学公式渲染 | 降级 | 降级 | 降级（三端均为降级渲染） |
| JS 引擎 | QuickJS | JavaScriptCore | QuickJS（自编译 NAPI） |
| KMP shared | 引用中 | **已移除** | 不涉及 |

---

## 11. 已解决的重大工程问题

按影响面排序（完整清单见 `.trae/rules/project_rules.md` 陷阱登记）：

1. **WebSocket 主链路整体废弃**：从"PC 内核 + 网络中继"迁移到"端内 JS 引擎直跑"，删除 KernelManager/子进程/端口管理等全部中间层，冷启动与稳定性大幅改善。
2. **QuickJS 兼容性门禁**：构建期 acorn AST 扫描（check-quickjs-compat.mjs），把"运行期才发现语法不支持"的噩梦前移为构建失败。
3. **SSE 流式在 QuickJS 下的 flush 问题**：patch.mjs 打补丁修正，保证三端流式吐字节奏一致。
4. **kimi/Gemini 401/400 修复**（陷阱 29）：供应商特定的鉴权与参数适配。
5. **stream failed 详情透出**（陷阱 28）：上游错误细节穿透到 UI，不再只有"请求失败"。
6. **桥回调洪峰**：thinking/answer 双层节流（64字/200ms、16字/60ms）保护宿主 UI 线程。
7. **会话冷启动重建**：k3b seed 重放机制，jsonl 事件日志即真相源。

---

## 12. 演进方向

1. **iOS 设备工具补齐**：9/21 → 21/21，对齐 Android（当前最大端差异）。
2. **内核能力补齐阶段 2**：阶段 1 已落地 fs 三件套 / web_fetch / subagent，后续按上游节奏继续跟进（内核上游已迭代至 0.1.1-rc.2 之后）。
3. **数学公式渲染**：三端从降级渲染升级为原生排版。
4. **真机回归清单**：OOXML 实测、Tier B 工具、fs/web_fetch/subagent 三用例、reasoningEffort low 档抽验、max-tokens/NO_ADAPTER/万字思考回归（详见项目记忆 2.7 节）。
5. **shared/ KMP 模块退役评估**：iOS 已纯 Swift 化，Android 侧随功能迁移逐步收缩。

---

## 附录 A：关键文件速查

| 主题 | 路径 |
|---|---|
| 内核入口（插件 compose + API 面） | `tools/harness-transpiler/src/harness-entry.ts` |
| 宿主桥 polyfill | `tools/harness-transpiler/polyfills/host-bridge.js` |
| 设备工具注册 | `tools/harness-transpiler/polyfills/device-bridge.js` |
| 构建链 | `tools/harness-transpiler/build.mjs`（patch/compat-check 同目录） |
| iOS 引擎封装 | `iosApp/Sources/Service/HarnessEngine.swift` |
| Android 引擎封装 | `androidApp/app/src/main/java/.../engine/HarnessEngine.kt` |
| 鸿蒙 NAPI 导出 | `harmonyApp/entry/src/main/cpp/napi_init.cpp` |
| 鸿蒙设备工具（最全参考实现） | `harmonyApp/entry/src/main/ets/service/DeviceBridge.ets` |
| 子模块管理脚本 | `kernel.ps1` / `kernel.sh` |
| 项目记忆（AI 开工依据） | `.trae/rules/project_rules.md` |
| 用户指令逐字存档 | `doc/prompt.md` |

## 附录 B：AI 复现指南

若需从零复现本项目，按以下顺序：

1. **先读项目记忆** `.trae/rules/project_rules.md`（含全部陷阱登记与未验证项），再读本文件。
2. **搭内核链**：clone 内核子模块 → 跑 harness-transpiler 三段式构建 → 校验三端 SHA256 一致。
3. **实现桥**：任选一端起步（推荐 HarmonyOS，桥能力最全可作参考实现），实现 §5.1 的 8 个上行符号 + `__harnessCall` 驱动 + fetch/device 下行回调，跑通 `init → setProviderProfile → createSession → chat` 最小闭环。
4. **接门面**：实现 LocalEngine 的 11 个方法（§6.1 表），对接 UI 状态。
5. **铺能力**：DeviceBridge（对照鸿蒙 23 case）、ScriptSandbox（`__sb*` 十符号 + prelude.js）、SessionStore（sessions.json + jsonl）。
6. **过门禁**：本端构建 + CI 三端全绿 + 三端 harness.js SHA256 复核。
