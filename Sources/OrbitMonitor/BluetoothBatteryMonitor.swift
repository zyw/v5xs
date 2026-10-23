import CoreBluetooth
import Foundation
import MonitorCore

final class BluetoothBatteryMonitor: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onUpdate: (([PeripheralBattery]) -> Void)?

    private let batteryService = CBUUID(string: "180F")
    private let batteryLevel = CBUUID(string: "2A19")
    private var central: CBCentralManager?
    private var devices: [UUID: CBPeripheral] = [:]
    private var samples: [UUID: (name: String, value: Data)] = [:]
    private var kinds: [String: PeripheralBattery.Kind] = [:]

    func start() {
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func updateKinds(_ kinds: [String: PeripheralBattery.Kind]) {
        self.kinds = kinds
        publish()
    }

    func refresh() {
        guard let central, central.state == .poweredOn else { return }
        for peripheral in central.retrieveConnectedPeripherals(withServices: [batteryService]) {
            devices[peripheral.identifier] = peripheral
            peripheral.delegate = self
            if peripheral.state == .connected {
                if let characteristic = peripheral.services?
                    .first(where: { $0.uuid == batteryService })?
                    .characteristics?.first(where: { $0.uuid == batteryLevel }) {
                    peripheral.readValue(for: characteristic)
                } else {
                    peripheral.discoverServices([batteryService])
                }
            } else if peripheral.state == .disconnected {
                central.connect(peripheral)
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { refresh() }
        else {
            samples.removeAll()
            publish()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([batteryService])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        samples.removeValue(forKey: peripheral.identifier)
        devices.removeValue(forKey: peripheral.identifier)
        publish()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { return }
        for service in peripheral.services ?? [] where service.uuid == batteryService {
            peripheral.discoverCharacteristics([batteryLevel], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { return }
        for characteristic in service.characteristics ?? [] where characteristic.uuid == batteryLevel {
            peripheral.readValue(for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == batteryLevel,
              let name = peripheral.name?.trimmingCharacters(in: .whitespaces),
              let value = characteristic.value else { return }
        samples[peripheral.identifier] = (name, value)
        publish()
    }

    private func publish() {
        onUpdate?(samples.values.compactMap { sample in
            guard let kind = kinds[sample.name] else { return nil }
            return PeripheralBattery.fromBLE(name: sample.name, kind: kind, value: sample.value)
        })
    }
}
