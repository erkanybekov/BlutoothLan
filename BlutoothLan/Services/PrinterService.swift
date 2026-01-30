//
//  PrinterService.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 1/30/26.
//

import Foundation
import CoreBluetooth
import UIKit
import Combine

// MARK: - Printer Error

enum PrinterError: LocalizedError {
    case notConnected
    case invalidCharacteristic
    case imageProcessingFailed
    case transmissionFailed(String)
    case printerNotReady
    
    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Printer is not connected"
        case .invalidCharacteristic:
            return "Invalid printer characteristic"
        case .imageProcessingFailed:
            return "Failed to process image"
        case .transmissionFailed(let reason):
            return "Transmission failed: \(reason)"
        case .printerNotReady:
            return "Printer is not ready"
        }
    }
}

// MARK: - X6h Protocol (Correct from reverse engineering)

struct X6hProtocol {
    // Magic header
    static let magic: [UInt8] = [0x51, 0x78]
    static let trailer: UInt8 = 0xFF
    static let directionHostToPrinter: UInt8 = 0x00
    
    // Correct Command IDs from https://parzivail.github.io/ble-thermal-printer/
    static let cmdFeedPaper: UInt8 = 0xA1       // Feed paper (LE U16 pixels)
    static let cmdRawScanline: UInt8 = 0xA2    // Binary raw single scanline (48 bytes)
    static let cmdQuality: UInt8 = 0xA4        // Quality setting (0x31-0x35)
    static let cmdEnergy: UInt8 = 0xAF         // Thermal energy (LE U16)
    static let cmdDeviceStatus: UInt8 = 0xAE   // Device status
    static let cmdFeedSpeed: UInt8 = 0xBD      // Feed speed divisor
    static let cmdPrint: UInt8 = 0xBE          // Print command (type, grayscale)
    static let cmdCompressedBinary: UInt8 = 0xCE  // Binary compressed scanline
    static let cmdCompressedGray: UInt8 = 0xCF    // Gray compressed scanline
    
    // Print types
    static let printTypeImage: UInt8 = 0x00
    static let printTypeText: UInt8 = 0x01
    
    // Printer width
    static let printerWidthPixels = 384
    static let bytesPerLine = 48  // 384 / 8
    
    // CRC8 calculation (polynomial 0x07)
    static func crc8(_ data: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0x00
        for byte in data {
            crc ^= byte
            for _ in 0..<8 {
                if (crc & 0x80) != 0 {
                    crc = (crc << 1) ^ 0x07
                } else {
                    crc = crc << 1
                }
            }
        }
        return crc
    }
    
    // Build packet
    static func buildPacket(command: UInt8, payload: [UInt8], overrideCrc: UInt8? = nil) -> [UInt8] {
        var packet: [UInt8] = []
        
        // Magic
        packet.append(contentsOf: magic)
        
        // Command
        packet.append(command)
        
        // Direction
        packet.append(directionHostToPrinter)
        
        // Payload length (LE U16)
        let length = UInt16(payload.count)
        packet.append(UInt8(length & 0xFF))
        packet.append(UInt8((length >> 8) & 0xFF))
        
        // Payload
        packet.append(contentsOf: payload)
        
        // CRC8 of payload (or override for special commands)
        let crc = overrideCrc ?? crc8(payload)
        packet.append(crc)
        
        // Trailer
        packet.append(trailer)
        
        return packet
    }
    
    // Set quality (0x31=worst to 0x35=best)
    static func setQuality(_ quality: UInt8 = 0x35) -> [UInt8] {
        return buildPacket(command: cmdQuality, payload: [quality])
    }
    
    // Set thermal energy (higher = darker)
    static func setEnergy(_ energy: UInt16 = 0x4000) -> [UInt8] {
        return buildPacket(command: cmdEnergy, payload: [
            UInt8(energy & 0xFF),
            UInt8((energy >> 8) & 0xFF)
        ])
    }
    
