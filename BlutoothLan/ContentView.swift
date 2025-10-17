//
//  ContentView.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 10/17/25.
//

import SwiftUI
import SwiftData
import CoreBluetooth
import Combine

// MARK: - LAN Models

struct LANPeer: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let hostName: String?
    let domain: String
    let port: Int?
}

// MARK: - Bluetooth Models (Minimal Detail)

struct DiscoveredPeripheral: Identifiable, Hashable {
    let id: UUID
    let peripheral: CBPeripheral
    var name: String { peripheral.name ?? "Unnamed device" }
    var rssi: NSNumber
    var lastSeen: Date
    var advertisementData: [String: Any]

    init(peripheral: CBPeripheral, rssi: NSNumber, advertisementData: [String: Any], lastSeen: Date = Date()) {
        self.id = peripheral.identifier
        self.peripheral = peripheral
        self.rssi = rssi
        self.advertisementData = advertisementData
        self.lastSeen = lastSeen
    }

    static func == (lhs: DiscoveredPeripheral, rhs: DiscoveredPeripheral) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var isConnectable: Bool? {
        advertisementData[CBAdvertisementDataIsConnectable] as? Bool
    }

    var serviceUUIDs: [CBUUID] {
        (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
    }
}

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

// MARK: - UI

enum ConnectivityTab: String, CaseIterable, Identifiable {
    case bluetooth = "Bluetooth"
    case lan = "LAN"
    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var viewModel = ConnectivityViewModel()
    @State private var selectedTab: ConnectivityTab = .bluetooth
    @State private var filterText: String = ""
    @State private var sortByRSSI: Bool = true

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("Mode", selection: $selectedTab) {
                    ForEach(ConnectivityTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 12)

                Group {
                    switch selectedTab {
                    case .bluetooth:
                        bluetoothList
                    case .lan:
                        lanList
                    }
                }
                .animation(.default, value: selectedTab)
            }
            .navigationTitle("Nearby Devices")
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    if selectedTab == .bluetooth {
                        // Filter and sort controls
                        HStack(spacing: 12) {
                            if #available(iOS 15.0, *) {
                                TextField("Filter by name", text: $filterText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 220)
                            }
                            Button {
                                sortByRSSI.toggle()
                                sortDiscovered()
                            } label: {
                                Label(sortByRSSI ? "Strongest" : "A–Z", systemImage: sortByRSSI ? "antenna.radiowaves.left.and.right" : "textformat")
                            }
                            .labelStyle(.titleAndIcon)
                        }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    switch selectedTab {
                    case .bluetooth:
                        Button(viewModel.isScanningBluetooth ? "Stop" : "Scan") {
                            viewModel.isScanningBluetooth ? viewModel.stopBluetoothScan() : viewModel.startBluetoothScan()
                        }
                        .disabled(viewModel.bluetoothState != .poweredOn)
                    case .lan:
                        Button(viewModel.isBrowsingLAN ? "Stop Browse" : "Browse") {
                            viewModel.isBrowsingLAN ? viewModel.stopLANBrowsing() : viewModel.startLANBrowsing()
                        }
                        Button(viewModel.isAdvertisingLAN ? "Stop Adv" : "Advertise") {
                            viewModel.isAdvertisingLAN ? viewModel.stopLANAdvertising() : viewModel.startLANAdvertising()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Bluetooth UI

    private var bluetoothList: some View {
        List {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(viewModel.bluetoothState == .poweredOn ? .green : .secondary)
                    Text(statusTextForBluetooth())
                        .font(.subheadline)
                    Spacer()
                    if viewModel.isScanningBluetooth {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .accessibilityLabel("Bluetooth status")
            } footer: {
                Text(bluetoothFooterText())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(header: Text("Bluetooth Devices")) {
                let items = filteredAndSortedPeripherals()
                if items.isEmpty {
                    VStack(alignment: .center, spacing: 6) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(viewModel.isScanningBluetooth ? "Scanning…" : "No devices found")
                            .foregroundStyle(.secondary)
                        if viewModel.bluetoothState != .poweredOn {
                            Text("Turn on Bluetooth to discover nearby devices.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
                } else {
                    ForEach(items) { item in
                        NavigationLink(destination: DetailedView(item: item)) {
                            bluetoothRow(for: item)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func bluetoothRow(for item: DiscoveredPeripheral) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(1)
                    if let connectable = item.isConnectable {
                        Capsule()
                            .fill(connectable ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
                            .overlay(
                                Text(connectable ? "Connectable" : "Non‑connectable")
                                    .font(.caption2)
                                    .foregroundStyle(connectable ? .green : .secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                            )
                            .fixedSize()
                    }
                }
                HStack(spacing: 8) {
                    Text("RSSI \(item.rssi)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !item.serviceUUIDs.isEmpty {
                        Text("\(item.serviceUUIDs.count) service\(item.serviceUUIDs.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(item.peripheral.identifier.uuidString.suffix(4))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func filteredAndSortedPeripherals() -> [DiscoveredPeripheral] {
        var items = viewModel.discoveredPeripherals
        if !filterText.trimmingCharacters(in: .whitespaces).isEmpty {
            let q = filterText.lowercased()
            items = items.filter {
                $0.name.lowercased().contains(q) ||
                $0.peripheral.identifier.uuidString.lowercased().contains(q)
            }
        }
        if sortByRSSI {
            items.sort {
                if $0.rssi.intValue == $1.rssi.intValue {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return $0.rssi.intValue > $1.rssi.intValue
            }
        } else {
            items.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return items
    }

    private func bluetoothFooterText() -> String {
        switch viewModel.bluetoothState {
        case .poweredOn:
            return viewModel.isScanningBluetooth
            ? "Scanning nearby Bluetooth peripherals. This list updates live."
            : "Tap Scan to discover nearby peripherals."
        case .poweredOff:
            return "Bluetooth is off. Enable it in Settings to discover devices."
        case .unauthorized:
            return "This app is not authorized to use Bluetooth."
        case .unsupported:
            return "Bluetooth is not supported on this device."
        case .resetting:
            return "Bluetooth is resetting. Please wait…"
        case .unknown:
            fallthrough
        @unknown default:
            return "Bluetooth status is unknown."
        }
    }

    // MARK: - LAN UI

    private var lanList: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "network")
                        .foregroundStyle(isLANActive ? .purple : .secondary)
                    Text(viewModel.lanStatusMessage)
                        .font(.subheadline)
                    Spacer()
                    if isLANActive {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            } footer: {
                Text("Browse to discover peers on the local network. You can also advertise this device so others can find it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(header: Text("LAN Peers")) {
                if viewModel.lanPeers.isEmpty {
                    VStack(alignment: .center, spacing: 6) {
                        Image(systemName: "bonjour")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(viewModel.isBrowsingLAN ? "Discovering peers…" : "No peers discovered")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
                } else {
                    ForEach(viewModel.lanPeers) { peer in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: "bonjour")
                                    .foregroundStyle(.purple)
                                Text(peer.name)
                                    .font(.headline)
                                    .lineLimit(1)
                            }
                            HStack(spacing: 8) {
                                if let host = peer.hostName {
                                    Text(host).foregroundStyle(.secondary)
                                }
                                if let port = peer.port {
                                    Text(":\(port)").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var isLANActive: Bool {
        viewModel.isBrowsingLAN || viewModel.isAdvertisingLAN
    }

    // MARK: - Utils

    private func sortDiscovered() {
        if sortByRSSI {
            viewModel.discoveredPeripherals.sort {
                if $0.rssi.intValue == $1.rssi.intValue {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return $0.rssi.intValue > $1.rssi.intValue
            }
        } else {
            viewModel.discoveredPeripherals.sort {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    private func statusTextForBluetooth() -> String {
        switch viewModel.bluetoothState {
        case .unknown: return "Bluetooth: Unknown"
        case .resetting: return "Bluetooth: Resetting"
        case .unsupported: return "Bluetooth: Unsupported"
        case .unauthorized: return "Bluetooth: Unauthorized"
        case .poweredOff: return "Bluetooth: Off"
        case .poweredOn: return viewModel.isScanningBluetooth ? "Bluetooth: Scanning…" : "Bluetooth: Ready"
        @unknown default: return "Bluetooth: Unknown"
        }
    }
}

//#Preview {
//    ContentView()
//}
