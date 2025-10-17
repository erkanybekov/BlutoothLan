//
//  DetailedView.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 10/17/25.
//

import SwiftUI
import CoreBluetooth

struct DetailedView: View {
    let item: DiscoveredPeripheral

    var body: some View {
        List {
            basicsSection
            advertisementSection
            rawAdvertisementSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    private var basicsSection: some View {
        Section {
            ValueRow("Name", value: item.name)
            ValueRow("Identifier", value: item.peripheral.identifier.uuidString)
            ValueRow("Last RSSI", value: "\(item.rssi)")
            ValueRow("Last Seen", value: dateFormatter.string(from: item.lastSeen))
            if let connectable = item.isConnectable {
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
            if let localName = item.advertisementData[CBAdvertisementDataLocalNameKey] as? String {
                ValueRow("Local Name", value: localName)
            }
            if let tx = item.advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber {
                ValueRow("Tx Power", value: "\(tx)")
            }
            if let uuids = item.advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID], !uuids.isEmpty {
                keyValueList(title: "Service UUIDs", values: uuids.map { $0.uuidString })
            }
            if let overflow = item.advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID], !overflow.isEmpty {
                keyValueList(title: "Overflow UUIDs", values: overflow.map { $0.uuidString })
            }
            if let solicited = item.advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID], !solicited.isEmpty {
                keyValueList(title: "Solicited UUIDs", values: solicited.map { $0.uuidString })
            }
            if let mfg = item.advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, !mfg.isEmpty {
                ValueRow("Manufacturer Data", value: mfg.hexString(spaced: true), monospaced: true)
            }
            if let serviceData = item.advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data], !serviceData.isEmpty {
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

        return item.advertisementData
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
