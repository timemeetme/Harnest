# Harnest 项目 Prompt 汇总与进展报告

> 本文档汇总当前会话期间用户输入的所有 prompt，以及 Harnest 项目的最新进展。
> 生成时间：2026-08-26（Asia/Taipei）

---

## 一、用户 Prompt 汇总

### 会话：OOXML 沙箱扩展（当前会话）

| # | Prompt | 意图 |
|---|--------|------|
| 1 | 继续 | 驱动 q2 任务：编写 `tools/sandbox-prelude/prelude.js` |
| 2 | 继续 | 同上，继续推进 |
| 3 | Continue | 语言切换，语义相同：继续推进 q2 |
| 4 | Continue | 继续推进 q2 |
| 5 | Continue | 继续推进 q2 |
| 6 | Continue | 继续推进 q2 |
| 7 | Continue | 继续推进 q2 |
| 8 | Continue | 继续推进 q2 |
| 9 | Continue | 继续推进 q2 |
| 10 | 把历史上我输入的所有 prompt 汇总到一个文档，并且把当前项目进展汇总附在文后，输出到 doc/prompt.md | 生成本文档 |

### 继承会话：Tier B 实施批次（2026-08-25）

该批次在更早的会话中完成，用户 prompt 包括（按项目记忆还原）：

| # | Prompt（摘要） | 意图 |
|---|----------------|------|
| 1 | 继续研究内核 UI 源码与文档 | 第二轮内核 UI 研究：确立「源码有 ≠ bundle 有」方法论 |
| 2 | 按 Tier B 清单实施 | 落地 Tier A+B 全量：run_script 沙箱、getUsageStats、鸿蒙数学公式等 |
| 3 | 提交并推送 | 四批提交（feat(kernel)/feat(ios)/feat(android)/feat(harmony)）推送 origin/main |
| 4 | 继续 | 驱动各阶段任务推进 |
| 5 | 修复鸿蒙 4 处 ArkTS 编译错误 | ChatView 引用 UiState 不存在字段修复 |
| 6 | 装机验证 | hdc install + aa start 真机验证 |

### 继承会话：三端 UI 补齐批次（2026-08-25）

| # | Prompt（摘要） | 意图 |
|---|----------------|------|
| 1 | 以内核官方 UI 为基准盘点三端差距 | 9 项 UI 补齐（工具耗时、busyHint、MCP 图片、日志查看器等） |
| 2 | 提交并推送 | 15 文件 +1214/-62 推送 origin/main |
| 3 | 继续 | 驱动各阶段任务推进 |

### 继承会话：真机崩溃修复（2026-08-25）

| # | Prompt（摘要） | 意图 |
|---|----------------|------|
| 1 | 用户报 iOS 真机"卡死"，Xcode 显示 EXC_BREAKPOINT | 定位 DeviceBridge.topVC 主线程自派发崩溃并修复 |
| 2 | 验证修复 | 模拟器 build + XCTest 14/14 + 真机构建验证 |

### 继承会话：maxTokens 用户配置（2026-08-24）

| # | Prompt（摘要） | 意图 |
|---|----------------|------|
| 1 | 打通 provider 级 maxTokens 用户配置 | 三端 provider 编辑页新增「最大输出 Tokens」输入框 |
| 2 | 验证 | Android 编译 + 三端分发 SHA256 一致 |

### 继承会话：max-tokens 截断修复（2026-08-24）

| # | Prompt（摘要） | 意图 |
|---|----------------|------|
| 1 | 修复鸿蒙"0步 8000字思考→模型未返回内容" bug | max-tokens 截断三症状链修复 |
| 2 | CI 验证 | 三端复绿 |

### 继承会话：Xcode 27 beta 适配（2026-08-24）

| # | Prompt（摘要） | 意图 |
|---|----------------|------|
| 1 | 清零 Xcode 27 beta Swift 6 并发诊断告警 | 31+ 处 noasync/@Sendable/MainActor 修复 |
| 2 | 清零真机构建 API 弃用警告 | 部署目标提升 17.0 + onChange/EKEventStore/UIScreen.main 修复 |

### 继承会话：NSNull 崩溃 + 万字思考修复（2026-08-25）

