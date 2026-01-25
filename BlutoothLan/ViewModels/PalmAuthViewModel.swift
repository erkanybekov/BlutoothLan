//
//  PalmAuthViewModel.swift
//  BlutoothLan
//
//  ViewModel for Hand Geometry Authentication (Apple Vision Framework)
//  Supports Dual-Side Authentication (Palm + Back of Hand)
//

import Foundation
import Combine
import UIKit

class PalmAuthViewModel: ObservableObject {
    
    // MARK: - Published Properties
    @Published var cameraState: PalmCameraState = .idle
    @Published var verificationState: PalmVerificationState = .idle
    @Published var authMode: PalmAuthMode = .verify
    @Published var isPalmRegistered: Bool = false
    @Published var currentFrame: CGImage?
    @Published var handLandmarks: HandLandmarks?
    @Published var capturedFeatures: HandGeometryFeatures?
    @Published var showCameraPermissionAlert = false
    @Published var imageQuality: DetailedQualityResult?
    
    // MARK: - Dual-Side Authentication Properties
    @Published var dualSideStep: DualSideAuthStep = .idle
    @Published var captureSession = DualSideCaptureSession(requiredSamplesPerSide: 1)  // 1 sample for quick flow, can increase
    @Published var dualVerificationResult: DualVerificationResult?
    @Published var isDualSideMode: Bool = true  // Enable dual-side by default
    
    // Current side being captured
    var currentCaptureSide: HandSide {
        switch dualSideStep {
        case .capturingPalm, .palmCaptured:
            return .palm
        case .capturingBack, .backCaptured:
            return .backOfHand
        default:
            return .palm
        }
    }
    
    // MARK: - Settings
    var skipQualityCheck: Bool = false
    
    // MARK: - Private Properties
    private let cameraService = PalmCameraService()
    private let handGeometryService = HandGeometryService()
    private let featureExtractor = HandGeometryExtractor()
    private let matcher = HandGeometryMatcher()
    private let storageService = HandGeometryStorageService.shared
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    init() {
        setupBindings()
        checkRegistrationStatus()
        setupRealTimeQualityCheck()
    }
    
