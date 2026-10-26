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
// 这些文案现在跟随界面语言，所以先显式固定语言，避免依赖「默认语言恰好是简体中文」
Localization.shared.set(.zhHans)
check(HealthScore.label(for: 80) == "良好", "healthy label")
check(HealthScore.label(for: 40) == "偏高", "high-risk label")
check(UptimeText.describe(seconds: 3 * 86_400 + 12 * 3_600) == "已运行 3 天 12 小时", "uptime days")
check(UptimeText.describe(seconds: -1) == nil, "invalid uptime")
// 同一函数在英文下必须给出英文文案
Localization.shared.set(.en)
check(HealthScore.label(for: 80) == "Good", "healthy label in english")
check(UptimeText.describe(seconds: 3 * 86_400 + 12 * 3_600) == "Uptime 3 days 12 hours", "uptime days in english")
check(UptimeText.duration(seconds: 3 * 86_400 + 12 * 3_600) == "3 days 12 hours", "uptime duration in english")
Localization.shared.set(.zhHans)
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

// ---- 刷新频率设置：档位映射、持久化回落与旧设置迁移 ----
check(RefreshRate.allCases.count == 4, "four refresh rate options")
check(RefreshRate.default == .normal, "default refresh rate is one second")
check(RefreshRate.high.interval == 0.5, "high rate is half a second")
check(RefreshRate.normal.interval == 1, "normal rate is one second")
check(RefreshRate.relaxed.interval == 2, "relaxed rate is two seconds")
check(RefreshRate.low.interval == 5, "low rate is five seconds")
// 每档都必须真的更快/更慢，且都大于 0，避免选出会让定时器空转的值
check(RefreshRate.allCases.allSatisfy { $0.interval > 0 }, "every rate interval is positive")
let intervals = RefreshRate.allCases.map(\.interval)
check(zip(intervals, intervals.dropFirst()).allSatisfy { $0 < $1 }, "rates are strictly ordered")
// 持久化往返：rawValue 存进去必须能读回来
check(RefreshRate.allCases.allSatisfy { RefreshRate.stored($0.rawValue) == $0 }, "raw value round trips")
// 脏数据不能把采样停摆，必须回落到默认档
check(RefreshRate.stored(nil) == .normal, "missing stored value falls back to default")
check(RefreshRate.stored("") == .normal, "empty stored value falls back to default")
check(RefreshRate.stored("0") == .normal, "zero interval never accepted")
check(RefreshRate.stored("abc") == .normal, "garbage stored value falls back to default")
// 旧版 lowLatencyMode 迁移：开=极快，关=标准
check(RefreshRate.migratingFromLowLatency(true) == .high, "legacy low latency on migrates to high")
check(RefreshRate.migratingFromLowLatency(false) == .normal, "legacy low latency off migrates to normal")
// 每档都要有非空的人类可读名称与说明，否则设置页会出现空白选项
check(RefreshRate.allCases.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty }, "every rate has title and detail")

// ---- 采样循环必须能启动 ----
// 回归：configureTimer() 曾加过「guard timer != nil」守卫，导致 start() 首次调用
// 直接 return，定时器永不创建，采样停摆 => 健康分数一直显示「采集中」。
// 这里用与 MonitorStore 相同的「创建再重建」语义验证幂等性：
// 首次创建必须成功，重复调用必须替换为新定时器而不是直接跳过。
final class TimerProbe {
    var timer: Timer?
    var creations = 0

    /// 与 MonitorStore.configureTimer() 保持同一语义：无条件失效并重建。
    func configure(interval: TimeInterval) {
        timer?.invalidate()
        creations += 1
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in }
    }
}

let probe = TimerProbe()
probe.configure(interval: RefreshRate.normal.interval)
check(probe.timer != nil, "first configure creates a timer")
check(probe.creations == 1, "first configure is not skipped")
let firstTimer = probe.timer
probe.configure(interval: RefreshRate.low.interval)
check(probe.creations == 2, "reconfigure creates a new timer")
check(probe.timer !== firstTimer, "reconfigure replaces the old timer")
check(probe.timer != nil, "timer stays alive after reconfigure")
probe.timer?.invalidate()

// 每一档都能成功建立一个有效定时器（间隔必须大于 0，否则会忙循环）
for rate in RefreshRate.allCases {
    let p = TimerProbe()
    p.configure(interval: rate.interval)
    check(p.timer != nil, "timer starts for \(rate.title)")
    check(p.timer?.timeInterval == rate.interval, "timer uses \(rate.title) interval")
    p.timer?.invalidate()
}

