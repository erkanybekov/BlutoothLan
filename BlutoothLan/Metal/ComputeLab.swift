//
//  ComputeLab.swift
//  BlutoothLan
//
//  Part 3 host side, upgraded in Part 4.
//
//  A compute pass is simpler than a render pass — no drawable, no render pass
//  descriptor, no vertices:
//
//      command buffer → MTLComputeCommandEncoder → setComputePipelineState
//                     → bind buffers/textures → dispatchThreads → endEncoding
//
//  PART 4 CHANGES:
//
//  1. Working buffers are .storageModePrivate — GPU-only memory the CPU can't
//     touch. Faster, and the honest default for data the CPU never reads.
//     Getting results back needs a THIRD encoder type: MTLBlitCommandEncoder.
//
//  2. No more waitUntilCompleted(). That blocks the calling thread until the
//     GPU finishes. Real apps use addCompletedHandler and never block; here
//     that's wrapped in async/await.
//

import Metal
import MetalKit
import UIKit

struct ComputeResult {
    let image: UIImage?
    let milliseconds: Double
    let escposPreview: [UInt8]
    let dispatchCount: Int
    let note: String?
}

final class ComputeLab {

    // MARK: - Built once

    private let device: MTLDevice
    private let queue: MTLCommandQueue

    private let grayPipeline: MTLComputePipelineState
    private let bayerPipeline: MTLComputePipelineState
    private let atkinsonPipeline: MTLComputePipelineState
    private let packPipeline: MTLComputePipelineState
    private let reducePipeline: MTLComputePipelineState

    private let sourceTexture: MTLTexture
    let width: Int
    let height: Int
    private var pixelCount: Int { width * height }
    private var bytesPerRow: Int { (width + 7) / 8 }

    init?(side: Int = 384) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary()
        else { return nil }

        func pipeline(_ name: String) -> MTLComputePipelineState? {
            guard let fn = library.makeFunction(name: name) else { return nil }
            return try? device.makeComputePipelineState(function: fn)
        }

        guard let gray = pipeline("textureToGray"),
              let bayer = pipeline("bayerCompute"),
              let atkinson = pipeline("atkinsonWavefront"),
              let pack = pipeline("packToESCPOS"),
              let reduce = pipeline("reduceSum")
        else { return nil }

        guard let cgImage = ComputeLab.makeTestImage(side: CGFloat(side)).cgImage,
              let texture = try? MTKTextureLoader(device: device)
                .newTexture(cgImage: cgImage, options: [.SRGB: false])
        else { return nil }

