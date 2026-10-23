import Foundation

public enum CPULoad {
    public static func usage(previous: [UInt64], current: [UInt64]) -> Double? {
        guard previous.count == 4, current.count == 4 else { return nil }
        let deltas = zip(previous, current).map { old, new -> UInt64? in
            new >= old ? new - old : nil
        }
        guard deltas.allSatisfy({ $0 != nil }) else { return nil }
        let values = deltas.compactMap { $0 }
        let total = values.reduce(0, +)
        guard total > 0 else { return nil }
        return Double(total - values[2]) / Double(total) * 100
    }
}

public enum TrafficRate {
    public static func between(previous: UInt64, current: UInt64, seconds: Double) -> Double? {
        guard seconds > 0, seconds <= 10, current >= previous else { return nil }
        return Double(current - previous) / seconds
    }
}

public struct DiskCounters: Sendable {
    public let read: UInt64
    public let written: UInt64

    public init(read: UInt64, written: UInt64) {
        self.read = read
        self.written = written
    }
}

public enum DiskTraffic {
    public static func rates(
        previous: [UInt64: DiskCounters],
        current: [UInt64: DiskCounters],
        seconds: Double
    ) -> (read: Double, write: Double)? {
        guard !previous.isEmpty, previous.keys == current.keys else { return nil }
        var read = 0.0
        var write = 0.0
        for (id, counters) in current {
            guard let old = previous[id],
                  let readRate = TrafficRate.between(previous: old.read, current: counters.read, seconds: seconds),
                  let writeRate = TrafficRate.between(previous: old.written, current: counters.written, seconds: seconds)
            else { return nil }
            read += readRate
            write += writeRate
        }
        return (read, write)
    }
}

public struct AnimalPace: Sendable {
    public let frameInterval: TimeInterval

    public static func forLoad(_ percent: Double) -> AnimalPace {
        let load = percent.isFinite ? min(max(percent, 0), 100) : 0
        return AnimalPace(frameInterval: 0.30 - 0.245 * load / 100)
    }
}

public enum GPUMetadata {
    public static func coreCount(from data: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cards = root["SPDisplaysDataType"] as? [[String: Any]]
        else { return nil }
        return cards.lazy.compactMap {
            Int($0["sppci_cores"] as? String ?? "")
        }.first
    }

    public static func chipName(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cards = root["SPDisplaysDataType"] as? [[String: Any]],
              let name = cards.compactMap({ $0["_name"] as? String }).first(where: { $0.hasPrefix("Apple ") })
        else { return nil }
        return String(name.dropFirst("Apple ".count))
    }
}

public enum ThermalLevel: Sendable {
    case nominal, fair, serious, critical
}

public enum HealthScore {
    public static func value(cpu: Double?, memoryFraction: Double?, thermal: ThermalLevel) -> Int? {
        guard let cpu, cpu.isFinite, (0...100).contains(cpu),
              let memoryFraction, memoryFraction.isFinite, (0...1).contains(memoryFraction)
        else { return nil }
        let heatPenalty: Double = switch thermal {
        case .nominal: 0
        case .fair: 15
        case .serious: 35
        case .critical: 60
        }
        let cpuPenalty = max(0, cpu - 70) * 0.4
        let memoryPenalty = max(0, memoryFraction * 100 - 80) * 0.5
        return max(0, Int((100 - heatPenalty - cpuPenalty - memoryPenalty).rounded()))
    }

    public static func label(for score: Int) -> String {
        switch score {
        case 90...: "极佳"
        case 70..<90: "良好"
        case 50..<70: "注意"
        default: "偏高"
        }
    }
}

public enum UptimeText {
    public static func describe(seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let days = Int(seconds / 86_400)
        let hours = Int(seconds.truncatingRemainder(dividingBy: 86_400) / 3_600)
        return "\(days)天 \(hours)小时"
    }
}

public enum GPULoad {
    public static func usage(from statistics: [String: Any]) -> Double? {
        guard let value = statistics["Device Utilization %"] as? NSNumber else { return nil }
        let percent = value.doubleValue
        return percent.isFinite && (0...100).contains(percent) ? percent : nil
    }
}

public enum SMCTemperatures {
    public static func decodeFloat(bytes: [UInt8], type: [UInt8]) -> Double? {
        guard bytes.count == 4, type == [0x20, 0x74, 0x6c, 0x66] else { return nil }
        let bits = bytes.enumerated().reduce(UInt32(0)) { result, pair in
            result | (UInt32(pair.element) << (pair.offset * 8))
        }
        let temperature = Double(Float(bitPattern: bits))
        return temperature.isFinite && (5...110).contains(temperature) ? temperature : nil
    }

