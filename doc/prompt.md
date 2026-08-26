# Harnest 项目 Prompt 汇总与进展报告

> 本文档汇总 Harnest 项目全部开发会话的用户 prompt（按批次还原），以及项目最新进展。
>
> **数据源说明**：TRAE 的完整对话记录存储在 `AppData/Roaming/TRAE SOLO CN/ModularData/ai-agent/database.db`（872MB，整库加密，非标准 SQLite，无 v10 前缀），无法在应用外离线解密提取逐字 prompt。本文档历史部分以 **git 提交历史（63 笔）+ 项目记忆（`.trae/rules/project_rules.md` 维护日志）** 为权威源按批次还原；**自批次 18 起改为逐字记录**（维护协议第 6 条：每会话结束前把用户输入逐条原文追加到本文档）。
>
> 生成时间：2026-08-26（Asia/Taipei），仓库 HEAD：`f6e2cc3536`

---

## 一、用户 Prompt 汇总（按会话批次）

### 图例

- **W** = Windows 机会话，**M** = macOS 机会话
- prompt 原文可考据的给出原文；不可逐字还原的给出意图摘要（标注「意图」）

### 1. 项目奠基批次（2026-08-16 至 2026-08-18，W）

| # | Prompt（意图） | 产出提交 |
|---|---------------|----------|
| 1 | 初始化 Harnest 项目：KMP 三端 + deepseek-harness 内核 + GitHub Actions CI | `7a945a96a8` feat: initial Harnest |
| 2 | 修复 Android ProGuard Ktor 警告 | `3821d050fa` fix(android) |
| 3 | CI 加 QuickJS 兼容门禁 + 内核稳定 tag 同步机制 | `2ba02e7a75` feat(ci) |
| 4 | KMP 重构（com.harnest 包名）+ 跨端 provider 对齐 | `e8cfc9c20e` feat(mobile) |
| 5 | 鸿蒙落地内嵌 QuickJS 引擎 + 本地内核架构 | `0708d84202` feat(harmony) |

### 2. 三端 UI 对齐批次（2026-08-22 凌晨，W）

| # | Prompt（意图） | 产出提交 |
|---|---------------|----------|
| 1 | 三端 UI 对齐：Markdown 表格 GFM 布局、滚动到底、Plan 图标区分 | `034d5a2700` feat(mobile) |

### 3. CI 修复 8 轮迭代（2026-08-22，W）

| # | Prompt（意图） | 产出提交 |
|---|---------------|----------|
| 1 | 修复三条 CI workflow 失败（任务路径、artifact 路径） | `43e287c809` ci: fix three workflow failures |
| 2 | Harmony CI Node 20→22（pnpm 11 要求） | `19a355b613` ci(harmony) |
| 3 | 追踪 capability-manual.ts（transpiler 构建源，被 .gitignore 误伤） | `418e7dfdbb` ci(harmony) |
| 4 | 修复 KMP commonMain iOS 目标 13 处 Kotlin 编译错误 | `04b05eb1ed` fix(shared) |
| 5 | 修复 xcodeproj 工程名不匹配（Harnest.xcodeproj）与 artifact 路径 | `b622b1b5d0` ci(ios) |
| 6 | 修复 31 处 Swift 首次真实编译错误（PHPicker/EventKit/JSContext 可选等 8 类） | `544cb0a4b9` fix(ios) |
| 7 | 三端 NO_ADAPTER 修复：会话 provider apiKey 清空后回落默认 | `393558f465` fix(all) |
| 8 | iOS 侧 Swift 值语义移植 bug：ConfigService 缓存不回写 | `c5d5d82e71` fix(ios) |
| 9 | 补 iOS XCTest 套件（EngineBridge 6 + LocalEngineFlow 4 + ProvidersCatalog 4） | `6ae91064a3` test(ios) |

**结果**：CI 三端全绿（Build iOS 11m16s 首绿），产出 .app + XCFramework。

