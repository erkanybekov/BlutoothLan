//
//  DetailedView.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 10/17/25.
//

import SwiftUI
import CoreBluetooth

// MARK: - DetailedView for Live Scan (with connection capability)

struct DetailedView: View {
    private let item: DiscoveredPeripheral
    @StateObject private var viewModel: DeviceDetailViewModel
    @State private var expandedServices: Set<String> = []
    @State private var showWriteSheet = false
    @State private var selectedCharacteristic: DiscoveredCharacteristic?
    @State private var writeText = ""
    @Environment(\.scenePhase) private var scenePhase
    
    init(item: DiscoveredPeripheral, bluetoothService: BluetoothService) {
        self.item = item
        self._viewModel = StateObject(wrappedValue: DeviceDetailViewModel(
            peripheral: item.peripheral,
            bluetoothService: bluetoothService
        ))
    }

    var body: some View {
        List {
            // Quick Actions (when connected)
            if viewModel.connectionState == .ready {
                quickActionsSection
            }
            
            // Connection section (only for connectable devices)
            if item.isConnectable == true {
                connectionSection
            }
            
            // Services & Characteristics inline (when connected)
            if !viewModel.services.isEmpty {
                servicesAndCharacteristicsSection
            }
            
            basicsSection

            if hasAnyAdvertisementContent {
                advertisementSection
                rawAdvertisementSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if viewModel.connectionState.isConnected {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.disconnect()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .sheet(isPresented: $showWriteSheet) {
            writeSheet
        }
        .onChange(of: scenePhase) { newPhase in
            // Only disconnect when app goes to background, not on navigation
            if newPhase == .background {
                viewModel.disconnect()
            }
        }
        .overlay(alignment: .bottom) {
            writeResultToast
        }
        .onChange(of: viewModel.lastWriteResult?.timestamp) { _ in
            // Auto-hide toast after 3 seconds
            if viewModel.lastWriteResult != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        viewModel.clearWriteResult()
                    }
                }
            }
        }
    }
    
    // MARK: - Write Result Toast
    
    @ViewBuilder
    private var writeResultToast: some View {
        if let result = viewModel.lastWriteResult {
            HStack(spacing: 10) {
                Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.title3)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.message)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(result.characteristicUUID.prefix(8) + "...")
                        .font(.caption2)
                        .opacity(0.8)
                }
                
                Spacer()
                
