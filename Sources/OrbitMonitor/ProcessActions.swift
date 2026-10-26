import AppKit
import MonitorCore

@MainActor
enum ProcessActions {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func reveal(_ target: ProcessReading) {
        // 只有真的是 .app 包内可执行文件，才谈得上「在访达中显示」。
        guard let url = appBundleURL(for: target), ProcessInspector.stillRunning(target) else {
            alert(Strings.current(.cannotLocateAppFile))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 是否可以对这个进程执行终止类操作。
    /// 注意：不要用 `NSRunningApplication(processIdentifier:)` 作为判据——它只识别 GUI 应用，
    /// 对 java、各类 Helper、守护进程一律返回 nil，而这些正是进程榜里的主要成员。
    static func canTerminate(_ target: ProcessReading) -> Bool {
        ProcessInspector.stillRunning(target)
    }

    static func terminate(_ target: ProcessReading, force: Bool) {
        guard ProcessInspector.stillRunning(target) else {
            alert(Strings.current(.processGone))
            return
        }

        let displayName = displayName(of: target)

        if force {
            let dialog = NSAlert()
            dialog.messageText = Strings.current(.forceQuitPrompt, displayName)
            dialog.informativeText = Strings.current(.forceQuitMessage, Int(target.pid))
            dialog.addButton(withTitle: Strings.current(.cancel))
            dialog.addButton(withTitle: Strings.current(.forceQuit))
            dialog.alertStyle = .warning
            guard dialog.runModal() == .alertSecondButtonReturn else { return }
            guard ProcessInspector.stillRunning(target) else {
                alert(Strings.current(.processChangedDuringConfirm))
                return
            }
            // SIGKILL：进程无法拦截，一定退出。
            if let code = ProcessInspector.send(target.pid, SIGKILL) {
                alert(Strings.current(.cannotForceTerminate,
                                      displayName,
                                      ProcessInspector.errorDescription(code)))
            }
        } else {
            // SIGTERM：给进程自行清理退出的机会（与「强制退出」的 SIGKILL 区分开）。
            if let code = ProcessInspector.send(target.pid, SIGTERM) {
                alert(Strings.current(.cannotTerminate,
                                      displayName,
                                      ProcessInspector.errorDescription(code)))
            }
        }
    }

    /// 进程在界面上的可读名称；GUI 应用优先用本地化名称。
    private static func displayName(of target: ProcessReading) -> String {
        if let application = NSRunningApplication(processIdentifier: target.pid),
           let name = application.localizedName {
            return name
        }
        return target.name
    }

    /// 若进程位于某个 .app 内，返回该 .app 的 URL。
    private static func appBundleURL(for target: ProcessReading) -> URL? {
        if let url = NSRunningApplication(processIdentifier: target.pid)?.bundleURL {
            return url
        }
        // 非 GUI 进程没有 NSRunningApplication，退化为按路径向上找 .app 祖先目录。
        guard let range = target.executablePath.range(of: ".app/", options: .backwards) else { return nil }
        return URL(fileURLWithPath: String(target.executablePath[..<range.lowerBound]) + ".app")
    }

    private static func alert(_ text: String) {
        let dialog = NSAlert()
        dialog.messageText = Strings.current(.operationIncomplete)
        dialog.informativeText = text
        dialog.runModal()
    }
}
