package com.harnest.app.dsh.kernel

/**
 * DSH 内核源码版本信息 — App 打包时从内核自动生成。
 * 在 CI/构建脚本中由 kernel-manager 生成 src/**/kotlin/.../KernelVersion.kt 类同文件。
 */
data object KernelVersion {
    /** git tag 或 commit hash，在构建时注入 */
    const val GIT_COMMIT: String = "unknown"
    /** 语义化版本，如 "0.1.0-rc.5" */
    const val VERSION: String = "0.0.0"
    /** 构建时间 */
    const val BUILD_TIME: String = "unknown"
}

/**
 * 内核更新检查接口 — App 可通过这个接口决定是否提示用户升级。
 * 默认实现从 DSH GitHub Releases 获取最新 tag。
 */
interface KernelVersionChecker {
    suspend fun latestVersion(): String?
    suspend fun needsUpdate(current: String): Boolean
}
