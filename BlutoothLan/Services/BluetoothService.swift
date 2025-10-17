//
//  BluetoothService.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 10/17/25.
//

import Foundation
import CoreBluetooth
import Combine

protocol BluetoothServicing {
    var statePublisher: AnyPublisher<CBManagerState, Never> { get }
    var peripheralsPublisher: AnyPublisher<[DiscoveredPeripheral], Never> { get }
    var isScanningPublisher: AnyPublisher<Bool, Never> { get }

    func startScan(timeout: TimeInterval)
    func stopScan()
}

final class BluetoothService: NSObject, BluetoothServicing {
    private let stateSubject = CurrentValueSubject<CBManagerState, Never>(.unknown)
    private let peripheralsSubject = CurrentValueSubject<[DiscoveredPeripheral], Never>([])
    private let scanningSubject = CurrentValueSubject<Bool, Never>(false)

    var statePublisher: AnyPublisher<CBManagerState, Never> { stateSubject.eraseToAnyPublisher() }
    var peripheralsPublisher: AnyPublisher<[DiscoveredPeripheral], Never> { peripheralsSubject.eraseToAnyPublisher() }
    var isScanningPublisher: AnyPublisher<Bool, Never> { scanningSubject.eraseToAnyPublisher() }

    private var central: CBCentralManager!
    private var scanTimeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

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
}

extension BluetoothService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        stateSubject.send(central.state)
        if central.state != .poweredOn {
            stopScan()
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
}
