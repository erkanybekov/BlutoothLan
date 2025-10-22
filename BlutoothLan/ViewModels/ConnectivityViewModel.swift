//
//  ConnectivityViewModel.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 10/17/25.
//

import CoreBluetooth
import Combine
import SwiftUI

// MARK: - View Model

@MainActor
final class ConnectivityViewModel: ObservableObject {
    // Services
    private let bluetoothService: BluetoothServicing
    private let bonjourService: BonjourService
    private let coreData: CoreDataManager

    private var cancellables: Set<AnyCancellable> = []

    // Bluetooth
    @Published var discoveredPeripherals: [DiscoveredPeripheral] = []
    @Published var isScanningBluetooth = false
    @Published var bluetoothState: CBManagerState = .unknown

    // LAN (Bonjour)
    @Published var lanPeers: [LANPeer] = []
    @Published var isBrowsingLAN = false
    @Published var isAdvertisingLAN = false
    @Published var lanStatusMessage: String = "Idle"

    init(bluetoothService: BluetoothServicing = BluetoothService(),
         bonjourService: BonjourService = BonjourService(),
         coreData: CoreDataManager = .instance) {
        self.bluetoothService = bluetoothService
        self.bonjourService = bonjourService
        self.coreData = coreData
        bind()
    }

    private func bind() {
        // Bluetooth state
        bluetoothService.statePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$bluetoothState)

        // Bluetooth discovered peripherals + save to Core Data
        bluetoothService.peripheralsPublisher
            .receive(on: DispatchQueue.main)
            .handleEvents(receiveOutput: { [weak self] peripherals in
                guard let self = self else { return }
                Task { // still on MainActor
                    let now = Date()
                    for p in peripherals {
                        let id = p.peripheral.identifier.uuidString

                        // Prefer advertisement local name, then peripheral.name; ignore empty/"Unknown"
                        let advLocalName = (p.advertisementData[CBAdvertisementDataLocalNameKey] as? String)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let reportedName = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let candidateName = (advLocalName?.isEmpty == false ? advLocalName :
                                             (reportedName.isEmpty ? nil : reportedName))

                        // Persist via Core Data upsert
                        try? await self.coreData.upsertDevice(
                            id: id,
                            name: candidateName,
                            type: DeviceType.bluetooth.rawValue,
                            lastSeen: now,
                            rssi: Int32(truncatingIfNeeded: p.rssi.intValue),
                            ip: nil
                        )
                    }
                }
            })
            .assign(to: &$discoveredPeripherals)

        // Bluetooth scanning flag
        bluetoothService.isScanningPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$isScanningBluetooth)

        // Bonjour peers + save to Core Data
        bonjourService.peersPublisher
            .receive(on: DispatchQueue.main)
            .handleEvents(receiveOutput: { [weak self] peers in
                guard let self = self else { return }
                Task {
                    let now = Date()
                    for peer in peers {
                        // Keep previous uniqueness: id = hostName ?? name
                        let id = peer.hostName ?? peer.name
                        let trimmedName = peer.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let name = trimmedName.isEmpty ? nil : trimmedName

                        try? await self.coreData.upsertDevice(
                            id: id,
                            name: name,
                            type: DeviceType.lan.rawValue,
                            lastSeen: now,
                            rssi: nil,
                            ip: peer.hostName
                        )
                    }
                }
            })
            .assign(to: &$lanPeers)

        // Bonjour status
        bonjourService.statusPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$lanStatusMessage)

        // Bonjour flags
        bonjourService.isBrowsingPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$isBrowsingLAN)

        bonjourService.isAdvertisingPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$isAdvertisingLAN)
    }

    // MARK: - Bluetooth Controls

    func startBluetoothScan(timeout: TimeInterval = 15) {
        guard bluetoothState == .poweredOn else { return }
        bluetoothService.startScan(timeout: timeout)
    }

    func stopBluetoothScan() {
        bluetoothService.stopScan()
    }

    // MARK: - LAN Controls (Bonjour)

    func startLANBrowsing(timeout: TimeInterval = 15) {
        bonjourService.startBrowsing(timeout: timeout)
    }

    func stopLANBrowsing() {
        bonjourService.stopBrowsing()
    }

    func startLANAdvertising(port: Int = 0) {
        bonjourService.startAdvertising(port: port)
    }

    func stopLANAdvertising() {
        bonjourService.stopAdvertising()
    }
}

