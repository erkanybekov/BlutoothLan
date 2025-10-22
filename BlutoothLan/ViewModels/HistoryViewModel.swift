//
//  HistoryViewModel.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 10/17/25.
//

import Foundation
import Combine
import CoreData

enum HistoryFilterType: String, CaseIterable, Identifiable {
    case all = "All"
    case bluetooth = "Bluetooth"
    case lan = "LAN"
    var id: String { rawValue }
}

@MainActor
final class HistoryViewModel: ObservableObject {
    // MARK: - Dependencies
    private let coreData: CoreDataManager

    // MARK: - Published state
    @Published var items: [Device] = []
    @Published var searchText: String = ""
    @Published var filterType: HistoryFilterType = .all
    @Published var dateFrom: Date?
    @Published var dateTo: Date?

    // MARK: - Private
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Init
    init(coreData: CoreDataManager = .instance) {
        self.coreData = coreData
        bind()
        Task { await reload() }
    }

    // MARK: - Binding
    private func bind() {
        Publishers.CombineLatest4(
            $searchText
                .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
                .removeDuplicates(),
            $filterType.removeDuplicates(),
            $dateFrom.removeDuplicates(),
            $dateTo.removeDuplicates()
        )
        .sink { [weak self] _, _, _, _ in
            guard let self else { return }
            Task { await self.reload() }
        }
        .store(in: &cancellables)
    }

    // MARK: - Public API

    /// Reloads items from Core Data using current filters.
    func reload() async {
        do {
            let predicate = buildPredicate(
                search: searchText,
                type: filterType,
                from: dateFrom,
                to: dateTo
            )
            let sort = [NSSortDescriptor(key: "lastSeen", ascending: false)]
            let entities = try await coreData.fetchDevices(predicate: predicate, sort: sort, fetchLimit: 0)
            self.items = entities.map(Self.mapEntityToDevice)
        } catch {
            // In production, consider surfacing an error state to the UI.
            print("HistoryViewModel reload error: \(error.localizedDescription)")
            self.items = []
        }
    }

    /// Deletes a single item by id.
    func delete(item: Device) async {
        do {
            try await coreData.deleteDevice(id: item.id)
            await reload()
        } catch {
            print("HistoryViewModel delete error: \(error.localizedDescription)")
        }
    }

    /// Deletes items by filter type (or all).
    func deleteAll(of type: HistoryFilterType? = nil) async {
        do {
            let predicate: NSPredicate? = {
                switch type {
                case .some(.bluetooth):
                    return NSPredicate(format: "type == %d", DeviceType.bluetooth.rawValue)
                case .some(.lan):
                    return NSPredicate(format: "type == %d", DeviceType.lan.rawValue)
                case .some(.all), .none:
                    return nil
                }
            }()
            try await coreData.deleteAllDevices(predicate: predicate)
            await reload()
        } catch {
            print("HistoryViewModel deleteAll error: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    /// Builds a Core Data predicate from current filters.
    private func buildPredicate(search: String,
                                type: HistoryFilterType,
                                from: Date?,
                                to: Date?) -> NSPredicate? {
        var subpredicates: [NSPredicate] = []

        // Type
        switch type {
        case .bluetooth:
            subpredicates.append(NSPredicate(format: "type == %d", DeviceType.bluetooth.rawValue))
        case .lan:
            subpredicates.append(NSPredicate(format: "type == %d", DeviceType.lan.rawValue))
        case .all:
            break
        }

        // Search in name or id (case-insensitive)
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let namePred = NSPredicate(format: "name CONTAINS[cd] %@", trimmed)
            let idPred = NSPredicate(format: "id CONTAINS[cd] %@", trimmed)
            subpredicates.append(NSCompoundPredicate(orPredicateWithSubpredicates: [namePred, idPred]))
        }

        // Date range
        if let from {
            subpredicates.append(NSPredicate(format: "lastSeen >= %@", from as NSDate))
        }
        if let to {
            subpredicates.append(NSPredicate(format: "lastSeen <= %@", to as NSDate))
        }

        guard !subpredicates.isEmpty else { return nil }
        return NSCompoundPredicate(andPredicateWithSubpredicates: subpredicates)
    }

    /// Maps DeviceEntity to app-facing Device model.
    private static func mapEntityToDevice(_ e: DeviceEntity) -> Device {
        Device(
            id: e.id ?? UUID().uuidString,
            name: {
                guard let s = e.name?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
                return s
            }(),
            type: DeviceType(rawValue: e.type) ?? .bluetooth,
            lastSeen: e.lastSeen,
            rssi: e.rssi,
            ip: {
                guard let s = e.ip?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
                return s
            }()
        )
    }
}