    // Set feed speed (smaller = faster)
    static func setFeedSpeed(_ speed: UInt8 = 0x23) -> [UInt8] {
        return buildPacket(command: cmdFeedSpeed, payload: [speed])
    }
    
    // Start print (Image mode)
    static func startPrint() -> [UInt8] {
        return buildPacket(command: cmdPrint, payload: [printTypeImage])
    }
    
    // Raw scanline (48 bytes for 384 pixels)
    static func rawScanline(_ data: [UInt8]) -> [UInt8] {
        // Pad or trim to exactly 48 bytes
        var scanline = data
        if scanline.count < bytesPerLine {
            scanline.append(contentsOf: [UInt8](repeating: 0, count: bytesPerLine - scanline.count))
        } else if scanline.count > bytesPerLine {
            scanline = Array(scanline.prefix(bytesPerLine))
        }
        return buildPacket(command: cmdRawScanline, payload: scanline)
    }
    
    // Feed paper (pixels, not lines!)
    static func feedPaper(pixels: UInt16 = 100) -> [UInt8] {
        return buildPacket(command: cmdFeedPaper, payload: [
            UInt8(pixels & 0xFF),
            UInt8((pixels >> 8) & 0xFF)
        ])
    }
}

// MARK: - Printer Service

@MainActor
final class PrinterService: ObservableObject {
    
    // Known printer service UUIDs (from the screenshot)
    nonisolated static let knownPrinterServiceUUIDs: Set<String> = [
        "AE30", "AE3A", // From X6h printer
        "18F0", // Generic ESC/POS printer service
        "AF30" // Some thermal printers
    ]
    
    // Typical printer width in pixels
    nonisolated static let defaultPrinterWidth = 384 // 48mm thermal printer
    nonisolated static let defaultDPI = 203 // Dots per inch
    
    // MARK: - Properties
    
    @Published private(set) var isPrinting = false
    @Published private(set) var printProgress: Double = 0
    @Published private(set) var lastError: PrinterError?
    
    private let bluetoothService: BluetoothService
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var writeWithResponseCandidates: [CBCharacteristic] = []
    private var writeWithoutResponseCandidates: [CBCharacteristic] = []
    
    // MARK: - Init
    
    init(bluetoothService: BluetoothService) {
        self.bluetoothService = bluetoothService
    }
    
    // MARK: - Printer Detection
    
    func isPrinterDevice(peripheral: CBPeripheral?, advertisementData: [String: Any] = [:]) -> Bool {
        // Check by device name
        if let name = peripheral?.name?.uppercased() {
            if name.contains("PRINT") || name.contains("X6H") || name.contains("THERMAL") {
                return true
            }
        }
        
        // Check by service UUIDs in advertisement
        if let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            for uuid in serviceUUIDs {
                let uuidStr = uuid.uuidString.uppercased()
                if Self.knownPrinterServiceUUIDs.contains(uuidStr) {
                    return true
                }
            }
        }
        
