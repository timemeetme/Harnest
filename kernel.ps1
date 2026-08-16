[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet(
        'status', 'pull', 'fetch', 'merge', 'build',
        'run', 'stop', 'upgrade', 'log', 'diff',
        'remote', 'add-remote', 'help'
    )]
    [string]$Command = 'help',

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ArgsList = @()
)

$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$KernelRoot = Join-Path $Root 'kernel\deepseek-harness'
$ConfigDir = Join-Path $Root 'kernel\configs'
$PidFile = Join-Path $Root 'kernel\.pid'
$UpstreamUrl = 'https://github.com/deepseek-ai/deepseek-harness.git'
$DefaultPort = 3080
$DefaultProfile = 'mobile'

function Write-Step($msg) {
    Write-Host "==> $msg" -ForegroundColor Cyan
}
function Write-Ok($msg) {
    Write-Host "    $msg" -ForegroundColor Green
}
function Write-Warn($msg) {
    Write-Host "    WARNING: $msg" -ForegroundColor Yellow
}
function Write-Err($msg) {
    Write-Host "    ERROR: $msg" -ForegroundColor Red
}

function Assert-Git {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Err 'git 未安装，请先安装 git'
        exit 1
    }
    if (-not (Test-Path $KernelRoot)) {
        Write-Err "kernel submodule 不存在: $KernelRoot"
        Write-Err '请先执行: git submodule update --init --recursive'
        exit 1
    }
}

function Assert-Pnpm {
    param([bool]$InstallHint = $true)
    $ok = (Get-Command pnpm -ErrorAction SilentlyContinue) -ne $null
    if (-not $ok -and $InstallHint) {
        Write-Err 'pnpm 未安装'
        Write-Host '    安装方式: npm install -g pnpm@11' -ForegroundColor DarkGray
    }
    return $ok
}

function Invoke-KernelGit {
    param([string[]]$GitArgs)
    Push-Location $KernelRoot
    try {
        & git @GitArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            Pop-Location
            exit $LASTEXITCODE
        }
    } finally {
        Pop-Location
    }
}

function Invoke-RootGit {
    param([string[]]$GitArgs)
    Push-Location $Root
    try {
        & git @GitArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            Pop-Location
            exit $LASTEXITCODE
        }
    } finally {
        Pop-Location
    }
}

function Get-UpstreamBranch {
    $branch = git -C $KernelRoot ls-remote --heads upstream main 2>$null
    if ($LASTEXITCODE -eq 0 -and $branch) { return 'main' }
    $branch = git -C $KernelRoot ls-remote --heads upstream master 2>$null
    if ($LASTEXITCODE -eq 0 -and $branch) { return 'master' }
    return 'master'
}

function Invoke-Command {
    param(
        [Parameter(Position = 0)]
        [scriptblock]$Body
    )
    try {
        & $Body
    } catch {
        Write-Err $_.Exception.Message
        exit 1
    }
}

function Show-Help {
    @"
kernel.ps1 — DeepSeek Harness 内核一键管理

用法:
  .\kernel.ps1 <command> [options]

命令:
  status              查看内核版本、当前分支、submodule 状态
  pull                fetch upstream + merge + 推送 submodule 指针到我们的 fork
  fetch               仅 fetch upstream 不 merge
  merge               把 upstream/<branch> merge 进当前 submodule 工作树
  build               pnpm install + pnpm build
  run                 启动 headless WebSocket 服务 (web profile)
                        选项: --port <N>     (默认 3080)
                              --profile <name> (mobile | full, 默认 mobile)
  stop                停止正在运行的进程 (读取 kernel\.pid)
  upgrade             pull + build + 重启 — 最常用的一键升级
  log                 查看上游 git log
                        选项: --lines <N> (默认 20)
  diff                本地 submodule hash vs upstream/<branch> 的 diff
  remote              显示 kernel 的 upstream/origin remotes
  add-remote          交互式添加 upstream remote

路径:
  kernel 子模块: $KernelRoot
  配置文件:       $ConfigDir\mobile-minimal.cordis.yml | full.cordis.yml
  PID 文件:       $PidFile
"@
}

