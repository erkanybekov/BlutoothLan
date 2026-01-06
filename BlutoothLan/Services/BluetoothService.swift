//
//  BluetoothService.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 10/17/25.
//

import Foundation
import CoreBluetooth
import Combine

// MARK: - Connection State

enum BLEConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case discoveringServices
    case ready
    case failed(String)
    
    var isConnected: Bool {
        switch self {
        case .connected, .discoveringServices, .ready:
            return true
        default:
            return false
        }
    }
}

// MARK: - Discovered Characteristic Model

struct DiscoveredCharacteristic: Identifiable {
    let id: String
    let characteristic: CBCharacteristic
    var value: Data?
    var isNotifying: Bool
    
    init(characteristic: CBCharacteristic) {
        self.id = characteristic.uuid.uuidString
        self.characteristic = characteristic
        self.value = characteristic.value
        self.isNotifying = characteristic.isNotifying
    }
    
    var canRead: Bool { characteristic.properties.contains(.read) }
    var canWrite: Bool { characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) }
    var canNotify: Bool { characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) }
    
    var propertiesDescription: String {
        var props: [String] = []
        if canRead { props.append("Read") }
        if canWrite { props.append("Write") }
        if canNotify { props.append("Notify") }
        return props.joined(separator: ", ")
    }
}

// MARK: - Discovered Service Model

struct DiscoveredService: Identifiable {
    let id: String
    let service: CBService
    var characteristics: [DiscoveredCharacteristic]
    
    init(service: CBService) {
        self.id = service.uuid.uuidString
        self.service = service
        self.characteristics = []
    }
    
    var name: String {
        knownServiceNames[service.uuid.uuidString] ?? service.uuid.uuidString
    }
}

// Known BLE Service Names
private let knownServiceNames: [String: String] = [
    "180A": "Device Information",
    "180F": "Battery Service",
    "180D": "Heart Rate",
    "1800": "Generic Access",
    "1801": "Generic Attribute",
    "181C": "User Data",
    "1805": "Current Time",
    "1804": "Tx Power",
    "181A": "Environmental Sensing",
]

// MARK: - Write Result

struct BLEWriteResult {
    let success: Bool
    let message: String
    let characteristicUUID: String
    let timestamp: Date
    
    static func success(for uuid: String) -> BLEWriteResult {
        BLEWriteResult(success: true, message: "✓ Команда отправлена", characteristicUUID: uuid, timestamp: Date())
    }
    
    static func failure(for uuid: String, error: String) -> BLEWriteResult {
        BLEWriteResult(success: false, message: "✗ Ошибка: \(error)", characteristicUUID: uuid, timestamp: Date())
    }
}

// MARK: - Protocol

protocol BluetoothServicing {
    var statePublisher: AnyPublisher<CBManagerState, Never> { get }
    var peripheralsPublisher: AnyPublisher<[DiscoveredPeripheral], Never> { get }
    var isScanningPublisher: AnyPublisher<Bool, Never> { get }
    var connectionStatePublisher: AnyPublisher<BLEConnectionState, Never> { get }
    var servicesPublisher: AnyPublisher<[DiscoveredService], Never> { get }
    var connectedPeripheralPublisher: AnyPublisher<CBPeripheral?, Never> { get }
    var writeResultPublisher: AnyPublisher<BLEWriteResult, Never> { get }

    func startScan(timeout: TimeInterval)
    func stopScan()
    func connect(to peripheral: CBPeripheral)
    func disconnect()
    func readValue(for characteristic: CBCharacteristic)
    func writeValue(_ data: Data, for characteristic: CBCharacteristic, withResponse: Bool)
    func setNotify(_ enabled: Bool, for characteristic: CBCharacteristic)
}

// MARK: - BluetoothService

final class BluetoothService: NSObject, BluetoothServicing {
    // Scanning
    private let stateSubject = CurrentValueSubject<CBManagerState, Never>(.unknown)
    private let peripheralsSubject = CurrentValueSubject<[DiscoveredPeripheral], Never>([])
    private let scanningSubject = CurrentValueSubject<Bool, Never>(false)
    
    // Connection
    private let connectionStateSubject = CurrentValueSubject<BLEConnectionState, Never>(.disconnected)
    private let servicesSubject = CurrentValueSubject<[DiscoveredService], Never>([])
    private let connectedPeripheralSubject = CurrentValueSubject<CBPeripheral?, Never>(nil)
    
    // Write result
    private let writeResultSubject = PassthroughSubject<BLEWriteResult, Never>()

    // Publishers
    var statePublisher: AnyPublisher<CBManagerState, Never> { stateSubject.eraseToAnyPublisher() }
    var peripheralsPublisher: AnyPublisher<[DiscoveredPeripheral], Never> { peripheralsSubject.eraseToAnyPublisher() }
    var isScanningPublisher: AnyPublisher<Bool, Never> { scanningSubject.eraseToAnyPublisher() }
    var connectionStatePublisher: AnyPublisher<BLEConnectionState, Never> { connectionStateSubject.eraseToAnyPublisher() }
    var servicesPublisher: AnyPublisher<[DiscoveredService], Never> { servicesSubject.eraseToAnyPublisher() }
    var connectedPeripheralPublisher: AnyPublisher<CBPeripheral?, Never> { connectedPeripheralSubject.eraseToAnyPublisher() }
    var writeResultPublisher: AnyPublisher<BLEWriteResult, Never> { writeResultSubject.eraseToAnyPublisher() }

