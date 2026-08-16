#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_ROOT="$ROOT/kernel/deepseek-harness"
CONFIG_DIR="$ROOT/kernel/configs"
PID_FILE="$ROOT/kernel/.pid"
UPSTREAM_URL="https://github.com/deepseek-ai/deepseek-harness.git"
DEFAULT_PORT=3080
DEFAULT_PROFILE="mobile"

step()  { printf "\033[36m==> %s\033[0m\n" "$*"; }
ok()    { printf "\033[32m    %s\033[0m\n" "$*"; }
warn()  { printf "\033[33m    WARNING: %s\033[0m\n" "$*"; }
err()   { printf "\033[31m    ERROR: %s\033[0m\n" "$*" >&2; }

assert_git() {
    command -v git >/dev/null 2>&1 || { err "git 未安装"; exit 1; }
    if [[ ! -d "$KERNEL_ROOT" ]]; then
        err "kernel submodule 不存在: $KERNEL_ROOT"
        err "请先执行: git submodule update --init --recursive"
        exit 1
    fi
}

assert_pnpm() {
    if ! command -v pnpm >/dev/null 2>&1; then
        err "pnpm 未安装"
        echo "    安装: npm install -g pnpm@11"
        return 1
    fi
}

upstream_branch() {
    if git -C "$KERNEL_ROOT" ls-remote --exit-code --heads upstream main >/dev/null 2>&1; then
        echo "main"
    else
        echo "master"
    fi
}

cmd_status() {
    assert_git
    step "DeepSeek Harness 内核状态"

    local hash short branch version submodule_status
    hash=$(git -C "$KERNEL_ROOT" rev-parse HEAD)
    short="${hash:0:9}"
    branch=$(git -C "$KERNEL_ROOT" branch --show-current)
    version=$(node -e "console.log(require('$KERNEL_ROOT/package.json').version)" 2>/dev/null || echo "unknown")
    submodule_status=$(git -C "$ROOT" submodule status kernel/deepseek-harness)

    ok "版本     : v$version"
    ok "HEAD     : $short"
    ok "分支     : $branch"
    ok "submodule: $submodule_status"

    if git -C "$KERNEL_ROOT" remote | grep -qx "upstream"; then
        local ub
        ub=$(upstream_branch)
        ok "upstream 分支: $ub"
        if git -C "$KERNEL_ROOT" fetch upstream --tags --quiet 2>/dev/null; then
            local behind ahead
            behind=$(git -C "$KERNEL_ROOT" rev-list --count "HEAD..upstream/$ub" 2>/dev/null || echo "?")
            ahead=$(git -C "$KERNEL_ROOT" rev-list --count "upstream/$ub..HEAD" 2>/dev/null || echo "?")
            if [[ "$behind" == "0" && "$ahead" == "0" ]]; then
                ok "与 upstream 同步"
            else
                warn "ahead $ahead / behind $behind vs upstream/$ub"
            fi
        else
            warn "无法比较 upstream 差异 (fetch 失败)"
        fi
    else
        warn "未配置 upstream remote (run add-remote)"
    fi

    ok "node     : $(node --version 2>/dev/null || echo '未安装')"
    ok "pnpm     : $(pnpm --version 2>/dev/null || echo '未安装')"

    if [[ -f "$PID_FILE" ]]; then
        ok "运行中   : PID $(cat "$PID_FILE")"
    else
        ok "运行中   : 否"
    fi
}

cmd_fetch() {
    assert_git
    if ! git -C "$KERNEL_ROOT" remote | grep -qx "upstream"; then
        step "添加 upstream remote -> $UPSTREAM_URL"
        git -C "$KERNEL_ROOT" remote add upstream "$UPSTREAM_URL"
    fi
    step "fetch upstream ..."
    git -C "$KERNEL_ROOT" fetch upstream --tags
    ok "fetch 完成"
}

cmd_merge() {
    assert_git
    cmd_fetch
    local ub
    ub=$(upstream_branch)

    step "merge upstream/$ub -> 当前分支"

    local stash_name="kernel-ps1-auto-stash-before-merge"
    local need_stash=false
    if [[ -n "$(git -C "$KERNEL_ROOT" status --porcelain)" ]]; then
        warn "工作区有未提交改动，将 stash"
        git -C "$KERNEL_ROOT" stash push -u -m "$stash_name" >/dev/null
        need_stash=true
    fi

    if ! git -C "$KERNEL_ROOT" merge --no-edit "upstream/$ub"; then
        err "merge 冲突！请手动解决"
        exit 1
    fi

    if $need_stash; then
        step "恢复之前的改动 ..."
        git -C "$KERNEL_ROOT" stash pop 2>/dev/null || true
    fi
    ok "merge 完成"
}

cmd_pull() {
    assert_git
    cmd_merge

    step "推送 submodule 指针变更到 fork"
    git -C "$ROOT" add kernel/deepseek-harness
    if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
        local new_hash
        new_hash=$(git -C "$KERNEL_ROOT" rev-parse HEAD)
        git -C "$ROOT" commit -m "kernel: bump submodule to ${new_hash:0:9}"
        if git -C "$ROOT" push; then
            ok "submodule 指针已推送到 fork"
        else
            warn "推送失败 — 请手动推送"
        fi
    else
        ok "submodule 指针无变化，跳过推送"
    fi
}

cmd_build() {
    assert_git
    assert_pnpm
    step "pnpm install ..."
    ( cd "$KERNEL_ROOT" && pnpm install --frozen-lockfile ) || {
        warn "frozen-lockfile 失败，尝试不带锁 ..."
        ( cd "$KERNEL_ROOT" && pnpm install )
    }
    step "pnpm build (host + client + web) ..."
    ( cd "$KERNEL_ROOT" && pnpm run build )
    ok "构建完成"
}