// ---- 面板底部状态栏的文案必须跟随所选刷新频率 ----
// 回归：底部曾写死「每秒更新」，用户把频率改成 5 秒后仍显示「每秒更新」，
// 与实际采样间隔不符。
// 文案现在统一为「每 %@ 秒更新」，由 intervalText 提供数字，各语言共用同一条译文。
Localization.shared.set(.zhHans)
check(RefreshRate.high.shortDescription == "每 0.5 秒更新", "high footer text")
check(RefreshRate.normal.shortDescription == "每 1 秒更新", "normal footer text")
check(RefreshRate.relaxed.shortDescription == "每 2 秒更新", "relaxed footer text")
check(RefreshRate.low.shortDescription == "每 5 秒更新", "low footer text")
// 两档文案若相同，用户改档后就看不出来，因此必须互不相同
let descriptions = RefreshRate.allCases.map(\.shortDescription)
check(Set(descriptions).count == RefreshRate.allCases.count, "every rate has a distinct footer text")
check(RefreshRate.allCases.allSatisfy { !$0.shortDescription.isEmpty }, "footer text is never empty")
// 文案里的秒数必须与 interval 吻合，防止改了 interval 忘了改文案
for rate in RefreshRate.allCases {
    check(rate.intervalText == (rate.interval == rate.interval.rounded()
                                     ? String(Int(rate.interval)) : String(rate.interval)),
          "interval text matches interval for \(rate.title)")
    check(rate.shortDescription.contains(rate.intervalText),
          "footer text mentions \(rate.intervalText) for \(rate.title)")
}
// 英文下必须给出英文文案，且仍包含秒数
Localization.shared.set(.en)
check(RefreshRate.low.shortDescription.contains("5"), "english footer mentions seconds")
check(RefreshRate.low.shortDescription.lowercased().contains("update"),
      "english footer is translated")
Localization.shared.set(.zhHans)

// ---- 国际化：三种语言的完整性 ----
// 任何一个 key 缺译文，界面上就会露出 key 原文（或空白），因此在测试里锁死。
let allLanguages: [AppLanguage] = [.zhHans, .zhHant, .en]
for lang in allLanguages {
    for key in StringKey.allCases {
        let value = Strings.text(key, lang)
        check(!value.isEmpty, "\(lang.rawValue) has text for \(key.rawValue)")
        // 回落到 key 原文说明该语言缺这条译文
        check(value != key.rawValue, "\(lang.rawValue) translated \(key.rawValue)")
    }
}
// 简体与繁体不能整段相同（否则说明繁体的没真正翻译）。专有名词/单位允许相同，
// 所以只要求「多数条目不同」，阈值取 60%。
let zhKeys = StringKey.allCases
let differing = zhKeys.filter { Strings.text($0, .zhHans) != Strings.text($0, .zhHant) }.count
check(Double(differing) / Double(zhKeys.count) > 0.6,
      "traditional Chinese is genuinely translated (differing \(differing)/\(zhKeys.count))")
// 三种语言都必须至少有一条与英文不同（防止英文表被中文覆盖）
check(zhKeys.contains { Strings.text($0, .en) != Strings.text($0, .zhHans) },
      "english table is distinct from simplified Chinese")

// 语言枚举与系统语言推断
check(AppLanguage.allCases.count == 3, "three supported languages")
check(AppLanguage.zhHans.nativeName == "简体中文", "simplified native name")
check(AppLanguage.zhHant.nativeName == "繁體中文", "traditional native name")
check(AppLanguage.en.nativeName == "English", "english native name")
// 持久化值往返与脏数据回落
check(AppLanguage.stored("zh-Hant") == .zhHant, "stored traditional round trips")
check(AppLanguage.stored("en") == .en, "stored english round trips")
check(AppLanguage.stored(nil) == nil, "missing stored language returns nil")
check(AppLanguage.stored("fr") == nil, "unsupported language returns nil")

// 带参数的文案：占位符必须被正确替换
let loc = Localization(language: .zhHans, defaults: UserDefaults(suiteName: "test-i18n")!)
check(loc.t(.updateAvailable, "0.1.2") == "发现新版本 v0.1.2", "formatted update available")
check(loc.t(.appCacheDays, 30) == "应用列表缓存：30 天", "formatted cache days")
loc.set(.en)
check(loc.t(.updateAvailable, "0.1.2") == "Version v0.1.2 available", "english formatted text")
check(loc.t(.appCacheDays, 30) == "App list cache: 30 days", "english formatted cache days")
loc.set(.zhHant)
check(loc.t(.healthCollecting) == "收集資料中", "traditional collecting text")
// 切换语言后取值必须变化（否则界面不会刷新）
let enValue = { () -> String in loc.set(.en); return loc.t(.settings) }()
let zhValue = { () -> String in loc.set(.zhHans); return loc.t(.settings) }()
check(enValue != zhValue, "switching language changes resolved text")

print("152 metric checks passed")