### 4. 项目记忆建立（2026-08-23，M → W 融合）

| # | Prompt（意图） | 产出提交 |
|---|---------------|----------|
| 1 | 生成项目记忆文件（架构、已验证命令、陷阱、验证状态） | `7500cc0924` docs: add TRAE project memory |
| 2 | Windows 端融合：CI 修复史、陷阱 9-13、双机环境事实 | `f2b48c5489` docs(memory): merge Windows-side knowledge |
| 3 | 会话内进展自动同步 GitHub（维护协议第 3 条） | `c36c6626f2` docs(memory): session-scoped auto-sync protocol |
| 4 | 开工前先 pull 记忆文件（协议第 1 条，pull→干活→push 闭环） | `e30bb6be73` docs(memory): protocol applies to both machines |

### 5. max-tokens 截断修复（2026-08-24 下午，W）

| # | Prompt（意图） | 产出提交 |
|---|---------------|----------|
| 1 | 修复鸿蒙「0步 8000字思考 → 模型未返回内容」bug | `73efc45193` fix(all): max-tokens 截断误报 — reasoner 预算放开 + 三端兜底文案 |
| 2 | 沉淀记忆（陷阱 14 三症状链 + transpiler 打包命令段） | `b39a7c7f83`、`b81b512af9` docs(memory) |

**根因链**：DeepSeek 深度思考计入 max_tokens 输出额度 → 思考中途耗尽 → `finish_reason:"length"` → 内核 `reason={kind:'max-tokens'}` 无 error 字段 → 三端宿主落默认文案。修复：内核 chat() 补文案 + reasoner 模型级 maxTokens=65536 + 三端兜底。

### 6. maxTokens 用户配置批次（2026-08-24 傍晚，W）

| # | Prompt（意图） | 产出提交 |
|---|---------------|----------|
| 1 | 打通 provider 级 maxTokens 用户配置（三端设置页输入框 + 内核透传） | `8c78bd6e89` feat(all) |
| 2 | 沉淀记忆（决定链：模型级 > provider 用户配置 > reasoner 硬编码 > 兜底 8192） | `1daa3321e5` docs(memory) |

27 处改动全部串行编辑零丢失（陷阱 13 变体防护生效）。

### 7. Mac 拉取复验 + Xcode 27 适配（2026-08-24 深夜，M）

| # | Prompt（意图） | 产出提交 |
|---|---------------|----------|
| 1 | Mac 拉取复验 8c78bd6e89（双机记忆 rebase 冲突合并 + Debug/Release/XCTest 14/14） | `620dbd825d`、`a2eac9635e` docs |
| 2 | 清零 Xcode 27 beta Swift 6 并发诊断告警（31 issue：noasync 锁/@Sendable 捕获/MainActor 隔离/unused 结果） | `2922a9650a` fix(ios) |
| 3 | 沉淀陷阱 15 + DEVELOPER_DIR 环境命令 | `87310a7913` docs(memory) |
| 4 | 清零 Xcode 27 真机构建 12 处 API 弃用警告（部署目标提升 17.0 + onChange/EKEventStore/UIScreen.main 修复） | `23130e84fa` fix(ios) |
| 5 | 沉淀陷阱 16 + 部署目标 17.0 + 真机连接事实 | `d3b0d6bdf0` docs(memory) |

**环境变更**：Mac 升级 macOS 27 + Xcode-beta.app 27A5237l 成为唯一 Xcode；真机 MyPhone（iPhone 17 Pro / iOS 27 beta）已连接。

### 8. 模型选择器 + 思考展示批次（2026-08-25 凌晨，M）

