import Darwin
import Foundation
import IOKit
import IOKit.ps

public struct MetricPoint: Identifiable, Sendable {
    public let time: Date
    public let value: Double
    public var id: Date { time }

    public init(time: Date, value: Double) {
        self.time = time
        self.value = value
    }
}

public struct NetworkPoint: Identifiable, Sendable {
    public let time: Date
    public let download: Double
    public let upload: Double
    public var id: Date { time }

    public init(time: Date, download: Double, upload: Double) {
        self.time = time
        self.download = download
        self.upload = upload
    }
}

public struct ProcessReading: Identifiable, Sendable {
    public let pid: Int32
    public let name: String
    public let executablePath: String
    public let startTime: String
    public let memoryBytes: UInt64
    public let cpuPercent: Double
    public var id: Int32 { pid }

    public init(pid: Int32, name: String, executablePath: String, startTime: String, memoryBytes: UInt64, cpuPercent: Double) {
        self.pid = pid
        self.name = name
        self.executablePath = executablePath
        self.startTime = startTime
        self.memoryBytes = memoryBytes
        self.cpuPercent = cpuPercent
    }

    public static func parse(_ line: String) -> ProcessReading? {
        let parts = line.split(maxSplits: 8, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard parts.count == 9,
              let pid = Int32(parts[0]),
              let cpu = Double(parts[1]),
              let rss = UInt64(parts[2]),
              pid != getpid() else { return nil }

        // 路径与启动时间一律以 libproc/sysctl 为准，不用 ps 的输出：
        // `ps -o comm=` 来自内核 p_comm（仅 MAXCOMLEN=16 字节），长路径会被截断，
        // 截断值既不是完整路径、也无法与完整路径比对，后续「终止」必然误判。
        // `ps lstart=` 是本地化文本，随 locale/时区变化，不适合做身份比对。
        guard let identity = ProcessInspector.identity(of: pid) else { return nil }

        let name: String
        if let appRange = identity.path.range(of: ".app/", options: .backwards) {
            let bundlePath = String(identity.path[..<appRange.lowerBound])
            name = URL(fileURLWithPath: bundlePath).lastPathComponent
        } else {
            name = URL(fileURLWithPath: identity.path).lastPathComponent
        }
        return ProcessReading(
            pid: pid,
            name: name,
            executablePath: identity.path,
            startTime: identity.start,
            memoryBytes: rss * 1024,
            cpuPercent: cpu
        )
    }
}

public struct MachineDetails: Sendable {
    public let cpuCores: Int
    public let performanceCores: Int?
    public let efficiencyCores: Int?
    public let memoryBytes: UInt64
    public let bootTime: Date?

    public init() {
        cpuCores = ProcessInfo.processInfo.processorCount
        performanceCores = Self.sysctlInt("hw.perflevel0.physicalcpu")
        efficiencyCores = Self.sysctlInt("hw.perflevel1.physicalcpu")
        memoryBytes = ProcessInfo.processInfo.physicalMemory
        var boot = timeval()
        var bootSize = MemoryLayout<timeval>.size
        bootTime = sysctlbyname("kern.boottime", &boot, &bootSize, nil, 0) == 0
            ? Date(timeIntervalSince1970: TimeInterval(boot.tv_sec)) : nil
    }

    private static func sysctlInt(_ key: String) -> Int? {
        var result: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(key, &result, &size, nil, 0) == 0, result > 0 else { return nil }
        return Int(result)
    }
}

public final class SystemSampler {
    private var previousCPU: [UInt64]?
    private var previousNetwork: (download: UInt64, upload: UInt64, time: Date)?
    private var previousDisk: (counters: [UInt64: DiskCounters], time: Date)?

    public init() {}

    public func cpuUsage() -> Double? {
        guard let current = Self.cpuTicks() else { return nil }
        defer { previousCPU = current }
        guard let previousCPU else { return nil }
        return CPULoad.usage(previous: previousCPU, current: current)
    }

    public func networkRates(at time: Date = Date()) -> (download: Double, upload: Double)? {
        guard let current = Self.networkBytes() else { return nil }
        defer { previousNetwork = (current.download, current.upload, time) }
        guard let previousNetwork else { return nil }
        let interval = time.timeIntervalSince(previousNetwork.time)
        guard let download = TrafficRate.between(previous: previousNetwork.download, current: current.download, seconds: interval),
              let upload = TrafficRate.between(previous: previousNetwork.upload, current: current.upload, seconds: interval)
        else { return nil }
        return (download, upload)
    }

