//
//  Renderer.swift
//  BlutoothLan
//
//  Part 2: the Metal object graph, which SwiftUI's shader modifiers hid from you.
//
//  THE SPLIT THAT MATTERS — get this wrong and everything is slow:
//
//    Built ONCE (expensive, reused forever):
//      MTLDevice           the GPU itself
//      MTLCommandQueue     ordered channel for submitting work
//      MTLRenderPipelineState  compiled shaders + output format, frozen
//      MTLBuffer / MTLTexture  GPU memory
//
//    Built EVERY FRAME (cheap, thrown away):
//      MTLCommandBuffer        one batch of work
//      MTLRenderCommandEncoder writes GPU commands into that batch
//
//  Beginners build pipeline states inside draw(). That's the #1 Metal
//  performance mistake — it recompiles shaders 60 times a second.
//

import MetalKit
import UIKit

enum RenderStage: String, CaseIterable, Identifiable {
    case clearColor   = "9 · Clear colour"
    case triangle     = "10 · Triangle"
    case interpolated = "11 · Vertex buffer"
    case texture      = "12 · Texture + quad"

    var id: String { rawValue }

    var explanation: String {
        switch self {
        case .clearColor:
            return "Nothing is drawn. Device, queue, command buffer and encoder all exist and run — if this colour appears, the whole object graph is wired correctly. Start here so a failure has exactly one cause."
        case .triangle:
            return "Three vertices hardcoded in the shader, indexed by [[vertex_id]]. NDC space: -1…1, origin centre, +Y up (opposite of UIKit)."
        case .interpolated:
            return "Vertices now come from an MTLBuffer, each with its own colour. You wrote three colours; the rasterizer produced every shade between them, in fixed-function hardware."
        case .texture:
            return "Full-screen quad sampling a texture, with a grayscale mix in the fragment shader. Same maths as Part 1 — but inside a pipeline you own."
        }
    }
}

/// Matches `struct Vertex` in Shaders.metal.
/// float2 is 8 bytes/align 8, float4 is 16/align 16 — so colour starts at
/// offset 16 and the struct is 32 bytes. Swift's SIMD types lay out identically.
struct LabVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

/// Matches `struct TexVertex` in Shaders.metal. Two float2s: 16 bytes, no padding.
struct LabTexVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
}

final class Renderer: NSObject, MTKViewDelegate {

    // MARK: - Built once

    let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?

    private var trianglePipeline: MTLRenderPipelineState?
    private var interpolatedPipeline: MTLRenderPipelineState?
    private var quadPipeline: MTLRenderPipelineState?

    private var triangleBuffer: MTLBuffer?
    private var quadBuffer: MTLBuffer?
    private var texture: MTLTexture?

    // MARK: - Per-frame inputs

    var stage: RenderStage = .clearColor
    var grayAmount: Float = 0

    // MARK: - Setup

    override init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        self.commandQueue = device?.makeCommandQueue()
        super.init()

        guard let device, let library = device.makeDefaultLibrary() else { return }

        // Shaders were compiled at BUILD time into default.metallib. This just
        // looks them up by name — a typo here fails at runtime, not compile time.
        buildPipelines(device: device, library: library)
        buildBuffers(device: device)
        buildTexture(device: device)
    }

    private func buildPipelines(device: MTLDevice, library: MTLLibrary) {
        func makePipeline(vertex: String, fragment: String) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            // Must match MTKView.colorPixelFormat, or creation throws.
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        trianglePipeline     = makePipeline(vertex: "triangle_vertex",     fragment: "triangle_fragment")
        interpolatedPipeline = makePipeline(vertex: "interpolated_vertex", fragment: "triangle_fragment")
        quadPipeline         = makePipeline(vertex: "quad_vertex",         fragment: "quad_fragment")
    }

    private func buildBuffers(device: MTLDevice) {
        // One colour per corner. The blend between them is not written anywhere.
        let triangle: [LabVertex] = [
            LabVertex(position: [ 0.0,  0.8], color: [1, 0, 0, 1]),   // red   top
            LabVertex(position: [-0.8, -0.8], color: [0, 1, 0, 1]),   // green bottom left
            LabVertex(position: [ 0.8, -0.8], color: [0, 0, 1, 1])    // blue  bottom right
        ]
        triangleBuffer = device.makeBuffer(
            bytes: triangle,
            length: MemoryLayout<LabVertex>.stride * triangle.count
        )

        // Triangle strip covering the screen. NDC on the left, UV on the right —
        // note UV's origin is top-left while NDC's +Y is up.
        let quad: [LabTexVertex] = [
            LabTexVertex(position: [-1,  1], uv: [0, 0]),   // top left
            LabTexVertex(position: [-1, -1], uv: [0, 1]),   // bottom left
            LabTexVertex(position: [ 1,  1], uv: [1, 0]),   // top right
            LabTexVertex(position: [ 1, -1], uv: [1, 1])    // bottom right
        ]
        quadBuffer = device.makeBuffer(
            bytes: quad,
            length: MemoryLayout<LabTexVertex>.stride * quad.count
        )
    }

    private func buildTexture(device: MTLDevice) {
        guard let cgImage = Renderer.makeTestImage(side: 512).cgImage else { return }
        let loader = MTKTextureLoader(device: device)
        // .SRGB false keeps the values raw so the grayscale maths is predictable.
        texture = try? loader.newTexture(cgImage: cgImage, options: [.SRGB: false])
    }

    // MARK: - Per frame

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let commandQueue,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        // The render pass descriptor already carries the clear colour, so
        // "stage 9" needs literally nothing else — open the encoder and close it.
        switch stage {
        case .clearColor:
            break

        case .triangle:
            if let trianglePipeline {
                encoder.setRenderPipelineState(trianglePipeline)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }

        case .interpolated:
            if let interpolatedPipeline, let triangleBuffer {
                encoder.setRenderPipelineState(interpolatedPipeline)
                encoder.setVertexBuffer(triangleBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }

        case .texture:
            if let quadPipeline, let quadBuffer, let texture {
                encoder.setRenderPipelineState(quadPipeline)
                encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
                encoder.setFragmentTexture(texture, index: 0)
                // Small data (<4KB) can skip the MTLBuffer entirely.
                var gray = grayAmount
                encoder.setFragmentBytes(&gray, length: MemoryLayout<Float>.size, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Test image

    /// Drawn procedurally so the project needs no image assets.
    private static func makeTestImage(side: CGFloat) -> UIImage {
        // scale = 1 so `side` means pixels, not points. The default is the
        // screen scale, which would make this a 1536px texture on a 3x device.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1

        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side),
                                       format: format).image { ctx in
            let cg = ctx.cgContext

            let colors = [
                UIColor.systemBlue.cgColor,
                UIColor.systemPurple.cgColor,
                UIColor.systemOrange.cgColor,
                UIColor.systemYellow.cgColor
            ]
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors as CFArray,
                locations: [0, 0.4, 0.75, 1]
            ) {
                cg.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: side, y: side),
                    options: []
                )
            }

            UIColor.white.withAlphaComponent(0.85).setFill()
            cg.fillEllipse(in: CGRect(x: side * 0.10, y: side * 0.30,
                                      width: side * 0.28, height: side * 0.28))

            UIColor.black.withAlphaComponent(0.55).setFill()
            cg.fillEllipse(in: CGRect(x: side * 0.58, y: side * 0.58,
                                      width: side * 0.28, height: side * 0.28))

            let text = "METAL" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: side * 0.15, weight: .black),
                .foregroundColor: UIColor.white
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (side - size.width) / 2, y: side * 0.08),
                      withAttributes: attributes)
        }
    }
}