| # | Prompt（意图） | 产出提交 |
|---|---------------|----------|
| 1 | 设置页新增「从文件导入配置」入口 | `4320053ab0` feat(ios) |
| 2 | 模型选择即生效 + 三端思考模式命名对齐 | `1050f942a2` fix(all) |
| 3 | 模型选择器改为模型/思考模式并列 Tab | `4f87ae0b34` fix(all) |
| 4 | 思考内容实时展示不截断 | `21dcf40117` fix(all) |
| 5 | iOS 思考面板可滚动 + 自动滚到底 | `99d3de5b5a` fix(ios) |
| 6 | Android/Harmony 思考面板可滚动不截断 | `6c51ee2f3b` fix(all) |

### 9. NSNull 崩溃 + 万字思考修复（2026-08-25 凌晨，M）

| # | Prompt（意图） | 产出提交 |
|---|---------------|----------|
| 1 | 修复 NSJSONSerialization 顶层 NSNull 崩溃（用户报文逐字复现）+ 万字思考卡死 | `f36ae0b4e2` fix(all) |
| 2 | 沉淀陷阱 17/18 + 模拟器 OS 26.5 环境变更 | `34b567a2ad` docs(memory) |

**双修复**：①内核 extractDetails undefined 化剥离 null 字段 + iOS encodeString NSNull 守卫/isValidJSONObject 前置（`try?` 接不住 ObjC 异常已实证）；②内核 emit 阈值 16字/60ms→64字/200ms + iOS 150ms 节流/flushPendingThink 收尾补偿 + 渲染尾部 4000 字封顶。

### 10. 鸿蒙本地构建 + 真机装机（2026-08-25 凌晨，W）

| # | Prompt（意图） | 产出提交 |
|---|---------------|----------|
| 1 | Windows 本地鸿蒙构建 + 真机装机验证 | `214532ffd3` fix(harmony): 修复引用不存在的 state.currentSession（4 处 ArkTS ERROR，CI best-effort 没拦） |
| 2 | 沉淀陷阱 19（Harmony CI 不拦截 ArkTS 编译错误）+ 装机命令段 | `3710fe738f` docs(memory) |

**验证**：hvigorw BUILD SUCCESSFUL + 本地调试证书 SignHap + hdc install -r + aa start，真机 6HR0226328004267 进程存活。

### 11. 三连提交：分段折叠 + 节流统一 + UI 批次 1-3（2026-08-25 凌晨，M）

| # | Prompt（意图） | 产出提交 |
|---|---------------|----------|
| 1 | 思考/回复按 (turn,step) 分段三级折叠（概览/分段/全文，对标 trae/workbuddy） | `1fbdcfdba7` feat(all) |
| 2 | 三端统一 150ms 节流修复万字内容实时渲染卡顿 | `b3f694e194` fix(all) |
| 3 | 三端 UI 功能补齐批次 1-3 + 一致性终检（26 项全对齐） | `f2e4d6d905` feat(all) |
| 4 | 沉淀记忆（CI 三端全绿确认） | `971536b223`、`825aba6692` docs(memory) |

**补齐项**：代码块复制/错误重试/会话重命名/提问卡跳过/清空消息/token 用量/重新生成/回到底部悬浮按钮/工具卡展开/steer 展开行/subagent 专属行。

### 12. 真机崩溃修复（2026-08-25 早晨，M）

| # | Prompt（原文可考） | 产出提交 |
|---|-------------------|----------|
| 1 | 用户报 iOS 真机「卡死」，Xcode 显示 `Thread 1: EXC_BREAKPOINT (code=1)`，贴崩溃帧 + os_log Harness/event 日志（turn5 step6 调 device_files op=pick） | `432d631469` fix(ios): DeviceBridge.topVC 主线程 main.sync 自派发崩溃 |
| 2 | 沉淀陷阱 20 + 日志获取备查 | `2f70452b49` docs(memory) |

**根因**：`main.async` 闭包内再调无条件 `main.sync` 的 topVC() → libdispatch 自派发 assert 必崩。camera/photos/files pick 三条工具路径自上线即带雷。修复：提取 compute() + Thread.isMainThread 守卫（对齐 Android Handler.runBlocking 首行同线程守卫）。