| # | Prompt（摘要） | 意图 |
|---|----------------|------|
| 1 | 修复 NSJSONSerialization 顶层 NSNull 崩溃 | 内核 undefined 化 + iOS NSNull 守卫 |
| 2 | 修复万字思考卡死 | 内核 emit 阈值调整 + iOS 150ms 节流 + flush 补偿 |

### 继承会话：CI 修复史（2026-08-22）

| # | Prompt（摘要） | 意图 |
|---|----------------|------|
| 1-8 | 逐轮修复 CI（Android/Harmony/iOS） | 8 轮迭代至三端全绿 |

---

## 二、当前项目进展汇总

### 2.1 仓库状态

- **仓库**: `git@github.com:timemeetme/Harnest.git`，主分支 `main`
- **当前 HEAD**: `bac427b6d8`（Tier B 批次推送后）
- **工作区**: 有未提交改动（OOXML 沙箱扩展批次进行中）
- **CI 状态**: 三端全绿（Build iOS 7m24s / Build Android 3m53s / Build HarmonyOS 2m59s，截至 87b4a506d4）

### 2.2 架构总览

```
kernel/deepseek-harness (git 子模块)
        │  kernel.sh / kernel.ps1 同步（pnpm@11，端口 3080，profile=mobile）
        ▼
tools/harness-transpiler (TS 转译器，pnpm)
        │  build.mjs → patch.mjs → check-quickjs-compat.mjs
        ▼
各端打包 harness.js：
  iosApp/Resources/harness.js
  androidApp/app/src/main/assets/harness.js
  harmonyApp/entry/src/main/resources/rawfile/harness.js
```

**端侧**：
- `iosApp/` — SwiftUI App；JavaScriptCore 桥接执行（`HarnessEngine.swift`）
- `androidApp/` — Kotlin Compose；QuickJS 沙箱（`ScriptSandbox.kt`）
- `harmonyApp/` — ArkTS + C++ QuickJS（`ScriptEngine.cpp`），hvigor 构建
- `shared/` — KMP 共享模块，iOS 产物为 XCFramework

### 2.3 已完成里程碑

#### Tier B 批次（2026-08-25，已推送 origin/main）

| 功能 | 说明 | 状态 |
|------|------|------|
| run_script 沙箱 | 模型自写 JS 经 `__deviceCall('runScript')` 交宿主独立沙箱执行 | ✅ 三端全绿 |
| getUsageStats | TokenMeter 水位条数据接口 | ✅ 三端全绿 |
| /plan 斜杠拦截 | 输入框预拦截 /plan 命令 | ✅ 三端全绿 |
| 提问卡分页 | 3 题/页分页（末页才提交） | ✅ 三端全绿 |
| 鸿蒙数学公式 | 三规则渲染（对齐 iOS） | ✅ 三端全绿 |

#### 三端 UI 补齐 9 项（2026-08-25，已推送 origin/main）

| 功能 | 说明 | 状态 |
|------|------|------|
| 工具耗时 ⏱ | 宿主侧计时（tool-start/tool-end 差值） | ✅ 三端 |
| busyHint 十处阶段文案 | 含字数+回合耗时跳动器 | ✅ 三端 |
| MCP base64 图片 | McpImageView 等价 | ✅ 三端 |
| 运行日志查看器 | setLogLineListener 镜像 300 行环形缓冲 | ✅ 三端 |
| 代码块语法高亮 | | ✅ 三端 |
| 网络图片三态 | 加载中/成功/失败 | ✅ 三端 |
| 长按编辑重发 | 对话框预填原文 → 标准发送链路 | ✅ 三端 |
| 会话导出 | Markdown 组装 + ShareLink/ACTION_SEND/DocumentViewPicker | ✅ 三端 |
| 重启引擎 ⟳ | busy 防重入 + NO_ADAPTER 防护 | ✅ Android |

#### 真机崩溃修复（2026-08-25，已推送 origin/main）

| 问题 | 根因 | 修复 |
|------|------|------|
| iOS 真机 EXC_BREAKPOINT | DeviceBridge.topVC 主线程自派发 | Thread.isMainThread 守卫 |

#### maxTokens 用户配置（2026-08-24，已推送 origin/main）