    public static func cpu(from readings: [String: Double]) -> Double? {
        let keys = ["Tp01", "Tp05", "Tp09", "Tp0D"]
        let values = keys.compactMap { readings[$0] }
        guard values.count == keys.count, values.allSatisfy({ (5...110).contains($0) }) else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    public static func gpu(from readings: [String: Double]) -> Double? {
        guard let value = readings["Tg0f"], (5...110).contains(value) else { return nil }
        return value
    }
}

public enum SMCKeyEncoding {
    public static func bytes(_ key: String) -> [UInt8]? {
        guard key.utf8.count == 4 else { return nil }
        return Array(key.utf8.reversed())
    }
}

public struct PeripheralBattery: Identifiable, Sendable {
    public enum Kind: Sendable {
        case mouse, keyboard
    }

    public let name: String
    public let percentage: Int
    public let kind: Kind?
    public var id: String { name }

    public init(name: String, percentage: Int, kind: Kind? = nil) {
        self.name = name
        self.percentage = percentage
        self.kind = kind
    }

    public static func parse(_ properties: [String: Any]) -> PeripheralBattery? {
        guard let transport = properties["Transport"] as? String,
              transport.localizedCaseInsensitiveContains("bluetooth"),
              let name = properties["Product"] as? String,
              let number = properties["BatteryPercent"] as? NSNumber
                ?? properties["BatteryLevel"] as? NSNumber
        else { return nil }
        let percentage = number.intValue
        guard (0...100).contains(percentage) else { return nil }
        let usage = (properties["PrimaryUsage"] as? NSNumber)?.intValue
        let kind: Kind? = switch usage {
        case 2: .mouse
        case 6: .keyboard
        default: kind(for: name)
        }
        return PeripheralBattery(name: name, percentage: percentage, kind: kind)
    }

    public static func fromBluetoothReport(_ data: Data) -> [PeripheralBattery] {
        guard let controllers = bluetoothControllers(from: data) else { return [] }
        return controllers.flatMap { controller -> [PeripheralBattery] in
            guard let devices = controller["device_connected"] as? [[String: [String: Any]]] else { return [] }
            return devices.flatMap { device -> [PeripheralBattery] in
                device.compactMap { name, details in
                    guard let value = details["device_batteryLevelMain"] as? String,
                          value.hasSuffix("%"),
                          let percentage = Int(value.dropLast()),
                          (0...100).contains(percentage) else { return nil }
                    let type = (details["device_minorType"] as? String).flatMap(kind(for:)) ?? kind(for: name)
                    return PeripheralBattery(name: name.trimmingCharacters(in: .whitespaces), percentage: percentage, kind: type)
                }
            }
        }
    }

    public static func deviceKinds(fromBluetoothReport data: Data) -> [String: Kind] {
        guard let controllers = bluetoothControllers(from: data) else { return [:] }
        var result: [String: Kind] = [:]
        for controller in controllers {
            guard let devices = controller["device_connected"] as? [[String: [String: Any]]] else { continue }
            for device in devices {
                for (name, details) in device {
                    if let type = (details["device_minorType"] as? String).flatMap(kind(for:)) ?? kind(for: name) {
                        result[name.trimmingCharacters(in: .whitespaces)] = type
                    }
                }
            }
        }
        return result
    }

    public static func fromBLE(name: String, kind: Kind, value: Data) -> PeripheralBattery? {
        guard value.count == 1, let percentage = value.first, percentage <= 100 else { return nil }
        return PeripheralBattery(name: name, percentage: Int(percentage), kind: kind)
    }

    private static func bluetoothControllers(from data: Data) -> [[String: Any]]? {
        guard let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return report["SPBluetoothDataType"] as? [[String: Any]]
    }

    private static func kind(for text: String) -> Kind? {
        if text.localizedCaseInsensitiveContains("mouse") || text.contains("鼠标") { return .mouse }
        if text.localizedCaseInsensitiveContains("keyboard") || text.contains("键盘") { return .keyboard }
        return nil
    }
}

public enum ProcessIdentity {
    public static func matches(expectedPath: String, expectedStart: String, observedPath: String?, observedStart: String?) -> Bool {
        guard let observedPath, let observedStart,
              !expectedPath.isEmpty, !expectedStart.isEmpty else { return false }
        return expectedPath == observedPath && expectedStart == observedStart
    }
}