function Invoke-Status {
    Assert-Git
    Write-Step 'DeepSeek Harness 内核状态'

    $hash = (git -C $KernelRoot rev-parse HEAD).Trim()
    $short = $hash.Substring(0, 9)
    $branch = (git -C $KernelRoot branch --show-current).Trim()
    $versionLine = (Get-Content (Join-Path $KernelRoot 'package.json') |
        ConvertFrom-Json).version
    $submoduleStatus = (git -C $Root submodule status kernel/deepseek-harness).Trim()

    Write-Ok "版本     : v$versionLine"
    Write-Ok "HEAD     : $short  ($hash)"
    Write-Ok "分支     : $branch"
    Write-Ok "submodule: $submoduleStatus"

    $upstreamExists = (git -C $KernelRoot remote 2>$null) -contains 'upstream'
    if ($upstreamExists) {
        $upstreamBranch = Get-UpstreamBranch
        Write-Ok "upstream 分支: $upstreamBranch"
        $behind = (git -C $KernelRoot rev-list --count HEAD..upstream/$upstreamBranch 2>$null).Trim()
        $ahead = (git -C $KernelRoot rev-list --count upstream/$upstreamBranch..HEAD 2>$null).Trim()
        if ($LASTEXITCODE -eq 0) {
            if ($behind -eq '0' -and $ahead -eq '0') {
                Write-Ok '与 upstream 同步'
            } else {
                Write-Warn "ahead $ahead / behind $behind vs upstream/$upstreamBranch"
            }
        } else {
            Write-Warn '无法比较 upstream 差异 (可能未 fetch)'
        }
    } else {
        Write-Warn '未配置 upstream remote (add-remote 添加)'
    }

    $nodeOk = (Get-Command node -ErrorAction SilentlyContinue) -ne $null
    $pnpmOk = (Get-Command pnpm -ErrorAction SilentlyContinue) -ne $null
    $nodeVer = if ($nodeOk) { (node --version) } else { '未安装' }
    $pnpmVer = if ($pnpmOk) { (pnpm --version) } else { '未安装' }
    Write-Ok "node     : $nodeVer"
    Write-Ok "pnpm     : $pnpmVer"

    $built = Test-Path (Join-Path $KernelRoot 'packages\host\apiproxy\lib')
    $builtStr = if ($built) { '是' } else { '否 (run build)' }
    Write-Ok "已构建   : $builtStr"

    if (Test-Path $PidFile) {
        $pidContent = Get-Content $PidFile -Raw
        Write-Ok "运行中   : PID $pidContent"
    } else {
        Write-Ok '运行中   : 否'
    }
}

function Invoke-Fetch {
    Assert-Git
    Invoke-Command {
        $upstreamExists = (git -C $KernelRoot remote 2>$null) -contains 'upstream'
        if (-not $upstreamExists) {
            Write-Step "添加 upstream remote -> $UpstreamUrl"
            git -C $KernelRoot remote add upstream $UpstreamUrl
        }
        Write-Step 'fetch upstream ...'
        git -C $KernelRoot fetch upstream --tags
        Write-Ok 'fetch 完成'
    }
}

function Invoke-Merge {
    Assert-Git
    Invoke-Command {
        Invoke-Fetch
        $upstreamBranch = Get-UpstreamBranch
        Write-Step "merge upstream/$upstreamBranch -> 当前分支"

        $localStatus = git -C $KernelRoot status --porcelain
        if ($localStatus) {
            Write-Warn '工作区有未提交改动，将 stash'
            git -C $KernelRoot stash push -u -m 'kernel-ps1-auto-stash-before-merge'
        }

        git -C $KernelRoot merge --no-edit "upstream/$upstreamBranch"
        if ($LASTEXITCODE -ne 0) {
            Write-Err 'merge 冲突！请手动解决后执行 git submodule status'
            exit 1
        }

        if ($localStatus) {
            Write-Step '恢复之前的改动 ...'
            git -C $KernelRoot stash pop 2>$null
        }
        Write-Ok 'merge 完成'
    }
}