| 功能 | 说明 | 状态 |
|------|------|------|
| provider 级 maxTokens | 三端 provider 编辑页输入框 | ✅ 三端 |
| 决定链 | 模型级 > provider 级用户配置 > reasoner 硬编码 > 兜底 8192 | ✅ |

#### 三端 UI 功能一致性矩阵（2026-08-25，26 项全对齐）

思考分段三级折叠、回复折叠、节流、代码块复制、错误重试、会话重命名、提问卡跳过、清空消息、token 用量、重新生成、回到底部、工具卡展开、steer+subagent 渲染、评分、fork、停止、排队转向、后台任务卡、会话管理、Provider+maxTokens、导入导出、详情页、深色、Markdown 全集。

### 2.4 当前进行中：OOXML 沙箱扩展批次

**目标**：让 run_script 沙箱能真读写 .docx/.xlsx/.pptx 文件。

**三步路径**：
1. 沙箱加 `readBytes/writeBytes` 走 base64 字符串过桥
2. 沙箱 runtime 预置纯 JS zip 库 + 最小化 OOXML 写器（`tools/sandbox-prelude/prelude.js`）
3. 文件进出：pick 导入 + 分享导出

**进度**：

| 任务 | 状态 | 说明 |
|------|------|------|
| q1 前置核实 | ✅ | 三端 pick 落点 + 沙箱根目录约定确认 |
| q2 prelude.js | ✅ | `tools/sandbox-prelude/prelude.js`（base64/UTF-8/CRC32/zipPack/zipUnpack+inflate/makeXlsx/makeDocx/makePptx/readXlsx/readDocxText/readBytes/writeBytes） |
| q3 测试门禁 | ✅ | node 往返/CRC向量/中文名/大文件 + PowerShell Expand-Archive + [xml] 良构 + Compress-Archive 回读 inflate 全部通过 |
| q4 内核 entry | ✅ | run_script 描述更新（新能力清单）+ 结果 schema 加 files 数组 + 重打包分发三端（SHA256 68FEA9B1…） |
| q5 iOS 接线 | 🔄 子代理完成 | prelude 资源加载 + b64 桥 + writtenFiles 追踪 + pick 落点修正（Documents/Scripts/picked） |
| q6 Android 接线 | 🔄 子代理结果丢失 | 需重发或手动核实 |
| q7 鸿蒙接线 | 🔄 子代理结果丢失 | 需重发或手动核实 |
| q8 本地门禁+提交 | ⬜ | Android compile + 鸿蒙 hvigorw + 分批提交推送 + CI 验证 |
| q9 记忆更新 | ⬜ | 记忆维护独立 docs(memory) 提交 |

**prelude.js 已验证能力**：

| 模块 | 功能 | 验证结果 |
|------|------|----------|
| base64 | 编解码 | ✅ 往返一致 |
| UTF-8 | 编解码（含中文+emoji） | ✅ 往返一致 |
| CRC32 | 标准查表法 | ✅ 向量 '123456789' → 0xCBF43926 |
| zipPack | STORE 模式打包 | ✅ PowerShell Expand-Archive 可读 |
| zipUnpack | 解包 + inflate | ✅ PS Compress-Archive deflate 回读成功 |
| inflate | 固定/动态 Huffman | ✅ 1MB 17ms |
| makeXlsx | 多 sheet + sharedStrings | ✅ [xml] 良构 + 数据正确 |
| makeDocx | 段落 + bold/italic/heading | ✅ [xml] 良构 |
| makePptx | 多 slide + title/bullets | ✅ [xml] 良构 |
| readXlsx | zipUnpack + XML 提取 | ✅ 数据还原正确 |
| readDocxText | zipUnpack + 段落提取 | ✅ 文本还原正确 |

**三端桥名约定**（已核实完全一致）：

```
__sbLog(line)              → 累计 stdout（64KB 环形）
__sbFetch(url, initJson)   → fetchId（异步）
__sbFetchDone(id, ok, ...) → 回投
__sbRead(path)             → "{ok,data}" JSON 字符串
__sbWrite(path, content)   → "{ok}" JSON 字符串
__sbSettle(json)           → 结算信号量
__sbSettleErr(msg)         → 结算错误
__sbReadB64(path)          → "{ok,dataBase64}" （新增）
__sbWriteB64(path, b64)    → "{ok}" （新增）
```

