import AppKit
import Combine
import MonitorCore
import Network
import ServiceManagement

/// 菜单栏动物形象。
///
/// `rawValue` 是**持久化标识**，必须保持不变（用户已保存的选择依赖它）；
/// 界面上显示的名称一律走 `displayName`，跟随界面语言。
enum Animal: String, CaseIterable, Identifiable {
    case cat, rabbit, fox, dog, horse, dinosaur, frog, chicken, duck, fish

    var id: String { rawValue }

    /// 跟随界面语言的显示名。
    var displayName: String {
        switch self {
        case .cat: return Strings.current(.animalCat)
        case .rabbit: return Strings.current(.animalRabbit)
        case .fox: return Strings.current(.animalFox)
        case .dog: return Strings.current(.animalDog)
        case .horse: return Strings.current(.animalHorse)
        case .dinosaur: return Strings.current(.animalDinosaur)
        case .frog: return Strings.current(.animalFrog)
        case .chicken: return Strings.current(.animalChicken)
        case .duck: return Strings.current(.animalDuck)
        case .fish: return Strings.current(.animalFish)
        }
    }
}

@MainActor
final class MonitorStore: ObservableObject {
    @Published var cpu: Double?
    @Published var memoryUsed: UInt64?
    @Published var diskAvailable: Int64?
    @Published var diskTotal: Int64?
    @Published var diskRead: Double?
    @Published var diskWrite: Double?
    @Published var batteryPercentage: Int?
    @Published var batteryStatus = Strings.current(.batteryNoInfo)
    @Published var peripherals: [PeripheralBattery] = []
    @Published var processes: [ProcessReading] = []
    @Published var gpuCores: Int?
    @Published var chipName: String?
    @Published var networkType = "—"
    /// 监测页面的采样频率。改后立即重建定时器，无需重启。
    @Published var refreshRate: RefreshRate {
        didSet {
            guard oldValue != refreshRate else { return }
            UserDefaults.standard.set(refreshRate.rawValue, forKey: Self.refreshRateKey)
            configureTimer()
        }
    }
    @Published var gpuUsage: Double?
    @Published var gpuHistory: [MetricPoint] = []
    @Published var cpuTemperature: Double?
    @Published var gpuTemperature: Double?
    @Published var cpuHistory: [MetricPoint] = []
    @Published var networkHistory: [NetworkPoint] = []
    @Published var download: Double?
    @Published var upload: Double?
    @Published var animal: Animal {
        didSet { UserDefaults.standard.set(animal.rawValue, forKey: "animal") }
    }
    @Published var animationPaused: Bool {
        didSet { UserDefaults.standard.set(animationPaused, forKey: "animationPaused") }
    }
    /// 已安装应用列表缓存时长（天）。改后立即写入，卸载窗口下次读取新值。
    @Published var appCacheDays: Double {
        didSet { AppListCacheSetting.set(appCacheDays) }
    }
    /// 摄像头 / 麦克风占用状态（用于面板里的「隐私」条）。
    @Published var micInUse = false
    @Published var micProcess: String?
    @Published var camInUse = false
    @Published var camProcess: String?

    let machine = MachineDetails()
    private let sampler = SystemSampler()
    private let bluetoothMonitor = BluetoothBatteryMonitor()
    private let privacyMonitor = PrivacyMonitor()
    private var reportedPeripherals: [PeripheralBattery] = []
    private var blePeripherals: [PeripheralBattery] = []
    private var timer: Timer?
    private static let refreshRateKey = "refreshRate"
    private static let legacyLowLatencyKey = "lowLatencyMode"
    private let pathMonitor = NWPathMonitor()
    private var lastSlowSample: Date?
    private var smoothedCPU: Double?

    var pace: AnimalPace {
        AnimalPace.forLoad(smoothedCPU ?? cpu ?? 0)
    }