function Invoke-Pull {
    Assert-Git
    Invoke-Command {
        Invoke-Merge
        Write-Step '推送 submodule 指针变更到 fork'
        Invoke-RootGit -GitArgs @('add', 'kernel/deepseek-harness')
        $dirty = git -C $Root status --porcelain
        if ($dirty) {
            Invoke-RootGit -GitArgs @('commit', '-m', "kernel: bump submodule to $(git -C $KernelRoot rev-parse HEAD | ForEach-Object { $_.Substring(0,9) })")
            git -C $Root push
            if ($LASTEXITCODE -ne 0) {
                Write-Warn '推送失败 — 请手动推送'
            } else {
                Write-Ok 'submodule 指针已推送到 fork'
            }
        } else {
            Write-Ok 'submodule 指针无变化，跳过推送'
        }
    }
}

function Invoke-Build {
    Assert-Git
    $pnpmOk = Assert-Pnpm -InstallHint $false
    if (-not $pnpmOk) {
        Write-Err 'pnpm 未安装，无法构建'
        Write-Host '    npm install -g pnpm@11' -ForegroundColor DarkGray
        exit 1
    }
    Invoke-Command {
        Push-Location $KernelRoot
        try {
            Write-Step 'pnpm install ...'
            pnpm install --frozen-lockfile 2>&1 | Select-Object -Last 5
            if ($LASTEXITCODE -ne 0) {
                Write-Warn 'frozen-lockfile 失败，尝试不带锁 ...'
                pnpm install
                if ($LASTEXITCODE -ne 0) {
                    Write-Err 'pnpm install 失败'
                    exit 1
                }
            }
            Write-Step 'pnpm build (host + client + web) ...'
            pnpm run build
            if ($LASTEXITCODE -ne 0) {
                Write-Err '构建失败'
                exit 1
            }
            Write-Ok '构建完成'
        } finally {
            Pop-Location
        }
    }
}

