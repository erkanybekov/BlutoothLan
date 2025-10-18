//
//  DetailedView.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 10/17/25.
//

import SwiftUI
import CoreBluetooth

struct DetailedView: View {
    // Unified source used by the view, can be built from live scan or persisted entity.
    private let source: DetailSource

    // Keep existing initializer for live scans
    init(item: DiscoveredPeripheral) {
        self.source = DetailSource(
            name: item.name,
            identifier: item.peripheral.identifier.uuidString,
            rssi: item.rssi.intValue,
            lastSeen: item.lastSeen,
            advertisementData: item.advertisementData,
            isConnectable: item.isConnectable
        )
    }

    // New initializer for persisted history
    init(entity: DeviceEntity) {
        let name = (entity.name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        let identifier = entity.id ?? "—"
        let rssiValue = (entity.rssi != 0) ? Int(entity.rssi) : nil
        let lastSeen = entity.lastSeen

        // Simple path: no decoded advertisement data (we can extend later if needed)
        self.source = DetailSource(
            name: name ?? identifier,
            identifier: identifier,
            rssi: rssiValue,
            lastSeen: lastSeen,
            advertisementData: [:],
            isConnectable: nil
        )
    }

    var body: some View {
        List {
            basicsSection

            if hasAnyAdvertisementContent {
                advertisementSection
                rawAdvertisementSection
            } else {
                // Optional: show a small hint that no advertisement details are available
                Section {
                    Text("No saved advertisement details for this device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Advertisement")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    private var basicsSection: some View {
        Section {
            ValueRow("Name", value: source.name)
            ValueRow("Identifier", value: source.identifier, monospaced: true)
            if let rssi = source.rssi {
                ValueRow("Last RSSI", value: "\(rssi)")
            }
            if let lastSeen = source.lastSeen {
                ValueRow("Last Seen", value: dateFormatter.string(from: lastSeen))
            }
            if let connectable = source.isConnectable {
                ValueRow("Connectable", value: connectable ? "Yes" : "No")
            }
        } header: {
            Text("Device")
        } footer: {
            Text("Information shown here comes from Bluetooth advertisements. No connection is made.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var advertisementSection: some View {
        Section {
            if let localName = source.advertisementData[CBAdvertisementDataLocalNameKey] as? String, !localName.isEmpty {
                ValueRow("Local Name", value: localName)
            }
            if let tx = source.advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber {
                ValueRow("Tx Power", value: "\(tx)")
            }
            if let uuids = source.advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID], !uuids.isEmpty {
                keyValueList(title: "Service UUIDs", values: uuids.map { $0.uuidString })
            }
            if let overflow = source.advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID], !overflow.isEmpty {
                keyValueList(title: "Overflow UUIDs", values: overflow.map { $0.uuidString })
            }
            if let solicited = source.advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID], !solicited.isEmpty {
                keyValueList(title: "Solicited UUIDs", values: solicited.map { $0.uuidString })
            }
            if let mfg = source.advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, !mfg.isEmpty {
                ValueRow("Manufacturer Data", value: mfg.hexString(spaced: true), monospaced: true)
            }
            if let serviceData = source.advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data], !serviceData.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Service Data")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ForEach(serviceData.sorted(by: { $0.key.uuidString < $1.key.uuidString }), id: \.key) { entry in
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.key.uuidString)
                                .font(.callout)
                            Spacer(minLength: 8)
                            Text(entry.value.hexString(spaced: true))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
        } header: {
            Text("Advertisement")
        }
    }

    private var rawAdvertisementSection: some View {
        Section {
            ForEach(remainingAdvertisementPairs(), id: \.key) { pair in
                ValueRow(pair.key, value: pair.value, monospaced: true)
            }
        } header: {
            Text("Raw Advertisement")
        }
    }

    // MARK: - Helpers

    private var hasAnyAdvertisementContent: Bool {
        // Check if any known advertisement keys exist
        if let s = source.advertisementData[CBAdvertisementDataLocalNameKey] as? String, !s.isEmpty { return true }
        if source.advertisementData[CBAdvertisementDataTxPowerLevelKey] != nil { return true }
        if let uuids = source.advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID], !uuids.isEmpty { return true }
        if let overflow = source.advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID], !overflow.isEmpty { return true }
        if let solicited = source.advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID], !solicited.isEmpty { return true }
        if let mfg = source.advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, !mfg.isEmpty { return true }
        if let serviceData = source.advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data], !serviceData.isEmpty { return true }
        // Or any unknown keys
        return !remainingAdvertisementPairs().isEmpty
    }

    private func keyValueList(title: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(values, id: \.self) { v in
                Text(v).font(.callout)
            }
        }
    }

    private func remainingAdvertisementPairs() -> [(key: String, value: String)] {
        let knownKeys: Set<String> = [
            CBAdvertisementDataLocalNameKey,
            CBAdvertisementDataIsConnectable,
            CBAdvertisementDataTxPowerLevelKey,
            CBAdvertisementDataServiceUUIDsKey,
            CBAdvertisementDataOverflowServiceUUIDsKey,
            CBAdvertisementDataSolicitedServiceUUIDsKey,
            CBAdvertisementDataManufacturerDataKey,
            CBAdvertisementDataServiceDataKey
        ]

        return source.advertisementData
            .filter { !knownKeys.contains($0.key) }
            .map { (key: $0.key, value: stringify($0.value)) }
            .sorted { $0.key < $1.key }
    }

    private func stringify(_ value: Any) -> String {
        switch value {
        case let s as String:
            return s
        case let n as NSNumber:
            return n.stringValue
        case let d as Data:
            return d.hexString(spaced: true)
        case let uuids as [CBUUID]:
            return uuids.map { $0.uuidString }.joined(separator: ", ")
        case let dict as [CBUUID: Data]:
            return dict
                .map { "\($0.key.uuidString): \($0.value.hexString(spaced: true))" }
                .sorted()
                .joined(separator: " | ")
        case let arr as [Any]:
            return arr.map { stringify($0) }.joined(separator: ", ")
        default:
            return String(describing: value)
        }
    }

    private var dateFormatter: DateFormatter {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .medium
        return df
    }
}

// MARK: - Internal model

private struct DetailSource {
    let name: String
    let identifier: String
    let rssi: Int?
    let lastSeen: Date?
    let advertisementData: [String: Any]
    let isConnectable: Bool?
}

// MARK: - iOS 15-friendly labeled row

private struct ValueRow: View {
    let title: String
    let value: String
    var monospaced: Bool = false

    init(_ title: String, value: String, monospaced: Bool = false) {
        self.title = title
        self.value = value
        self.monospaced = monospaced
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Small Data helper used above

private extension Data {
    func hexString(_ spaced: Bool = false) -> String {
        let hex = self.map { String(format: "%02x", $0) }.joined(separator: spaced ? " " : "")
        return hex.uppercased()
    }
}
