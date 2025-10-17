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
        let sort = [NSSortDescriptor(key: "lastSeen", ascending: false)]
        do {
            let result = try await persistence.fetchDevices(predicate: nil, sort: sort, limit: nil)
            await MainActor.run { self.items = result }
        } catch {
            // В продакшене можно добавить обработку ошибки/логирование
        }
    }
}
