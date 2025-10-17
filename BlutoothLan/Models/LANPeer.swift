//
//  LANPeer.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 10/17/25.
//


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