                Button {
                    withAnimation {
                        viewModel.clearWriteResult()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .opacity(0.7)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(result.success ? Color.green : Color.red)
            .foregroundColor(.white)
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: viewModel.lastWriteResult?.timestamp)
        }
    }
    
    // MARK: - Quick Actions Section
    
    private var quickActionsSection: some View {
        Section {
            // Battery Level (if available)
            if let batteryChar = findCharacteristic(uuid: "2A19") {
                HStack {
                    Image(systemName: "battery.100")
                        .foregroundStyle(.green)
                    Text("Battery Level")
                    Spacer()
                    if let value = batteryChar.value, let level = value.first {
                        Text("\(level)%")
                            .fontWeight(.semibold)
                    } else {
                        Button("Read") {
                            viewModel.readValue(for: batteryChar.characteristic)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            
            // Device Name (if available)
            if let nameChar = findCharacteristic(uuid: "2A00"),
               let value = nameChar.value,
               let name = String(data: value, encoding: .utf8) {
                HStack {
                    Image(systemName: "tag")
                        .foregroundStyle(.blue)
                    Text("Device Name")
                    Spacer()
                    Text(name)
                        .foregroundStyle(.secondary)
                }
            }
            
            // Manufacturer (if available)
            if let mfgChar = findCharacteristic(uuid: "2A29"),
               let value = mfgChar.value,
               let mfg = String(data: value, encoding: .utf8) {
                HStack {
                    Image(systemName: "building.2")
                        .foregroundStyle(.purple)
                    Text("Manufacturer")
                    Spacer()
                    Text(mfg)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Label("Quick Info", systemImage: "bolt.fill")
        }
    }
    
    private func findCharacteristic(uuid: String) -> DiscoveredCharacteristic? {
        for service in viewModel.services {
            if let char = service.characteristics.first(where: { $0.id == uuid }) {
                return char
            }
        }
        return nil
    }

    // MARK: - Connection Section
    
    private var connectionSection: some View {
        Section {
            // Status row
            HStack {
                Circle()
                    .fill(statusColor(for: viewModel.connectionState))
                    .frame(width: 10, height: 10)
                Text(viewModel.connectionStatusText)
                    .font(.subheadline)
                Spacer()
                if viewModel.isConnecting {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            
            // Connect/Disconnect button
            Button {
                viewModel.toggleConnection()
            } label: {
                HStack {
                    Spacer()
                    Text(viewModel.connectionButtonTitle)
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.connectionState.isConnected ? .red : .blue)
            .disabled(viewModel.isConnecting)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        } header: {
            Text("Connection")
        } footer: {
            connectionFooterText
        }
    }
    
    @ViewBuilder
    private var connectionFooterText: some View {
        switch viewModel.connectionState {
        case .disconnected:
            Text("Tap Connect to discover what this device can do.")
        case .connecting, .discoveringServices:
            Text("Establishing connection and reading device capabilities...")
        case .ready:
            Text("✓ Connected! Explore services below or use Quick Actions above.")
        case .failed(let error):
            Text("⚠️ \(error). Try again or move closer to the device.")
                .foregroundStyle(.red)
        default:
            EmptyView()
        }
    }
    
    private func statusColor(for state: BLEConnectionState) -> Color {
        switch state {
        case .disconnected: return .gray
        case .connecting, .connected, .discoveringServices: return .orange
        case .ready: return .green
        case .failed: return .red
        }
    }
    
    // MARK: - Services & Characteristics Inline
    
    private var servicesAndCharacteristicsSection: some View {
        ForEach(viewModel.services) { service in
            Section {
                // Service header (tappable to expand)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if expandedServices.contains(service.id) {
                            expandedServices.remove(service.id)
                        } else {
                            expandedServices.insert(service.id)
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: serviceIcon(for: service.id))
                            .foregroundStyle(serviceColor(for: service.id))
                            .frame(width: 24)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(service.name)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("\(service.characteristics.count) characteristics")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        Image(systemName: expandedServices.contains(service.id) ? "chevron.up" : "chevron.down")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                
                // Expanded characteristics
                if expandedServices.contains(service.id) {
                    ForEach(service.characteristics) { char in
                        characteristicRow(char, service: service)
                    }
                }
            } header: {
                if service.id == viewModel.services.first?.id {
                    Text("Services & Characteristics")
                }
            } footer: {
                if service.id == viewModel.services.first?.id && expandedServices.isEmpty {
                    Text("Tap a service to see its characteristics and interact with them.")
                }
            }
        }
    }
    
    private func serviceIcon(for uuid: String) -> String {
        switch uuid {
        case "180F": return "battery.100"
        case "180A": return "info.circle"
        case "180D": return "heart.fill"
        case "1800": return "antenna.radiowaves.left.and.right"
        case "1801": return "gearshape"
        default: return "cube.box"
        }
    }
    
    private func serviceColor(for uuid: String) -> Color {
        switch uuid {
        case "180F": return .green
        case "180A": return .blue
        case "180D": return .red
        case "1800": return .purple
        default: return .orange
        }
    }
    
    @ViewBuilder
    private func characteristicRow(_ char: DiscoveredCharacteristic, service: DiscoveredService) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Name and UUID
            HStack {
                Text(characteristicName(for: char.id))
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                // Property badges
                HStack(spacing: 4) {
                    if char.canRead {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.blue)
                            .font(.caption)
                    }
                    if char.canWrite {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                    if char.canNotify {
                        Image(systemName: char.isNotifying ? "bell.fill" : "bell")
                            .foregroundStyle(char.isNotifying ? .orange : .gray)
                            .font(.caption)
                    }
                }
            }
            
            // Value display
            if let value = char.value, !value.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    // Show human-readable value if possible
                    if let readable = humanReadableValue(for: char.id, data: value) {
                        Text(readable)
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                    }
                    
                    // Always show hex
                    Text(value.hexString(spaced: true))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(white: 0.5, opacity: 0.1))
                .cornerRadius(6)
            }
            
            // Hint about what this characteristic does
            if let hint = characteristicHint(for: char.id) {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            // Action buttons
            HStack(spacing: 8) {
                if char.canRead {
                    Button {
                        viewModel.readValue(for: char.characteristic)
                    } label: {
                        Label("Read", systemImage: "arrow.down")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                
                if char.canWrite {
                    Button {
                        selectedCharacteristic = char
                        writeText = ""
                        showWriteSheet = true
                    } label: {
                        Label("Write", systemImage: "arrow.up")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                
                if char.canNotify {
                    Button {
                        viewModel.toggleNotify(for: char.characteristic, enabled: !char.isNotifying)
                    } label: {
                        Label(char.isNotifying ? "Stop" : "Subscribe", systemImage: char.isNotifying ? "bell.slash" : "bell")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(char.isNotifying ? .orange : nil)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, 24) // Indent characteristics under service
    }
    
    private func characteristicName(for uuid: String) -> String {
        let names: [String: String] = [
            "2A00": "Device Name",
            "2A01": "Appearance",
            "2A19": "Battery Level",
            "2A24": "Model Number",
            "2A25": "Serial Number",
            "2A26": "Firmware Version",
            "2A27": "Hardware Version",
            "2A28": "Software Version",
            "2A29": "Manufacturer",
            "2A37": "Heart Rate",
            "2A6E": "Temperature",
            "2A6F": "Humidity",
        ]
        return names[uuid] ?? "Unknown (\(uuid.prefix(8))...)"
    }
    
    private func characteristicHint(for uuid: String) -> String? {
        let hints: [String: String] = [
            "2A00": "The advertised name of this device",
            "2A19": "Current battery percentage (0-100%)",
            "2A29": "Company that made this device",
            "2A26": "Firmware version for updates",
            "2A37": "Real-time heart rate data (subscribe to monitor)",
            "2A6E": "Temperature sensor reading",
        ]
        return hints[uuid]
    }
    
    private func humanReadableValue(for uuid: String, data: Data) -> String? {
        switch uuid {
        case "2A19": // Battery Level
            if let level = data.first {
                return "\(level)%"
            }
        case "2A00", "2A24", "2A25", "2A26", "2A27", "2A28", "2A29": // String values
            if let str = String(data: data, encoding: .utf8) {
                return str.trimmingCharacters(in: .controlCharacters)
            }
        case "2A6E": // Temperature
            if data.count >= 2 {
                let temp = Int16(data[0]) | (Int16(data[1]) << 8)
                return String(format: "%.1f°C", Double(temp) / 100.0)
            }
        default:
            // Для неизвестных характеристик пробуем декодировать как текст
            if let readable = data.asReadableText(), !readable.isEmpty {
                return readable
            }
        }
        return nil
    }

    // MARK: - Write Sheet
    
    @ViewBuilder
    private var writeSheet: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    if let char = selectedCharacteristic {
                        // Characteristic info
                        VStack(alignment: .leading, spacing: 8) {
                            Text(characteristicName(for: char.id))
                                .font(.headline)
                            Text(char.id)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            
                            if let hint = characteristicHint(for: char.id) {
                                Text(hint)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(12)
                        
                        // Common values for known characteristics
                        if let suggestions = writeSuggestions(for: char.id) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Быстрые значения")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                
                                FlowLayout(spacing: 8) {
                                    ForEach(suggestions, id: \.0) { label, value in
                                        Button(label) {
                                            writeText = value
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                }
                            }
                        }
                    }
                    
                    // Input field
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Введите значение")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        TextField("Текст или hex (01 02 03)", text: $writeText)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                    }
                    
                    // Live preview of what will be sent
                    if !writeText.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Предпросмотр")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            // Text → Hex preview
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: "text.quote")
                                        .foregroundStyle(.blue)
                                    Text("Как текст")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                }
                                if let textData = writeText.data(using: .utf8) {
                                    Text(textData.hexString(spaced: true))
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                    Text("\(textData.count) байт")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(8)
                            
                            // Hex preview (if valid)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: "number")
                                        .foregroundStyle(.orange)
                                    Text("Как hex")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                }
                                let cleanHex = writeText.replacingOccurrences(of: " ", with: "")
                                if let hexData = Data(hexString: cleanHex) {
                                    if let readable = hexData.asReadableText() {
                                        Text("→ \"\(readable)\"")
                                            .font(.caption)
                                            .foregroundStyle(.primary)
                                    }
                                    Text("\(hexData.count) байт")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                } else {
                                    Text("⚠️ Неверный hex формат")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(8)
                        }
                    }
                    
                    // Action buttons
                    VStack(spacing: 10) {
                        Button {
                            writeTextValue()
                        } label: {
                            HStack {
                                Image(systemName: "text.quote")
                                Text("Отправить как текст")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .disabled(writeText.isEmpty)
                        
                        Button {
                            writeHexValue()
                        } label: {
                            HStack {
                                Image(systemName: "number")
                                Text("Отправить как hex")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(writeText.isEmpty || Data(hexString: writeText.replacingOccurrences(of: " ", with: "")) == nil)
                    }
                    
                    // Help section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("💡 Подсказка")
                            .font(.caption)
                            .fontWeight(.medium)
                        
                        Text("• **Текст**: введите команду как есть (например: `ON`, `OFF`, `hello`)\n• **Hex**: введите байты через пробел (например: `01 02 FF`)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.yellow.opacity(0.1))
                    .cornerRadius(8)
                }
                .padding()
            }
            .navigationTitle("Отправить команду")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { showWriteSheet = false }
                }
            }
        }
        .presentationDetents([.large])
    }
    
    private func writeSuggestions(for uuid: String) -> [(String, String)]? {
        // Common write values for known characteristics
        switch uuid {
        case "2A00": // Device Name
            return [("My Device", "My Device"), ("iPhone", "iPhone")]
        default:
            // Типичные команды для неизвестных характеристик
            return [
                ("ON", "01"),
                ("OFF", "00"),
                ("0x01", "01"),
                ("0x00", "00"),
                ("0xFF", "FF"),
                ("Test", "Test")
            ]
        }
    }
    
    private func writeHexValue() {
        guard let char = selectedCharacteristic else { return }
        let hexString = writeText.replacingOccurrences(of: " ", with: "")
        if let data = Data(hexString: hexString) {
            viewModel.writeValue(data, for: char.characteristic)
            showWriteSheet = false
        }
    }
    
    private func writeTextValue() {
        guard let char = selectedCharacteristic else { return }
        if let data = writeText.data(using: .utf8) {
            viewModel.writeValue(data, for: char.characteristic)
            showWriteSheet = false
        }
    }

    // MARK: - Basics Section

    private var basicsSection: some View {
        Section {
            ValueRow("Name", value: item.name)
            ValueRow("Identifier", value: item.peripheral.identifier.uuidString, monospaced: true)
            ValueRow("Last RSSI", value: "\(item.rssi.intValue) dBm")
            ValueRow("Last Seen", value: dateFormatter.string(from: item.lastSeen))
            if let connectable = item.isConnectable {
                ValueRow("Connectable", value: connectable ? "Yes" : "No")
            }
        } header: {
            Text("Device Info")
        }
    }

    private var advertisementSection: some View {
        Section {
            if let localName = item.advertisementData[CBAdvertisementDataLocalNameKey] as? String, !localName.isEmpty {
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

    private var hasAnyAdvertisementContent: Bool {
        if let s = item.advertisementData[CBAdvertisementDataLocalNameKey] as? String, !s.isEmpty { return true }
        if item.advertisementData[CBAdvertisementDataTxPowerLevelKey] != nil { return true }
        if let uuids = item.advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID], !uuids.isEmpty { return true }
        if let overflow = item.advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID], !overflow.isEmpty { return true }
        if let solicited = item.advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID], !solicited.isEmpty { return true }
        if let mfg = item.advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, !mfg.isEmpty { return true }
        if let serviceData = item.advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data], !serviceData.isEmpty { return true }
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

        return item.advertisementData
            .filter { !knownKeys.contains($0.key) }
            .map { (key: $0.key, value: stringify($0.value)) }
            .sorted { $0.key < $1.key }
    }

    private func stringify(_ value: Any) -> String {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let d as Data: return d.hexString(spaced: true)
        case let uuids as [CBUUID]: return uuids.map { $0.uuidString }.joined(separator: ", ")
        case let dict as [CBUUID: Data]:
            return dict.map { "\($0.key.uuidString): \($0.value.hexString(spaced: true))" }.sorted().joined(separator: " | ")
        case let arr as [Any]: return arr.map { stringify($0) }.joined(separator: ", ")
        default: return String(describing: value)
        }
    }

    private var dateFormatter: DateFormatter {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .medium
        return df
    }
}

// MARK: - FlowLayout for suggestions

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                      y: bounds.minY + result.positions[index].y),
                          proposal: .unspecified)
        }
    }
    
    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []
        
        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0
            
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                positions.append(CGPoint(x: x, y: y))
                rowHeight = max(rowHeight, size.height)
                x += size.width + spacing
                self.size.width = max(self.size.width, x)
            }
            self.size.height = y + rowHeight
        }
    }
}

// MARK: - HistoryDetailedView for Persisted History (no connection capability)

struct HistoryDetailedView: View {
    private let entity: DeviceEntity
    
    init(entity: DeviceEntity) {
        self.entity = entity
    }
    
    private var displayName: String {
        let name = (entity.name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        return name ?? (entity.id ?? "Unknown")
    }

    var body: some View {
        List {
            Section {
                ValueRow("Name", value: displayName)
                ValueRow("Identifier", value: entity.id ?? "—", monospaced: true)
                if entity.rssi != 0 {
                    ValueRow("Last RSSI", value: "\(entity.rssi) dBm")
                }
                if let lastSeen = entity.lastSeen {
                    ValueRow("Last Seen", value: dateFormatter.string(from: lastSeen))
                }
            } header: {
                Text("Device")
            } footer: {
                Text("This device was discovered in a previous scan.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            
            Section {
                Text("No saved advertisement details for this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Advertisement")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private var dateFormatter: DateFormatter {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .medium
        return df
    }
}

// MARK: - iOS 15-friendly labeled row

struct ValueRow: View {
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
