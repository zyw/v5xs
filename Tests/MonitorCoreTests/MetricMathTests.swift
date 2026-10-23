import XCTest
@testable import MonitorCore

final class MetricMathTests: XCTestCase {
    func testCPULoadUsesTickDeltasAndClampsReset() {
        XCTAssertEqual(CPULoad.usage(previous: [100, 20, 300, 10], current: [130, 30, 400, 60]) ?? -1, 47.37, accuracy: 0.01)
        XCTAssertNil(CPULoad.usage(previous: [100, 20, 300, 10], current: [50, 20, 300, 10]))
    }

    func testNetworkRateRejectsResetAndInvalidInterval() {
        XCTAssertEqual(TrafficRate.between(previous: 1_000, current: 3_000, seconds: 2), 1_000)
        XCTAssertNil(TrafficRate.between(previous: 3_000, current: 1_000, seconds: 2))
        XCTAssertNil(TrafficRate.between(previous: 1_000, current: 3_000, seconds: 0))
        XCTAssertNil(TrafficRate.between(previous: 1_000, current: 3_000, seconds: 30))
    }

    func testDiskRatesUseMatchingDeviceCountersAndRejectReset() {
        let before: [UInt64: DiskCounters] = [
            7: DiskCounters(read: 1_000, written: 2_000),
            9: DiskCounters(read: 500, written: 800)
        ]
        let after: [UInt64: DiskCounters] = [
            7: DiskCounters(read: 3_000, written: 2_500),
            9: DiskCounters(read: 1_000, written: 1_000)
        ]
        XCTAssertEqual(DiskTraffic.rates(previous: before, current: after, seconds: 2)?.read, 1_250)
        XCTAssertEqual(DiskTraffic.rates(previous: before, current: after, seconds: 2)?.write, 350)
        XCTAssertNil(DiskTraffic.rates(previous: before, current: [7: DiskCounters(read: 100, written: 2_500), 9: after[9]!], seconds: 2))
        XCTAssertNil(DiskTraffic.rates(previous: before, current: after, seconds: 0))
        XCTAssertNil(DiskTraffic.rates(previous: before, current: after, seconds: 30))
        XCTAssertNil(DiskTraffic.rates(previous: before, current: [7: after[7]!], seconds: 2))
    }

    func testAnimalPaceClearlyRespondsToCPULoad() {
        let loads: [Double] = [0, 20, 50, 80, 100]
        let framesPerSecond = loads.map { 1 / AnimalPace.forLoad($0).frameInterval }
        XCTAssertEqual(framesPerSecond[0], 5, accuracy: 0.01)
        XCTAssertEqual(framesPerSecond[1], 10, accuracy: 0.01)
        XCTAssertEqual(framesPerSecond[2], 17.5, accuracy: 0.01)
        XCTAssertEqual(framesPerSecond[3], 25, accuracy: 0.01)
        XCTAssertEqual(framesPerSecond[4], 30, accuracy: 0.01)
        for index in 1..<framesPerSecond.count {
            XCTAssertGreaterThan(framesPerSecond[index], framesPerSecond[index - 1])
        }
        XCTAssertEqual(1 / AnimalPace.forLoad(-20).frameInterval, 5, accuracy: 0.01)
        XCTAssertEqual(1 / AnimalPace.forLoad(130).frameInterval, 30, accuracy: 0.01)
    }

