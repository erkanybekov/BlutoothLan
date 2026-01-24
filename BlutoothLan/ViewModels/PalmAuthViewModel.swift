//
//  PalmAuthViewModel.swift
//  BlutoothLan
//
//  ViewModel for Palm Authentication
//

import Foundation
import Combine

class PalmAuthViewModel: ObservableObject {
    
    // MARK: - Published Properties
    @Published var detectionState: PalmDetectionState = .idle
    @Published var verificationState: PalmVerificationState = .idle
    @Published var showCameraPermissionAlert = false
    @Published var capturedLandmarks: [PalmLandmark]?
    @Published var captureConfidence: Float = 0
    
    // MARK: - Private Properties
    private let handDetectionService = HandDetectionService()
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    init() {
        setupBindings()
    }
    
    // MARK: - Private Methods
    private func setupBindings() {
        // Observe detection state changes
        handDetectionService.$detectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.detectionState = state
                
                // Auto-capture when good detection is achieved
                if case .success(let landmarks, let confidence) = state {
                    if confidence > 0.7 && self?.capturedLandmarks == nil {
                        self?.capturedLandmarks = landmarks
                        self?.captureConfidence = confidence
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Public Methods
    
    /// Start hand detection
    func startDetection() {
        handDetectionService.checkCameraPermission { [weak self] granted in
            if granted {
                self?.handDetectionService.startDetection()
            } else {
                self?.showCameraPermissionAlert = true
                self?.detectionState = .error("Camera permission denied")
            }
        }
    }
    
    /// Stop hand detection
    func stopDetection() {
        handDetectionService.stopDetection()
    }
    
    /// Get camera preview layer
    func getPreviewLayer() -> AVCaptureVideoPreviewLayer? {
        return handDetectionService.getPreviewLayer()
    }
    
    /// Capture current landmarks
    func captureLandmarks() {
        if case .success(let landmarks, let confidence) = detectionState {
            capturedLandmarks = landmarks
            captureConfidence = confidence
        }
    }
    
    /// Reset captured data
    func resetCapture() {
        capturedLandmarks = nil
        captureConfidence = 0
        verificationState = .idle
    }
    
    /// Verify captured landmarks
    func verifyPalm(userId: String? = nil) {
        guard let landmarks = capturedLandmarks else {
            verificationState = .error("No landmarks captured")
            return
        }
        
        verificationState = .loading
        
        // Create verification request
        let request = PalmVerificationRequest(
            landmarks: landmarks,
            accuracy: Double(captureConfidence),
            userId: userId
        )
        
        // Simulate verification (replace with actual API call)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            // Mock response - replace with actual verification logic
            let response = PalmVerificationResponse(
                verified: true,
                confidence: Double(self?.captureConfidence ?? 0),
                message: "Palm verified successfully",
                timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                userId: userId
            )
            
            self?.verificationState = .success(response)
        }
    }
    
    /// Send verification request to server
    func sendVerificationRequest(_ request: PalmVerificationRequest, to endpoint: String) async throws -> PalmVerificationResponse {
        guard let url = URL(string: endpoint) else {
            throw URLError(.badURL)
        }
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        
        return try JSONDecoder().decode(PalmVerificationResponse.self, from: data)
    }
}

// MARK: - Import AVFoundation for preview layer
import AVFoundation
