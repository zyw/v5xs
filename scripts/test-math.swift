import Foundation
import MonitorCore

func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    guard condition() else {
        fputs("FAIL: \(name)\n", stderr)
        exit(1)
    }
}

check(abs((CPULoad.usage(previous: [100, 20, 300, 10], current: [130, 30, 400, 60]) ?? -1) - 47.37) < 0.01, "CPU delta")
check(CPULoad.usage(previous: [100, 20, 300, 10], current: [50, 20, 300, 10]) == nil, "CPU reset")
check(TrafficRate.between(previous: 1_000, current: 3_000, seconds: 2) == 1_000, "network rate")
check(TrafficRate.between(previous: 3_000, current: 1_000, seconds: 2) == nil, "network reset")
check(TrafficRate.between(previous: 1_000, current: 3_000, seconds: 0) == nil, "invalid interval")
check(TrafficRate.between(previous: 1_000, current: 3_000, seconds: 30) == nil, "sleep gap")
let oldDisk: [UInt64: DiskCounters] = [7: DiskCounters(read: 1_000, written: 2_000)]
let newDisk: [UInt64: DiskCounters] = [7: DiskCounters(read: 3_000, written: 2_500)]
check(DiskTraffic.rates(previous: oldDisk, current: newDisk, seconds: 2)?.read == 1_000, "disk read rate")
check(DiskTraffic.rates(previous: oldDisk, current: newDisk, seconds: 2)?.write == 250, "disk write rate")
check(DiskTraffic.rates(previous: oldDisk, current: [7: DiskCounters(read: 500, written: 2_500)], seconds: 2) == nil, "disk counter reset")
check(DiskTraffic.rates(previous: oldDisk, current: newDisk, seconds: 0) == nil, "disk invalid interval")
check(DiskTraffic.rates(previous: oldDisk, current: newDisk, seconds: 30) == nil, "disk sleep gap")
check(DiskTraffic.rates(previous: oldDisk, current: [8: DiskCounters(read: 3_000, written: 2_500)], seconds: 2) == nil, "disk replacement")
check(abs(1 / AnimalPace.forLoad(0).frameInterval - 5) < 0.01, "idle animation runs at five frames per second")
check(abs(1 / AnimalPace.forLoad(50).frameInterval - 17.5) < 0.01, "half CPU runs at 17.5 frames per second")
check(abs(1 / AnimalPace.forLoad(100).frameInterval - 30) < 0.01, "full CPU runs at 30 frames per second")
check(abs(1 / AnimalPace.forLoad(-20).frameInterval - 5) < 0.01, "CPU below zero is clamped")
check(abs(1 / AnimalPace.forLoad(130).frameInterval - 30) < 0.01, "CPU above 100 is clamped")
check(GPUMetadata.coreCount(from: Data(#"{"SPDisplaysDataType":[{"_name":"Apple M2","sppci_cores":"8"}]}"#.utf8)) == 8, "GPU core JSON")
check(GPUMetadata.coreCount(from: Data("{}".utf8)) == nil, "absent GPU count")
check(GPUMetadata.chipName(from: Data(#"{"SPDisplaysDataType":[{"_name":"Apple M2","sppci_cores":"8"}]}"#.utf8)) == "M2", "chip name")
check(GPULoad.usage(from: ["Device Utilization %": 79]) == 79, "GPU device utilization")
check(GPULoad.usage(from: ["Device Utilization %": -1]) == nil, "invalid GPU negative")
check(GPULoad.usage(from: ["Device Utilization %": 101]) == nil, "invalid GPU over 100")
check(GPULoad.usage(from: ["Renderer Utilization %": 78]) == nil, "no device utilization")
check(abs((SMCTemperatures.decodeFloat(bytes: [0x75, 0x20, 0x40, 0x42], type: [0x20, 0x74, 0x6c, 0x66]) ?? 0) - 48.03) < 0.01, "SMC float")
check(SMCTemperatures.decodeFloat(bytes: [0x75, 0x20, 0x40, 0x42], type: [0, 0, 0, 0]) == nil, "SMC type")
check(SMCTemperatures.cpu(from: ["Tp01": 48, "Tp05": 46, "Tp09": 50, "Tp0D": 48]) == 48, "verified M2 CPU sensors")
check(SMCTemperatures.cpu(from: ["Tp01": 48, "Tp05": 46, "Tp09": 50]) == nil, "incomplete CPU sensors")
check(SMCTemperatures.gpu(from: ["Tg0f": 42]) == 42, "verified M2 GPU sensor")
check(SMCTemperatures.gpu(from: ["Tg0f": 135]) == nil, "invalid GPU temperature")
check(SMCKeyEncoding.bytes("Tp01") == [0x31, 0x30, 0x70, 0x54], "SMC key little endian")
check(HealthScore.value(cpu: 10, memoryFraction: 0.4, thermal: .nominal) == 100, "healthy score")
check(HealthScore.value(cpu: 80, memoryFraction: 0.9, thermal: .fair) == 76, "elevated score")
check(HealthScore.value(cpu: nil, memoryFraction: 0.4, thermal: .nominal) == nil, "missing CPU score")
check(HealthScore.label(for: 80) == "良好", "healthy label")
check(HealthScore.label(for: 40) == "偏高", "high-risk label")
check(UptimeText.describe(seconds: 3 * 86_400 + 12 * 3_600) == "3天 12小时", "uptime days")
check(UptimeText.describe(seconds: -1) == nil, "invalid uptime")
check(PeripheralBattery.parse(["Product": "Magic Mouse", "Transport": "Bluetooth", "BatteryPercent": 84])?.percentage == 84, "HID battery")
check(PeripheralBattery.parse(["Product": "Internal", "Transport": "USB", "BatteryPercent": 80]) == nil, "internal device")
check(PeripheralBattery.parse(["Product": "Mouse", "Transport": "Bluetooth", "BatteryPercent": 140]) == nil, "invalid battery")
let bluetoothReport = Data(#"{"SPBluetoothDataType":[{"device_connected":[{"F99-BT5.0 ":{"device_minorType":"Keyboard","device_batteryLevelMain":"100%"}},{"RAPOO 5.0MS":{"device_minorType":"Mouse"}}]}]}"#.utf8)
check(PeripheralBattery.fromBluetoothReport(bluetoothReport).first?.percentage == 100, "connected keyboard battery")
check(PeripheralBattery.fromBluetoothReport(bluetoothReport).first?.kind == .keyboard, "keyboard type without name hint")
check(PeripheralBattery.fromBluetoothReport(bluetoothReport).count == 1, "missing mouse battery is not fabricated")
check(PeripheralBattery.parse(["Product": "Generic", "Transport": "Bluetooth Low Energy", "PrimaryUsage": 2, "BatteryPercent": 52])?.kind == .mouse, "HID mouse usage")
check(PeripheralBattery.deviceKinds(fromBluetoothReport: bluetoothReport)["RAPOO 5.0MS"] == .mouse, "connected mouse type without reported battery")
check(PeripheralBattery.fromBLE(name: "RAPOO 5.0MS", kind: .mouse, value: Data([65]))?.percentage == 65, "BLE battery characteristic")
check(PeripheralBattery.fromBLE(name: "RAPOO 5.0MS", kind: .mouse, value: Data([255])) == nil, "invalid BLE battery value")
check(ProcessIdentity.matches(expectedPath: "/Applications/Foo.app/Contents/MacOS/Foo", expectedStart: "Thu Oct 22 19:59:09 2026", observedPath: "/Applications/Foo.app/Contents/MacOS/Foo", observedStart: "Thu Oct 22 19:59:09 2026"), "same process identity")
check(!ProcessIdentity.matches(expectedPath: "/Applications/Foo.app/Contents/MacOS/Foo", expectedStart: "Thu Oct 22 19:59:09 2026", observedPath: "/Applications/Foo.app/Contents/MacOS/Foo", observedStart: "Thu Oct 22 20:00:00 2026"), "reused PID start")
check(!ProcessIdentity.matches(expectedPath: "/Applications/Foo.app/Contents/MacOS/Foo", expectedStart: "Thu Oct 22 19:59:09 2026", observedPath: nil, observedStart: nil), "exited process")
// 解析器不再从 ps 文本里取路径/启动时间（ps 的 comm 会被内核截断到 16 字节、
// lstart 是本地化文本），改为按 pid 走 libproc 查真实身份。因此这里断言的是：
// ps 行里的 CPU/RSS 被正确解析，而路径与启动时间来自进程自身。
let selfPid = String(getpid())
let selfPath = ProcessInspector.executablePath(of: getpid())
check(selfPath != nil, "libproc resolves own executable path")
check(ProcessInspector.startEpoch(of: getpid()) != nil, "libproc resolves own start epoch")
// 自身进程在解析时被主动排除（避免自己杀自己）
check(ProcessReading.parse(selfPid + " 0.0 1024 Thu Oct 22 19:59:09 2026 " + (selfPath ?? "/bin/foo")) == nil,
      "own process is excluded")
// 不存在的 pid 必须解析失败，而不是返回一个路径错误/时间错误的条目
check(ProcessReading.parse("999999 1.1 33312 Thu Oct 22 19:59:09 2026 /Applications/Foo Bar.app/Contents/MacOS/Foo") == nil,
      "nonexistent pid is rejected")
// 真实存在但不是自己的进程：路径必须是完整路径（含空格也没问题）
let otherPid = getppid()
if let other = ProcessInspector.executablePath(of: otherPid) {
    let line = "\(otherPid) 0.0 1024 Thu Oct 22 19:59:09 2026 \(other)"
    let parsed = ProcessReading.parse(line)
    check(parsed?.executablePath == other, "process path comes from libproc, not ps text")
    if let start = ProcessInspector.startEpoch(of: otherPid) {
        check(parsed?.startTime == start, "process start is epoch seconds from sysctl")
        check(Int64(parsed?.startTime ?? "x") != nil, "start time is numeric epoch")
    }
}
// 更新清单解析：契约字段、架构回落、版本比较与错误分支。
let feedSample = Data(#"""
{"version":"0.2.0","build":2,"minimumSystemVersion":"14.0","publishedAt":"2026-10-25T10:00:00Z",
 "notes":"修复若干问题","downloads":[
   {"architecture":"arm64","url":"https://example.com/v5xs-arm64.dmg","size":12345678,
    "sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"},
   {"architecture":"universal","url":"https://example.com/v5xs-universal.dmg"}]}
"""#.utf8)
let feedRelease = try UpdateFeed.release(from: feedSample)
check(feedRelease.version == "0.2.0", "feed version")
check(feedRelease.build == 2, "feed build")
check(feedRelease.minimumSystemVersion == "14.0", "feed minimum system")
check(feedRelease.downloads.count == 2, "feed downloads")
check(feedRelease.downloads.first?.size == 12_345_678, "feed download size")
check(feedRelease.downloads.last?.size == nil, "absent download size stays nil")
check(feedRelease.publishedAt == ISO8601DateFormatter().date(from: "2026-10-25T10:00:00Z"), "feed published date")
check(UpdateFeed.download(for: feedRelease, architecture: "arm64")?.architecture == "arm64", "feed exact arch")
check(UpdateFeed.download(for: feedRelease, architecture: "ARM64")?.architecture == "arm64", "feed arch is case insensitive")
check(UpdateFeed.download(for: feedRelease, architecture: "x86_64")?.architecture == "universal", "feed universal fallback")
check(UpdateFeed.download(for: feedRelease, architecture: "  ") == nil, "feed blank arch")
check(UpdateFeed.isNewer(feedRelease, thanBuild: 1, currentVersion: "0.1.0"), "newer build")
check(!UpdateFeed.isNewer(feedRelease, thanBuild: 2, currentVersion: "0.2.0"), "same build same version")
check(!UpdateFeed.isNewer(feedRelease, thanBuild: 3, currentVersion: "0.1.0"), "older build")
check(UpdateFeed.isNewer(feedRelease, thanBuild: 2, currentVersion: "0.1.9"), "same build higher version")
check(!UpdateFeed.isNewer(feedRelease, thanBuild: 2, currentVersion: "0.10.0"), "same build lower version")
check(UpdateFeed.compareVersions("1.2.10", "1.2.9") == 1, "version comparison is numeric")
check(UpdateFeed.compareVersions("0.2.0", "0.2") == 0, "version missing component is zero")
check(UpdateFeed.satisfiesMinimumSystem(nil, currentVersion: "14.0.0"), "absent minimum system")
check(!UpdateFeed.satisfiesMinimumSystem("15.0", currentVersion: "14.6.1"), "unmet minimum system")

func expectFeedError(_ json: String, _ expected: UpdateFeedError, _ name: String) {
    do {
        _ = try UpdateFeed.release(from: Data(json.utf8))
        check(false, name + " (did not throw)")
    } catch {
        check((error as? UpdateFeedError) == expected, name)
    }
}
expectFeedError(#"{"build":2,"downloads":[{"architecture":"arm64","url":"https://e.com/a.dmg"}]}"#, .missingVersion, "feed missing version")
expectFeedError(#"{"version":"0.2.0","build":2}"#, .missingDownloads, "feed missing downloads")
expectFeedError(#"{"version":"0.2.0","build":2,"downloads":[]}"#, .missingDownloads, "feed empty downloads")
expectFeedError("not json", .malformed, "feed malformed json")
expectFeedError(#"{"version":"0.2.0","downloads":[{"architecture":"arm64","url":"https://e.com/a.dmg"}]}"#, .malformed, "feed missing build")
expectFeedError(#"{"version":"0.2.0","build":2,"downloads":[{"architecture":"arm64","url":"file:///tmp/a.dmg"}]}"#, .malformed, "feed non http url")
// ---- ProcessIdentity：进程终止前的一致性校验（防杀错进程） ----
// 内核 p_comm 只有 MAXCOMLEN(16) 字节，ps -o comm= 对长路径必然截断，
// 截断值绝不能与完整 executablePath 判为同一进程。
let longPath = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/155.0.8059.86/Helpers/Google Chrome Helper (Aperitif Renderer).app/Contents/MacOS/Google Chrome Helper (Aperitif Renderer)"
check(!ProcessIdentity.matches(expectedPath: longPath, expectedStart: "Mon Oct 26 16:07:47 2026",
                               observedPath: "Google Chrome He", observedStart: "Mon Oct 26 16:07:47 2026"),
      "truncated comm must not match full path")
check(ProcessIdentity.matches(expectedPath: "/usr/bin/java", expectedStart: "1793002067",
                              observedPath: "/usr/bin/java", observedStart: "1793002067"),
      "identical path and start time match")
check(!ProcessIdentity.matches(expectedPath: "/usr/bin/java", expectedStart: "1793002067",
                               observedPath: "/usr/bin/java", observedStart: "1793002100"),
      "same path different start is a different process")
check(!ProcessIdentity.matches(expectedPath: "", expectedStart: "1", observedPath: "", observedStart: "1"),
      "empty expected path never matches")
check(!ProcessIdentity.matches(expectedPath: "/a", expectedStart: "", observedPath: "/a", observedStart: ""),
      "empty expected start never matches")
check(!ProcessIdentity.matches(expectedPath: "/a", expectedStart: "1", observedPath: nil, observedStart: "1"),
      "nil observed path never matches")
check(!ProcessIdentity.matches(expectedPath: "/a", expectedStart: "1", observedPath: "/a", observedStart: nil),
      "nil observed start never matches")
check(!ProcessIdentity.matches(expectedPath: longPath, expectedStart: "1793002067",
                               observedPath: longPath, observedStart: "1793009999"),
      "recycled pid with same path is rejected")

print("85 metric checks passed")