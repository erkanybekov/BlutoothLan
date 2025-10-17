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
final class ConnectivityViewModel: NSObject, ObservableObject {
    // Bluetooth
    private var centralManager: CBCentralManager?
    private var peripherals: [CBPeripheral] = []
    @Published var peripheralNames: [String] = [] // legacy list (not shown anymore)
    @Published var discoveredPeripherals: [DiscoveredPeripheral] = []
    @Published var isScanningBluetooth = false
    @Published var bluetoothState: CBManagerState = .unknown

    // LAN (Bonjour)
    private let serviceType = "_blutoothlan._tcp." // include trailing dot for Info.plist and matching
    private var browser: NetServiceBrowser?
    private var advertiser: NetService?
    private var resolvingServices: Set<NetService> = []

    @Published var lanPeers: [LANPeer] = []
    @Published var isBrowsingLAN = false
    @Published var isAdvertisingLAN = false
    @Published var lanStatusMessage: String = "Idle"

    override init() {
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Bluetooth Controls

    func startBluetoothScan() {
        guard bluetoothState == .poweredOn else { return }
        peripherals.removeAll()
        discoveredPeripherals.removeAll()
        centralManager?.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
        isScanningBluetooth = true
    }

    func stopBluetoothScan() {
        centralManager?.stopScan()
        isScanningBluetooth = false
    }

    // MARK: - LAN Controls

    func startLANBrowsing() {
        lanPeers.removeAll()
        browser?.stop()
        browser = NetServiceBrowser()
        browser?.delegate = self
        browser?.searchForServices(ofType: serviceType, inDomain: "local.")
        isBrowsingLAN = true
        lanStatusMessage = "Browsing..."
    }

    func stopLANBrowsing() {
        browser?.stop()
        isBrowsingLAN = false
        lanStatusMessage = "Stopped"
        for svc in resolvingServices { svc.stop() }
        resolvingServices.removeAll()
    }

    func startLANAdvertising(port: Int = 0) {
        advertiser?.stop()
        let service = NetService(domain: "local.", type: serviceType, name: UIDevice.current.name, port: Int32(port))
        service.includesPeerToPeer = true
        service.delegate = self
        service.publish(options: [.listenForConnections])
        advertiser = service
        isAdvertisingLAN = true
        lanStatusMessage = "Advertising..."
    }

    func stopLANAdvertising() {
        advertiser?.stop()
        advertiser = nil
        isAdvertisingLAN = false
        lanStatusMessage = isBrowsingLAN ? "Browsing..." : "Idle"
    }
}

// MARK: - Bluetooth Delegate

extension ConnectivityViewModel: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        switch central.state {
        case .poweredOn:
            break
        case .poweredOff, .resetting, .unauthorized, .unknown, .unsupported:
            stopBluetoothScan()
        @unknown default:
            stopBluetoothScan()
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {

        if let index = discoveredPeripherals.firstIndex(where: { $0.id == peripheral.identifier }) {
            // Update existing entry
            discoveredPeripherals[index].rssi = RSSI
            discoveredPeripherals[index].lastSeen = Date()
            var merged = discoveredPeripherals[index].advertisementData
            advertisementData.forEach { merged[$0.key] = $0.value }
            discoveredPeripherals[index].advertisementData = merged
        } else {
            let item = DiscoveredPeripheral(peripheral: peripheral, rssi: RSSI, advertisementData: advertisementData)
            discoveredPeripherals.append(item)
        }

        // Sort: strongest signal first, then by name
        discoveredPeripherals.sort {
            if $0.rssi.intValue == $1.rssi.intValue {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.rssi.intValue > $1.rssi.intValue
        }
    }
}

// MARK: - Bonjour Delegates

extension ConnectivityViewModel: NetServiceBrowserDelegate, NetServiceDelegate {
    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        lanStatusMessage = "Searching..."
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        lanStatusMessage = isAdvertisingLAN ? "Advertising" : "Idle"
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        lanStatusMessage = "Browse error: \(errorDict)"
        isBrowsingLAN = false
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didFind service: NetService,
                           moreComing: Bool) {
        service.delegate = self
        resolvingServices.insert(service)
        service.resolve(withTimeout: 5.0)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didRemove service: NetService,
                           moreComing: Bool) {
        let removedName = service.name
        lanPeers.removeAll { $0.name == removedName }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        resolvingServices.remove(sender)
        let host = sender.hostName
        let port = sender.port > 0 ? sender.port : nil
        let peer = LANPeer(name: sender.name, hostName: host, domain: sender.domain, port: port)
        if !lanPeers.contains(peer) {
            lanPeers.append(peer)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        resolvingServices.remove(sender)
    }

    func netServiceWillPublish(_ sender: NetService) {
        lanStatusMessage = "Publishing..."
    }

    func netServiceDidPublish(_ sender: NetService) {
        lanStatusMessage = "Advertising as \(sender.name)"
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        lanStatusMessage = "Advertise error: \(errorDict)"
        isAdvertisingLAN = false
    }

    func netServiceDidStop(_ sender: NetService) { }
}
