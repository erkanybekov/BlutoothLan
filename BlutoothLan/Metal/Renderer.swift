//
//  Renderer.swift
//  BlutoothLan
//
//  Part 2: the Metal object graph, which SwiftUI's shader modifiers hid from you.
//  Part 4 adds what Part 2 cut corners on — vertex descriptors, index buffers,
//  depth testing, and multi-pass rendering.
//
//  THE SPLIT THAT MATTERS — get this wrong and everything is slow:
//
//    Built ONCE (expensive, reused forever):
//      MTLDevice           the GPU itself
//      MTLCommandQueue     ordered channel for submitting work
//      MTLRenderPipelineState  compiled shaders + output format, frozen
//      MTLDepthStencilState    depth test configuration
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
import simd

enum RenderStage: String, CaseIterable, Identifiable {
    case clearColor   = "9 · Clear colour"
    case triangle     = "10 · Triangle"
    case interpolated = "11 · Vertex buffer"
    case texture      = "12 · Texture + quad"
    case cube         = "15 · 3D cube"
    case multipass    = "16 · Multi-pass"
    case blending     = "20 · Blending"
    case msaa         = "22 · MSAA"
    case argumentBuf  = "23 · Argument buffer"

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
        case .cube:
            return "MTLVertexDescriptor + [[stage_in]], an index buffer (8 corners → 36 triangle vertices), a depth buffer, and back-face culling (stage 21). Depth is pipeline state; culling is an encoder setting. Turn each off separately."
        case .multipass:
            return "Pass 1 renders adjustments into an OFFSCREEN texture. Pass 2 dithers that result to the screen. The intermediate never leaves the GPU — and pass 2 sees pass 1's output, which no colorEffect can do."
        case .blending:
            return "Three overlapping translucent quads. Blending is baked into the PIPELINE STATE, not set per draw — so each mode needs its own pipeline, built once at init."
        case .msaa:
            return "A thin diagonal triangle, where aliasing is obvious. Sample count is baked into both the view AND the pipeline, so they must agree — hence two pipelines, one per count."
        case .argumentBuf:
            return "Same output as stage 12, but the texture, sampler and uniform are packed into ONE argument buffer filled in once at init and bound with a single call. Because the GPU reaches the texture through the buffer, useResource() is mandatory — without it Metal doesn't know the texture is live."
        }
    }
}

/// Blending is part of the pipeline state, so each mode is a separate PSO.
enum BlendMode: String, CaseIterable, Identifiable {
    case off      = "Off"
    case alpha    = "Alpha"
    case additive = "Additive"

    var id: String { rawValue }
}

/// Matches `struct Vertex` in Shaders.metal.
struct LabVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

/// Matches `struct TexVertex` in Shaders.metal. Two float2s: 16 bytes, no padding.
struct LabTexVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
}

/// Matches `struct CubeVertexIn`. Both members are float4 deliberately — a
/// SIMD3<Float> is 16 bytes in Swift but 12 in MSL's packed_float3, and that
/// mismatch is a classic silent corruption. Two float4s have no such trap.
struct CubeVertex {
    var position: SIMD4<Float>
    var color: SIMD4<Float>
}

struct CubeUniforms {
    var mvp: simd_float4x4
}

final class Renderer: NSObject, MTKViewDelegate {

    // MARK: - Built once

    let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?

    private var trianglePipeline: MTLRenderPipelineState?
    private var interpolatedPipeline: MTLRenderPipelineState?
    private var quadPipeline: MTLRenderPipelineState?
    private var cubePipeline: MTLRenderPipelineState?
    private var adjustPipeline: MTLRenderPipelineState?     // offscreen, no depth
    private var ditherPipeline: MTLRenderPipelineState?     // onscreen, has depth

    private var depthState: MTLDepthStencilState?
    private var noDepthState: MTLDepthStencilState?

