//
//  HistoryViewModel.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 10/17/25.
//

import Foundation
import Combine

enum HistoryFilterType: String, CaseIterable, Identifiable {
    case all = "All"
    case bluetooth = "Bluetooth"
    case lan = "LAN"
    var id: String { rawValue }
}

@MainActor
final class HistoryViewModel: ObservableObject {
    private let persistence: PersistenceService
    
    @Published var items: [Device] = []
    @Published var searchText: String = ""
    @Published var filterType: HistoryFilterType = .all
    @Published var dateFrom: Date?
    @Published var dateTo: Date?
    
    private var cancellables: Set<AnyCancellable> = []
    
    init(persistence: PersistenceService = .shared) {
        self.persistence = persistence

        Publishers.CombineLatest4(
            $searchText
                .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
                .removeDuplicates(),
            $filterType.removeDuplicates(),
            $dateFrom.removeDuplicates(),
            $dateTo.removeDuplicates()
        )
        .sink { [weak self] _, _, _, _ in
            Task { await self?.reload() }
        }
        .store(in: &cancellables)

        Task { @MainActor in
            await self.reload()
        }
    }
    
    func reload() async {
        // Build the filter closure
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSearch = !trimmedSearch.isEmpty

        let typeFilter: DeviceType? = {
            switch filterType {
            case .all: return nil
            case .bluetooth: return .bluetooth
            case .lan: return .lan
            }
        }()

        let matches: (Device) -> Bool = { device in
            // Type
            if let type = typeFilter, device.type != type {
                return false
            }
            // Search in name or id
            if hasSearch {
                let name = (device.name ?? "").lowercased()
                let id = device.id.lowercased()
                let q = trimmedSearch.lowercased()
                if !name.contains(q) && !id.contains(q) {
                    return false
                }
            }
            // Date range
            if let from = self.dateFrom {
                if let last = device.lastSeen {
                    if last < from { return false }
                } else {
                    return false
                }
            }
            if let to = self.dateTo {
                if let last = device.lastSeen {
                    if last > to { return false }
                } else {
                    return false
                }
            }
            return true
        }

        let sort: (Device, Device) -> Bool = {
            ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast)
        }

        let result = await persistence.fetch(where: matches, sort: sort, limit: nil)
        self.items = result
    }
    
    // MARK: - Deletes
    
    func delete(item: Device) async {
        let id = item.id
        await persistence.delete(id: id)
        await reload()
    }
    
    func deleteAll(of type: HistoryFilterType? = nil) async {
        switch type {
        case .some(.bluetooth):
            await deleteByFilter { $0.type == .bluetooth }
        case .some(.lan):
            await deleteByFilter { $0.type == .lan }
        case .some(.all), .none:
            await deleteByFilter { _ in true }
        }
        await reload()
    }

    private func deleteByFilter(_ predicate: @escaping (Device) -> Bool) async {
        let all = await persistence.fetch(where: predicate, sort: nil, limit: nil)
        for obj in all {
            await persistence.delete(id: obj.id)
        }
    }
}