    public func diskRates(at time: Date = Date()) -> (read: Double, write: Double)? {
        guard let current = Self.diskCounters() else {
            previousDisk = nil
            return nil
        }
        defer { previousDisk = (current, time) }
        guard let previousDisk else { return nil }
        return DiskTraffic.rates(
            previous: previousDisk.counters,
            current: current,
            seconds: time.timeIntervalSince(previousDisk.time)
        )
    }

    public static func memoryUsedBytes() -> UInt64? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        let pages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return pages * UInt64(pageSize)
    }

    public static func diskSpace() -> (available: Int64, total: Int64)? {
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey]
        ), let total = values.volumeTotalCapacity else { return nil }
        let available = values.volumeAvailableCapacityForImportantUsage
        let fallback = values.volumeAvailableCapacity.map(Int64.init)
        guard let capacity = [available, fallback].compactMap({ $0 }).first(where: { $0 > 0 }) ?? fallback ?? available
        else { return nil }
        return (capacity, Int64(total))
    }

    public static func battery() -> (percentage: Int, status: String)? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let details = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any],
                  details[kIOPSTypeKey as String] as? String == kIOPSInternalBatteryType
            else { continue }
            let current = details[kIOPSCurrentCapacityKey as String] as? Int ?? 0
            let maximum = details[kIOPSMaxCapacityKey as String] as? Int ?? 0
            guard maximum > 0 else { continue }
            let percentage = min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded())))
            let connected = details[kIOPSPowerSourceStateKey as String] as? String == kIOPSACPowerValue
            return (percentage, connected ? Strings.current(.batteryConnected) : Strings.current(.batteryOnBattery))
        }
        return nil
    }

    public static func peripherals() -> [PeripheralBattery] {
        peripheralSnapshot().batteries
    }

    public static func peripheralSnapshot() -> (batteries: [PeripheralBattery], kinds: [String: PeripheralBattery.Kind]) {
        var found: [String: PeripheralBattery] = [:]
        var kinds: [String: PeripheralBattery.Kind] = [:]
        for serviceClass in ["IOHIDDevice", "AppleDeviceManagementHIDEventService"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(serviceClass), &iterator) == KERN_SUCCESS
            else { continue }
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                var properties: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let values = properties?.takeRetainedValue() as? [String: Any],
                      let battery = PeripheralBattery.parse(values)
                else { continue }
                found[battery.name] = battery
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                kinds = PeripheralBattery.deviceKinds(fromBluetoothReport: data)
                for battery in PeripheralBattery.fromBluetoothReport(data) {
                    found[battery.name] = battery
                }
            }
        }
        return (found.values.sorted { $0.name < $1.name }, kinds)
    }

    public static func gpuDetails() -> (cores: Int?, chipName: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPDisplaysDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (nil, nil) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return (nil, nil) }
        return (GPUMetadata.coreCount(from: data), GPUMetadata.chipName(from: data))
    }

    public static func gpuUsage() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var readings: [Double] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let statistics = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any],
                  let usage = GPULoad.usage(from: statistics) else { continue }
            readings.append(usage)
        }
        return readings.count == 1 ? readings[0] : nil
    }

    public static func temperatures() -> (cpu: Double?, gpu: Double?) {
        guard SMCTemperatureReader.supportedModel else { return (nil, nil) }
        let readings = SMCTemperatureReader.readings()
        return (SMCTemperatures.cpu(from: readings), SMCTemperatures.gpu(from: readings))
    }

    public static func processes() -> [ProcessReading] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-A", "-o", "pid=,pcpu=,rss=,lstart=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { ProcessReading.parse(String($0)) }
        .sorted { $0.memoryBytes > $1.memoryBytes }
        .prefix(5)
        .map { $0 }
    }

    private static func cpuTicks() -> [UInt64]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.size))
        }
        var total = [UInt64](repeating: 0, count: 4)
        for core in 0..<Int(cpuCount) {
            for state in 0..<4 {
                total[state] += UInt64(UInt32(bitPattern: info[core * 4 + state]))
            }
        }
        return total
    }

    private static func networkBytes() -> (download: UInt64, upload: UInt64)? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return nil }
        defer { freeifaddrs(first) }
        var download: UInt64 = 0
        var upload: UInt64 = 0
        var cursor = first
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            guard entry.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  entry.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let data = entry.ifa_data else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            download += UInt64(stats.ifi_ibytes)
            upload += UInt64(stats.ifi_obytes)
        }
        return (download, upload)
    }

    private static func diskCounters() -> [UInt64: DiskCounters]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var result: [UInt64: DiskCounters] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS,
                  let property = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let read = property["Bytes (Read)"] as? NSNumber,
                  let written = property["Bytes (Write)"] as? NSNumber
            else { continue }
            result[id] = DiskCounters(read: read.uint64Value, written: written.uint64Value)
        }
        return result.isEmpty ? nil : result
    }
}
