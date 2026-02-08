//
//  PrinterViewModel.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 1/30/26.
//

import Foundation
import UIKit
import CoreBluetooth
import Combine
import PhotosUI
import SwiftUI

@MainActor
final class PrinterViewModel: ObservableObject {
    
    // MARK: - Biometric Auth
    
    private let biometricAuth = BiometricAuthService()
    
    // MARK: - Published Properties
    
    @Published var currentJob: PrintJob?
    @Published var status: PrintStatus = .idle
    @Published var connectedPrinter: CBPeripheral?
    @Published var isPrinterReady: Bool = false
    @Published var selectedImage: UIImage?
    @Published var processedPreview: UIImage?
    @Published var errorMessage: String?
    
    // Dithering options
    @Published var brightness: Double = 0.0 // -1.0 to 1.0
    @Published var contrast: Double = 1.0 // 0.5 to 2.0
    @Published var threshold: UInt8 = 128 // 0 to 255
    
    // MARK: - Properties
    
    private let bluetoothService: BluetoothService
    private let printerService: PrinterService
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Init
    
    init(bluetoothService: BluetoothService) {
        self.bluetoothService = bluetoothService
        self.printerService = PrinterService(bluetoothService: bluetoothService)
        
        setupBindings()
    }
    
    // MARK: - Setup
    
    private func setupBindings() {
        // Monitor connected peripheral
        bluetoothService.connectedPeripheralPublisher
            .sink { [weak self] peripheral in
                self?.connectedPrinter = peripheral
                self?.checkPrinterStatus()
            }
            .store(in: &cancellables)
        
        // Monitor services to detect printer
        bluetoothService.servicesPublisher
            .sink { [weak self] services in
                guard let self = self else { return }
                self.printerService.setupPrinterCharacteristics(from: services)
                self.checkPrinterStatus()
            }
            .store(in: &cancellables)
        
        // Monitor printer service status
        printerService.$isPrinting
            .sink { [weak self] isPrinting in
                if isPrinting {
                    self?.status = .printing(progress: 0)
                }
            }
            .store(in: &cancellables)
        
        printerService.$printProgress
            .sink { [weak self] progress in
                if progress > 0 {
                    self?.status = .printing(progress: progress)
                    
                    if progress >= 1.0 {
                        self?.status = .completed
                        // Auto reset after 3 seconds
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            if case .completed = self?.status {
                                self?.status = .idle
                                self?.currentJob = nil
                            }
                        }
                    }
                }
            }
            .store(in: &cancellables)
        
        printerService.$lastError
            .sink { [weak self] error in
                if let error = error {
                    self?.status = .failed(error.localizedDescription)
                    self?.errorMessage = error.localizedDescription
                }
            }
            .store(in: &cancellables)
    }
    
    private func checkPrinterStatus() {
        isPrinterReady = connectedPrinter != nil && printerService.hasValidCharacteristics
    }
    
    // MARK: - Biometric Auth Helpers
    
    var biometricType: BiometricType {
        return biometricAuth.biometricType()
    }
    
    var isBiometricAvailable: Bool {
        return biometricAuth.isBiometricAvailable()
    }
    
    /// Authenticate user before printing
    private func authenticateForPrint() async throws {
        let biometricName = biometricAuth.biometricType().displayName
        let reason = "Authenticate with \(biometricName) to print"
        
        do {
            let authenticated = try await biometricAuth.authenticate(reason: reason)
            if !authenticated {
                throw BiometricAuthError.authenticationFailed
            }
        } catch {
            // Rethrow the error to be handled by caller
            throw error
        }
    }
    
    // MARK: - Image Selection
    
    func selectImage(_ image: UIImage) {
        selectedImage = image
        errorMessage = nil
        
        // Generate quick preview
        Task {
            if let preview = ImageProcessor.quickPreview(image: image) {
                processedPreview = preview
            }
        }
    }
    
    func clearSelection() {
        selectedImage = nil
        processedPreview = nil
        currentJob = nil
        status = .idle
        errorMessage = nil
    }
    
    // MARK: - Image Processing
    
    func processImage() async throws {
        guard let image = selectedImage else {
            throw ImageProcessingError.invalidImage
        }
        
        status = .processing
        
        let options = DitheringOptions(
            threshold: threshold,
            contrast: contrast,
            brightness: brightness
        )
        
        do {
            let (preview, escposData) = try ImageProcessor.processForPrinting(
                image: image,
                width: PrinterService.defaultPrinterWidth,
                options: options
            )
            
            processedPreview = preview
            
            var job = PrintJob(image: image)
            job.processedImage = preview
            job.escposData = escposData
            job.status = .idle
            
            currentJob = job
            status = .idle
            
        } catch {
            status = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
            throw error
        }
    }
    
    // MARK: - Printing (with Face ID/Touch ID)
    
    func printCurrentJob() async throws {
        guard let job = currentJob,
              let escposData = job.escposData else {
            throw PrinterError.imageProcessingFailed
        }
        
        guard isPrinterReady else {
            throw PrinterError.notConnected
        }
        
        // 🔐 REQUIRE BIOMETRIC AUTHENTICATION BEFORE PRINTING
        do {
            try await authenticateForPrint()
        } catch let error as BiometricAuthError {
            status = .failed(error.localizedDescription ?? "Authentication failed")
            errorMessage = error.localizedDescription
            throw error
        } catch {
            status = .failed("Authentication failed")
            errorMessage = "Authentication failed"
            throw error
        }
        
        // Authentication successful, proceed with printing
        status = .printing(progress: 0)
        
        do {
            try await printerService.printImage(escposData)
            status = .completed
            
            // Auto reset after 3 seconds
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if case .completed = status {
                status = .idle
                currentJob = nil
            }
            
        } catch {
            status = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
            throw error
        }
    }
    
    /// Quick print: select, process, and print in one go (with Face ID)
    func quickPrint(image: UIImage) async throws {
        selectImage(image)
        try await processImage()
        try await printCurrentJob() // Will require Face ID inside
    }
    
    // MARK: - Printer Actions (without Face ID requirement)
    
    func testPrinter() async throws {
        guard isPrinterReady else {
            throw PrinterError.notConnected
        }
        
        try await printerService.testPrinter()
    }

    func testAllWriteCharacteristics() async throws {
        guard isPrinterReady else {
            throw PrinterError.notConnected
        }

        try await printerService.testAllWriteCharacteristics()
    }
    
    func feedPaper(lines: Int = 50) async throws {
        guard isPrinterReady else {
            throw PrinterError.notConnected
        }
        
        try await printerService.feedPaper(lines: lines)
    }
    
    // MARK: - Helpers
    
    var canPrint: Bool {
        return isPrinterReady && currentJob?.escposData != nil && !status.isActive
    }
    
    var canProcess: Bool {
        return selectedImage != nil && !status.isActive
    }
    
    func isPrinterDevice(peripheral: CBPeripheral?, advertisementData: [String: Any] = [:]) -> Bool {
        return printerService.isPrinterDevice(peripheral: peripheral, advertisementData: advertisementData)
    }
    
    func isPrinterDevice(services: [DiscoveredService]) -> Bool {
        return printerService.isPrinterDevice(services: services)
    }
}
