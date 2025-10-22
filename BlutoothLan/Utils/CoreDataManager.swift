//
//  CoreDataManager.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 10/22/25.
//

@preconcurrency import CoreData

actor CoreDataManager {
    
    // MARK: - Singleton
    static let instance: CoreDataManager = {
        // Force-unwrap is safe here because we control the async construction below
        return try! CoreDataManager(modelName: "DeviceModel")
    }()
    
    // MARK: - Core Data stack
    let container: NSPersistentContainer
    let context: NSManagedObjectContext   // viewContext for read/UI
    
    // Dedicated background context for writes
    private let backgroundContext: NSManagedObjectContext
    
    // MARK: - Init
    
    // Async-friendly initializer that loads persistent stores without blocking the main thread.
    init(modelName: String) throws {
        let container = NSPersistentContainer(name: modelName)
        
        // Load stores synchronously inside a continuation to make this init throw/complete deterministically.
        var loadError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        container.loadPersistentStores { _, error in
            loadError = error
            semaphore.signal()
        }
        semaphore.wait()
        if let loadError {
            throw loadError
        }
        
        // Configure contexts
        let viewContext = container.viewContext
        viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        viewContext.automaticallyMergesChangesFromParent = true
        viewContext.undoManager = nil
        
        let bg = container.newBackgroundContext()
        bg.mergePolicy = NSMergePolicy.mergeByPropertyStoreTrump
        bg.automaticallyMergesChangesFromParent = true
        bg.undoManager = nil
        
        self.container = container
        self.context = viewContext
        self.backgroundContext = bg
    }
    
    // MARK: - Public API
    
    /// Fetch on the viewContext (read operations for UI). Safe to call from any actor.
    func fetch<T: NSManagedObject>(_ request: NSFetchRequest<T>) async throws -> [T] {
        try await context.perform {
            try self.context.fetch(request)
        }
    }
    
    /// Perform a write on the background context. Changes will merge into viewContext automatically.
    func performWrite(_ block: @escaping (NSManagedObjectContext) throws -> Void) async throws {
        try await backgroundContext.perform {
            try block(self.backgroundContext)
            if self.backgroundContext.hasChanges {
                try self.backgroundContext.save()
            }
        }
    }
    
    /// Save viewContext if it has changes (e.g., when edits happen on main).
    func saveViewContextIfNeeded() async throws {
        try await context.perform {
            if self.context.hasChanges {
                try self.context.save()
            }
        }
    }
    
    // Convenience helpers for common operations on DeviceEntity
    
    /// Fetch all DeviceEntity with optional predicate/sort/limit
    func fetchDevices(predicate: NSPredicate? = nil,
                      sort: [NSSortDescriptor] = [NSSortDescriptor(key: "lastSeen", ascending: false)],
                      fetchLimit: Int = 0) async throws -> [DeviceEntity] {
        let request = NSFetchRequest<DeviceEntity>(entityName: "DeviceEntity")
        request.predicate = predicate
        request.sortDescriptors = sort
        request.fetchLimit = fetchLimit
        return try await fetch(request)
    }
    
    /// Upsert a DeviceEntity by id
    func upsertDevice(id: String,
                      name: String?,
                      type: Int16,
                      lastSeen: Date?,
                      rssi: Int32?,
                      ip: String?) async throws {
        try await performWrite { ctx in
            let request = NSFetchRequest<DeviceEntity>(entityName: "DeviceEntity")
            request.predicate = NSPredicate(format: "id == %@", id)
            request.fetchLimit = 1
            
            let existing = try ctx.fetch(request).first
            let obj = existing ?? DeviceEntity(context: ctx)
            
            // Assign fields
            obj.id = id
            if let name = name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               name.caseInsensitiveCompare("unknown") != .orderedSame {
                obj.name = name
            } else if existing == nil {
                // Keep nil rather than writing "Unknown"
                obj.name = nil
            }
            obj.type = type
            if let lastSeen { obj.lastSeen = lastSeen }
            if let rssi { obj.rssi = rssi }
            if let ip { obj.ip = ip }
        }
    }
    
    /// Delete one DeviceEntity by id
    func deleteDevice(id: String) async throws {
        try await performWrite { ctx in
            let request = NSFetchRequest<NSManagedObjectID>(entityName: "DeviceEntity")
            request.resultType = .managedObjectIDResultType
            request.predicate = NSPredicate(format: "id == %@", id)
            let ids = try ctx.fetch(request)
            for oid in ids {
                if let obj = try? ctx.existingObject(with: oid) {
                    ctx.delete(obj)
                }
            }
        }
    }
    
    /// Delete all DeviceEntity optionally filtered by predicate
    func deleteAllDevices(predicate: NSPredicate? = nil) async throws {
        try await performWrite { ctx in
            let fetch = NSFetchRequest<NSFetchRequestResult>(entityName: "DeviceEntity")
            fetch.predicate = predicate
            let batch = NSBatchDeleteRequest(fetchRequest: fetch)
            batch.resultType = .resultTypeObjectIDs
            let result = try ctx.execute(batch) as? NSBatchDeleteResult
            if let ids = result?.result as? [NSManagedObjectID], !ids.isEmpty {
                let changes = [NSDeletedObjectsKey: ids]
                NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [self.context, ctx])
            }
        }
    }
    
    // MARK: - Legacy compatibility
    
    /// Legacy `save()` kept for compatibility with older call sites.
    func save() {
        Task {
            try? await saveViewContextIfNeeded()
        }
    }
}