cmd_run() {
    assert_git
    assert_pnpm

    local port="$DEFAULT_PORT"
    local profile="$DEFAULT_PROFILE"
    local pass_through=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port)
                port="$2"; shift 2 ;;
            --profile)
                profile="$2"; shift 2 ;;
            *)
                pass_through+=("$1"); shift ;;
        esac
    done

    if [[ -f "$PID_FILE" ]]; then
        local old_pid
        old_pid=$(cat "$PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            warn "已有进程 PID $old_pid 正在运行，请先 ./kernel.sh stop"
            exit 1
        else
            warn "残留 PID 文件（进程不存在），清理中"
            rm -f "$PID_FILE"
        fi
    fi

    local patch
    case "$profile" in
        mobile) patch="$CONFIG_DIR/mobile-minimal.cordis.yml" ;;
        full)   patch="$CONFIG_DIR/full.cordis.yml" ;;
        *)      patch="$CONFIG_DIR/mobile-minimal.cordis.yml" ;;
    esac
    if [[ ! -f "$patch" ]]; then
        err "配置文件不存在: $patch"
        exit 1
    fi

    step "启动 dsh --profile web --patch $patch --port $port"
    ok "pid 文件: $PID_FILE"

    export DSH_PORT="$port"
    (
        cd "$KERNEL_ROOT"
        nohup pnpm dsh --profile web --patch "$patch" > "$ROOT/kernel/dsh.log" 2>&1 &
        echo $! > "$PID_FILE"
    )
    ok "进程已启动 PID $(cat "$PID_FILE")，端口 $port"
    ok "日志: $ROOT/kernel/dsh.log"
}

cmd_stop() {
    assert_git
    if [[ ! -f "$PID_FILE" ]]; then
        ok "没有正在运行的进程 (kernel/.pid 不存在)"
        return
    fi
    local pid
    pid=$(cat "$PID_FILE")
    if [[ -z "$pid" ]]; then
        rm -f "$PID_FILE"
        return
    fi
    if kill -0 "$pid" 2>/dev/null; then
        step "停止 PID $pid ..."
        kill "$pid" 2>/dev/null || true
        sleep 0.5
        if kill -0 "$pid" 2>/dev/null; then
            warn "进程未终止，SIGKILL ..."
            kill -9 "$pid" 2>/dev/null || true
        fi
        ok "PID $pid 已停止"
    else
        warn "PID $pid 不存在，清理残留 PID 文件"
    fi
    rm -f "$PID_FILE"
}

cmd_upgrade() {
    assert_git
    cmd_pull
    cmd_build
    cmd_stop
    cmd_run
}

cmd_log() {
    assert_git
    local lines=20
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --lines) lines="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    git -C "$KERNEL_ROOT" log --oneline -n "$lines"
}

cmd_diff() {
    assert_git
    if ! git -C "$KERNEL_ROOT" remote | grep -qx "upstream"; then
        cmd_fetch
    fi
    local ub
    ub=$(upstream_branch)
    step "本地 HEAD vs upstream/$ub"
    git -C "$KERNEL_ROOT" log --oneline "HEAD...upstream/$ub"
}

cmd_remote() {
    assert_git
    step "kernel submodule remotes:"
    git -C "$KERNEL_ROOT" remote -v
}

cmd_add_remote() {
    assert_git
    if git -C "$KERNEL_ROOT" remote | grep -qx "upstream"; then
        local current
        current=$(git -C "$KERNEL_ROOT" config remote.upstream.url)
        warn "upstream 已存在: $current"
        read -r -p "是否替换? (y/N) " ans
        [[ "$ans" == "y" ]] || return 0
        git -C "$KERNEL_ROOT" remote remove upstream
    fi
    read -r -p "upstream URL [$UPSTREAM_URL]: " url
    url="${url:-$UPSTREAM_URL}"
    git -C "$KERNEL_ROOT" remote add upstream "$url"
    ok "upstream -> $url"
    cmd_fetch
}

show_help() {
    cat <<EOF
kernel.sh — DeepSeek Harness 内核一键管理 (macOS / Linux)

用法:
  ./kernel.sh <command> [options]

命令:
  status              查看内核版本、当前分支、submodule 状态
  pull                fetch upstream + merge + 推送 submodule 指针
  fetch               仅 fetch upstream
  merge               把 upstream/<branch> merge 进 submodule
  build               pnpm install + pnpm build
  run                 启动 WebSocket 服务 (web profile)
                        选项: --port <N>     (默认 3080)
                              --profile <name> (mobile | full, 默认 mobile)
  stop                停止进程 (读取 kernel/.pid)
  upgrade             pull + build + 重启 — 一键升级
  log                 查看上游 git log
                        选项: --lines <N> (默认 20)
  diff                本地 HEAD vs upstream/<branch> diff
  remote              显示 kernel remotes
  add-remote          交互式添加 upstream remote

路径:
  kernel 子模块: $KERNEL_ROOT
  配置文件:       $CONFIG_DIR/mobile-minimal.cordis.yml | full.cordis.yml
  PID 文件:       $PID_FILE
EOF
}

cmd="${1:-help}"
shift || true

case "$cmd" in
    status)     cmd_status ;;
    pull)       cmd_pull ;;
    fetch)      cmd_fetch ;;
    merge)      cmd_merge ;;
    build)      cmd_build ;;
    run)        cmd_run "$@" ;;
    stop)       cmd_stop ;;
    upgrade)    cmd_upgrade ;;
    log)        cmd_log "$@" ;;
    diff)       cmd_diff ;;
    remote)     cmd_remote ;;
    add-remote) cmd_add_remote ;;
    help|-h|--help) show_help ;;
    *) show_help; exit 1 ;;
esac
