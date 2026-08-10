//
//  ComputeLab.swift
//  BlutoothLan
//
//  Part 3 host side. A compute pass is simpler than a render pass — there's no
//  drawable, no render pass descriptor, no vertices:
//
//      command buffer → MTLComputeCommandEncoder → setComputePipelineState
//                     → bind buffers/textures → dispatchThreads → endEncoding
//
//  Everything here runs on demand, not per frame, because step 14 is slow
//  enough that you'd notice.
//

import Metal
import MetalKit
import UIKit

struct ComputeResult {
    let image: UIImage
    let milliseconds: Double
    let escposPreview: [UInt8]      // first bytes of the printer payload
    let dispatchCount: Int
}

final class ComputeLab {

    // Built once.
    private let device: MTLDevice
    private let queue: MTLCommandQueue

    private let grayPipeline: MTLComputePipelineState
    private let bayerPipeline: MTLComputePipelineState
    private let atkinsonPipeline: MTLComputePipelineState
    private let packPipeline: MTLComputePipelineState

    private let sourceTexture: MTLTexture
    let width: Int
    let height: Int
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
              let pack = pipeline("packToESCPOS")
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
        self.sourceTexture = texture
        self.width = texture.width
        self.height = texture.height
    }

    // MARK: - Shared setup

    /// Runs textureToGray and returns a shared buffer of 0…1 luma.
    private func makeGrayBuffer() -> MTLBuffer? {
        let count = width * height
        guard let buffer = device.makeBuffer(length: count * MemoryLayout<Float>.stride,
                                             options: .storageModeShared),
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
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return buffer
    }

    /// Threadgroup sizing straight from the pipeline's own limits — never
    /// hardcode 16x16 and hope.
    private func dispatch2D(_ encoder: MTLComputeCommandEncoder,
                            pipeline: MTLComputePipelineState,
                            width: Int, height: Int) {
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }

    // MARK: - Step 13 · Bayer on compute

    func runBayer() -> ComputeResult? {
        guard let grayBuffer = makeGrayBuffer(),
              let bits = device.makeBuffer(length: width * height, options: .storageModeShared)
        else { return nil }

        let start = CFAbsoluteTimeGetCurrent()

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        encoder.setComputePipelineState(bayerPipeline)
        encoder.setBuffer(grayBuffer, offset: 0, index: 0)
        encoder.setBuffer(bits, offset: 0, index: 1)
        var size = SIMD2<Int32>(Int32(width), Int32(height))
        encoder.setBytes(&size, length: MemoryLayout<SIMD2<Int32>>.size, index: 2)
        dispatch2D(encoder, pipeline: bayerPipeline, width: width, height: height)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000

        return finish(bits: bits, milliseconds: ms, dispatchCount: 1)
    }

    // MARK: - Step 14 · Atkinson wavefront

    func runAtkinsonGPU(threshold: Float = 0.5) -> ComputeResult? {
        guard let grayBuffer = makeGrayBuffer(),
              let bits = device.makeBuffer(length: width * height, options: .storageModeShared)
        else { return nil }

        let start = CFAbsoluteTimeGetCurrent()

        // A serial encoder guarantees dispatch N finishes before N+1 starts.
        // Without this, wavefronts would overlap and the dependency chain breaks.
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder(dispatchType: .serial)
        else { return nil }

        encoder.setComputePipelineState(atkinsonPipeline)
        encoder.setBuffer(grayBuffer, offset: 0, index: 0)
        encoder.setBuffer(bits, offset: 0, index: 1)
        var size = SIMD2<Int32>(Int32(width), Int32(height))
        encoder.setBytes(&size, length: MemoryLayout<SIMD2<Int32>>.size, index: 2)
        var t = threshold
        encoder.setBytes(&t, length: MemoryLayout<Float>.size, index: 4)

        let threadWidth = atkinsonPipeline.threadExecutionWidth
        let maxK = (width - 1) + 4 * (height - 1)
        var dispatches = 0

        // k = x + 4y. Walk k upward; every pixel on a given k is independent.
        for k in 0...maxK {
            // x = k - 4y must land inside [0, width) and y inside [0, height).
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
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000

        return finish(bits: bits, milliseconds: ms, dispatchCount: dispatches)
    }

    // MARK: - CPU reference

    /// Same algorithm, plain scan order — this is what ImageProcessor does.
    func runAtkinsonCPU(threshold: Float = 0.5) -> ComputeResult? {
        guard let grayBuffer = makeGrayBuffer() else { return nil }

        let start = CFAbsoluteTimeGetCurrent()

        let w = width, h = height
        var gray = [Float](repeating: 0, count: w * h)
        memcpy(&gray, grayBuffer.contents(), w * h * MemoryLayout<Float>.stride)
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

        guard let buffer = device.makeBuffer(bytes: bits, length: w * h, options: .storageModeShared)
        else { return nil }
        return finish(bits: buffer, milliseconds: ms, dispatchCount: 0)
    }

    // MARK: - Output

    /// Packs to ESC/POS on the GPU, then builds a preview image on the CPU.
    private func finish(bits: MTLBuffer, milliseconds: Double, dispatchCount: Int) -> ComputeResult? {
        guard let packed = device.makeBuffer(length: bytesPerRow * height,
                                             options: .storageModeShared),
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
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let bitPtr = bits.contents().bindMemory(to: UInt8.self, capacity: width * height)
        var pixels = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            pixels[i] = bitPtr[i] != 0 ? 0 : 255      // 1 = black
        }

        guard let image = ComputeLab.makeImage(from: pixels, width: width, height: height)
        else { return nil }

        let packedPtr = packed.contents().bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
        // Row 0 is the white corner of the test image — all-zero bits and a dull
        // preview. Sample the middle row, where there's actually content.
        let rowStart = (height / 2) * bytesPerRow
        let previewCount = min(12, bytesPerRow)
        let preview = (0..<previewCount).map { packedPtr[rowStart + $0] }

        return ComputeResult(image: image,
                             milliseconds: milliseconds,
                             escposPreview: preview,
                             dispatchCount: dispatchCount)
    }

    private static func makeImage(from pixels: [UInt8], width: Int, height: Int) -> UIImage? {
        var data = pixels
        guard let provider = CGDataProvider(data: Data(data) as CFData),
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
        _ = data.count
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