    private var central: CBCentralManager!
    private var scanTimeoutTask: Task<Void, Never>?
    private var connectedPeripheral: CBPeripheral?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Scanning

    func startScan(timeout: TimeInterval = 15) {
        guard central.state == .poweredOn else { return }
        peripheralsSubject.value = []
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
        scanningSubject.send(true)

        scanTimeoutTask?.cancel()
        scanTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await MainActor.run {
                self?.stopScan()
            }
        }
    }

    func stopScan() {
        guard scanningSubject.value else { return }
        central.stopScan()
        scanningSubject.send(false)
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
    }
    
    // MARK: - Connection
    
    func connect(to peripheral: CBPeripheral) {
        stopScan()
        
        // Disconnect if already connected to another device
        if let existing = connectedPeripheral {
            central.cancelPeripheralConnection(existing)
        }
        
        connectedPeripheral = peripheral
        peripheral.delegate = self
        connectedPeripheralSubject.send(peripheral)
        connectionStateSubject.send(.connecting)
        servicesSubject.send([])
        
        central.connect(peripheral, options: nil)
    }
    
    func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        central.cancelPeripheralConnection(peripheral)
    }
    
    // MARK: - Characteristic Operations
    
    func readValue(for characteristic: CBCharacteristic) {
        connectedPeripheral?.readValue(for: characteristic)
    }
    
    func writeValue(_ data: Data, for characteristic: CBCharacteristic, withResponse: Bool = true) {
        let type: CBCharacteristicWriteType = withResponse ? .withResponse : .withoutResponse
        connectedPeripheral?.writeValue(data, for: characteristic, type: type)
    }
    
    func setNotify(_ enabled: Bool, for characteristic: CBCharacteristic) {
        connectedPeripheral?.setNotifyValue(enabled, for: characteristic)
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        stateSubject.send(central.state)
        if central.state != .poweredOn {
            stopScan()
            if connectedPeripheral != nil {
                connectionStateSubject.send(.disconnected)
                connectedPeripheral = nil
                connectedPeripheralSubject.send(nil)
            }
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {

        var items = peripheralsSubject.value
        if let idx = items.firstIndex(where: { $0.id == peripheral.identifier }) {
            items[idx].rssi = RSSI
            items[idx].lastSeen = Date()
            var merged = items[idx].advertisementData
            advertisementData.forEach { merged[$0.key] = $0.value }
            items[idx].advertisementData = merged
        } else {
            let item = DiscoveredPeripheral(peripheral: peripheral, rssi: RSSI, advertisementData: advertisementData)
            items.append(item)
        }

        items.sort {
            if $0.rssi.intValue == $1.rssi.intValue {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.rssi.intValue > $1.rssi.intValue
        }
        peripheralsSubject.send(items)
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionStateSubject.send(.discoveringServices)
        peripheral.discoverServices(nil)
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionStateSubject.send(.failed(error?.localizedDescription ?? "Connection failed"))
        connectedPeripheral = nil
        connectedPeripheralSubject.send(nil)
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectionStateSubject.send(.disconnected)
        connectedPeripheral = nil
        connectedPeripheralSubject.send(nil)
        servicesSubject.send([])
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothService: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else {
            connectionStateSubject.send(.failed("No services found"))
            return
        }
        
        let discoveredServices = services.map { DiscoveredService(service: $0) }
        servicesSubject.send(discoveredServices)
        
        // Discover characteristics for each service
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
        
        connectionStateSubject.send(.ready)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        
        var services = servicesSubject.value
        if let idx = services.firstIndex(where: { $0.id == service.uuid.uuidString }) {
            services[idx].characteristics = characteristics.map { DiscoveredCharacteristic(characteristic: $0) }
            servicesSubject.send(services)
            
            // Auto-read readable characteristics
            for char in characteristics {
                if char.properties.contains(.read) {
                    peripheral.readValue(for: char)
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        var services = servicesSubject.value
        for (sIdx, service) in services.enumerated() {
            if let cIdx = service.characteristics.firstIndex(where: { $0.id == characteristic.uuid.uuidString }) {
                services[sIdx].characteristics[cIdx].value = characteristic.value
                servicesSubject.send(services)
                break
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid.uuidString
        if let error = error {
            writeResultSubject.send(.failure(for: uuid, error: error.localizedDescription))
        } else {
            writeResultSubject.send(.success(for: uuid))
            // Re-read value after successful write
            peripheral.readValue(for: characteristic)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        var services = servicesSubject.value
        for (sIdx, service) in services.enumerated() {
            if let cIdx = service.characteristics.firstIndex(where: { $0.id == characteristic.uuid.uuidString }) {
                services[sIdx].characteristics[cIdx].isNotifying = characteristic.isNotifying
                servicesSubject.send(services)
                break
            }
        }
    }
}
