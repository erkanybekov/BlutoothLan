//
//  PersistenceService.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 10/17/25.
//

import Foundation
import CoreData
import CoreBluetooth

enum DeviceType: Int16 {
    case bluetooth = 0
    case lan = 1
}

actor PersistenceService {
    static let shared = PersistenceService()

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "BlutoothLan")
        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }
        container.loadPersistentStores { _, error in
            if let error = error {
                assertionFailure("Core Data load error: \(error)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    // MARK: - Device CRUD
    
//Примечание: Для этого нужен DeviceEntity в .xcdatamodeld со свойствами:
//    • id: String
//    • name: String (Optional)
//    • type: Integer 16
//    • lastSeen: Date (Optional)
//    • rssi: Integer 32 (Optional)
//    • ip: String (Optional)

    func upsertBluetoothDevice(from peripheral: DiscoveredPeripheral) async throws {
        try await container.performBackgroundTask { ctx in
            let id = peripheral.peripheral.identifier.uuidString
            let req: NSFetchRequest<DeviceEntity> = DeviceEntity.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", id)
            req.fetchLimit = 1

            let device: DeviceEntity
            if let existing = try ctx.fetch(req).first {
                device = existing
            } else {
                device = DeviceEntity(context: ctx)
                device.id = id
                device.type = DeviceType.bluetooth.rawValue
            }

            device.name = peripheral.name
            device.lastSeen = Date()
            device.rssi = Int32(truncatingIfNeeded: peripheral.rssi.intValue)

            try ctx.save()
        }
    }

    func upsertLANDevice(from peer: LANPeer) async throws {
        try await container.performBackgroundTask { ctx in
            let id = peer.hostName ?? peer.name
            let req: NSFetchRequest<DeviceEntity> = DeviceEntity.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", id)
            req.fetchLimit = 1

            let device: DeviceEntity
            if let existing = try ctx.fetch(req).first {
                device = existing
            } else {
                device = DeviceEntity(context: ctx)
                device.id = id
                device.type = DeviceType.lan.rawValue
            }

            device.name = peer.name
            device.lastSeen = Date()
            device.ip = peer.hostName

            try ctx.save()
        }
    }

    func fetchDevices(predicate: NSPredicate? = nil,
                      sort: [NSSortDescriptor] = [NSSortDescriptor(key: "lastSeen", ascending: false)],
                      limit: Int? = nil) async throws -> [DeviceEntity] {
        try await withCheckedThrowingContinuation { cont in
            container.performBackgroundTask { ctx in
                let req: NSFetchRequest<DeviceEntity> = DeviceEntity.fetchRequest()
                req.predicate = predicate
                req.sortDescriptors = sort
                if let limit { req.fetchLimit = limit }
                do {
                    let result = try ctx.fetch(req)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
