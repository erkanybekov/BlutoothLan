//
//  HandLandmarkOverlay.swift
//  BlutoothLan
//
//  Overlay view for visualizing hand landmarks
//

import SwiftUI

struct HandLandmarkOverlayView: View {
    let landmarks: [PalmLandmark]
    let frameSize: CGSize
    
    var body: some View {
        Canvas { context, size in
            // Draw connections between landmarks
            drawConnections(context: context, size: size)
            
            // Draw landmark points
            for landmark in landmarks {
                let point = CGPoint(
                    x: CGFloat(landmark.x) * size.width,
                    y: CGFloat(1 - landmark.y) * size.height // Flip Y coordinate
                )
                
                // Draw outer circle
                context.fill(
                    Circle().path(in: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)),
                    with: .color(.green.opacity(0.3))
                )
                
                // Draw inner circle
                context.fill(
                    Circle().path(in: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)),
                    with: .color(.green)
                )
            }
        }
        .frame(width: frameSize.width, height: frameSize.height)
    }
    
    private func drawConnections(context: GraphicsContext, size: CGSize) {
        // Hand landmark connections (simplified)
        let connections: [(Int, Int)] = [
            // Thumb
            (0, 1), (1, 2), (2, 3), (3, 4),
            // Index finger
            (0, 5), (5, 6), (6, 7), (7, 8),
            // Middle finger
            (0, 9), (9, 10), (10, 11), (11, 12),
            // Ring finger
            (0, 13), (13, 14), (14, 15), (15, 16),
            // Pinky
            (0, 17), (17, 18), (18, 19), (19, 20)
        ]
        
        for (start, end) in connections {
            guard start < landmarks.count && end < landmarks.count else { continue }
            
            let startPoint = CGPoint(
                x: CGFloat(landmarks[start].x) * size.width,
                y: CGFloat(1 - landmarks[start].y) * size.height
            )
            
            let endPoint = CGPoint(
                x: CGFloat(landmarks[end].x) * size.width,
                y: CGFloat(1 - landmarks[end].y) * size.height
            )
            
            var path = Path()
            path.move(to: startPoint)
            path.addLine(to: endPoint)
            
            context.stroke(
                path,
                with: .color(.green.opacity(0.6)),
                lineWidth: 2
            )
        }
    }
}

// MARK: - Landmark Info View
struct LandmarkInfoView: View {
    let landmarks: [PalmLandmark]
    let confidence: Float
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "hand.point.up.left.fill")
                    .foregroundStyle(.green)
                Text("Hand Detected")
                    .font(.headline)
            }
            
            HStack {
                Text("Landmarks:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("\(landmarks.count)")
                    .font(.subheadline.bold())
            }
            
            HStack {
                Text("Confidence:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("\(Int(confidence * 100))%")
                    .font(.subheadline.bold())
                    .foregroundStyle(confidenceColor)
            }
            
            // Confidence bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 8)
                    
                    RoundedRectangle(cornerRadius: 4)
                        .fill(confidenceColor)
                        .frame(width: geometry.size.width * CGFloat(confidence), height: 8)
                }
            }
            .frame(height: 8)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
    }
    
    private var confidenceColor: Color {
        if confidence > 0.8 {
            return .green
        } else if confidence > 0.6 {
            return .yellow
        } else {
            return .orange
        }
    }
}

#Preview {
    ZStack {
        Color.black
        
        VStack {
            // Sample landmarks
            let sampleLandmarks = (0..<21).map { i in
                PalmLandmark(
                    x: Float.random(in: 0.3...0.7),
                    y: Float.random(in: 0.3...0.7),
                    z: 0
                )
            }
            
            HandLandmarkOverlayView(
                landmarks: sampleLandmarks,
                frameSize: CGSize(width: 300, height: 400)
            )
            
            LandmarkInfoView(
                landmarks: sampleLandmarks,
                confidence: 0.85
            )
            .padding()
        }
    }
}
