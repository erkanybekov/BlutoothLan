//
//  DeviceDetailViewModel.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 1/6/26.
//

import Foundation
import CoreBluetooth
import Combine

@MainActor
final class DeviceDetailViewModel: ObservableObject {
    // MARK: - Published Properties
    
    @Published private(set) var connectionState: BLEConnectionState = .disconnected
    @Published private(set) var services: [DiscoveredService] = []
    @Published private(set) var isConnecting: Bool = false
    @Published private(set) var lastWriteResult: BLEWriteResult?
    
    // MARK: - Properties
    
    let peripheral: CBPeripheral
    private let bluetoothService: BluetoothService
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Init
    
    init(peripheral: CBPeripheral, bluetoothService: BluetoothService) {
        self.peripheral = peripheral
        self.bluetoothService = bluetoothService
        
        setupBindings()
    }
    
    // MARK: - Setup
    
    private func setupBindings() {
        bluetoothService.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.connectionState = state
                self?.isConnecting = (state == .connecting || state == .discoveringServices)
            }
            .store(in: &cancellables)
        
        bluetoothService.servicesPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$services)
        
        bluetoothService.writeResultPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] result in
                self?.lastWriteResult = result
            }
            .store(in: &cancellables)
    }
    
    func clearWriteResult() {
        lastWriteResult = nil
    }
    
    // MARK: - Actions
    
    func connect() {
        bluetoothService.connect(to: peripheral)
    }
    
    func disconnect() {
        bluetoothService.disconnect()
    }
    
    func toggleConnection() {
        if connectionState.isConnected {
            disconnect()
        } else {
            connect()
        }
    }
    
    func readValue(for characteristic: CBCharacteristic) {
        bluetoothService.readValue(for: characteristic)
    }
    
    func writeValue(_ data: Data, for characteristic: CBCharacteristic) {
        let withResponse = characteristic.properties.contains(.write)
        bluetoothService.writeValue(data, for: characteristic, withResponse: withResponse)
    }
    
    func toggleNotify(for characteristic: CBCharacteristic, enabled: Bool) {
        bluetoothService.setNotify(enabled, for: characteristic)
    }
    
    // MARK: - Helpers
    
    var connectionButtonTitle: String {
        switch connectionState {
        case .disconnected:
            return "Connect"
        case .connecting:
            return "Connecting..."
        case .connected, .discoveringServices:
            return "Discovering..."
        case .ready:
            return "Disconnect"
        case .failed:
            return "Retry"
        }
    }
    
    var connectionStatusText: String {
        switch connectionState {
        case .disconnected:
            return "Not connected"
        case .connecting:
            return "Connecting..."
        case .connected:
            return "Connected"
        case .discoveringServices:
            return "Discovering services..."
        case .ready:
            return "Connected • \(services.count) services"
        case .failed(let error):
            return "Failed: \(error)"
        }
    }
}