function Invoke-Run {
    Assert-Git
    $pnpmOk = Assert-Pnpm -InstallHint $false
    if (-not $pnpmOk) {
        Write-Err 'pnpm 未安装，无法启动'
        exit 1
    }

    $port = $DefaultPort
    $profile = $DefaultProfile
    $passThrough = @()
    for ($i = 0; $i -lt $ArgsList.Count; $i++) {
        switch ($ArgsList[$i]) {
            '--port' { $port = $ArgsList[++$i] }
            '--profile' { $profile = $ArgsList[++$i] }
            default { $passThrough += $ArgsList[$i] }
        }
    }

    if (Test-Path $PidFile) {
        $oldPid = (Get-Content $PidFile -Raw).Trim()
        try {
            $proc = Get-Process -Id $oldPid -ErrorAction Stop
            Write-Warn "已有进程 PID $oldPid 正在运行，请先 .\kernel.ps1 stop"
            exit 1
        } catch {
            Write-Warn "残留 PID 文件（进程不存在），清理中"
            Remove-Item $PidFile -Force
        }
    }

    $profileName = 'web'
    switch ($profile) {
        'mobile' { $patch = (Join-Path $ConfigDir 'mobile-minimal.cordis.yml') }
        'full'   { $patch = (Join-Path $ConfigDir 'full.cordis.yml') }
        default  { $patch = (Join-Path $ConfigDir 'mobile-minimal.cordis.yml') }
    }
    if (-not (Test-Path $patch)) {
        Write-Err "配置文件不存在: $patch"
        exit 1
    }

    Push-Location $KernelRoot
    try {
        Write-Step "启动 dsh --profile $profileName --patch $patch --port $port"
        Write-Ok "pid 文件: $PidFile (Ctrl+C 停止后请 .\kernel.ps1 stop 清理)"

        $env:DSH_PORT = "$port"
        $proc = Start-Process -FilePath 'pnpm' `
            -ArgumentList @('dsh', '--profile', $profileName, '--patch', $patch) `
            -WorkingDirectory $KernelRoot `
            -PassThru -NoNewWindow
        $proc.Id | Out-File -FilePath $PidFile -NoNewline
        Write-Ok "进程已启动 PID $($proc.Id)，端口 $port"
    } finally {
        Pop-Location
    }
}

function Invoke-Stop {
    Assert-Git
    if (-not (Test-Path $PidFile)) {
        Write-Ok '没有正在运行的进程 (kernel\.pid 不存在)'
        return
    }
    $pidContent = (Get-Content $PidFile -Raw).Trim()
    if (-not $pidContent) {
        Remove-Item $PidFile -Force
        return
    }
    try {
        $proc = Get-Process -Id $pidContent -ErrorAction Stop
        Write-Step "停止 PID $pidContent ($($proc.ProcessName)) ..."
        Stop-Process -Id $pidContent -Force
        Start-Sleep -Milliseconds 300
        if (Get-Process -Id $pidContent -ErrorAction SilentlyContinue) {
            Write-Warn '进程未终止，再试一次 ...'
            Stop-Process -Id $pidContent -Force
        }
        Write-Ok "PID $pidContent 已停止"
    } catch {
        Write-Warn "PID $pidContent 不存在，清理残留 PID 文件"
    }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
}

function Invoke-Upgrade {
    Assert-Git
    Invoke-Command {
        Invoke-Pull
        Invoke-Build
        Invoke-Stop
        Invoke-Run -ArgsList @()
    }
}

function Invoke-Log {
    Assert-Git
    $lines = 20
    for ($i = 0; $i -lt $ArgsList.Count; $i++) {
        if ($ArgsList[$i] -eq '--lines') { $lines = [int]$ArgsList[++$i] }
    }
    Invoke-KernelGit -GitArgs @('log', "--oneline", "-n", "$lines")
}

function Invoke-Diff {
    Assert-Git
    Invoke-Command {
        $upstreamExists = (git -C $KernelRoot remote 2>$null) -contains 'upstream'
        if (-not $upstreamExists) { Invoke-Fetch }
        $upstreamBranch = Get-UpstreamBranch
        Write-Step "本地 HEAD vs upstream/$upstreamBranch"
        Invoke-KernelGit -GitArgs @('log', "--oneline", "HEAD...upstream/$upstreamBranch")
    }
}

function Invoke-Remote {
    Assert-Git
    Write-Step 'kernel submodule remotes:'
    Invoke-KernelGit -GitArgs @('remote', '-v')
}

function Invoke-AddRemote {
    Assert-Git
    Invoke-Command {
        $upstreamExists = (git -C $KernelRoot remote 2>$null) -contains 'upstream'
        if ($upstreamExists) {
            $current = git -C $KernelRoot config remote.upstream.url
            Write-Warn "upstream 已存在: $current"
            $ans = Read-Host '是否替换? (y/N)'
            if ($ans -ne 'y') { return }
            git -C $KernelRoot remote remove upstream
        }
        $url = Read-Host "upstream URL [$UpstreamUrl]"
        if (-not $url) { $url = $UpstreamUrl }
        git -C $KernelRoot remote add upstream $url
        Write-Ok "upstream -> $url"
        Invoke-Fetch
    }
}

switch ($Command) {
    'status'     { Invoke-Status }
    'pull'       { Invoke-Pull }
    'fetch'      { Invoke-Fetch }
    'merge'      { Invoke-Merge }
    'build'      { Invoke-Build }
    'run'        { Invoke-Run -ArgsList $ArgsList }
    'stop'       { Invoke-Stop }
    'upgrade'    { Invoke-Upgrade }
    'log'        { Invoke-Log }
    'diff'       { Invoke-Diff }
    'remote'     { Invoke-Remote }
    'add-remote' { Invoke-AddRemote }
    'help'       { Show-Help }
    default      { Show-Help; exit 1 }
}
