//
//  PalmAuthView.swift
//  BlutoothLan
//
//  Palm Authentication View
//

import SwiftUI
import AVFoundation

struct PalmAuthView: View {
    @StateObject private var viewModel = PalmAuthViewModel()
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            // Camera Preview
            CameraPreviewView(viewModel: viewModel)
                .ignoresSafeArea()
            
            // Overlay UI
            VStack {
                // Top bar
                HStack {
                    Button {
                        viewModel.stopDetection()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .shadow(radius: 4)
                    }
                    
                    Spacer()
                    
                    Text("Palm Authentication")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                    
                    Spacer()
                    
                    // Placeholder for symmetry
                    Color.clear
                        .frame(width: 44, height: 44)
                }
                .padding()
                
                Spacer()
                
                // Detection frame with landmarks overlay
                ZStack {
                    detectionFrameView
                    
                    // Show landmarks overlay when detected
                    if case .success(let landmarks, _) = viewModel.detectionState {
                        HandLandmarkOverlayView(
                            landmarks: landmarks,
                            frameSize: CGSize(width: 280, height: 350)
                        )
                    }
                }
                
                Spacer()
                
                // Status and controls
                controlsView
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(.ultraThinMaterial)
                    )
                    .padding()
            }
        }
        .onAppear {
            viewModel.startDetection()
        }
        .onDisappear {
            viewModel.stopDetection()
        }
        .alert("Camera Permission Required", isPresented: $viewModel.showCameraPermissionAlert) {
            Button("Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {
                dismiss()
            }
        } message: {
            Text("Please allow camera access in Settings to use palm authentication.")
        }
    }
    
    // MARK: - Detection Frame View
    
    private var detectionFrameView: some View {
        ZStack {
            // Frame outline
            RoundedRectangle(cornerRadius: 20)
                .stroke(frameColor, lineWidth: 3)
                .frame(width: 280, height: 350)
                .shadow(color: frameColor.opacity(0.5), radius: 10)
            
            // Corner markers
            VStack {
                HStack {
                    cornerMarker
                    Spacer()
                    cornerMarker.rotationEffect(.degrees(90))
                }
                Spacer()
                HStack {
                    cornerMarker.rotationEffect(.degrees(-90))
                    Spacer()
                    cornerMarker.rotationEffect(.degrees(180))
                }
            }
            .frame(width: 280, height: 350)
            
            // Instruction text
            VStack {
                Spacer()
                Text(instructionText)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(.ultraThinMaterial)
                    )
                    .padding(.bottom, -40)
            }
            .frame(width: 280, height: 350)
        }
    }
    
    private var cornerMarker: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 30))
            path.addLine(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 30, y: 0))
        }
        .stroke(frameColor, lineWidth: 4)
        .frame(width: 30, height: 30)
    }
    
    private var frameColor: Color {
        switch viewModel.detectionState {
        case .idle:
            return .gray
        case .detecting:
            return .yellow
        case .success(_, let confidence):
            return confidence > 0.7 ? .green : .yellow
        case .error:
            return .red
        }
    }
    
    private var instructionText: String {
        switch viewModel.detectionState {
        case .idle:
            return "Position your palm in the frame"
        case .detecting:
            return "Hold steady..."
        case .success(_, let confidence):
            return confidence > 0.7 ? "Perfect! Hold still" : "Almost there..."
        case .error(let message):
            return message
        }
    }
    
    // MARK: - Controls View
    
    private var controlsView: some View {
        VStack(spacing: 16) {
            // Status indicator with landmark info
            if case .success(let landmarks, let confidence) = viewModel.detectionState {
                LandmarkInfoView(landmarks: landmarks, confidence: confidence)
            } else {
                HStack(spacing: 12) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 12, height: 12)
                    
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    
                    Spacer()
                }
            }
            
            // Verification state
            if viewModel.verificationState != .idle {
                verificationStatusView
            }
            
            // Action buttons
            HStack(spacing: 12) {
                if viewModel.capturedLandmarks == nil {
                    Button {
                        viewModel.captureLandmarks()
                    } label: {
                        HStack {
                            Image(systemName: "hand.raised.fill")
                            Text("Capture")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(canCapture ? Color.blue : Color.gray)
                        .foregroundStyle(.white)
                        .cornerRadius(12)
                    }
                    .disabled(!canCapture)
                } else {
                    Button {
                        viewModel.resetCapture()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Retry")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.orange)
                        .foregroundStyle(.white)
                        .cornerRadius(12)
                    }
                    
                    Button {
                        viewModel.verifyPalm()
                    } label: {
                        HStack {
                            if case .loading = viewModel.verificationState {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Image(systemName: "checkmark.shield.fill")
                                Text("Verify")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundStyle(.white)
                        .cornerRadius(12)
                    }
                    .disabled(viewModel.verificationState == .loading)
                }
            }
        }
    }
    
    private var verificationStatusView: some View {
        HStack(spacing: 10) {
            switch viewModel.verificationState {
            case .loading:
                ProgressView()
                Text("Verifying...")
                    .font(.subheadline)
            case .success(let response):
                Image(systemName: response.verified ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(response.verified ? .green : .red)
                Text(response.message)
                    .font(.subheadline)
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.subheadline)
            case .idle:
                EmptyView()
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }
    
    private var canCapture: Bool {
        if case .success(_, let confidence) = viewModel.detectionState {
            return confidence > 0.7
        }
        return false
    }
    
    private var statusColor: Color {
        switch viewModel.detectionState {
        case .idle:
            return .gray
        case .detecting:
            return .yellow
        case .success:
            return .green
        case .error:
            return .red
        }
    }
    
    private var statusText: String {
        switch viewModel.detectionState {
        case .idle:
            return "Ready"
        case .detecting:
            return "Detecting hand..."
        case .success:
            return "Hand detected"
        case .error(let message):
            return message
        }
    }
}

// MARK: - Camera Preview View

struct CameraPreviewView: UIViewRepresentable {
    let viewModel: PalmAuthViewModel
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .black
        
        if let previewLayer = viewModel.getPreviewLayer() {
            previewLayer.frame = view.bounds
            view.layer.addSublayer(previewLayer)
            context.coordinator.previewLayer = previewLayer
        }
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        if let previewLayer = context.coordinator.previewLayer {
            DispatchQueue.main.async {
                previewLayer.frame = uiView.bounds
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        var previewLayer: AVCaptureVideoPreviewLayer?
    }
}

// MARK: - Preview

#Preview {
    PalmAuthView()
}
