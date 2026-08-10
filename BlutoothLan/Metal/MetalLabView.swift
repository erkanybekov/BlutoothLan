//
//  MetalLabView.swift
//  BlutoothLan
//
//  Part 2 playground. MTKView is UIKit, so it reaches SwiftUI through
//  UIViewRepresentable — that wrapper is the only "glue" here.
//

import SwiftUI
import MetalKit

struct MetalLabView: View {
    @State private var stage: RenderStage = .clearColor
    @State private var grayAmount: Double = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if MTLCreateSystemDefaultDevice() == nil {
                    Text("No Metal device available on this machine.")
                        .foregroundStyle(.red)
                        .frame(height: 300)
                } else {
                    MetalCanvas(stage: stage, grayAmount: Float(grayAmount))
                        .frame(width: 300, height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Picker("Stage", selection: $stage) {
                    ForEach(RenderStage.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.menu)

                Text(stage.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if stage == .texture {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Grayscale mix").font(.caption)
                            Spacer()
                            Text(String(format: "%.2f", grayAmount))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $grayAmount, in: 0...1)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Metal Lab")
        .navigationBarTitleDisplayMode(.inline)
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

    func makeCoordinator() -> Renderer { Renderer() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.device
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm          // must match the pipeline descriptor
        view.clearColor = MTLClearColorMake(0.05, 0.06, 0.12, 1.0)

        // MTKView redraws continuously at up to 60fps by default. For something
        // like the printer preview — which only changes when a slider moves —
        // you'd set isPaused = true and enableSetNeedsDisplay = true instead.
        view.preferredFramesPerSecond = 60
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.stage = stage
        context.coordinator.grayAmount = grayAmount
    }
}

#Preview {
    NavigationView { MetalLabView() }
}