        self.device = device
        self.queue = queue
        self.grayPipeline = gray
        self.bayerPipeline = bayer
        self.atkinsonPipeline = atkinson
        self.packPipeline = pack
        self.reducePipeline = reduce
        self.sourceTexture = texture
        self.width = texture.width
        self.height = texture.height
    }

    // MARK: - Non-blocking submission

    /// The Part 4 fix. `waitUntilCompleted()` parks the calling thread until the
    /// GPU is done; in a render loop that's a dropped frame. `addCompletedHandler`
    /// hands control back immediately and calls you later — here bridged to
    /// async/await so the call site still reads top to bottom.
    private func submit(_ commandBuffer: MTLCommandBuffer) async {
        await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { _ in continuation.resume() }
            commandBuffer.commit()
        }
    }

    private func dispatch2D(_ encoder: MTLComputeCommandEncoder,
                            pipeline: MTLComputePipelineState,
                            width: Int, height: Int) {
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }

    /// GPU-only memory. The CPU literally cannot read or write this pointer —
    /// which is why every readback below needs a blit.
    private func makePrivateBuffer(length: Int) -> MTLBuffer? {
        device.makeBuffer(length: length, options: .storageModePrivate)
    }

    /// Copies device-private memory into CPU-visible memory using a blit
    /// encoder — the third encoder type, alongside render and compute.
    private func blitToShared(_ source: MTLBuffer, length: Int) async -> MTLBuffer? {
        guard let staging = device.makeBuffer(length: length, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder()
        else { return nil }

        blit.copy(from: source, sourceOffset: 0,
                  to: staging, destinationOffset: 0, size: length)
        blit.endEncoding()
        await submit(commandBuffer)
        return staging
    }

    // MARK: - Shared setup

    private func makeGrayBuffer() async -> MTLBuffer? {
        guard let buffer = makePrivateBuffer(length: pixelCount * MemoryLayout<Float>.stride),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        encoder.setComputePipelineState(grayPipeline)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        var w = Int32(width)
        encoder.setBytes(&w, length: MemoryLayout<Int32>.size, index: 1)

        dispatch2D(encoder, pipeline: grayPipeline, width: width, height: height)
        encoder.endEncoding()
        await submit(commandBuffer)

        return buffer
    }

    // MARK: - Step 13 · Bayer on compute

    func runBayer() async -> ComputeResult? {
        guard let gray = await makeGrayBuffer(),
              let bits = makePrivateBuffer(length: pixelCount)
        else { return nil }

        let start = CFAbsoluteTimeGetCurrent()

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        encoder.setComputePipelineState(bayerPipeline)
        encoder.setBuffer(gray, offset: 0, index: 0)
        encoder.setBuffer(bits, offset: 0, index: 1)
        var size = SIMD2<Int32>(Int32(width), Int32(height))
        encoder.setBytes(&size, length: MemoryLayout<SIMD2<Int32>>.size, index: 2)
        dispatch2D(encoder, pipeline: bayerPipeline, width: width, height: height)
        encoder.endEncoding()
        await submit(commandBuffer)

        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        return await finish(bits: bits, milliseconds: ms, dispatchCount: 1, note: nil)
    }

    // MARK: - Step 14 · Atkinson wavefront

    func runAtkinsonGPU(threshold: Float = 0.5) async -> ComputeResult? {
        guard let gray = await makeGrayBuffer(),
              let bits = makePrivateBuffer(length: pixelCount)
        else { return nil }

        let start = CFAbsoluteTimeGetCurrent()

        // A serial encoder guarantees dispatch N finishes before N+1 starts.
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder(dispatchType: .serial)
        else { return nil }

        encoder.setComputePipelineState(atkinsonPipeline)
        encoder.setBuffer(gray, offset: 0, index: 0)
        encoder.setBuffer(bits, offset: 0, index: 1)
        var size = SIMD2<Int32>(Int32(width), Int32(height))
        encoder.setBytes(&size, length: MemoryLayout<SIMD2<Int32>>.size, index: 2)
        var t = threshold
        encoder.setBytes(&t, length: MemoryLayout<Float>.size, index: 4)

        let threadWidth = atkinsonPipeline.threadExecutionWidth
        let maxK = (width - 1) + 4 * (height - 1)
        var dispatches = 0

        for k in 0...maxK {
            let yMin = max(0, Int(ceil(Double(k - width + 1) / 4.0)))
            let yMax = min(height - 1, k / 4)
            if yMin > yMax { continue }

            var kAndYMin = SIMD2<Int32>(Int32(k), Int32(yMin))
            encoder.setBytes(&kAndYMin, length: MemoryLayout<SIMD2<Int32>>.size, index: 3)

            let count = yMax - yMin + 1
            encoder.dispatchThreads(
                MTLSize(width: count, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: min(count, threadWidth), height: 1, depth: 1)
            )
            dispatches += 1
        }

        encoder.endEncoding()
        await submit(commandBuffer)

        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        return await finish(bits: bits, milliseconds: ms, dispatchCount: dispatches, note: nil)
    }

    // MARK: - CPU reference

    func runAtkinsonCPU(threshold: Float = 0.5) async -> ComputeResult? {
        guard let grayPrivate = await makeGrayBuffer(),
              let grayShared = await blitToShared(grayPrivate,
                                                  length: pixelCount * MemoryLayout<Float>.stride)
        else { return nil }

        let start = CFAbsoluteTimeGetCurrent()

        let w = width, h = height
        var gray = [Float](repeating: 0, count: w * h)
        memcpy(&gray, grayShared.contents(), w * h * MemoryLayout<Float>.stride)
        var bits = [UInt8](repeating: 0, count: w * h)

        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let oldV = gray[i]
                let newV: Float = oldV > threshold ? 1 : 0
                bits[i] = newV < 0.5 ? 1 : 0
                let err = (oldV - newV) / 8

                func add(_ j: Int) { gray[j] = min(max(gray[j] + err, 0), 1) }

                if x + 1 < w { add(i + 1) }
                if x + 2 < w { add(i + 2) }
                if y + 1 < h {
                    if x - 1 >= 0 { add(i + w - 1) }
                    add(i + w)
                    if x + 1 < w { add(i + w + 1) }
                }
                if y + 2 < h { add(i + 2 * w) }
            }
        }

        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000

        guard let buffer = device.makeBuffer(bytes: bits, length: w * h,
                                             options: .storageModeShared)
        else { return nil }
        return await finish(bits: buffer, milliseconds: ms, dispatchCount: 0, note: nil)
    }

    // MARK: - Step 19 · Threadgroup reduction

    /// Mean luminance via tree reduction in threadgroup memory, checked against
    /// a plain CPU sum.
    func runReduction() async -> ComputeResult? {
        guard let gray = await makeGrayBuffer() else { return nil }

        let threadsPerGroup = min(256, reducePipeline.maxTotalThreadsPerThreadgroup)
        let groups = (pixelCount + threadsPerGroup - 1) / threadsPerGroup

        guard let partials = makePrivateBuffer(length: groups * MemoryLayout<Float>.stride)
        else { return nil }

        let start = CFAbsoluteTimeGetCurrent()

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        encoder.setComputePipelineState(reducePipeline)
        encoder.setBuffer(gray, offset: 0, index: 0)
        encoder.setBuffer(partials, offset: 0, index: 1)
        var count = Int32(pixelCount)
        encoder.setBytes(&count, length: MemoryLayout<Int32>.size, index: 2)

        // dispatchThreadgroups, not dispatchThreads: the reduction needs whole,
        // uniformly sized groups because it indexes threadgroup memory directly.
        encoder.dispatchThreadgroups(
            MTLSize(width: groups, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadsPerGroup, height: 1, depth: 1)
        )
        encoder.endEncoding()
        await submit(commandBuffer)

        guard let staged = await blitToShared(partials,
                                              length: groups * MemoryLayout<Float>.stride)
        else { return nil }

        let ptr = staged.contents().bindMemory(to: Float.self, capacity: groups)
        var total: Float = 0
        for i in 0..<groups { total += ptr[i] }
        let gpuMean = total / Float(pixelCount)
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000

        // CPU check.
        guard let grayShared = await blitToShared(gray,
                                                  length: pixelCount * MemoryLayout<Float>.stride)
        else { return nil }
        let gptr = grayShared.contents().bindMemory(to: Float.self, capacity: pixelCount)
        var cpuTotal: Float = 0
        for i in 0..<pixelCount { cpuTotal += gptr[i] }
        let cpuMean = cpuTotal / Float(pixelCount)

        let note = String(
            format: """
            GPU mean luma  %.6f
            CPU mean luma  %.6f
            %d groups × %d threads, %d rounds each
            """,
            gpuMean, cpuMean, groups, threadsPerGroup,
            Int(log2(Double(threadsPerGroup)))
        )

        return ComputeResult(image: nil, milliseconds: ms,
                             escposPreview: [], dispatchCount: 1, note: note)
    }

    // MARK: - Output

    private func finish(bits: MTLBuffer,
                        milliseconds: Double,
                        dispatchCount: Int,
                        note: String?) async -> ComputeResult? {
        guard let packed = makePrivateBuffer(length: bytesPerRow * height),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        encoder.setComputePipelineState(packPipeline)
        encoder.setBuffer(bits, offset: 0, index: 0)
        encoder.setBuffer(packed, offset: 0, index: 1)
        var size = SIMD2<Int32>(Int32(width), Int32(height))
        encoder.setBytes(&size, length: MemoryLayout<SIMD2<Int32>>.size, index: 2)
        var bpr = Int32(bytesPerRow)
        encoder.setBytes(&bpr, length: MemoryLayout<Int32>.size, index: 3)

        dispatch2D(encoder, pipeline: packPipeline, width: bytesPerRow, height: height)
        encoder.endEncoding()
        await submit(commandBuffer)

        // Both readbacks go through a blit — the buffers above are GPU-private.
        guard let bitsStaged = await blitToShared(bits, length: pixelCount),
              let packedStaged = await blitToShared(packed, length: bytesPerRow * height)
        else { return nil }

        let bitPtr = bitsStaged.contents().bindMemory(to: UInt8.self, capacity: pixelCount)
        var pixels = [UInt8](repeating: 0, count: pixelCount)
        for i in 0..<pixelCount {
            pixels[i] = bitPtr[i] != 0 ? 0 : 255      // 1 = black
        }

        let image = ComputeLab.makeImage(from: pixels, width: width, height: height)

        let packedPtr = packedStaged.contents().bindMemory(to: UInt8.self,
                                                           capacity: bytesPerRow * height)
        let rowStart = (height / 2) * bytesPerRow
        let previewCount = min(12, bytesPerRow)
        let preview = (0..<previewCount).map { packedPtr[rowStart + $0] }

        return ComputeResult(image: image,
                             milliseconds: milliseconds,
                             escposPreview: preview,
                             dispatchCount: dispatchCount,
                             note: note)
    }

    private static func makeImage(from pixels: [UInt8], width: Int, height: Int) -> UIImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(width: width,
                                    height: height,
                                    bitsPerComponent: 8,
                                    bitsPerPixel: 8,
                                    bytesPerRow: width,
                                    space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                    provider: provider,
                                    decode: nil,
                                    shouldInterpolate: false,
                                    intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Source

    static func makeTestImage(side: CGFloat) -> UIImage {
        // scale = 1 so `side` means PIXELS. The default is the screen scale,
        // which on a 3x device silently gives you a 1152px image when you
        // asked for 384 — and 9x the compute work.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1

        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side),
                                       format: format).image { ctx in
            let cg = ctx.cgContext

            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [UIColor.white.cgColor, UIColor.darkGray.cgColor, UIColor.black.cgColor] as CFArray,
                locations: [0, 0.6, 1]
            ) {
                cg.drawLinearGradient(gradient, start: .zero,
                                      end: CGPoint(x: side, y: side), options: [])
            }

            UIColor.white.setFill()
            cg.fillEllipse(in: CGRect(x: side * 0.55, y: side * 0.10,
                                      width: side * 0.3, height: side * 0.3))
            UIColor.black.setFill()
            cg.fillEllipse(in: CGRect(x: side * 0.10, y: side * 0.60,
                                      width: side * 0.3, height: side * 0.3))

            let text = "384px" as NSString
            text.draw(at: CGPoint(x: side * 0.08, y: side * 0.10), withAttributes: [
                .font: UIFont.systemFont(ofSize: side * 0.11, weight: .black),
                .foregroundColor: UIColor.black
            ])
        }
    }
}
