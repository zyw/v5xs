import Foundation

/// 重启辅助脚本的生成逻辑。
///
/// 为什么必须是独立进程：正在运行的应用无法替换自己的 bundle（文件被内核映射），
/// 这是硬约束。所以流程是「生成脚本 → 退出 App → 由脚本完成替换并重新拉起」。
///
/// 为什么做成纯函数：这是整个自动更新里**唯一一个写错就会删掉用户应用**的地方。
/// 把脚本内容作为可断言的值产出，才能在测试里逐字检查每一条路径
/// （失败回滚、等待旧进程退出、解挂 DMG），而不是靠人工 review 一眼扫过。
public enum UpdateInstallScript {
    /// 生成重启辅助脚本。
    ///
    /// - Parameters:
    ///   - pid: 即将退出的 v5xs 进程 pid，脚本会等它真正结束后再动手。
    ///   - stagedApp: 已复制好的新 .app 路径（与 targetApp 在同一磁盘卷上，保证 rename 是原子操作）。
    ///   - targetApp: 目标位置，通常是 /Applications/v5xs.app。
    ///   - mountPoint: 需要解挂的 DMG 挂载点，没有则为 nil。
    public static func make(
        pid: Int32,
        stagedApp: String,
        targetApp: String,
        mountPoint: String?
    ) -> String {
        let backup = targetApp + ".v5xs-old"
        let detach = mountPoint.map {
            "hdiutil detach " + shellQuote($0) + " -quiet >/dev/null 2>&1 || true"
        } ?? "true"

        // 刻意用「先 mv 到备份，成功后再换入」的顺序：任何一步失败都要能把应用恢复到
        // 可用状态。自动更新最坏的结果是「更新失败但仍能用旧版」，
        // 绝不能是「更新失败且应用没了」。
        //
        // 这里用字符串拼接而非多行字面量插值：脚本里有 $VAR、$(seq ...) 这类
        // shell 语法，与 Swift 的插值标记容易互相干扰，拼接更不容易出错。
        var lines: [String] = []
        lines.append("#!/bin/bash")
        lines.append("# v5xs 自动更新：等待旧进程退出 → 原子替换 → 重新拉起。")
        lines.append("# 本脚本由 v5xs 生成，只在本机执行一次。")
        lines.append("set -u")
        lines.append("")
        lines.append("TARGET=" + shellQuote(targetApp))
        lines.append("STAGED=" + shellQuote(stagedApp))
        lines.append("BACKUP=" + shellQuote(backup))
        lines.append("WAIT_PID=" + String(pid))
        lines.append("")
        lines.append("# 1) 等待旧进程真正退出，最多 15 秒。")
        lines.append("#    不能用固定 sleep：应用退出与脚本启动存在竞争，快了会复制失败。")
        lines.append("for _ in $(seq 1 150); do")
        lines.append("  if ! kill -0 \"$WAIT_PID\" 2>/dev/null; then break; fi")
        lines.append("  sleep 0.1")
        lines.append("done")
        lines.append("")
        lines.append("# 2) 新包必须完整，否则不做任何改动（避免把旧版本也弄丢）。")
        lines.append("#    只检查目录存在是不够的：空目录也能 mv 成功，结果是把用户的应用")
        lines.append("#    换成一个打不开的空壳。必须确认里面有可执行文件。")
        lines.append("if [ ! -d \"$STAGED\" ] || [ ! -x \"$STAGED/Contents/MacOS/v5xs\" ]; then")
        lines.append("  open \"$TARGET\"")
        lines.append("  exit 1")
        lines.append("fi")
        lines.append("")
        lines.append("# 3) 备份旧版本。失败就直接放弃，不动现有安装。")
        lines.append("rm -rf \"$BACKUP\"")
        lines.append("if [ -d \"$TARGET\" ] && ! mv \"$TARGET\" \"$BACKUP\"; then")
        lines.append("  open \"$TARGET\"")
        lines.append("  exit 1")
        lines.append("fi")
        lines.append("")
        lines.append("# 4) 换入新版本。")
        lines.append("if mv \"$STAGED\" \"$TARGET\"; then")
        lines.append("  " + detach)
        lines.append("  rm -rf \"$BACKUP\"")
        lines.append("  open \"$TARGET\"")
        lines.append("  exit 0")
        lines.append("fi")
        lines.append("")
        lines.append("# 5) 失败回滚：恢复旧版本并重新打开，用户至少还在用能用的版本。")
        lines.append("if [ -d \"$BACKUP\" ]; then")
        lines.append("  rm -rf \"$TARGET\"")
        lines.append("  mv \"$BACKUP\" \"$TARGET\"")
        lines.append("fi")
        lines.append(detach)
        lines.append("open \"$TARGET\"")
        lines.append("exit 1")
        return lines.joined(separator: "\n") + "\n"
    }

    /// 包一层 shell 单引号转义。
    /// 路径里可能含空格、中文、甚至单引号（用户主目录名），
    /// 直接拼接会导致命令被切断——这在自动更新里是致命的。
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 脚本的落盘位置：固定用 /tmp，而不是 `FileManager.default.temporaryDirectory`。
    ///
    /// 后者返回 per-user 的 `$TMPDIR`（形如 /var/folders/xx/…/T/），路径随用户变化，
    /// 且系统会在空间紧张时清理。更新脚本要在 App 退出**之后**才被执行，这段时间里
    /// 它必须还在——固定路径更可控。/tmp 在 macOS 上指向 /private/tmp，是稳定路径。
    /// 文件名带 pid，便于排查并发。
    public static func scriptURL(pid: Int32) -> URL {
        URL(fileURLWithPath: "/tmp/v5xs-update-\(pid).sh")
    }
}

/// 判断脚本里是否包含关键路径。供测试断言，避免正则写在各处。
public enum UpdateInstallScriptInspector {
    public static func containsRollback(_ script: String) -> Bool {
        script.contains("mv \"$BACKUP\" \"$TARGET\"")
    }

    public static func waitsForProcessExit(_ script: String) -> Bool {
        script.contains("kill -0 \"$WAIT_PID\"")
    }

    public static func detachesMount(_ script: String) -> Bool {
        script.contains("hdiutil detach")
    }

    public static func reopensApp(_ script: String) -> Bool {
        script.contains("open \"$TARGET\"")
    }

    /// 是否校验了新包里有可执行文件（防止把应用换成空壳）。
    public static func validatesExecutable(_ script: String) -> Bool {
        script.contains("-x \"$STAGED/Contents/MacOS/v5xs\"")
    }
}
