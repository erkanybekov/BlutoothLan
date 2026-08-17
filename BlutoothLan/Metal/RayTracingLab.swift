//
//  RayTracingLab.swift
//  BlutoothLan
//
//  Building an acceleration structure and tracing one ray per pixel.
//
//  The acceleration structure is the whole trick. Testing every ray against
//  every triangle is O(rays × triangles); a BVH makes it roughly
//  O(rays × log triangles). Metal builds and owns that structure — you hand it
//  geometry and it hands you something you can intersect.
//
//  DEVICE-ONLY: the iOS Simulator reports supportsRaytracing == false. This
//  compiles there but shows an unsupported state.
//

import Metal
import MetalKit
import SwiftUI
import simd

final class RayTracingLab {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var accelerationStructure: MTLAccelerationStructure?
    private var vertexBuffer: MTLBuffer?

    let supported: Bool
    let size = 512

    struct Uniforms {
        var cameraPosition: SIMD3<Float>
        var time: Float
        var size: SIMD2<UInt32>
    }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return nil }

        self.device = device
        self.queue = queue
        self.supported = device.supportsRaytracing

        // The library function only exists if the shader compiled; on a device
        // without RT support the pipeline may still fail, so bail cleanly.
        guard let library = device.makeDefaultLibrary(),
              let fn = library.makeFunction(name: "rayTraceKernel"),
              let p = try? device.makeComputePipelineState(function: fn)
        else { return nil }
        self.pipeline = p

        guard supported else { return }      // don't build an AS we can't use
        buildAccelerationStructure()
    }

    /// A small pile of triangles: a ground quad and a pyramid above it.
    private func buildAccelerationStructure() {
        let v: [SIMD3<Float>] = [
            // ground quad
            [-3, -1, -2], [ 3, -1, -2], [ 3, -1, -8],
            [-3, -1, -2], [ 3, -1, -8], [-3, -1, -8],
            // pyramid
            [ 0,  1.2, -5], [-1.2, -1, -3.8], [ 1.2, -1, -3.8],
            [ 0,  1.2, -5], [ 1.2, -1, -3.8], [ 1.2, -1, -6.2],
            [ 0,  1.2, -5], [ 1.2, -1, -6.2], [-1.2, -1, -6.2],
            [ 0,  1.2, -5], [-1.2, -1, -6.2], [-1.2, -1, -3.8]
        ]

        vertexBuffer = device.makeBuffer(bytes: v,
                                         length: MemoryLayout<SIMD3<Float>>.stride * v.count,
                                         options: .storageModeShared)

        let geometry = MTLAccelerationStructureTriangleGeometryDescriptor()
        geometry.vertexBuffer = vertexBuffer
        geometry.vertexStride = MemoryLayout<SIMD3<Float>>.stride
        geometry.triangleCount = v.count / 3

        let descriptor = MTLPrimitiveAccelerationStructureDescriptor()
        descriptor.geometryDescriptors = [geometry]

        // Ask Metal how big the structure and its scratch space need to be.
        let sizes = device.accelerationStructureSizes(descriptor: descriptor)
        guard let accel = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
              let scratch = device.makeBuffer(length: max(sizes.buildScratchBufferSize, 1),
                                              options: .storageModePrivate),
              let cb = queue.makeCommandBuffer(),
              // Building needs its own encoder type, alongside render/compute/blit.
              let enc = cb.makeAccelerationStructureCommandEncoder()
        else { return }

        enc.build(accelerationStructure: accel,
                  descriptor: descriptor,
                  scratchBuffer: scratch,
                  scratchBufferOffset: 0)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        accelerationStructure = accel
    }

    func render(time: Float) async -> UIImage? {
        guard supported, let accel = accelerationStructure else { return nil }

        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        d.usage = [.shaderWrite, .shaderRead]
        d.storageMode = .shared
        guard let out = device.makeTexture(descriptor: d),
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder()
        else { return nil }

        enc.setComputePipelineState(pipeline)
        enc.setTexture(out, index: 0)
        enc.setAccelerationStructure(accel, bufferIndex: 0)

        var u = Uniforms(cameraPosition: [sin(time) * 1.5, 0.4, 1.5],
                         time: time,
                         size: SIMD2<UInt32>(UInt32(size), UInt32(size)))
        enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)

        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        enc.dispatchThreads(MTLSize(width: size, height: size, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        enc.endEncoding()

        await withCheckedContinuation { c in
            cb.addCompletedHandler { _ in c.resume() }
            cb.commit()
        }

        return image(from: out)
    }

    private func image(from texture: MTLTexture) -> UIImage? {
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        texture.getBytes(&bytes, bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                         mipmapLevel: 0)

        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: texture.width, height: texture.height,
                               bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: bytesPerRow,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue:
                                    CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct RayTracingLabView: View {
    @State private var lab: RayTracingLab?
    @State private var loaded = false
    @State private var image: UIImage?
    @State private var angle: Double = 0
    @State private var running = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if !loaded {
                    ProgressView().frame(height: 300)
                } else if lab == nil || lab?.supported == false {
                    unsupported
                } else {
                    content
                }
            }
            .padding()
        }
        .navigationTitle("Ray tracing")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded else { return }
            lab = RayTracingLab()
            loaded = true
            await trace()
        }
    }

    private var unsupported: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle)
            Text("Ray tracing unavailable on this device.")
                .multilineTextAlignment(.center)
            Text("MTLDevice.supportsRaytracing is false. The iOS Simulator reports no ray-tracing support — run on a physical iPhone.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.orange)
        .padding()
    }

    private var content: some View {
        VStack(spacing: 16) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Color.black
                }
            }
            .frame(width: 300, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text("One ray per pixel through a BVH. Rasterisation asks which pixels a triangle covers; ray tracing asks what each pixel can see — which is why a ray can hit geometry that isn't on screen.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Camera angle").font(.caption)
                    Spacer()
                    Text(String(format: "%.2f", angle))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: $angle, in: 0...6.28)
                    .onChange(of: angle) { _, _ in Task { await trace() } }
            }
        }
    }

    private func trace() async {
        guard let lab, lab.supported, !running else { return }
        running = true
        image = await lab.render(time: Float(angle))
        running = false
    }
}

#Preview {
    NavigationView { RayTracingLabView() }
}
