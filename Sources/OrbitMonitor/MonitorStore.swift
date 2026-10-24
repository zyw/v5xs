import AppKit
import Combine
import MonitorCore
import Network
import ServiceManagement

enum Animal: String, CaseIterable, Identifiable {
    case cat = "猫"
    case rabbit = "兔"
    case fox = "狐"
    case dog = "狗"
    case horse = "马"
    case dinosaur = "恐龙"
    case frog = "青蛙"
    case chicken = "鸡"
    case duck = "鸭"
    case fish = "鱼"
    var id: String { rawValue }
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
    @Published var batteryStatus = "未提供电量"
    @Published var peripherals: [PeripheralBattery] = []
    @Published var processes: [ProcessReading] = []
    @Published var gpuCores: Int?
    @Published var chipName: String?
    @Published var networkType = "—"
    @Published var lowLatencyMode: Bool {
        didSet {
            UserDefaults.standard.set(lowLatencyMode, forKey: "lowLatencyMode")
            if timer != nil { configureTimer() }
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

    let machine = MachineDetails()
    private let sampler = SystemSampler()
    private let bluetoothMonitor = BluetoothBatteryMonitor()
    private var reportedPeripherals: [PeripheralBattery] = []
    private var blePeripherals: [PeripheralBattery] = []
    private var timer: Timer?
    private let pathMonitor = NWPathMonitor()
    private var lastSlowSample: Date?
    private var smoothedCPU: Double?

    var pace: AnimalPace {
        AnimalPace.forLoad(smoothedCPU ?? cpu ?? 0)
    }

    var thermalDescription: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "正常"
        case .fair: "略高"
        case .serious: "偏高"
        case .critical: "严重"
        @unknown default: "未知"
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
        lowLatencyMode = UserDefaults.standard.bool(forKey: "lowLatencyMode")
        appCacheDays = AppListCacheSetting.days
    }

    func start() {
        bluetoothMonitor.onUpdate = { [weak self] devices in
            self?.blePeripherals = devices
            self?.updatePeripherals()
        }
        bluetoothMonitor.start()
        sample()
        configureTimer()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let label: String
            if path.status != .satisfied { label = "离线" }
            else if path.usesInterfaceType(.wifi) { label = "Wi-Fi" }
            else if path.usesInterfaceType(.wiredEthernet) { label = "以太网" }
            else if path.usesInterfaceType(.cellular) { label = "蜂窝网络" }
            else { label = "网络" }
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

    private func configureTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: lowLatencyMode ? 0.5 : 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pathMonitor.cancel()
        bluetoothMonitor.onUpdate = nil
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