### 13. 三端 UI 补齐 9 项（2026-08-25 上午，W）

| # | Prompt（意图） | 产出提交 |
|---|---------------|----------|
| 1 | 以内核官方 UI 为基准盘点三端差距，按推荐方案 9 项全补 | `846cd43200` feat(harmony 8 项)、`a02a105d09` feat(ios 4 项)、`c05ac2d9aa` feat(android 3 项) |
| 2 | 沉淀记忆 + 陷阱 21 | `209f2d7e5f`、`78e8cb7526` docs(memory) |

**鸿蒙 8 项**：工具耗时⏱ 宿主侧计时 / busyHint 十处阶段文案+字数+回合耗时跳动器 / MCP base64 图片 / 运行日志查看器 300 行环形缓冲 / 代码块语法高亮 / 网络图片三态 / 长按编辑重发 / DocumentViewPicker 存 .md。
**iOS 4 项**：traceJson "d" 字段+fmtToolDuration / busySec .task 计时 / ResendSheet contextMenu / ShareLink exportMarkdown。
**Android 3 项**：重启引擎⟳ busy 防重入+NO_ADAPTER 防护 / combinedClickable 长按对话框 / ACTION_SEND。

三个并行子代理实施（三端文件互不相交），主线程逐文件 diff 复核。

### 14. 第二轮内核 UI 研究（2026-08-25 上午，W，纯研究）

| # | Prompt（原文可考） | 产出提交 |
|---|-------------------|----------|
| 1 | 「继续研究内核 UI 源码与文档」 | `fb3ebf355d` docs(memory): 源码≠bundle 方法论（陷阱 22）+ 差距分级清单（陷阱 23） |

**决定性结论**：官方六大 React 组件包与文档能力多数不在 mobile harness.js bundle（approval/goals/skills/schedule/web-search/spill/attachment/diff-read-search-terminal 专属卡全无生产者）；真在的 = /plan 命令已注册 + TokenMeter 服务在（entry 未暴露）。产出 Tier A/B/C 分级清单。

### 15. Tier B 实施批次（2026-08-25 下午，W）

| # | Prompt（意图） | 产出提交 |
|---|---------------|----------|
| 1 | 按 Tier B 清单落地 Tier A+B 全量 | `b08b09c571` docs(memory)（沉淀）→ `364bc5b96b` feat(kernel)、`ce0e24b3e0` feat(ios)、`986a999d21` feat(android)、`87b4a506d4` feat(harmony) |
| 2 | 提交推送 + CI 验证 | `8ea2efa467`、`bac427b6d8` docs(memory) |

**内容**：内核 entry 注册 `run_script` 沙箱工具（fetch/readText/writeText/log 四 API + 超时熔断 1-120s）+ `getUsageStats()`；鸿蒙 6 项（数学公式三规则/提问卡分页+图标/ScriptEngine.cpp per-instance QuickJS/d.ts+DeviceBridge/AppViewModel 编排/token 水位条/斜杠提示）；Android 全量镜像（ScriptSandbox.kt + 水位条 + /plan + 分页）；iOS ScriptSandbox.swift 379 行（JSC 专用串行队列 + 微任务泵 + 超时释放）。

**CI 三端全绿**：Build iOS 7m24s（ScriptSandbox.swift 首次真实编译通过）/ HarmonyOS 2m59s / Android 3m53s。

### 16. Tier B 深度 Review + resolvePath 修复（2026-08-26 凌晨，M）

| # | Prompt（意图） | 产出提交 |
|---|---------------|----------|
| 1 | Tier B 批次深度 Review + iOS 沙箱 resolvePath 绝对路径解析 Bug 修复 | `53315ce2e0` fix(ios)、`369725b236` docs(memory) |

### 17. OOXML 沙箱扩展批次（2026-08-26 上午，W）

