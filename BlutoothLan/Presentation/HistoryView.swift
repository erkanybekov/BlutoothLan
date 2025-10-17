//
//  HistoryView.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 10/17/25.
//

import SwiftUI

struct HistoryView: View {
    @StateObject private var viewModel = HistoryViewModel()

    var body: some View {
        List {
            filtersSection

            Section(header: Text("Devices")) {
                if viewModel.items.isEmpty {
                    VStack(alignment: .center, spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No history yet")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
                } else {
                    ForEach(viewModel.items, id: \.objectID) { device in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: device.type == DeviceType.bluetooth.rawValue ? "dot.radiowaves.left.and.right" : "bonjour")
                                    .foregroundStyle(device.type == DeviceType.bluetooth.rawValue ? .blue : .purple)
                                Text(device.name ?? device.id ?? "Unknown")
                                    .font(.headline)
                                    .lineLimit(1)
                                Spacer()
                                if let last = device.lastSeen {
                                    Text(Self.dateFormatter.string(from: last))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            HStack(spacing: 8) {
                                if let id = device.id {
                                    Text(id.suffix(6))
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                if let ip = device.ip, !ip.isEmpty {
                                    Text(ip)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if device.type == DeviceType.bluetooth.rawValue, device.rssi != 0 {
                                    Text("RSSI \(device.rssi)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("History")
        .task {
            await viewModel.reload()
        }
    }

    private var filtersSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Type", selection: $viewModel.filterType) {
                    ForEach(HistoryFilterType.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)

                if #available(iOS 15.0, *) {
                    TextField("Search name, id or IP", text: $viewModel.searchText)
                        .textFieldStyle(.roundedBorder)
                } else {
                    // iOS 14 fallback (если вдруг)
                    Text("Search requires iOS 15")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    // Преобразуем Binding<Date?> -> Binding<Date> с дефолтным значением
                    DatePicker("From",
                               selection: Binding($viewModel.dateFrom, replacingNilWith: Date()),
                               displayedComponents: .date)
                    DatePicker("To",
                               selection: Binding($viewModel.dateTo, replacingNilWith: Date()),
                               displayedComponents: .date)
                }
                .labelsHidden()
            }
        } header: {
            Text("Filters")
        }
    }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return df
    }()
}

// MARK: - Helpers for optional Date binding

private extension Binding where Value == Date {
    init(_ source: Binding<Date?>, replacingNilWith defaultValue: Date) {
        self.init(
            get: { source.wrappedValue ?? defaultValue },
            set: { newValue in source.wrappedValue = newValue }
        )
    }
}
