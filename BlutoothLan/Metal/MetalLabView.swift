//
//  MetalLabView.swift
//  BlutoothLan
//
//  Part 2 + 4 playground. MTKView is UIKit, so it reaches SwiftUI through
//  UIViewRepresentable — that wrapper is the only "glue" here.
//

import SwiftUI
import MetalKit

struct MetalLabView: View {
    @State private var stage: RenderStage = .clearColor
    @State private var grayAmount: Double = 0
    @State private var depthEnabled = true
    @State private var cullingEnabled = false
    @State private var blendMode: BlendMode = .alpha
    @State private var msaaEnabled = true
    @State private var brightness: Double = 0
    @State private var contrast: Double = 1.4
    @State private var gamma: Double = 1

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if MTLCreateSystemDefaultDevice() == nil {
                    Text("No Metal device available on this machine.")
                        .foregroundStyle(.red)
                        .frame(height: 300)
                } else {
                    MetalCanvas(stage: stage,
                                grayAmount: Float(grayAmount),
                                depthEnabled: depthEnabled,
                                cullingEnabled: cullingEnabled,
                                blendMode: blendMode,
                                msaaEnabled: msaaEnabled,
                                brightness: Float(brightness),
                                contrast: Float(contrast),
                                gamma: Float(gamma))
                        .frame(width: 300, height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Picker("Stage", selection: $stage) {
                    ForEach(RenderStage.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.menu)

                if stage == .argumentBuf,
                   MTLCreateSystemDefaultDevice()?.argumentBuffersSupport != .tier2 {
                    Text("Argument buffers are tier 1 on this device — texture access through them isn't supported and the command buffer aborts. Run on a physical iPhone (Apple silicon reports tier 2). See Capabilities.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Text(stage.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                controls
            }
            .padding()
        }
        .navigationTitle("Metal Lab")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var controls: some View {
        switch stage {
        case .texture:
            slider("Grayscale mix", $grayAmount, 0...1)
        case .cube:
            Toggle("Depth testing", isOn: $depthEnabled)
                .font(.subheadline)
            Toggle("Back-face culling", isOn: $cullingEnabled)
                .font(.subheadline)
        case .blending:
            Picker("Blend", selection: $blendMode) {
                ForEach(BlendMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        case .msaa:
            Toggle("4× MSAA", isOn: $msaaEnabled)
                .font(.subheadline)
        case .multipass:
            slider("Brightness (pass 1)", $brightness, -0.4...0.4)
            slider("Contrast (pass 1)", $contrast, 0...3)
            slider("Gamma (pass 1)", $gamma, 0.2...3)
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

/// Bridges MTKView into SwiftUI.
///
/// The Renderer lives in the Coordinator, so it survives SwiftUI re-rendering
/// the struct. If you built the device and pipelines in `makeUIView` instead,
/// they'd be rebuilt constantly — the exact mistake Renderer.swift warns about.
private struct MetalCanvas: UIViewRepresentable {
    let stage: RenderStage
    let grayAmount: Float
    let depthEnabled: Bool
    let cullingEnabled: Bool
    let blendMode: BlendMode
    let msaaEnabled: Bool
    let brightness: Float
    let contrast: Float
    let gamma: Float

    func makeCoordinator() -> Renderer { Renderer() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.device
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm          // must match the pipeline descriptor
        // Setting this makes MTKView create and manage the depth texture for us.
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColorMake(0.05, 0.06, 0.12, 1.0)

        view.preferredFramesPerSecond = 60
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.stage = stage
        context.coordinator.grayAmount = grayAmount
        context.coordinator.depthEnabled = depthEnabled
        context.coordinator.cullingEnabled = cullingEnabled
        context.coordinator.blendMode = blendMode
        context.coordinator.msaaEnabled = msaaEnabled
        context.coordinator.brightness = brightness
        context.coordinator.contrast = contrast
        context.coordinator.gamma = gamma

        // The VIEW's sample count and the PIPELINE's must agree, so the view
        // switches with the stage. MTKView rebuilds its MSAA and depth textures
        // and sets up the multisample resolve for us.
        let wanted = (stage == .msaa && msaaEnabled) ? 4 : 1
        if view.sampleCount != wanted { view.sampleCount = wanted }

        // Only the cube animates. Everything else is static, so redraw ON DEMAND
        // instead of burning 60fps to draw an identical frame — this is the mode
        // a printer preview would use, where the image changes only when a
        // slider moves.
        let animates = (stage == .cube)
        view.isPaused = !animates
        view.enableSetNeedsDisplay = !animates
        if !animates {
            view.setNeedsDisplay()      // this call is what schedules the redraw
        }
    }
}

#Preview {
    NavigationView { MetalLabView() }
}
