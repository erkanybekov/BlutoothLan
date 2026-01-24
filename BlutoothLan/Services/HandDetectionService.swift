//
//  HandDetectionService.swift
//  BlutoothLan
//
//  Hand Detection Service using MediaPipe
//

import Foundation
import AVFoundation
import UIKit
import Vision
import Combine

// MARK: - Hand Detection Service
class HandDetectionService: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    @Published var detectionState: PalmDetectionState = .idle
    @Published var isSessionRunning = false
    
    // MARK: - Private Properties
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private let videoOutputQueue = DispatchQueue(label: "com.blutoothlan.videoOutputQueue")
    
    // Hand pose request
    private lazy var handPoseRequest: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        return request
    }()
    
    // MARK: - Initialization
    override init() {
        super.init()
    }
    
    // MARK: - Public Methods
    
    /// Start camera session and hand detection
    func startDetection() {
        guard !isSessionRunning else { return }
        
        setupCaptureSession()
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.startRunning()
            DispatchQueue.main.async {
                self?.isSessionRunning = true
                self?.detectionState = .detecting
            }
        }
    }
    
    /// Stop camera session
    func stopDetection() {
        guard isSessionRunning else { return }
        
        captureSession?.stopRunning()
        isSessionRunning = false
        detectionState = .idle
    }
    
    /// Get preview layer for camera feed
    func getPreviewLayer() -> AVCaptureVideoPreviewLayer? {
        guard let session = captureSession else { return nil }
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        return previewLayer
    }
    
    // MARK: - Private Methods
    
    private func setupCaptureSession() {
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .high
        
        // Setup camera input
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
              session.canAddInput(videoInput) else {
            detectionState = .error("Failed to setup camera")
            return
        }
        
        session.addInput(videoInput)
        
        // Setup video output
        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(self, queue: videoOutputQueue)
        output.alwaysDiscardsLateVideoFrames = true
        
        guard session.canAddOutput(output) else {
            detectionState = .error("Failed to setup video output")
            return
        }
        
        session.addOutput(output)
        session.commitConfiguration()
        
        self.captureSession = session
        self.videoOutput = output
    }
    
    private func processHandPose(_ observation: VNHumanHandPoseObservation) {
        // Extract all hand landmarks
        guard let recognizedPoints = try? observation.recognizedPoints(.all) else {
            return
        }
        
        var landmarks: [PalmLandmark] = []
        var totalConfidence: Float = 0
        
        // Convert Vision landmarks to our model
        for (_, point) in recognizedPoints {
            guard point.confidence > 0.3 else { continue }
            
            let landmark = PalmLandmark(
                x: Float(point.location.x),
                y: Float(point.location.y),
                z: 0 // Vision doesn't provide Z coordinate
            )
            landmarks.append(landmark)
            totalConfidence += point.confidence
        }
        
        // Calculate average confidence
        let avgConfidence = landmarks.isEmpty ? 0 : totalConfidence / Float(landmarks.count)
        
        // Update state on main thread
        DispatchQueue.main.async { [weak self] in
            if landmarks.count >= 15 { // Minimum landmarks for a valid hand
                self?.detectionState = .success(landmarks: landmarks, confidence: avgConfidence)
            } else {
                self?.detectionState = .detecting
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension HandDetectionService: AVCaptureVideoDataOutputSampleBufferDelegate {
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        
        do {
            try handler.perform([handPoseRequest])
            
            guard let observations = handPoseRequest.results, !observations.isEmpty else {
                DispatchQueue.main.async { [weak self] in
                    if self?.detectionState != .detecting {
                        self?.detectionState = .detecting
                    }
                }
                return
            }
            
            // Process the first detected hand
            if let firstHand = observations.first {
                processHandPose(firstHand)
            }
            
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.detectionState = .error("Detection failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Camera Permission Helper
extension HandDetectionService {
    
    func checkCameraPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }
}
