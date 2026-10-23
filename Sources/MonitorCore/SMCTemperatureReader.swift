import Darwin
import Foundation
import IOKit

enum SMCTemperatureReader {
    static let supportedModel: Bool = {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return false }
        var bytes = [CChar](repeating: 0, count: size)
        let status = bytes.withUnsafeMutableBufferPointer {
            sysctlbyname("hw.model", $0.baseAddress, &size, nil, 0)
        }
        let model = bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return status == 0 && String(decoding: model, as: UTF8.self) == "Mac14,2"
    }()

    static func readings() -> [String: Double] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return [:] }
        defer { IOServiceClose(connection) }

        var result: [String: Double] = [:]
        for key in ["Tp01", "Tp05", "Tp09", "Tp0D", "Tg0f"] {
            if let value = read(key, connection: connection) { result[key] = value }
        }
        return result
    }

    private static func read(_ key: String, connection: io_connect_t) -> Double? {
        guard let encodedKey = SMCKeyEncoding.bytes(key) else { return nil }
        // SMCKeyData is 80 bytes; these offsets match the native version, keyInfo, and value fields.
        var input = [UInt8](repeating: 0, count: 80)
        for (index, byte) in encodedKey.enumerated() { input[index] = byte }
        input[42] = 9 // SMC key metadata request
        guard let metadata = call(input, connection: connection), metadata[40] == 0,
              metadata[28] == 4, metadata[29...31].allSatisfy({ $0 == 0 })
        else { return nil }
        input[28] = 4
        input[42] = 5 // SMC key value request
        guard let value = call(input, connection: connection), value[40] == 0 else { return nil }
        return SMCTemperatures.decodeFloat(
            bytes: Array(value[48..<52]),
            type: Array(metadata[32..<36])
        )
    }

    private static func call(_ input: [UInt8], connection: io_connect_t) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: 80)
        var size = output.count
        let status = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                IOConnectCallStructMethod(connection, 2, source.baseAddress, input.count, destination.baseAddress, &size)
            }
        }
        return status == KERN_SUCCESS && size == output.count ? output : nil
    }
}
