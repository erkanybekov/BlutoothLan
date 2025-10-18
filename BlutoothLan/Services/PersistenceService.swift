//
//  PersistenceService.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 10/17/25.
//

import Foundation

enum DeviceType: Int16 {
    case bluetooth = 0
    case lan = 1
}

// Plain input model decoupled from Bluetooth/LAN types.
struct DeviceRecord: Sendable, Hashable {
    let id: String
    var name: String?
    var type: DeviceType
    var lastSeen: Date?
    var rssi: Int32?
    var ip: String?

    init(id: String,
         name: String? = nil,
         type: DeviceType,
         lastSeen: Date? = nil,
         rssi: Int32? = nil,
         ip: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.lastSeen = lastSeen
        self.rssi = rssi
        self.ip = ip
    }
}

// The app-facing model replacing DeviceEntity
struct Device: Identifiable, Hashable, Sendable {
    let id: String
    var name: String?
    var type: DeviceType
    var lastSeen: Date?
    var rssi: Int32
    var ip: String?
}

actor PersistenceService {
    static let shared = PersistenceService()

    // In-memory storage keyed by id
    private var storage: [String: Device] = [:]

    init() { }

    // Upsert by id. Never overwrites a meaningful stored name with empty/"Unknown".
    @discardableResult
    func add(_ record: DeviceRecord) async -> Device {
        let existing = storage[record.id]

        // Resolve name: avoid overwriting a good name with empty/Unknown
        let trimmedCandidate = record.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isMeaningful = (trimmedCandidate?.isEmpty == false) &&
                           (trimmedCandidate?.caseInsensitiveCompare("unknown") != .orderedSame)
        let resolvedName: String? = {
            if isMeaningful {
                return trimmedCandidate
            } else {
                return existing?.name // keep previous good name
            }
        }()

        let device = Device(
            id: record.id,
            name: resolvedName ?? existing?.name,
            type: record.type,
            lastSeen: record.lastSeen ?? existing?.lastSeen ?? Date(),
            rssi: record.rssi ?? existing?.rssi ?? 0,
            ip: record.ip ?? existing?.ip
        )
        storage[record.id] = device
        return device
    }

    func delete(id: String) async {
        storage.removeValue(forKey: id)
    }

    // Simple fetch using NSPredicate replacement via closure for flexibility
    // If you prefer NSPredicate, we can add it back, but a closure is simpler without Core Data.
    func fetch(
        where matches: ((Device) -> Bool)? = nil,
        sort: ((Device, Device) -> Bool)? = { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) },
        limit: Int? = nil
    ) async -> [Device] {
        var values = Array(storage.values)
        if let matches { values = values.filter(matches) }
        if let sort { values.sort(by: sort) }
        if let limit { values = Array(values.prefix(limit)) }
        return values
    }
}