| # | Prompt（原文可考） | 产出提交 |
|---|-------------------|----------|
| 1 | 「继续」/「Continue」×N（驱动 q1-q9 全链路：prelude.js 编写 → 测试门禁 → 内核 entry → 三端接线 → 本地门禁 → 提交） | `c6ceeca620` feat(kernel)、`4afd7ad992` feat(all)、`68588cd043` feat(ios)、`c15f7c2c7b` feat(android)、`e07ab8ec2b` feat(harmony) |
| 2 | 「把历史上我输入的所有promt汇总到一个文档，并且把当前项目进展汇总附在文后，输出到doc/prompt.md」 | `06eb5c0982` docs: prompt history summary |
| 3 | （中断期并行会话）鸿蒙调用链断点补齐 + iOS Result 泛型修复 | `8bec92e86d` docs(memory)、`c9f453c744` fix(ios) |

**OOXML 内容**：`tools/sandbox-prelude/prelude.js` 482 行纯 JS（base64/UTF-8/CRC32/zipPack STORE/zipUnpack+inflate/makeXlsx/makeDocx/makePptx/readXlsx/readDocxText/readBytes/writeBytes）；三端 `__sbReadB64/__sbWriteB64` 桥；pick 落点统一沙箱根 picked/；内核 entry 描述 + files schema。

**验证**：node 往返 + PowerShell Expand-Archive/[xml] 良构/Compress-Archive deflate 回读 + 1MB inflate 17ms + Android/鸿蒙本地门禁 + CI 三端全绿（iOS 首轮 Result<Void,String> 失败后修复复跑）。

### 18. prompt.md 补全批次（2026-08-26 下午，W）

| # | Prompt（逐字原文） | 产出提交 |
|---|-------------------|----------|
| 1 | 「"D:\Projects\HarnessApp\doc\prompt.md" 文件不完整，我可以在trae的应用里看到所有对话记录，但是这个文档里太少了，只有最近几次对话的promt」 | `57bff75aa4` docs: rewrite prompt history |
| 2 | 「好的，以后每个会话结束都默认把输入逐条追加到文档里」 | 本次（协议第 6 条入库 + 本批次记录） |

---

## 二、当前项目进展汇总

### 2.1 仓库状态

- **仓库**：`git@github.com:timemeetme/Harnest.git`，主分支 `main`
- **当前 HEAD**：`f6e2cc3536`（2026-08-26，记忆收尾）
- **CI 状态**：三端全绿（HarmonyOS 2m35s / Android 3m32s / iOS 复跑通过，c9f453c744 触发）
- **双机开发**：Mac（SSH heavencme 协作者）+ Windows（https + gh CLI，需手动挂系统代理 127.0.0.1:7890）

### 2.2 架构总览

