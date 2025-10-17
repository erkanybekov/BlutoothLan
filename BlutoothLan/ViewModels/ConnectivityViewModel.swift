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
    private let persistence: PersistenceService

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
         persistence: PersistenceService = .shared) {
        self.bluetoothService = bluetoothService
        self.bonjourService = bonjourService
        self.persistence = persistence
        bind()
    }

    private func bind() {
        bluetoothService.statePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$bluetoothState)

        bluetoothService.peripheralsPublisher
            .receive(on: DispatchQueue.main)
            .handleEvents(receiveOutput: { [weak self] peripherals in
                guard let self = self else { return }
                Task {
                    for p in peripherals {
                        try? await self.persistence.upsertBluetoothDevice(from: p)
                    }
                }
            })
            .assign(to: &$discoveredPeripherals)

        bluetoothService.isScanningPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$isScanningBluetooth)

        bonjourService.peersPublisher
            .receive(on: DispatchQueue.main)
            .handleEvents(receiveOutput: { [weak self] peers in
                guard let self = self else { return }
                Task {
                    for peer in peers {
                        try? await self.persistence.upsertLANDevice(from: peer)
                    }
                }
            })
            .assign(to: &$lanPeers)

        bonjourService.statusPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$lanStatusMessage)

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