    private var argPipeline: MTLRenderPipelineState?
    private var argumentBuffer: MTLBuffer?
    private var argSampler: MTLSamplerState?

    /// One pipeline per blend mode — blending can't be toggled on an encoder.
    private var blendPipelines: [BlendMode: MTLRenderPipelineState] = [:]
    /// Keyed by rasterSampleCount. The view's sampleCount and the pipeline's
    /// must match exactly or the draw is rejected.
    private var msaaPipelines: [Int: MTLRenderPipelineState] = [:]

    private var triangleBuffer: MTLBuffer?
    private var blendBuffer: MTLBuffer?
    private var thinTriangleBuffer: MTLBuffer?
    private var quadBuffer: MTLBuffer?
    private var cubeBuffer: MTLBuffer?
    private var cubeIndexBuffer: MTLBuffer?
    private var texture: MTLTexture?

    /// Offscreen render target for stage 16. Rebuilt only when the size changes.
    private var offscreen: MTLTexture?

    private let cubeIndexCount = 36

    // MARK: - Per-frame inputs

    var stage: RenderStage = .clearColor
    var grayAmount: Float = 0
    var depthEnabled: Bool = true
    var cullingEnabled: Bool = false
    var blendMode: BlendMode = .alpha
    var msaaEnabled: Bool = true
    var brightness: Float = 0
    var contrast: Float = 1
    var gamma: Float = 1

    private var angle: Float = 0
    private var lastFrameTime: CFTimeInterval = 0

    // MARK: - Setup

    override init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        self.commandQueue = device?.makeCommandQueue()
        super.init()

        guard let device, let library = device.makeDefaultLibrary() else { return }