```
kernel/deepseek-harness (git 子模块，上游 deepseek-ai/deepseek-harness)
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
- `iosApp/` — SwiftUI；JavaScriptCore 桥接（`HarnessEngine.swift`）；XcodeGen 工程生成
- `androidApp/` — Kotlin Compose；QuickJS 沙箱（`ScriptSandbox.kt`）
- `harmonyApp/` — ArkTS + C++ QuickJS（`ScriptEngine.cpp`），hvigor 构建
- `shared/` — KMP 共享模块，iOS 产物为 XCFramework（CI 对齐产物）

### 2.3 里程碑一览（63 笔提交）

| 日期 | 里程碑 | 关键提交 |
|------|--------|----------|
| 08-16~18 | 项目奠基：KMP 三端 + 内核 + CI + 鸿蒙 QuickJS | `7a945a96a8` 等 5 笔 |
| 08-22 | CI 8 轮修复 → 三端全绿 + XCTest 14/14 | `43e287c809`…`6ae91064a3` |
| 08-23 | 项目记忆建立 + 双机同步协议 | `7500cc0924` 等 4 笔 |
| 08-24 | max-tokens 截断修复 + maxTokens 用户配置 | `73efc45193`、`8c78bd6e89` |
| 08-24 | Xcode 27 beta 适配（Swift 6 并发 + API 弃用） | `2922a9650a`、`23130e84fa` |
| 08-25 | 模型选择器 + 思考展示 + NSNull 崩溃 + 万字思考 | `f36ae0b4e2` 等 7 笔 |
| 08-25 | 鸿蒙本地构建 + 真机装机 | `214532ffd3` |
| 08-25 | 分段折叠 + 150ms 节流 + UI 批次 1-3（26 项对齐） | `1fbdcfdba7`…`f2e4d6d905` |
| 08-25 | 真机崩溃修复（main.sync 自派发） | `432d631469` |
| 08-25 | 三端 UI 补齐 9 项 | `846cd43200` 等 3 笔 |
| 08-25 | 第二轮内核 UI 研究（源码≠bundle 方法论） | `fb3ebf355d` |
| 08-25 | Tier B：run_script 沙箱 + getUsageStats + 鸿蒙 6 项 | `364bc5b96b` 等 4 笔 |
| 08-26 | Tier B Review + resolvePath 修复 | `53315ce2e0` |
| 08-26 | OOXML 沙箱扩展（prelude.js + 三端 b64 桥 + CI 全绿） | `c6ceeca620` 等 7 笔 |

### 2.4 三端功能矩阵（当前状态）

| 功能 | iOS | Android | Harmony |
|------|-----|---------|---------|
| 多 provider 配置 + maxTokens 用户配置 | ✅ | ✅ | ✅ |
| 思考分段三级折叠 / 回复折叠 / 150ms 节流 | ✅ | ✅ | ✅ |
| Markdown 全集（表格 GFM/代码块/数学公式） | ✅ | ✅ | ✅ |
| 工具卡展开 / steer+subagent / 评分 / fork | ✅ | ✅ | ✅ |
| 提问卡（跳过/3 题分页） | ✅ | ✅ | ✅ |
| run_script 沙箱（fetch/readText/writeText/log） | ✅ | ✅ | ✅ |
| OOXML（Prelude.makeXlsx/makeDocx/makePptx + readBytes/writeBytes） | ✅ | ✅ | ✅ |
| token 水位条（getUsageStats） | ✅ | ✅ | ✅ |
| /plan 斜杠拦截 | ✅ | ✅ | ✅ |
| 长按编辑重发 / 会话导出 Markdown | ✅ | ✅ | ✅ |
| 运行日志查看器 / MCP base64 图片 | ✅ | ✅ | ✅ |
| 深色模式 / 导入导出 / 详情页 | ✅ | ✅ | ✅ |

### 2.5 已验证命令速查

**Windows 机**：

```powershell
# Android 编译
cd androidApp; .\gradlew.bat :app:compileDebugKotlin --offline

# 鸿蒙构建 + 装机
cd harmonyApp
$env:DEVECO_SDK_HOME = "C:\Program Files\Huawei\DevEco Studio\sdk"
$env:PATH = "C:\Program Files\Huawei\DevEco Studio\tools\node;" + $env:PATH
.\hvigorw.bat --mode module -p module=entry@default assembleHap --no-daemon
$hdc = "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
& $hdc -t 6HR0226328004267 install -r .\entry\build\default\outputs\default\entry-default-signed.hap

# transpiler 打包 + 三端分发
cd tools\harness-transpiler; node build.mjs; node patch.mjs; node check-quickjs-compat.mjs

# GitHub 访问（需代理）
$env:HTTPS_PROXY="http://127.0.0.1:7890"; git push origin main; gh run list --limit 3
```

**macOS 机**：

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home

sh ./gradlew :shared:assembleSharedReleaseXCFramework --no-daemon
sh ./gradlew :shared:iosSimulatorArm64Test --no-daemon

cd iosApp && xcodegen generate
xcodebuild build -project Harnest.xcodeproj -scheme Harnest -destination 'platform=iOS Simulator,name=iPhone 17e'
xcodebuild test  -project Harnest.xcodeproj -scheme Harnest -destination 'platform=iOS Simulator,name=iPhone 17e'
```

