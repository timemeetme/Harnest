# 内核更新指南（deepseek-harness）

本文档说明如何将 `kernel/deepseek-harness`（git submodule）更新到上游最新稳定版本，并保证打包产物 `harness.js` 在 QuickJS（HarmonyOS 本地引擎）环境下的兼容性。

## 架构速览

```
kernel/deepseek-harness (submodule, 上游源码)
        │  esbuild bundle
        ▼
tools/harness-transpiler/output/harness.bundle.js
        │  patch.mjs（QuickJS 补丁 + polyfill 注入）
        ▼
tools/harness-transpiler/output/harness.js
        │  部署（复制）
        ▼
harmonyApp/entry/src/main/resources/rawfile/harness.js（随 HAP 打包）
```

- **polyfill 层**：`tools/harness-transpiler/polyfills/host-bridge.js` + `harness-shims-iife.js`，补齐 QuickJS 缺失的 Web/Node API（fetch 流、AbortSignal、TextEncoder、console 等）。
- **兼容性门禁**：`tools/harness-transpiler/check-quickjs-compat.mjs` 对 bundle 做静态分析，内核新代码引用了 QuickJS + polyfill 环境不存在的全局 API 时以 exit 1 失败。

## 方式一：CI 自动更新（推荐）

Workflow：`.github/workflows/kernel-sync.yml`

- **触发**：每周一 03:00（UTC）定时；或在 GitHub → Actions → Kernel Sync → Run workflow 手动触发。
- **解析策略**：优先取上游**最新稳定 tag**（严格 semver `x.y.z` / `vx.y.z`，自动排除 `-rc`/`-beta` 等预发布）；无稳定 tag 时回退 `master` 分支；也可在手动触发时填 `upstream_ref` 强制指定。
- **流程**：更新 submodule → 重建 harness.js → QuickJS 兼容性门禁 → 通过则创建 PR（`chore(kernel): sync deepseek-harness @ <短哈希>`）。

### 门禁失败时（CI 红色）

CI 会明确报错并上传 artifact `quickjs-compat-report-*`（保留 30 天），内含：

- `missing[]`：缺失 API 清单（名称、bundle 行号、引用次数）
- `howToFix.forAi`：供 AI 工具直接消费的修复指令

**修复流程（AI 工具或人工）**：

1. 下载 artifact，读取 `quickjs-compat-report.json` 的 `missing[]` 与 `howToFix`。
2. 对每个缺失 API，在 `tools/harness-transpiler/polyfills/host-bridge.js` 按现有模式补 polyfill（`if (typeof global.X === 'undefined') global.X = ...`）。
3. 本地复现直到门禁通过：
   ```powershell
   pnpm --dir tools/harness-transpiler run build
   pnpm --dir tools/harness-transpiler run patch
   pnpm --dir tools/harness-transpiler run check:quickjs   # exit 0 为通过
   ```
4. 提交修复，重新触发 Kernel Sync workflow。

若某 API 确认安全（仅 `typeof` 守卫内引用、或 QuickJS 内置但清单遗漏），可加入 `tools/harness-transpiler/quickjs-compat-allowlist.json` 并注明理由。**禁止预防性添加**——真缺失就该报错。

## 方式二：本地手动更新

```powershell
# 1. 拉取上游（也可用 kernel.ps1 upgrade）
git -C kernel/deepseek-harness fetch upstream --tags

# 2. 查看候选稳定 tag，检出目标版本
git -C kernel/deepseek-harness tag --list --sort=-v:refname `
  | Select-String '^v?\d+\.\d+\.\d+$' | Select-Object -First 3
git -C kernel/deepseek-harness checkout <tag>

# 3. 内核依赖如有变化则重装
pnpm --dir kernel/deepseek-harness install --frozen-lockfile

# 4. 重建 harness.js（bundle + patch）
pnpm --dir tools/harness-transpiler run build
pnpm --dir tools/harness-transpiler run patch

# 5. QuickJS 兼容性门禁（失败则按上文修复流程处理）
pnpm --dir tools/harness-transpiler run check:quickjs

# 6. 部署到 HarmonyOS rawfile（harness.js 必须随 HAP 内嵌，禁止运行时下载）
Copy-Item tools\harness-transpiler\output\harness.js `
  harmonyApp\entry\src\main\resources\rawfile\harness.js -Force

# 7. 重建 HAP 并装机验证（PowerShell 需先设 SDK 环境变量）
$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'
cd harmonyApp; .\hvigorw.bat assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

macOS/Linux 对应使用 `kernel.sh`，其余命令相同（`cp` 代替 `Copy-Item`）。

## 更新后验证清单

| 项目 | 命令 / 方法 | 通过标准 |
|------|------------|---------|
| 兼容性门禁 | `pnpm --dir tools/harness-transpiler run check:quickjs` | exit 0，无缺失 API |
| SSE 流解析 | `node tools/harness-transpiler/output/check-sse.mjs`（本地工具，不入库） | 全部 `RESULT: PASS` |
| QuickJS 全链路 | `node tools/harness-transpiler/output/check-fetch-bridge.mjs`（本地工具） | `reason.kind` 为 `completed` |
| 真机对话 | 手机端发消息（如「你好」） | 收到完整回复，无 `DeepSeek API stream ... failed` |

## 提交更新

内核版本更新 = submodule 指针前移：

```powershell
git add kernel/deepseek-harness
git commit -m "chore(kernel): bump deepseek-harness to <tag>"
git push
```

推送到 main 后，`build-harmony.yml` 会在 CI 上自动重建 harness.js、跑门禁、部署 rawfile 再打 HAP——本地无需提交任何打包产物（`tools/harness-transpiler/output/` 已在 .gitignore 中）。

## 常见问题

**Q：CI 报 `ERR_PNPM_IGNORED_BUILDS`？**
`tools/harness-transpiler/pnpm-workspace.yaml` 中 `allowBuilds.esbuild` 必须为 `true`（pnpm 11 生效键）。新增带安装脚本的依赖时用 `pnpm approve-builds <pkg>` 批准。

**Q：门禁误报了实际安全的 API？**
优先确认是否真有 `typeof` 守卫（守卫区域内的引用会被自动识别）；确属安全的再加入 allowlist 并写明理由。

**Q：手机端运行时才暴露的缺失（静态分析漏报）？**
静态分析只覆盖全局自由引用。实例方法级缺失（如某 API 存在但方法不全）请在真机日志定位后，直接补 polyfill 并考虑把该 API 的方法探测加入检测脚本的规则。
