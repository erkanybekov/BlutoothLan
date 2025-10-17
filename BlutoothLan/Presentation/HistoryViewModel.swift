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
    private let persistence: PersistenceService

    @Published var items: [DeviceEntity] = []
    @Published var searchText: String = ""
    @Published var filterType: HistoryFilterType = .all
    @Published var dateFrom: Date?
    @Published var dateTo: Date?

    private var cancellables: Set<AnyCancellable> = []

    init(persistence: PersistenceService = .shared) {
        self.persistence = persistence
        // Автоматическое обновление при изменении фильтров
        Publishers.CombineLatest4($searchText.debounce(for: .milliseconds(250), scheduler: DispatchQueue.main),
                                  $filterType,
                                  $dateFrom,
                                  $dateTo)
        .sink { [weak self] _, _, _, _ in
            Task { await self?.reload() }
        }
        .store(in: &cancellables)
    }

    func reload() async {
        var predicates: [NSPredicate] = []

        switch filterType {
        case .all:
            break
        case .bluetooth:
            predicates.append(NSPredicate(format: "type == %d", DeviceType.bluetooth.rawValue))
        case .lan:
            predicates.append(NSPredicate(format: "type == %d", DeviceType.lan.rawValue))
        }

        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let q = searchText
            predicates.append(NSPredicate(format: "name CONTAINS[cd] %@ OR id CONTAINS[cd] %@ OR ip CONTAINS[cd] %@", q, q, q))
        }

        if let from = dateFrom {
            predicates.append(NSPredicate(format: "lastSeen >= %@", from as NSDate))
        }
        if let to = dateTo {
            predicates.append(NSPredicate(format: "lastSeen <= %@", to as NSDate))
        }

        let predicate = predicates.isEmpty ? nil : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        let sort = [NSSortDescriptor(key: "lastSeen", ascending: false)]

        do {
            let result = try await persistence.fetchDevices(predicate: predicate, sort: sort, limit: nil)
            await MainActor.run { self.items = result }
        } catch {
            // В продакшене: логировать/показать ошибку
        }
    }
}
