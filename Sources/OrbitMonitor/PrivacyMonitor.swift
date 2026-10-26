import AVFoundation
import CoreAudio
import Foundation
import AppKit
import MonitorCore

/// 摄像头 / 麦克风占用检测。
/// - 麦克风：用 macOS 14.2+ 的 CoreAudio 进程对象（kAudioHardwarePropertyProcessObjectList）
///   枚举每个音频进程的输入采集状态，能精确到进程 bundle id —— 本机实测可用。
/// - 摄像头：用官方公开的 AVCaptureDevice.isInUseByAnotherApplication 判断"当前是否有其他应用
///   正在使用摄像头"（准确信号）。macOS 没有公开的"按进程归属"摄像头 API，所以无法精确到哪个
///   App；归属不到时如实显示"有其他进程在访问"，绝不编造应用名。
final class PrivacyMonitor: @unchecked Sendable {
    struct Status: Equatable {
        var micInUse: Bool
        var micProcess: String?
        var camInUse: Bool
        var camProcess: String?
        var supported: Bool   // false = 进程对象 API 不可用（< macOS 14.2），只给近似值
    }

    var onUpdate: ((Status) -> Void)?

    /// WebKit 子进程没有可读的应用名，用固定名称兜底。
    /// 做成计算属性而不是常量字典：常量在类型初始化时求值一次，
    /// 切换界面语言后不会更新。
    private var appNameOverrides: [String: String] {
        [
            "com.apple.WebKit.GPU": Strings.current(.browserName),
            "com.apple.WebKit.Networking": Strings.current(.browserName),
            "com.apple.WebKit.WebContent": Strings.current(.webPage),
        ]
    }

    private func displayName(forPid pid: Int32, bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        if let override = appNameOverrides[bundleID] { return override }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return nil
    }

    /// 读取全部音频进程，找出正在采集输入（麦克风）的进程。
    private func microphoneInUse() -> (pid: Int32, bundleID: String?)? {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize) == noErr else { return nil }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: count)
        var filledSize = dataSize
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &filledSize, &ids) == noErr else { return nil }
        for id in ids {
            if let (pid, bundleID) = self.micProcess(id: id), pid != getpid() {
                return (pid, bundleID)
            }
        }
        return nil
    }

    private func micProcess(id: AudioObjectID) -> (Int32, String?)? {
        func uint32Prop(_ selector: AudioObjectPropertySelector) -> UInt32? {
            var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var v: UInt32 = 0
            var s = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &v) == noErr else { return nil }
            return v
        }
        func cfProp(_ selector: AudioObjectPropertySelector) -> String? {
            var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr else { return nil }
            // kAudioProcessPropertyBundleID 返回一个 CFString 对象。先拿到原始指针，
            // 再确认它确实是 CFString 再转 Swift String（避免 Optional<CFString> 的误用告警）。
            var cfValue: CFTypeRef?
            var s = size
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &cfValue) == noErr,
                  let ref = cfValue,
                  CFGetTypeID(ref) == CFStringGetTypeID() else { return nil }
            return (ref as! CFString) as String
        }
        guard let runningInput = uint32Prop(kAudioProcessPropertyIsRunningInput), runningInput == 1 else { return nil }
        guard let pid = uint32Prop(kAudioProcessPropertyPID) else { return nil }
        return (Int32(pid), cfProp(kAudioProcessPropertyBundleID))
    }

    /// 摄像头：用官方公开的 AVCaptureDevice.isInUseByAnotherApplication 判断是否有其他应用
    /// 正在使用摄像头。返回的 name 仅在有把握时才给出（本实现不编造具体 App ——
    /// macOS 没有公开的按进程归属摄像头 API），否则由 UI 显示"有其他进程在访问"。
    private func cameraInUse() -> Bool {
        AVCaptureDevice.devices(for: .video).contains { $0.isInUseByAnotherApplication }
    }

    func refresh() {
        let mic = microphoneInUse()
        let camInUse = cameraInUse()
        let status = Status(
            micInUse: mic != nil,
            micProcess: mic.map {
                displayName(forPid: $0.pid, bundleID: $0.bundleID) ?? Strings.current(.otherProcess)
            } ?? nil,
            camInUse: camInUse,
            // macOS 无按进程归属摄像头的公开 API：有摄像头占用但具体是哪个 App 不可知，
            // 交给 UI 显示"有其他进程在访问"，绝不编造应用名。
            camProcess: nil,
            supported: true)
        // onUpdate 写入被 @MainActor 隔离的 @Published，需切回主线程。
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(status)
        }
    }
}