### 2.6 已知陷阱（27 条摘要，详见 `.trae/rules/project_rules.md`）

1. gradlew 无执行位 → macOS 用 `sh ./gradlew`
2. `:shared:allTests` 在 Mac 必失败（无 Android SDK）→ 用 `iosSimulatorArm64Test`
3. Swift 值语义移植陷阱 → Kotlin 可变引用 vs Swift 值类型
4. 引擎懒启动 → App 冷启动无引擎日志正常
5. xcodeproj 是生成物 → 改 project.yml 再 xcodegen
6. JSONSerialization 顶层标量 → 必须 `.fragmentsAllowed`
7. osascript 无辅助功能权限 → UI 验证用 XCTest/XCUITest
8. 裸 boot listProviders 返回空 → 必须先 init 注入 provider 档案
9. NO_ADAPTER → 挂载前校验 apiKey 为空则回落默认
10. Xcode 27 Swift 首次真实编译 8 类错误（PHPicker/EventKit/JSContext 可选等）
11. xcodegen 工程名链 → Harnest.xcodeproj
12. Harmony CI 三坑 → Node 22 / capability-manual.ts / hvigor best-effort
13. 会话中断丢修改 → 恢复后必须 git diff 逐条核对（变体：同文件多处编辑禁止并行）
14. max-tokens 截断三症状链 → reason={kind:'max-tokens'} 无 error 字段
15. Xcode 27 Swift 6 并发诊断四类模式（noasync 锁/@Sendable/MainActor/unused）
16. Xcode 27 API 弃用（部署目标 17.0 后消除）
17. NSJSONSerialization 顶层 NSNull 崩溃 → try? 接不住 ObjC 异常，isValidJSONObject 前置
18. 节流相位锁死 → 宿主窗口必须严格小于内核心跳（150ms < 200ms）
19. Harmony CI 不拦截 ArkTS 编译错误 → 推送前必须本地 hvigorw 构建
20. 主线程 main.sync 自派发 = 必崩 → Thread.isMainThread 守卫
21. 内核 tool-end 无 durationMs + ArkUI 无 stopPropagation → 宿主侧计时 / 空 onClick 消费
22. 官方 UI 能力「源码有 ≠ bundle 有」→ 复刻前必须实测打包产物
23. 三端 UI 差距分级基准 → Tier A/B/C
24. ArkTS .so 默认导入 = any + @ohos.net.http 字段名（RequestMethod/extraData）
25. Windows 机 git/gh 访问 GitHub 需手动挂系统代理（127.0.0.1:7890）
26. 并行会话会在同一仓库自主提交推送 → push 前必先 fetch 双向核对
27. Swift `Result<Success, Failure>` 的 Failure 必须遵 `Error` 协议 → 别用 Result<Void, String>

### 2.7 待验证项

- kernel.sh/kernel.ps1 内核子模块管理命令
- 真机回归 NO_ADAPTER 修复（清空 deepseek key 后重开旧会话）
- 真机回归 max-tokens 修复（deepseek-reasoner 问难题完整出答案）
- 真机验证 maxTokens 用户配置生效（1024 截断 / 65536 完整）
- 真机回归万字思考（分段折叠正常、刷新不卡死、回合结束不崩溃）
- Tier B 真机实测（run_script fetch/readText/writeText/log 链路与超时熔断；水位条分档变色；/plan 斜杠拦截；提问卡分页；数学公式渲染）
- **OOXML 真机实测**（Prelude.makeXlsx/makeDocx/makePptx 生成文件：writeBytes 落盘 + files 字段回传 + readXlsx/readDocxText 回读，三端各验一轮）

---

*本文档以 git 提交历史与项目记忆为权威源生成。如需逐字 prompt 原文，请在 TRAE 应用内查看对话记录（本地数据库整库加密，无法外部提取）。*