**iOS/Android 走 JSON envelope；鸿蒙 C++ 直接 JS_ThrowTypeError**（prelude 已容错两种语义）。

### 2.5 已验证命令速查

**Windows 机**：

```powershell
# Android 编译验证
cd androidApp; .\gradlew.bat :app:compileDebugKotlin --offline

# 鸿蒙构建 + 装机
cd harmonyApp; .\hvigorw.bat --mode module -p module=entry@default assembleHap --no-daemon
& "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" -t 6HR0226328004267 install -r .\entry\build\default\outputs\default\entry-default-signed.hap

# transpiler 打包 + 三端分发
cd tools\harness-transpiler; node build.mjs; node patch.mjs; node check-quickjs-compat.mjs
Copy-Item output\harness.js ..\..\iosApp\Resources\harness.js -Force
Copy-Item output\harness.js ..\..\androidApp\app\src\main\assets\harness.js -Force
Copy-Item output\harness.js ..\..\harmonyApp\entry\src\main\resources\rawfile\harness.js -Force

# CI 状态查询
gh run list --limit 3
```

**macOS 机**：

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home

# KMP 共享模块
sh ./gradlew :shared:assembleSharedReleaseXCFramework --no-daemon
sh ./gradlew :shared:iosSimulatorArm64Test --no-daemon

# iOS
cd iosApp && xcodegen generate
xcodebuild build -project Harnest.xcodeproj -scheme Harnest -destination 'platform=iOS Simulator,name=iPhone 17e'
xcodebuild test -project Harnest.xcodeproj -scheme Harnest -destination 'platform=iOS Simulator,name=iPhone 17e'
```

### 2.6 已知陷阱（24 条，详见项目记忆）

关键陷阱摘要：

1. **gradlew 无执行位** → macOS 用 `sh ./gradlew`
2. **Swift 值语义移植陷阱** → Kotlin JSONObject 可变引用 vs Swift 字典值类型
3. **引擎懒启动** → App 冷启动无引擎日志正常
4. **xcodeproj 是生成物** → 改 project.yml 再 xcodegen
5. **JSONSerialization 顶层标量** → 必须加 `.fragmentsAllowed`
6. **裸 boot listProviders 返回空** → 必须先 init 注入 provider 档案
7. **NO_ADAPTER** → 挂载前校验 apiKey 为空则回落默认
8. **Xcode 27 beta Swift 6 并发诊断** → 31+ 处 noasync/@Sendable/MainActor 修复
9. **Xcode 27 beta API 弃用** → 部署目标提升 17.0 后消除
10. **NSJSONSerialization 顶层 NSNull 崩溃** → try? 接不住 ObjC 异常，必须 isValidJSONObject 前置
11. **节流相位锁死** → 宿主窗口必须严格小于内核心跳
12. **Harmony CI 不拦截 ArkTS 编译错误** → 推送前必须本地 hvigorw 构建
13. **会话中断丢修改** → 恢复后必须 git diff 逐条核对
14. **max-tokens 截断三症状链** → finish_reason:"length" → reason={kind:'max-tokens'}
15. **主线程 DispatchQueue.main.sync 自派发 = 必崩** → Thread.isMainThread 守卫
16. **内核 tool-end 事件不携带 durationMs** → 宿主侧计时
17. **官方 UI 能力"源码有 ≠ bundle 有"** → 复刻前必须实测打包产物
18. **ArkTS .so 默认导入 = any** → 必须收口到 HarnessNative 类型化包装
19. **@ohos.net.http 正确字段名** → RequestMethod / extraData

### 2.7 待验证项

- kernel.sh/kernel.ps1 内核子模块管理命令
- 真机回归 NO_ADAPTER 修复
- 真机回归 max-tokens 修复
- 真机验证 maxTokens 用户配置生效
- 真机回归万字思考
- Tier B 真机实测（run_script 沙箱 fetch/readText/writeText/log 链路与超时熔断；水位条；/plan 斜杠拦截；提问卡分页；数学公式渲染）
- OOXML 批次真机实测（readBytes/writeBytes + makeXlsx/makeDocx/makePptx + 文件分享）

---

*本文档由 TRAE 自动生成，随项目进展更新。*
