//
//  ServiceDetailView.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 1/6/26.
//

import SwiftUI
import CoreBluetooth

struct ServiceDetailView: View {
    let service: DiscoveredService
    @ObservedObject var viewModel: DeviceDetailViewModel
    
    @State private var showWriteSheet: Bool = false
    @State private var selectedCharacteristic: DiscoveredCharacteristic?
    @State private var writeText: String = ""
    
    var body: some View {
        List {
            // Service info
            Section {
                ValueRow("UUID", value: service.id, monospaced: true)
                ValueRow("Characteristics", value: "\(service.characteristics.count)")
            } header: {
                Text("Service Info")
            }
            
            // Characteristics
            Section {
                if service.characteristics.isEmpty {
                    Text("No characteristics discovered")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(service.characteristics) { characteristic in
                        CharacteristicRow(
                            characteristic: characteristic,
                            onRead: {
                                viewModel.readValue(for: characteristic.characteristic)
                            },
                            onWrite: {
                                selectedCharacteristic = characteristic
                                writeText = ""
                                showWriteSheet = true
                            },
                            onToggleNotify: { enabled in
                                viewModel.toggleNotify(for: characteristic.characteristic, enabled: enabled)
                            }
                        )
                    }
                }
            } header: {
                Text("Characteristics")
            } footer: {
                Text("Tap actions to interact with each characteristic.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(service.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showWriteSheet) {
            writeSheet
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
    
    // MARK: - Write Sheet
    
    @ViewBuilder
    private var writeSheet: some View {
        NavigationView {
            VStack(spacing: 20) {
                if let char = selectedCharacteristic {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Characteristic")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(char.id)
                            .font(.callout.monospaced())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(12)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Value to write (hex or text)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    TextField("e.g. 01 02 03 or Hello", text: $writeText)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                }
                
                HStack(spacing: 12) {
                    Button("Write as Hex") {
                        writeHexValue()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(writeText.isEmpty)
                    
                    Button("Write as Text") {
                        writeTextValue()
                    }
                    .buttonStyle(.bordered)
                    .disabled(writeText.isEmpty)
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("Write Value")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showWriteSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
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
}

// MARK: - Characteristic Row

struct CharacteristicRow: View {
    let characteristic: DiscoveredCharacteristic
    let onRead: () -> Void
    let onWrite: () -> Void
    let onToggleNotify: (Bool) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // UUID and properties
            VStack(alignment: .leading, spacing: 4) {
                Text(characteristicName)
                    .font(.headline)
                Text(characteristic.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospaced()
                
                // Properties badges
                HStack(spacing: 6) {
                    if characteristic.canRead {
                        PropertyBadge(text: "Read", color: .blue)
                    }
                    if characteristic.canWrite {
                        PropertyBadge(text: "Write", color: .green)
                    }
                    if characteristic.canNotify {
                        PropertyBadge(text: "Notify", color: .orange)
                    }
                }
            }
            
            // Value display
            if let value = characteristic.value, !value.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Value")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Text(value.hexString(spaced: true))
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                    
                    // Try to show as string if valid UTF-8
                    if let string = String(data: value, encoding: .utf8),
                       !string.isEmpty,
                       string.allSatisfy({ $0.isASCII && !$0.isNewline }) {
                        Text("ASCII: \(string)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(white: 0.5, opacity: 0.1))
                .cornerRadius(8)
            }
            
            // Action buttons
            HStack(spacing: 12) {
                if characteristic.canRead {
                    Button {
                        onRead()
                    } label: {
                        Label("Read", systemImage: "arrow.down.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                
                if characteristic.canWrite {
                    Button {
                        onWrite()
                    } label: {
                        Label("Write", systemImage: "arrow.up.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                
                if characteristic.canNotify {
                    Button {
                        onToggleNotify(!characteristic.isNotifying)
                    } label: {
                        Label(
                            characteristic.isNotifying ? "Unsubscribe" : "Subscribe",
                            systemImage: characteristic.isNotifying ? "bell.slash" : "bell"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(characteristic.isNotifying ? .orange : nil)
                }
            }
        }
        .padding(.vertical, 8)
    }
    
    private var characteristicName: String {
        knownCharacteristicNames[characteristic.id] ?? "Characteristic"
    }
}

// MARK: - Property Badge

struct PropertyBadge: View {
    let text: String
    let color: Color
    
    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
}

// MARK: - Known Characteristic Names

private let knownCharacteristicNames: [String: String] = [
    "2A00": "Device Name",
    "2A01": "Appearance",
    "2A04": "Peripheral Preferred Connection Parameters",
    "2A19": "Battery Level",
    "2A24": "Model Number String",
    "2A25": "Serial Number String",
    "2A26": "Firmware Revision String",
    "2A27": "Hardware Revision String",
    "2A28": "Software Revision String",
    "2A29": "Manufacturer Name String",
    "2A37": "Heart Rate Measurement",
    "2A38": "Body Sensor Location",
    "2A6E": "Temperature",
    "2A6F": "Humidity",
]