    private func setupBindings() {
        // Observe camera frame updates
        cameraService.$currentFrame
            .receive(on: DispatchQueue.main)
            .sink { [weak self] frame in
                self?.currentFrame = frame
            }
            .store(in: &cancellables)
        
        // Observe camera session state
        cameraService.$isSessionRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRunning in
                if isRunning {
                    self?.cameraState = .ready
                }
            }
            .store(in: &cancellables)
    }
    
    private var lastQualityCheckTime: Date?
    
    private func setupRealTimeQualityCheck() {
        // Throttled quality check (every 0.5 seconds to avoid performance issues)
        cameraService.onFrameQualityCheck = { [weak self] image in
            guard let self = self else { return }
            
            // Throttle to avoid excessive processing
            let now = Date()
            if let lastCheck = self.lastQualityCheckTime,
               now.timeIntervalSince(lastCheck) < 0.5 {
                return
            }
            self.lastQualityCheckTime = now
            
            // Perform quality check
            let quality = self.handGeometryService.assessImageQuality(image)
            
            DispatchQueue.main.async {
                self.imageQuality = quality
            }
        }
        
        // Real-time hand tracking (throttling done in PalmCameraService at ~15 FPS)
        cameraService.onHandDetected = { [weak self] landmarks in
            guard let self = self else { return }
            
            // Update landmarks in real-time for visualization (nil clears old skeleton)
            self.handLandmarks = landmarks
        }
    }
    
    private func checkRegistrationStatus() {
        isPalmRegistered = storageService.isRegistered()
        isDualSideMode = storageService.isDualSideRegistered()
        authMode = isPalmRegistered ? .verify : .register
        
        // Start in appropriate state
        if authMode == .register {
            dualSideStep = .capturingPalm
        } else {
            dualSideStep = .capturingPalm  // Start with palm for verification too
        }
    }
    
    // MARK: - Camera Control
    
    func startCamera() {
        // Check if running on simulator
        if DeviceHelper.isSimulator {
            cameraState = .error("⚠️ Camera not available on simulator.\nPlease use a real device for palm authentication.")
            return
        }
        
        cameraService.checkCameraPermission { [weak self] granted in
            DispatchQueue.main.async {
                if granted {
                    self?.cameraService.startCamera()
                } else {
                    self?.showCameraPermissionAlert = true
                    self?.cameraState = .error("Camera permission denied")
                }
            }
        }
    }
    
    func stopCamera() {
        cameraService.stopCamera()
        cameraState = .idle
    }
    
    func updateROIRect(for size: CGSize) {
        // No longer needed - we show hand landmarks instead
    }
    
    // MARK: - Capture and Extract Features
    
    func captureAndExtractFeatures() {
        cameraState = .processing
        
        cameraService.capturePhoto { [weak self] image in
            guard let self = self, let image = image else {
                DispatchQueue.main.async {
                    self?.cameraState = .error("Failed to capture image")
                }
                return
            }
            
            // Extract features in background
            DispatchQueue.global(qos: .userInitiated).async {
                // Step 1: Check image quality
                let quality = self.handGeometryService.assessImageQuality(image)
                
                DispatchQueue.main.async {
                    self.imageQuality = quality
                }
                
                // Skip quality check if flag is set (for testing)
                if !self.skipQualityCheck && !quality.isGood {
                    print("❌ Quality check FAILED:")
                    print("  Score: \(String(format: "%.1f%%", quality.overallScore))")
                    print("  Issues: \(quality.issues.map { $0.rawValue }.joined(separator: ", "))")
                    
                    DispatchQueue.main.async {
                        self.cameraState = .error(quality.feedbackMessage)
                    }
                    return
                }
                
                print("✅ Quality check PASSED (Score: \(String(format: "%.1f%%", quality.overallScore)))")
                
                // Step 2: Detect hand landmarks using Vision Framework
                let sideMessage = self.currentCaptureSide == .palm ? "palm" : "back of hand"
                guard let landmarks = self.handGeometryService.detectHandLandmarks(from: image) else {
                    DispatchQueue.main.async {
                        self.cameraState = .error("No hand detected. Please show your \(sideMessage) clearly.")
                    }
                    return
                }
                
                // Step 3: Extract geometric features
                guard let features = self.featureExtractor.extractFeatures(from: landmarks) else {
                    DispatchQueue.main.async {
                        self.cameraState = .error("Failed to extract hand geometry features")
                    }
                    return
                }
                
                // Step 4: Validate features
                guard self.matcher.validateFeatures(features) else {
                    DispatchQueue.main.async {
                        self.cameraState = .error("Hand geometry incomplete. Please try again.")
                    }
                    return
                }
                
                DispatchQueue.main.async {
                    self.handLandmarks = landmarks
                    self.capturedFeatures = features
                    self.cameraState = .captured(image)
                    
                    // Update dual-side state
                    self.handleDualSideCapture(features: features)
                }
            }
        }
    }
    
    // MARK: - Dual-Side Capture Flow
    
    private func handleDualSideCapture(features: HandGeometryFeatures) {
        switch dualSideStep {
        case .capturingPalm:
            captureSession.addPalmSample(features)
            dualSideStep = .palmCaptured
            print("✅ Palm captured (\(captureSession.palmSamples.count)/\(captureSession.requiredSamplesPerSide))")
            
        case .capturingBack:
            captureSession.addBackSample(features)
            dualSideStep = .backCaptured
            print("✅ Back captured (\(captureSession.backSamples.count)/\(captureSession.requiredSamplesPerSide))")
            
        default:
            break
        }
    }
    
    /// Move to next step in dual-side flow
    func proceedToNextStep() {
        switch dualSideStep {
        case .palmCaptured:
            // Move to capturing back
            dualSideStep = .capturingBack
            capturedFeatures = nil
            cameraState = .ready
            print("➡️ Proceeding to back-of-hand capture")
            
        case .backCaptured:
            // Ready for final action (register or verify)
            print("✅ Both sides captured, ready for \(authMode == .register ? "registration" : "verification")")
            
        default:
            break
        }
    }
    
    /// Capture current side for dual-side flow
    func captureDualSide() {
        switch dualSideStep {
        case .idle:
            dualSideStep = .capturingPalm
            captureAndExtractFeatures()
            
        case .capturingPalm, .palmCaptured:
            captureAndExtractFeatures()
            
        case .capturingBack, .backCaptured:
            captureAndExtractFeatures()
            
        default:
            break
        }
    }
    
    // MARK: - Registration (Dual-Side)
    
    func registerPalm() {
        // For dual-side registration
        guard let palmFeatures = captureSession.palmFeatures,
              let backFeatures = captureSession.backFeatures else {
            
            // Check which side is missing
            if captureSession.palmFeatures == nil {
                verificationState = .error("Palm not captured yet")
            } else {
                verificationState = .error("Back of hand not captured yet")
            }
            return
        }
        
        verificationState = .loading
        dualSideStep = .processing
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Create biometric profile
            let profile = BiometricHandProfile(
                palmTemplate: palmFeatures,
                backTemplate: backFeatures,
                palmSampleCount: self.captureSession.palmSamples.count,
                backSampleCount: self.captureSession.backSamples.count
            )
            
            let success = self.storageService.saveBiometricProfile(profile)
            
            DispatchQueue.main.async {
                if success {
                    self.isPalmRegistered = true
                    self.isDualSideMode = true
                    self.authMode = .verify
                    self.dualSideStep = .completed(success: true)
                    
                    let palmResult = PalmVerificationResult(
                        isMatch: true,
                        matchPercentage: 1.0,
                        goodMatches: 100,
                        totalKeypoints: 100
                    )
                    self.verificationState = .success(palmResult)
                    
                    print("✅ Dual-side biometric profile registered successfully!")
                } else {
                    self.dualSideStep = .error("Failed to save biometric profile")
                    self.verificationState = .error("Failed to save biometric profile")
                }
            }
        }
    }
    
    /// Legacy single-side registration (kept for compatibility)
    func registerSingleSide() {
        guard let features = capturedFeatures else {
            verificationState = .error("No features captured")
            return
        }
        
        verificationState = .loading
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let success = self.storageService.saveTemplate(features)
            
            DispatchQueue.main.async {
                if success {
                    self.isPalmRegistered = true
                    self.authMode = .verify
                    
                    let palmResult = PalmVerificationResult(
                        isMatch: true,
                        matchPercentage: 1.0,
                        goodMatches: 100,
                        totalKeypoints: 100
                    )
                    self.verificationState = .success(palmResult)
                } else {
                    self.verificationState = .error("Failed to save hand geometry template")
                }
            }
        }
    }
    
    // MARK: - Verification (Dual-Side)
    
    func verifyPalm() {
        // Check if we have dual-side profile
        if let profile = storageService.loadBiometricProfile() {
            verifyDualSide(profile: profile)
        } else if let template = storageService.loadTemplate() {
            // Fall back to legacy single-side verification
            verifySingleSide(template: template)
        } else {
            verificationState = .error("No registered hand found")
        }
    }
    
    private func verifyDualSide(profile: BiometricHandProfile) {
        guard let palmFeatures = captureSession.palmFeatures,
              let backFeatures = captureSession.backFeatures else {
            
            if captureSession.palmFeatures == nil {
                verificationState = .error("Palm not captured yet")
            } else {
                verificationState = .error("Back of hand not captured yet")
            }
            return
        }
        
        verificationState = .loading
        dualSideStep = .processing
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let result = self.matcher.verifyDualSide(
                profile: profile,
                palmFeatures: palmFeatures,
                backFeatures: backFeatures
            )
            
            DispatchQueue.main.async {
                self.dualVerificationResult = result
                self.dualSideStep = .completed(success: result.isMatch)
                
                // Convert to PalmVerificationResult for UI compatibility
                let palmResult = PalmVerificationResult(
                    isMatch: result.isMatch,
                    matchPercentage: result.overallConfidence,
                    goodMatches: Int(result.overallConfidence * 100),
                    totalKeypoints: 100
                )
                self.verificationState = .success(palmResult)
            }
        }
    }
    
    private func verifySingleSide(template: StoredHandTemplate) {
        guard let features = capturedFeatures else {
            verificationState = .error("No features captured")
            return
        }
        
        verificationState = .loading
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let result = self.matcher.match(template: template.features, current: features)
            
            DispatchQueue.main.async {
                let palmResult = PalmVerificationResult(
                    isMatch: result.isMatch,
                    matchPercentage: result.matchPercentage,
                    goodMatches: Int(result.matchPercentage * 100),
                    totalKeypoints: 100
                )
                self.verificationState = .success(palmResult)
            }
        }
    }
    
    // MARK: - Delete Registration
    
    func deletePalmRegistration() {
        storageService.deleteAllTemplates()
        isPalmRegistered = false
        isDualSideMode = false
        authMode = .register
        resetCapture()
    }
    
    // MARK: - Reset
    
    func resetCapture() {
        capturedFeatures = nil
        verificationState = .idle
        cameraState = .ready
        dualSideStep = .capturingPalm
        dualVerificationResult = nil
        captureSession.reset()
    }
    
    /// Reset only the current side capture (retry current step)
    func retryCurrentSide() {
        capturedFeatures = nil
        cameraState = .ready
        
        switch dualSideStep {
        case .palmCaptured:
            // Remove last palm sample and retry
            if !captureSession.palmSamples.isEmpty {
                captureSession.palmSamples.removeLast()
            }
            dualSideStep = .capturingPalm
            
        case .backCaptured:
            // Remove last back sample and retry
            if !captureSession.backSamples.isEmpty {
                captureSession.backSamples.removeLast()
            }
            dualSideStep = .capturingBack
            
        default:
            break
        }
    }
    
    // MARK: - Progress Info
    
    var registrationProgress: String {
        let palmCount = captureSession.palmSamples.count
        let backCount = captureSession.backSamples.count
        let required = captureSession.requiredSamplesPerSide
        
        return "Palm: \(palmCount)/\(required) | Back: \(backCount)/\(required)"
    }
    
    var isReadyToRegister: Bool {
        return captureSession.isComplete
    }
    
    var isReadyToVerify: Bool {
        if isDualSideMode {
            return captureSession.palmFeatures != nil && captureSession.backFeatures != nil
        } else {
            return capturedFeatures != nil
        }
    }
}