        buildPipelines(device: device, library: library)
        buildDepthState(device: device)
        buildBuffers(device: device)
        buildTexture(device: device)
        buildArgumentBuffer(device: device, library: library)
    }

    /// True only where argument buffers can actually hold a texture.
    private(set) var argumentBuffersAvailable = false

    /// Pack texture + sampler + a float into one GPU-side struct, once.
    private func buildArgumentBuffer(device: MTLDevice, library: MTLLibrary) {
        // Tier 1 supports argument buffers but not texture access through them
        // the way this shader needs. The iOS Simulator reports tier 1 and aborts
        // the command buffer (MTLCommandBufferErrorDomain error 3) if you try.
        // Apple silicon devices report tier 2.
        guard device.argumentBuffersSupport == .tier2 else { return }
        argumentBuffersAvailable = true

        guard let fragment = library.makeFunction(name: "argbuffer_fragment") else { return }

        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "quad_vertex")
        d.fragmentFunction = fragment
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        d.depthAttachmentPixelFormat = .depth32Float
        argPipeline = try? device.makeRenderPipelineState(descriptor: d)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        argSampler = device.makeSamplerState(descriptor: samplerDescriptor)

        // The encoder knows the struct's GPU layout from the shader — you never
        // hand-compute offsets, which is the whole point of using it at Tier 1.
        let encoder = fragment.makeArgumentEncoder(bufferIndex: 0)
        guard let buffer = device.makeBuffer(length: encoder.encodedLength,
                                             options: .storageModeShared),
              let texture, let argSampler
        else { return }

        encoder.setArgumentBuffer(buffer, offset: 0)
        encoder.setTexture(texture, index: 0)
        encoder.setSamplerState(argSampler, index: 1)
        var gray: Float = 1.0
        memcpy(encoder.constantData(at: 2), &gray, MemoryLayout<Float>.size)

        argumentBuffer = buffer
    }

    private func buildPipelines(device: MTLDevice, library: MTLLibrary) {
        // A pipeline's attachment formats must match the render pass it's used
        // with. The offscreen pass has no depth attachment, so its pipeline must
        // declare .invalid — mixing these up is a runtime pipeline creation error.
        func makePipeline(vertex: String,
                          fragment: String,
                          vertexDescriptor: MTLVertexDescriptor? = nil,
                          depthFormat: MTLPixelFormat = .depth32Float) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.depthAttachmentPixelFormat = depthFormat
            descriptor.vertexDescriptor = vertexDescriptor
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        trianglePipeline     = makePipeline(vertex: "triangle_vertex",     fragment: "triangle_fragment")
        interpolatedPipeline = makePipeline(vertex: "interpolated_vertex", fragment: "triangle_fragment")
        quadPipeline         = makePipeline(vertex: "quad_vertex",         fragment: "quad_fragment")

        // The descriptor tells the GPU how to unpack each vertex from buffer 0.
        // This is what [[stage_in]] + [[attribute(n)]] read on the shader side.
        let cubeDescriptor = MTLVertexDescriptor()
        cubeDescriptor.attributes[0].format = .float4
        cubeDescriptor.attributes[0].offset = 0
        cubeDescriptor.attributes[0].bufferIndex = 0
        cubeDescriptor.attributes[1].format = .float4
        cubeDescriptor.attributes[1].offset = MemoryLayout<SIMD4<Float>>.stride
        cubeDescriptor.attributes[1].bufferIndex = 0
        cubeDescriptor.layouts[0].stride = MemoryLayout<CubeVertex>.stride

        cubePipeline = makePipeline(vertex: "cube_vertex",
                                    fragment: "triangle_fragment",
                                    vertexDescriptor: cubeDescriptor)

        adjustPipeline = makePipeline(vertex: "quad_vertex", fragment: "adjust_fragment",
                                      depthFormat: .invalid)          // offscreen
        ditherPipeline = makePipeline(vertex: "quad_vertex", fragment: "dither_fragment")

        buildBlendPipelines(device: device, library: library)
        buildMSAAPipelines(device: device, library: library)
    }

    /// Blending lives in the pipeline state object, so "change the blend mode"
    /// really means "switch to a different PSO". Build them all once up front —
    /// creating one inside draw() is the mistake this file keeps warning about.
    private func buildBlendPipelines(device: MTLDevice, library: MTLLibrary) {
        for mode in BlendMode.allCases {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "interpolated_vertex")
            d.fragmentFunction = library.makeFunction(name: "triangle_fragment")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            d.depthAttachmentPixelFormat = .depth32Float

            let a = d.colorAttachments[0]!
            switch mode {
            case .off:
                a.isBlendingEnabled = false
            case .alpha:
                // result = src·srcAlpha + dst·(1 − srcAlpha)
                a.isBlendingEnabled = true
                a.rgbBlendOperation = .add
                a.alphaBlendOperation = .add
                a.sourceRGBBlendFactor = .sourceAlpha
                a.sourceAlphaBlendFactor = .sourceAlpha
                a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            case .additive:
                // result = src·srcAlpha + dst — light accumulates, never darkens
                a.isBlendingEnabled = true
                a.rgbBlendOperation = .add
                a.alphaBlendOperation = .add
                a.sourceRGBBlendFactor = .sourceAlpha
                a.sourceAlphaBlendFactor = .sourceAlpha
                a.destinationRGBBlendFactor = .one
                a.destinationAlphaBlendFactor = .one
            }

            blendPipelines[mode] = try? device.makeRenderPipelineState(descriptor: d)
        }
    }

    private func buildMSAAPipelines(device: MTLDevice, library: MTLLibrary) {
        for samples in [1, 4] {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "interpolated_vertex")
            d.fragmentFunction = library.makeFunction(name: "triangle_fragment")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            d.depthAttachmentPixelFormat = .depth32Float
            d.rasterSampleCount = samples
            msaaPipelines[samples] = try? device.makeRenderPipelineState(descriptor: d)
        }
    }

    private func buildDepthState(device: MTLDevice) {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .less   // keep the fragment nearest the camera
        descriptor.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: descriptor)

        // "Depth off" has to be an explicit state: always pass, never write.
        // Passing nil to setDepthStencilState looks equivalent and aborts the
        // Metal simulator with "Invalid depth stencil state". Make the
        // disabled case a real object.
        let off = MTLDepthStencilDescriptor()
        off.depthCompareFunction = .always
        off.isDepthWriteEnabled = false
        noDepthState = device.makeDepthStencilState(descriptor: off)
    }

    private func buildBuffers(device: MTLDevice) {
        let triangle: [LabVertex] = [
            LabVertex(position: [ 0.0,  0.8], color: [1, 0, 0, 1]),
            LabVertex(position: [-0.8, -0.8], color: [0, 1, 0, 1]),
            LabVertex(position: [ 0.8, -0.8], color: [0, 0, 1, 1])
        ]
        triangleBuffer = device.makeBuffer(bytes: triangle,
                                           length: MemoryLayout<LabVertex>.stride * triangle.count)

        let quad: [LabTexVertex] = [
            LabTexVertex(position: [-1,  1], uv: [0, 0]),
            LabTexVertex(position: [-1, -1], uv: [0, 1]),
            LabTexVertex(position: [ 1,  1], uv: [1, 0]),
            LabTexVertex(position: [ 1, -1], uv: [1, 1])
        ]
        quadBuffer = device.makeBuffer(bytes: quad,
                                       length: MemoryLayout<LabTexVertex>.stride * quad.count)

        // EIGHT corners. Without indices you'd store 36 vertices to draw 12
        // triangles; with them you store 8 and reference them 36 times.
        let c: Float = 0.6
        let corners: [CubeVertex] = [
            CubeVertex(position: [-c, -c, -c, 1], color: [1, 0, 0, 1]),
            CubeVertex(position: [ c, -c, -c, 1], color: [0, 1, 0, 1]),
            CubeVertex(position: [ c,  c, -c, 1], color: [0, 0, 1, 1]),
            CubeVertex(position: [-c,  c, -c, 1], color: [1, 1, 0, 1]),
            CubeVertex(position: [-c, -c,  c, 1], color: [1, 0, 1, 1]),
            CubeVertex(position: [ c, -c,  c, 1], color: [0, 1, 1, 1]),
            CubeVertex(position: [ c,  c,  c, 1], color: [1, 1, 1, 1]),
            CubeVertex(position: [-c,  c,  c, 1], color: [0.2, 0.2, 0.2, 1])
        ]
        cubeBuffer = device.makeBuffer(bytes: corners,
                                       length: MemoryLayout<CubeVertex>.stride * corners.count)

        let indices: [UInt16] = [
            0, 1, 2,  2, 3, 0,      // -Z
            5, 4, 7,  7, 6, 5,      // +Z
            4, 0, 3,  3, 7, 4,      // -X
            1, 5, 6,  6, 2, 1,      // +X
            3, 2, 6,  6, 7, 3,      // +Y
            4, 5, 1,  1, 0, 4       // -Y
        ]
        cubeIndexBuffer = device.makeBuffer(bytes: indices,
                                            length: MemoryLayout<UInt16>.stride * indices.count)

        // Three overlapping translucent quads, 6 vertices each (two triangles).
        func makeQuad(_ cx: Float, _ cy: Float, _ colour: SIMD4<Float>) -> [LabVertex] {
            let s: Float = 0.45
            let corners: [SIMD2<Float>] = [
                [cx - s, cy + s], [cx - s, cy - s], [cx + s, cy + s],
                [cx + s, cy + s], [cx - s, cy - s], [cx + s, cy - s]
            ]
            return corners.map { LabVertex(position: $0, color: colour) }
        }
        let blendVerts = makeQuad(-0.25,  0.25, [1, 0.15, 0.15, 0.6])
                       + makeQuad( 0.25,  0.25, [0.15, 1, 0.15, 0.6])
                       + makeQuad( 0.0,  -0.25, [0.2, 0.4, 1, 0.6])
        blendBuffer = device.makeBuffer(bytes: blendVerts,
                                        length: MemoryLayout<LabVertex>.stride * blendVerts.count)

        // A near-horizontal sliver: the worst case for aliasing, so MSAA on/off
        // is unmistakable.
        let thin: [LabVertex] = [
            LabVertex(position: [-0.9, -0.06], color: [1, 1, 1, 1]),
            LabVertex(position: [ 0.9,  0.30], color: [1, 1, 1, 1]),
            LabVertex(position: [ 0.9,  0.16], color: [1, 1, 1, 1])
        ]
        thinTriangleBuffer = device.makeBuffer(bytes: thin,
                                               length: MemoryLayout<LabVertex>.stride * thin.count)
    }

    private func buildTexture(device: MTLDevice) {
        guard let cgImage = Renderer.makeTestImage(side: 512).cgImage else { return }
        let loader = MTKTextureLoader(device: device)
        texture = try? loader.newTexture(cgImage: cgImage, options: [.SRGB: false])
    }

    /// A texture you render INTO needs .renderTarget; reading it in pass 2
    /// needs .shaderRead. Omit either and Metal rejects the pass.
    private func offscreenTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        if let offscreen, offscreen.width == width, offscreen.height == height {
            return offscreen
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private        // GPU-only: never touched by the CPU
        offscreen = device.makeTexture(descriptor: descriptor)
        return offscreen
    }

    // MARK: - Per frame

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let device,
              let commandQueue,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        if stage == .multipass {
            encodeMultipass(device: device,
                            commandBuffer: commandBuffer,
                            descriptor: descriptor,
                            width: drawable.texture.width,
                            height: drawable.texture.height)
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

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
                var gray = grayAmount
                encoder.setFragmentBytes(&gray, length: MemoryLayout<Float>.size, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }

        case .cube:
            encodeCube(encoder: encoder, view: view)

        case .blending:
            if let pipeline = blendPipelines[blendMode], let blendBuffer {
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(blendBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 18)
            }

        case .msaa:
            let samples = msaaEnabled ? 4 : 1
            if let pipeline = msaaPipelines[samples], let thinTriangleBuffer {
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(thinTriangleBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }

        case .argumentBuf:
            if let argPipeline, let argumentBuffer, let quadBuffer, let texture {
                encoder.setRenderPipelineState(argPipeline)
                encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
                encoder.setFragmentBuffer(argumentBuffer, offset: 0, index: 0)
                // MANDATORY. Metal can't see through the argument buffer to know
                // the texture is referenced; drop this and you get black or a crash.
                encoder.useResource(texture, usage: .read, stages: .fragment)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }

        case .multipass:
            break   // handled above
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func encodeCube(encoder: MTLRenderCommandEncoder, view: MTKView) {
        guard let cubePipeline, let cubeBuffer, let cubeIndexBuffer else { return }

        // Advance by elapsed TIME, not per frame. `angle += 0.01` spins twice as
        // fast on a 120Hz ProMotion display as on a 60Hz one. The clamp stops a
        // huge jump after the app is backgrounded.
        let now = CACurrentMediaTime()
        let dt = lastFrameTime == 0 ? 1.0 / 60.0 : min(now - lastFrameTime, 0.1)
        lastFrameTime = now
        angle += Float(dt) * 0.6            // radians per second

        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        let projection = Renderer.perspective(fovY: .pi / 3, aspect: aspect, near: 0.1, far: 100)
        let view4 = Renderer.translation(SIMD3<Float>(0, 0, -3))
        let model = Renderer.rotation(angle: angle, axis: [0.4, 1, 0.2])

        var uniforms = CubeUniforms(mvp: projection * view4 * model)

        encoder.setRenderPipelineState(cubePipeline)
        // Toggling this off is the clearest way to see what depth testing does.
        encoder.setDepthStencilState(depthEnabled ? depthState : noDepthState)

        // Culling is a *different* mechanism from depth, and unlike blending it
        // IS a runtime encoder setting rather than pipeline state. It discards
        // triangles by winding order before rasterisation, so it's free
        // performance; depth resolves what's actually in front. Real renderers
        // use both. Turn depth off but culling on to see culling working alone.
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(cullingEnabled ? .back : .none)
        encoder.setVertexBuffer(cubeBuffer, offset: 0, index: 0)       // owned by the descriptor
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CubeUniforms>.size, index: 1)

        encoder.drawIndexedPrimitives(type: .triangle,
                                      indexCount: cubeIndexCount,
                                      indexType: .uint16,
                                      indexBuffer: cubeIndexBuffer,
                                      indexBufferOffset: 0)
    }

    private func encodeMultipass(device: MTLDevice,
                                 commandBuffer: MTLCommandBuffer,
                                 descriptor: MTLRenderPassDescriptor,
                                 width: Int,
                                 height: Int) {
        guard let adjustPipeline, let ditherPipeline,
              let quadBuffer, let texture,
              let target = offscreenTexture(device: device, width: width, height: height)
        else { return }

        // ---- PASS 1 → offscreen texture (a render pass descriptor you build) ----
        let pass1 = MTLRenderPassDescriptor()
        pass1.colorAttachments[0].texture = target
        pass1.colorAttachments[0].loadAction = .clear
        pass1.colorAttachments[0].storeAction = .store      // .store, or pass 2 reads garbage
        pass1.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        if let e1 = commandBuffer.makeRenderCommandEncoder(descriptor: pass1) {
            e1.setRenderPipelineState(adjustPipeline)
            e1.setVertexBuffer(quadBuffer, offset: 0, index: 0)
            e1.setFragmentTexture(texture, index: 0)
            var bcg = SIMD3<Float>(brightness, contrast, gamma)
            e1.setFragmentBytes(&bcg, length: MemoryLayout<SIMD3<Float>>.size, index: 0)
            e1.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            e1.endEncoding()
        }

        // ---- PASS 2 → the drawable, reading pass 1's output ----
        if let e2 = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
            e2.setRenderPipelineState(ditherPipeline)
            e2.setVertexBuffer(quadBuffer, offset: 0, index: 0)
            e2.setFragmentTexture(target, index: 0)
            var size = SIMD2<Float>(Float(width), Float(height))
            e2.setFragmentBytes(&size, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
            e2.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            e2.endEncoding()
        }
    }

    // MARK: - Matrices
    //
    // Metal's clip space maps z to [0, 1], not [-1, 1] like OpenGL. Porting an
    // OpenGL projection matrix without fixing that gives you a scene where
    // half the depth range is behind the camera.

    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let ys = 1 / tanf(fovY * 0.5)
        let xs = ys / aspect
        let zs = far / (near - far)
        return simd_float4x4(
            SIMD4<Float>(xs, 0, 0, 0),
            SIMD4<Float>(0, ys, 0, 0),
            SIMD4<Float>(0, 0, zs, -1),
            SIMD4<Float>(0, 0, zs * near, 0)
        )
    }

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return m
    }

    static func rotation(angle: Float, axis: SIMD3<Float>) -> simd_float4x4 {
        let a = normalize(axis)
        let c = cosf(angle), s = sinf(angle), ic = 1 - c

        return simd_float4x4(
            SIMD4<Float>(c + a.x * a.x * ic,        a.y * a.x * ic + a.z * s,  a.z * a.x * ic - a.y * s, 0),
            SIMD4<Float>(a.x * a.y * ic - a.z * s,  c + a.y * a.y * ic,        a.z * a.y * ic + a.x * s, 0),
            SIMD4<Float>(a.x * a.z * ic + a.y * s,  a.y * a.z * ic - a.x * s,  c + a.z * a.z * ic,       0),
            SIMD4<Float>(0, 0, 0, 1)
        )
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