    func testGPUCoreCountFromSystemProfilerJSON() {
        let data = Data(#"{"SPDisplaysDataType":[{"_name":"Apple M2","sppci_cores":"8"}]}"#.utf8)
        XCTAssertEqual(GPUMetadata.coreCount(from: data), 8)
        XCTAssertEqual(GPUMetadata.chipName(from: data), "M2")
        XCTAssertNil(GPUMetadata.coreCount(from: Data("{}".utf8)))
    }

    func testHealthScoreRequiresMeasurementsAndTracksThermalPressure() {
        XCTAssertEqual(HealthScore.value(cpu: 10, memoryFraction: 0.4, thermal: .nominal), 100)
        XCTAssertEqual(HealthScore.value(cpu: 80, memoryFraction: 0.9, thermal: .fair), 76)
        XCTAssertNil(HealthScore.value(cpu: nil, memoryFraction: 0.4, thermal: .nominal))
        XCTAssertEqual(HealthScore.label(for: 80), "良好")
        XCTAssertEqual(UptimeText.describe(seconds: 3 * 86_400 + 12 * 3_600), "3天 12小时")
        XCTAssertNil(UptimeText.describe(seconds: -1))
    }

    func testGPUUtilizationRejectsMissingAndInvalidRegistryValues() {
        XCTAssertEqual(GPULoad.usage(from: ["Device Utilization %": 79]), 79)
        XCTAssertNil(GPULoad.usage(from: ["Device Utilization %": -1]))
        XCTAssertNil(GPULoad.usage(from: ["Device Utilization %": 101]))
        XCTAssertNil(GPULoad.usage(from: ["Renderer Utilization %": 79]))
    }

    func testVerifiedM2SMCKeysAndTemperatureValidation() {
        XCTAssertEqual(SMCKeyEncoding.bytes("Tp01"), [0x31, 0x30, 0x70, 0x54])
        XCTAssertEqual(SMCTemperatures.decodeFloat(bytes: [0x75, 0x20, 0x40, 0x42], type: [0x20, 0x74, 0x6c, 0x66]) ?? 0, 48.03, accuracy: 0.01)
        XCTAssertNil(SMCTemperatures.decodeFloat(bytes: [0x75, 0x20, 0x40, 0x42], type: [0, 0, 0, 0]))
        XCTAssertEqual(SMCTemperatures.cpu(from: ["Tp01": 48, "Tp05": 46, "Tp09": 50, "Tp0D": 48]), 48)
        XCTAssertNil(SMCTemperatures.cpu(from: ["Tp01": 48, "Tp05": 46, "Tp09": 50]))
        XCTAssertEqual(SMCTemperatures.gpu(from: ["Tg0f": 42]), 42)
        XCTAssertNil(SMCTemperatures.gpu(from: ["Tg0f": 135]))
    }

    func testHIDBatteryRequiresExternalBluetoothAndValidPercentage() {
        let valid: [String: Any] = ["Product": "Magic Mouse", "Transport": "Bluetooth", "BatteryPercent": 84]
        XCTAssertEqual(PeripheralBattery.parse(valid)?.percentage, 84)
        XCTAssertNil(PeripheralBattery.parse(["Product": "Internal Keyboard", "Transport": "USB", "BatteryPercent": 80]))
        XCTAssertNil(PeripheralBattery.parse(["Product": "Mouse", "Transport": "Bluetooth", "BatteryPercent": 140]))
    }

    func testProcessIdentityRejectsReusedPIDPath() {
        XCTAssertTrue(ProcessIdentity.matches(expectedPath: "/Applications/Foo.app/Contents/MacOS/Foo", expectedStart: "Thu Oct 22 19:59:09 2026", observedPath: "/Applications/Foo.app/Contents/MacOS/Foo", observedStart: "Thu Oct 22 19:59:09 2026"))
        XCTAssertFalse(ProcessIdentity.matches(expectedPath: "/Applications/Foo.app/Contents/MacOS/Foo", expectedStart: "Thu Oct 22 19:59:09 2026", observedPath: "/Applications/Foo.app/Contents/MacOS/Foo", observedStart: "Thu Oct 22 20:00:00 2026"))
        XCTAssertFalse(ProcessIdentity.matches(expectedPath: "/Applications/Foo.app/Contents/MacOS/Foo", expectedStart: "Thu Oct 22 19:59:09 2026", observedPath: nil, observedStart: nil))
        let line = "45633 1.1 33312 Thu Oct 22 19:59:09 2026 /Applications/Foo Bar.app/Contents/MacOS/Foo"
        XCTAssertEqual(ProcessReading.parse(line)?.executablePath, "/Applications/Foo Bar.app/Contents/MacOS/Foo")
        XCTAssertEqual(ProcessReading.parse(line)?.startTime, "Thu Oct 22 19:59:09 2026")
        XCTAssertEqual(ProcessReading.parse(line)?.name, "Foo Bar")
    }
}
