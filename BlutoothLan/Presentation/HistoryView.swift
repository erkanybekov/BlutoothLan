//
//  HistoryView.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 10/17/25.
//

import SwiftUI

struct HistoryView: View {
    @StateObject private var viewModel = HistoryViewModel()

    // Фильтры UI
    @State private var showFilters: Bool = true
    @State private var showClearMenu: Bool = false

    var body: some View {
        List {
            // MARK: - Filters
            if showFilters {
                Section(header: Text("Filters")) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search by name or ID", text: $viewModel.searchText)
                            .textFieldStyle(.roundedBorder)
                    }

                    Picker("Type", selection: $viewModel.filterType) {
                        ForEach(HistoryFilterType.allCases) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)

                    // Compact date filter menu instead of inline date pickers
                    Menu {
                        // Quick presets
                        Button("Last hour") {
                            let now = Date()
                            viewModel.dateFrom = now.addingTimeInterval(-3600)
                            viewModel.dateTo = now
                        }
                        Button("Today") {
                            let cal = Calendar.current
                            let start = cal.startOfDay(for: Date())
                            viewModel.dateFrom = start
                            viewModel.dateTo = Date()
                        }
                        Button("Last 24 hours") {
                            let now = Date()
                            viewModel.dateFrom = now.addingTimeInterval(-24 * 3600)
                            viewModel.dateTo = now
                        }
                        Divider()
                        // Simple toggles to enable/clear each bound independently
                        Button(viewModel.dateFrom == nil ? "Set From = Now - 24h" : "Clear From") {
                            if viewModel.dateFrom == nil {
                                viewModel.dateFrom = Date().addingTimeInterval(-24 * 3600)
                            } else {
                                viewModel.dateFrom = nil
                            }
                        }
                        Button(viewModel.dateTo == nil ? "Set To = Now" : "Clear To") {
                            if viewModel.dateTo == nil {
                                viewModel.dateTo = Date()
                            } else {
                                viewModel.dateTo = nil
                            }
                        }
                        Divider()
                        Button("Clear All Date Filters") {
                            viewModel.dateFrom = nil
                            viewModel.dateTo = nil
                        }
                    } label: {
                        HStack {
                            Image(systemName: "calendar")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Date range")
                                Text(dateSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
            }

            // MARK: - Items
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
                    ForEach(viewModel.items, id: \.id) { device in
                        NavigationLink {
                            // If you want to reuse DetailedView, you can add an initializer for Device.
                            // For now, show a simple detail.
                            VStack(alignment: .leading, spacing: 12) {
                                Text(device.name ?? device.id).font(.title3)
                                Text("ID: \(device.id)").font(.callout).foregroundStyle(.secondary)
                                if let last = device.lastSeen {
                                    Text("Last Seen: \(Self.dateFormatter.string(from: last))").font(.callout)
                                }
                                if device.type == .bluetooth, device.rssi != 0 {
                                    Text("RSSI \(device.rssi)").font(.callout)
                                }
                                if let ip = device.ip, !ip.isEmpty {
                                    Text("IP: \(ip)").font(.callout)
                                }
                            }
                            .padding()
                            .navigationTitle("Details")
                            .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: device.type == .bluetooth ? "dot.radiowaves.left.and.right" : "bonjour")
                                        .foregroundStyle(device.type == .bluetooth ? .blue : .purple)
                                    Text((device.name?.isEmpty == false ? device.name : nil) ?? device.id)
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
                                    Text(device.id.suffix(6))
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                    if let ip = device.ip, !ip.isEmpty {
                                        Text(ip)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    if device.type == .bluetooth, device.rssi != 0 {
                                        Text("RSSI \(device.rssi)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                Task { await viewModel.delete(item: device) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete(perform: deleteRows)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button {
                    showFilters.toggle()
                } label: {
                    Label(showFilters ? "Hide Filters" : "Show Filters",
                          systemImage: "line.3.horizontal.decrease.circle")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button("Clear Bluetooth", role: .destructive) {
                        Task { await viewModel.deleteAll(of: .bluetooth) }
                    }
                    Button("Clear LAN", role: .destructive) {
                        Task { await viewModel.deleteAll(of: .lan) }
                    }
                    Divider()
                    Button("Clear All", role: .destructive) {
                        Task { await viewModel.deleteAll(of: .all) }
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(viewModel.items.isEmpty)
            }
        }
        .task {
            await viewModel.reload()
        }
    }

    private var dateSummary: String {
        switch (viewModel.dateFrom, viewModel.dateTo) {
        case (nil, nil):
            return "Any time"
        case let (from?, nil):
            return "From \(Self.dateFormatter.string(from: from))"
        case let (nil, to?):
            return "To \(Self.dateFormatter.string(from: to))"
        case let (from?, to?):
            return "\(Self.dateFormatter.string(from: from)) – \(Self.dateFormatter.string(from: to))"
        }
    }

    private func deleteRows(at offsets: IndexSet) {
        let toDelete = offsets.map { viewModel.items[$0] }
        Task {
            for item in toDelete {
                await viewModel.delete(item: item)
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return df
    }()
}