    var thermalDescription: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: Strings.current(.thermalNominal)
        case .fair: Strings.current(.thermalFair)
        case .serious: Strings.current(.thermalSerious)
        case .critical: Strings.current(.thermalCritical)
        @unknown default: Strings.current(.unknown)
        }
    }

    var thermalLevel: ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .fair
        }
    }

    var healthScore: Int? {
        HealthScore.value(
            cpu: smoothedCPU,
            memoryFraction: memoryUsed.map { Double($0) / Double(max(machine.memoryBytes, 1)) },
            thermal: thermalLevel
        )
    }

    init() {
        animal = Animal(rawValue: UserDefaults.standard.string(forKey: "animal") ?? "") ?? .cat
        animationPaused = UserDefaults.standard.bool(forKey: "animationPaused")
        // 旧版本只有一个 lowLatencyMode 布尔开关，迁移到新的多档刷新频率后继续生效。
        // 注意先算出值再赋给属性：refreshRate 带 didSet，赋值时读取 self 会触发
        // 「used before all stored properties are initialized」，所以全程用局部变量。
        let defaults = UserDefaults.standard
        let initialRate: RefreshRate
        if let stored = defaults.string(forKey: Self.refreshRateKey) {
            initialRate = RefreshRate.stored(stored)
        } else {
            initialRate = RefreshRate.migratingFromLowLatency(
                defaults.bool(forKey: Self.legacyLowLatencyKey)
            )
            defaults.set(initialRate.rawValue, forKey: Self.refreshRateKey)
        }
        refreshRate = initialRate
        appCacheDays = AppListCacheSetting.days
    }

    func start() {
        bluetoothMonitor.onUpdate = { [weak self] devices in
            self?.blePeripherals = devices
            self?.updatePeripherals()
        }
        bluetoothMonitor.start()
        privacyMonitor.onUpdate = { [weak self] status in
            guard let self else { return }
            self.micInUse = status.micInUse
            self.micProcess = status.micProcess
            self.camInUse = status.camInUse
            self.camProcess = status.camProcess
        }
        refreshPrivacy()
        sample()
        configureTimer()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let label: String
            if path.status != .satisfied { label = Strings.current(.netOffline) }
            else if path.usesInterfaceType(.wifi) { label = Strings.current(.netWifi) }
            else if path.usesInterfaceType(.wiredEthernet) { label = Strings.current(.netEthernet) }
            else if path.usesInterfaceType(.cellular) { label = Strings.current(.netCellular) }
            else { label = Strings.current(.netOther) }
            Task { @MainActor [weak self] in self?.networkType = label }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let details = SystemSampler.gpuDetails()
            DispatchQueue.main.async { [weak self] in
                self?.gpuCores = details.cores
                self?.chipName = details.chipName
            }
        }
    }

    /// 按当前刷新频率（重新）创建采样定时器。
    ///
    /// 注意：这里**不能**加 `guard timer != nil` 之类的「已在运行才处理」判断。
    /// `start()` 首次调用本方法时 `timer` 必然是 nil，加了守卫就等于永不创建定时器，
    /// 采样循环彻底停摆，健康分数会一直停在「采集中」（这个 bug 真实发生过）。
    /// 本方法应当是无条件幂等的：先失效旧定时器，再按当前频率建新的。
    private func configureTimer() {
        timer?.invalidate()
        let interval = refreshRate.interval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sample() }
        }
        // 只放宽、不收紧：系统默认容差约为间隔的 10%，这里取同样的 10% 但封顶 0.5 秒。
        // 容差允许系统合并唤醒，菜单栏常驻应用因此更省电；不要设得比默认更小，
        // 那只会增加唤醒次数。注意不能让容差超过间隔本身，否则采样会被明显拖慢。
        timer?.tolerance = min(interval * 0.1, 0.5, interval * 0.5)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pathMonitor.cancel()
        bluetoothMonitor.onUpdate = nil
        privacyMonitor.onUpdate = nil
    }

    /// 隐私状态轮询（CoreAudio 进程对象，比 1s 采样更重，降低到 5s）。
    private func refreshPrivacy() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.privacyMonitor.refresh()
        }
    }

    private func sample() {
        let now = Date()
        if let value = sampler.cpuUsage() {
            cpu = value
            smoothedCPU = (smoothedCPU ?? value) * 0.4 + value * 0.6
            cpuHistory.append(MetricPoint(time: now, value: value))
            cpuHistory = Array(cpuHistory.suffix(300))
        }
        gpuUsage = SystemSampler.gpuUsage()
        if let gpuUsage {
            gpuHistory.append(MetricPoint(time: now, value: gpuUsage))
            gpuHistory = Array(gpuHistory.suffix(60))
        } else {
            gpuHistory.removeAll()
        }
        if let rates = sampler.networkRates(at: now) {
            download = rates.download
            upload = rates.upload
            networkHistory.append(NetworkPoint(time: now, download: rates.download, upload: rates.upload))
            networkHistory = Array(networkHistory.suffix(300))
        } else {
            download = nil
            upload = nil
            if let last = networkHistory.last, now.timeIntervalSince(last.time) > 10 {
                networkHistory.removeAll()
            }
        }
        if let rates = sampler.diskRates(at: now) {
            diskRead = rates.read
            diskWrite = rates.write
        } else {
            diskRead = nil
            diskWrite = nil
        }
        if let lastSlowSample, now.timeIntervalSince(lastSlowSample) < 15 { return }
        lastSlowSample = now
        refreshPrivacy()
        let temperatures = SystemSampler.temperatures()
        cpuTemperature = temperatures.cpu
        gpuTemperature = temperatures.gpu
        memoryUsed = SystemSampler.memoryUsedBytes()
        if let disk = SystemSampler.diskSpace() {
            diskAvailable = disk.available
            diskTotal = disk.total
        } else {
            diskAvailable = nil
            diskTotal = nil
        }
        if let battery = SystemSampler.battery() {
            batteryPercentage = battery.percentage
            batteryStatus = battery.status
        }
        bluetoothMonitor.refresh()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = SystemSampler.peripheralSnapshot()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reportedPeripherals = snapshot.batteries
                if !snapshot.kinds.isEmpty {
                    self.bluetoothMonitor.updateKinds(snapshot.kinds)
                }
                self.updatePeripherals()
            }
        }
        refreshProcesses()
    }

    private func updatePeripherals() {
        var byName = Dictionary(uniqueKeysWithValues: reportedPeripherals.map { ($0.name, $0) })
        for battery in blePeripherals { byName[battery.name] = battery }
        peripherals = byName.values.sorted { $0.name < $1.name }
    }

    func refreshProcesses() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let current = SystemSampler.processes()
            DispatchQueue.main.async { [weak self] in self?.processes = current }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }
}
