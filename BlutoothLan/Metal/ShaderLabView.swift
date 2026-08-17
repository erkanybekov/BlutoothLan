//
//  ShaderLabView.swift
//  BlutoothLan
//
//  Live playground for the shaders in Effects.metal.
//  Pick a step, drag the sliders, watch what changes.
//

import SwiftUI

enum LabEffect: String, CaseIterable, Identifiable {
    case none          = "Original"
    case changeColor   = "1 · Replace"
    case horizontalFade = "2 · position"
    case halfAndHalf   = "3 · Branch"
    case grayscale     = "4 · Read source"
    case adjustments   = "5 · Uniforms"
    case bayerDither   = "6 · Bayer dither"
    case ripple        = "7 · Distortion"
    case boxBlur       = "8 · Blur (layer)"
    case sharpen       = "8 · Sharpen (layer)"
    
    var id: String { rawValue }
    
    var explanation: String {
        switch self {
        case .none:
            return "The unmodified source. Everything below is this image, per pixel."
        case .changeColor:
            return "Returns a flat colour, ignoring position. The source is replaced, not tinted."
        case .horizontalFade:
            return "Uses position.x / width to ramp red across the view. `color` is never read, so the source vanishes."
        case .halfAndHalf:
            return "An if on position.x. Same idea as the fade, but a hard edge."
        case .grayscale:
            return "First shader that reads `color`. Rec.601 luma weights — green counts most."
        case .adjustments:
            return "ImageProcessor.applyAdjustments as a shader. Sliders feed straight into the GPU each frame."
        case .bayerDither:
            return "Ordered dithering: each pixel picks a threshold from a 4x4 matrix using its own x,y. No pixel needs any other — so it parallelises. Atkinson cannot."
        case .ripple:
            return "distortionEffect returns a POSITION, not a colour. You say where to sample FROM."
        case .boxBlur:
            return "layerEffect can read neighbours via layer.sample(). 5x5 average."
        case .sharpen:
            return "Unsharp mask: original + (original − blurred) × amount."
        }
    }
}

struct ShaderLabView: View {
    @State private var effect: LabEffect = .none
    @State private var brightness: Double = 0.0
    @State private var contrast: Double = 1.0
    @State private var gamma: Double = 1.0
    @State private var amplitude: Double = 8.0
    @State private var radius: Double = 1.5
    @State private var sharpAmount: Double = 1.5
    
    private let side: CGFloat = 300
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Only the ripple needs a clock. Wrapping every effect in
                // TimelineView(.animation) redrew all ten at display rate to
                // produce an identical frame.
                Group {
                    if effect == .ripple {
                        TimelineView(.animation) { timeline in
                            canvas(time: timeline.date.timeIntervalSince1970)
                        }
                    } else {
                        canvas(time: 0)
                    }
                }
                .frame(width: side, height: side)
                .clipped()
                
                Picker("Effect", selection: $effect) {
                    ForEach(LabEffect.allCases) { e in
                        Text(e.rawValue).tag(e)
                    }
                }
                .pickerStyle(.menu)
                
                Text(effect.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal)
                
                controls
            }
            .padding()
        }
        .navigationTitle("Shader Lab")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    // MARK: - Canvas
    
    @ViewBuilder
    private func canvas(time: TimeInterval) -> some View {
        let src = testImage
        
        switch effect {
        case .none:
            src
        case .changeColor:
            src.colorEffect(ShaderLibrary.changeColor(.color(.red)))
        case .horizontalFade:
            src.colorEffect(ShaderLibrary.horizontalFade(.float(side)))
        case .halfAndHalf:
            src.colorEffect(ShaderLibrary.halfAndHalf(.float(side)))
        case .grayscale:
            src.colorEffect(ShaderLibrary.grayscale())
        case .adjustments:
            src.colorEffect(ShaderLibrary.adjustments(
                .float(brightness), .float(contrast), .float(gamma)
            ))
        case .bayerDither:
            src.colorEffect(ShaderLibrary.bayerDither())
        case .ripple:
            src.distortionEffect(
                ShaderLibrary.ripple(
                    .float2(side, side),
                    .float(time.truncatingRemainder(dividingBy: 1000)),
                    .float(amplitude)
                ),
                maxSampleOffset: CGSize(width: amplitude, height: amplitude)
            )
        case .boxBlur:
            src.layerEffect(
                ShaderLibrary.boxBlur(.float(radius)),
                maxSampleOffset: CGSize(width: radius * 2, height: radius * 2)
            )
        case .sharpen:
            src.layerEffect(
                ShaderLibrary.sharpen(.float(sharpAmount)),
                maxSampleOffset: CGSize(width: 1, height: 1)
            )
        }
    }
    
    /// Continuous-tone test image. Smooth gradients make grayscale, gamma and
    /// dithering visible in a way a flat colour never would.
    private var testImage: some View {
        ZStack {
            LinearGradient(
                colors: [.blue, .purple, .orange, .yellow],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            RadialGradient(
                colors: [.white.opacity(0.9), .clear],
                center: .init(x: 0.3, y: 0.3),
                startRadius: 4,
                endRadius: 130
            )
            
            Circle()
                .fill(.black.opacity(0.55))
                .frame(width: 90, height: 90)
                .offset(x: 70, y: 80)
            
            Text("METAL")
                .font(.system(size: 44, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .offset(y: -100)
        }
        .frame(width: side, height: side)
    }
    
    // MARK: - Controls
    
    @ViewBuilder
    private var controls: some View {
        switch effect {
        case .adjustments:
            slider("Brightness", $brightness, -0.5...0.5)
            slider("Contrast", $contrast, 0.0...3.0)
            slider("Gamma", $gamma, 0.1...3.0)
        case .ripple:
            slider("Amplitude", $amplitude, 0...30)
        case .boxBlur:
            slider("Radius", $radius, 0.5...6)
        case .sharpen:
            slider("Amount", $sharpAmount, 0...5)
        default:
            EmptyView()
        }
    }
    
    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}

#Preview {
    NavigationView { ShaderLabView() }
}