        return false
    }
    
    func isPrinterDevice(services: [DiscoveredService]) -> Bool {
        for service in services {
            let serviceUUID = service.id.uppercased()
            if Self.knownPrinterServiceUUIDs.contains(serviceUUID) {
                return true
            }
        }
        return false
    }
    
    // MARK: - Setup
    
    func setupPrinterCharacteristics(from services: [DiscoveredService]) {
        writeCharacteristic = nil
        notifyCharacteristic = nil
        writeWithResponseCandidates = []
        writeWithoutResponseCandidates = []

        // Find printer service
        for service in services {
            let serviceUUID = service.id.uppercased()
            
            if Self.knownPrinterServiceUUIDs.contains(serviceUUID) {
                // Find write characteristic (writable)
                for char in service.characteristics {
                    if char.characteristic.properties.contains(.write) {
                        writeWithResponseCandidates.append(char.characteristic)
                    } else if char.characteristic.properties.contains(.writeWithoutResponse) {
                        writeWithoutResponseCandidates.append(char.characteristic)
                    }
                    
                    if char.canNotify && notifyCharacteristic == nil {
                        notifyCharacteristic = char.characteristic
                    }
                }
            }
        }

        // Prefer writeWithoutResponse for printers (often required)
        if let preferred = writeWithoutResponseCandidates.first {
            writeCharacteristic = preferred
        } else if let preferred = writeWithResponseCandidates.first {
            writeCharacteristic = preferred
        }
        
        // If no printer-specific service found, try to find any writable characteristic
        if writeCharacteristic == nil {
            for service in services {
                for char in service.characteristics {
                    if char.characteristic.properties.contains(.write) {
                        writeCharacteristic = char.characteristic
                        break
                    } else if char.characteristic.properties.contains(.writeWithoutResponse) {
                        writeCharacteristic = char.characteristic
                        break
                    }
                }
                if writeCharacteristic != nil { break }
            }
        }
        
        if let notifyCharacteristic {
            bluetoothService.setNotify(true, for: notifyCharacteristic)
        }
    }
    
    var hasValidCharacteristics: Bool {
        return writeCharacteristic != nil
    }
    
    // MARK: - Print Operations
    
    func printImage(_ imageData: Data, printerWidth: Int = defaultPrinterWidth) async throws {
        guard hasValidCharacteristics else {
            throw PrinterError.invalidCharacteristic
        }
        
        guard let characteristic = writeCharacteristic else {
            throw PrinterError.invalidCharacteristic
        }
        
        print("🖨️ Print job started (\(imageData.count) bytes)")
        
        isPrinting = true
        printProgress = 0
        lastError = nil
        
        do {
            // Step 1: Set quality to best
            try await sendCommand(X6hProtocol.setQuality(0x35), to: characteristic)
            try await Task.sleep(nanoseconds: 50_000_000)
            printProgress = 0.02
            
            // Step 2: Set feed speed (slower = better quality)
            try await sendCommand(X6hProtocol.setFeedSpeed(0x30), to: characteristic)
            try await Task.sleep(nanoseconds: 50_000_000)
            printProgress = 0.04
            
            // Step 3: Set energy (increase for darker print)
            try await sendCommand(X6hProtocol.setEnergy(0x5000), to: characteristic)
            try await Task.sleep(nanoseconds: 50_000_000)
            printProgress = 0.06
            
            // Step 4: Start print
            try await sendCommand(X6hProtocol.startPrint(), to: characteristic)
            try await Task.sleep(nanoseconds: 100_000_000)
            printProgress = 0.08
            
            // Step 5: Send scanlines (each row is 48 bytes = 384 pixels)
            let imageBytes = [UInt8](imageData)
            let bytesPerLine = X6hProtocol.bytesPerLine
            let totalLines = imageBytes.count / bytesPerLine
            
            // First line should be white (zeros) to avoid artifacts
            try await sendCommand(X6hProtocol.rawScanline([UInt8](repeating: 0, count: bytesPerLine)), to: characteristic)
            try await Task.sleep(nanoseconds: 5_000_000) // 5ms between lines
            
            for lineIndex in 0..<totalLines {
                let start = lineIndex * bytesPerLine
                let end = min(start + bytesPerLine, imageBytes.count)
                let lineData = Array(imageBytes[start..<end])
                
                let packet = X6hProtocol.rawScanline(lineData)
                try await sendCommand(packet, to: characteristic)
                
                printProgress = 0.1 + (0.85 * Double(lineIndex + 1) / Double(totalLines))
                
                // Small delay between lines
                try await Task.sleep(nanoseconds: 3_000_000) // 3ms
            }
            
            // Step 6: Feed paper (pixels, not lines!)
            try await sendCommand(X6hProtocol.feedPaper(pixels: 200), to: characteristic)
            try await Task.sleep(nanoseconds: 200_000_000)
            printProgress = 0.97
            
            // Step 7: Reset printer state for next print
            try await sendCommand(X6hProtocol.setQuality(0x35), to: characteristic)
            try await Task.sleep(nanoseconds: 50_000_000)
            printProgress = 1.0
            
            isPrinting = false
            print("🖨️ ✅ Print completed")
            
        } catch {
            isPrinting = false
            lastError = .transmissionFailed(error.localizedDescription)
            print("🖨️ ❌ Print failed: \(error.localizedDescription)")
            throw lastError!
        }
    }
    
    // MARK: - Low-level Operations
    
    private func sendCommand(_ command: [UInt8], to characteristic: CBCharacteristic) async throws {
        let data = Data(command)
        let withResponse = characteristic.properties.contains(.write) && !characteristic.properties.contains(.writeWithoutResponse)
        
        print("🖨️ [PrinterService] → Sending \(data.count) bytes (withResponse: \(withResponse))")
        
        return try await withCheckedThrowingContinuation { continuation in
            bluetoothService.writeValue(data, for: characteristic, withResponse: withResponse)
            
            // For withoutResponse, we can't wait for confirmation, so just continue
            if !withResponse {
                continuation.resume()
            } else {
                // Wait a bit for the write to complete
                Task {
                    try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
                    continuation.resume()
                }
            }
        }
    }
    
    // MARK: - Test Functions
    
    func testPrinter() async throws {
        guard hasValidCharacteristics else {
            throw PrinterError.invalidCharacteristic
        }
        
        guard let characteristic = writeCharacteristic else {
            throw PrinterError.invalidCharacteristic
        }
        
        print("🖨️ 🧪 Test print started")
        
        // Set quality
        try await sendCommand(X6hProtocol.setQuality(0x35), to: characteristic)
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Set feed speed
        try await sendCommand(X6hProtocol.setFeedSpeed(0x23), to: characteristic)
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Feed paper (100 pixels)
        try await sendCommand(X6hProtocol.feedPaper(pixels: 100), to: characteristic)
        try await Task.sleep(nanoseconds: 500_000_000)
        
        print("🖨️ ✅ Test completed")
    }

    func testAllWriteCharacteristics() async throws {
        let candidates = writeWithoutResponseCandidates + writeWithResponseCandidates
        guard !candidates.isEmpty else {
            throw PrinterError.invalidCharacteristic
        }

        print("🖨️ 🧪 Probing \(candidates.count) characteristics...")
        
        for (index, candidate) in candidates.enumerated() {
            print("🖨️ [\(index+1)/\(candidates.count)] Testing: \(candidate.uuid.uuidString.prefix(4))")

            // Test 1: Set quality (0xA4)
            try await sendCommand(X6hProtocol.setQuality(0x35), to: candidate)
            try await Task.sleep(nanoseconds: 200_000_000)

            // Test 2: Feed paper (0xA1 with pixels)
            try await sendCommand(X6hProtocol.feedPaper(pixels: 100), to: candidate)
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1s to see the feed
            
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        print("🖨️ ✅ Probe complete")
    }
    
    func feedPaper(lines: Int = 100) async throws {
        guard let characteristic = writeCharacteristic else {
            throw PrinterError.invalidCharacteristic
        }
        
        // X6h uses pixels, not lines. ~8 pixels per line
        let pixels = UInt16(min(lines * 8, 65535))
        print("🖨️ 📄 Feed paper: \(pixels) pixels")
        try await sendCommand(X6hProtocol.feedPaper(pixels: pixels), to: characteristic)
    }
}

// MARK: - Data Extension

private extension Data {
    func chunked(into size: Int) -> [[UInt8]] {
        var chunks: [[UInt8]] = []
        var currentIndex = 0
        let bytes = [UInt8](self)
        
        while currentIndex < bytes.count {
            let endIndex = Swift.min(currentIndex + size, bytes.count)
            chunks.append(Array(bytes[currentIndex..<endIndex]))
            currentIndex = endIndex
        }
        
        return chunks
    }
}
