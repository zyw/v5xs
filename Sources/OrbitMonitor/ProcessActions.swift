import AppKit
import MonitorCore

@MainActor
enum ProcessActions {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func reveal(_ target: ProcessReading) {
        guard let application = NSRunningApplication(processIdentifier: target.pid),
              let url = application.bundleURL, identityMatches(target) else {
            alert("无法定位此进程的应用文件")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func terminate(_ target: ProcessReading, force: Bool) {
        guard let application = NSRunningApplication(processIdentifier: target.pid),
              identityMatches(target) else {
            alert("进程已经结束或 PID 已被其他进程使用")
            return
        }
        if force {
            let dialog = NSAlert()
            dialog.messageText = "强制退出 \(target.name)？"
            dialog.informativeText = "PID \(target.pid) · 未保存的工作可能丢失。建议先尝试“终止”。"
            dialog.addButton(withTitle: "取消")
            dialog.addButton(withTitle: "强制退出")
            dialog.alertStyle = .warning
            guard dialog.runModal() == .alertSecondButtonReturn else { return }
            guard identityMatches(target) else {
                alert("确认期间进程已经结束或 PID 已变化")
                return
            }
            if !application.forceTerminate() { alert("无法强制退出该进程，可能缺少权限") }
        } else if !application.terminate() {
            alert("无法终止该进程，可能缺少权限")
        }
    }

    private static func identityMatches(_ target: ProcessReading) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(target.pid)", "-o", "lstart=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let parts = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(maxSplits: 5, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        let start = parts?.count == 6 ? parts?[0...4].joined(separator: " ") : nil
        let path = parts?.count == 6 ? String(parts![5]) : nil
        return process.terminationStatus == 0 &&
            ProcessIdentity.matches(
                expectedPath: target.executablePath,
                expectedStart: target.startTime,
                observedPath: path,
                observedStart: start
            )
    }

    private static func alert(_ text: String) {
        let dialog = NSAlert()
        dialog.messageText = "操作未完成"
        dialog.informativeText = text
        dialog.runModal()
    }
}
