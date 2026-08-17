//
//  MPSLab.swift
//  BlutoothLan
//
//  Metal Performance Shaders — Apple's pre-tuned GPU kernels.
//
//  The lesson here is knowing when NOT to write a shader. MPS ships hand-tuned,
//  per-GPU-family implementations of the operations you'd otherwise write badly:
//  blurs, convolutions, histograms, resampling, matrix maths.
//
//  Benchmarked against the naive `boxBlurCompute` kernel in Compute.metal so the
//  gap is measured rather than asserted.
//

import Metal
import MetalKit
import MetalPerformanceShaders
import SwiftUI

struct MPSResult {
    let image: UIImage?
    let mpsMilliseconds: Double
    let handMilliseconds: Double
    let note: String
}

final class MPSLab {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let blurPipeline: MTLComputePipelineState
    private let source: MTLTexture

    let supported: Bool

    init?(side: Int = 384) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let fn = library.makeFunction(name: "boxBlurCompute"),
              let pipeline = try? device.makeComputePipelineState(function: fn)
        else { return nil }

        guard let cg = ComputeLab.makeTestImage(side: CGFloat(side)).cgImage,
              let tex = try? MTKTextureLoader(device: device)
                .newTexture(cgImage: cg, options: [
                    .SRGB: false,
                    .textureUsage: NSNumber(value: MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue)
                ])
        else { return nil }

        self.device = device
        self.queue = queue
        self.blurPipeline = pipeline
        self.source = tex
        // MPS is not present on every Metal device. Always ask before using it.
        self.supported = MPSSupportsMTLDevice(device)
    }

    private func makeDestination() -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: source.pixelFormat,
            width: source.width, height: source.height, mipmapped: false
        )
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    private func submit(_ cb: MTLCommandBuffer) async {
        await withCheckedContinuation { c in
            cb.addCompletedHandler { _ in c.resume() }
            cb.commit()
        }
    }

    func run(radius: Int = 4) async -> MPSResult? {
        guard supported,
              let mpsOut = makeDestination(),
              let handOut = makeDestination()
        else { return nil }

        // Constructed OUTSIDE the timed region. MPS compiles and specialises its
        // kernels lazily on first use, so building it inside the measurement
        // times the compiler, not the blur — that mistake made MPS look 40x
        // slower than a naive hand-written loop.
        // sigma chosen so the visual extent roughly matches the box radius.
        let blur = MPSImageGaussianBlur(device: device, sigma: Float(radius) / 2)

        // Warm both paths: first dispatch of anything pays one-time costs.
        await encodeMPS(blur, into: mpsOut)
        await encodeHand(radius: radius, into: handOut)

        // ---- measured ----
        let mpsStart = CFAbsoluteTimeGetCurrent()
        await encodeMPS(blur, into: mpsOut)
        let mpsMs = (CFAbsoluteTimeGetCurrent() - mpsStart) * 1000

        let handStart = CFAbsoluteTimeGetCurrent()
        await encodeHand(radius: radius, into: handOut)
        let handMs = (CFAbsoluteTimeGetCurrent() - handStart) * 1000

        let image = await readBack(mpsOut)
        let taps = (2 * radius + 1) * (2 * radius + 1)

        return MPSResult(
            image: image,
            mpsMilliseconds: mpsMs,
            handMilliseconds: handMs,
            note: """
            radius \(radius) · \(taps) taps/pixel naive
            MPS is separable + tuned per GPU family;
            the hand-written one is the obvious first draft.
            """
        )
    }

    private func encodeMPS(_ blur: MPSImageGaussianBlur, into dst: MTLTexture) async {
        guard let cb = queue.makeCommandBuffer() else { return }
        blur.encode(commandBuffer: cb, sourceTexture: source, destinationTexture: dst)
        await submit(cb)
    }

    private func encodeHand(radius: Int, into dst: MTLTexture) async {
        guard let cb = queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(blurPipeline)
        enc.setTexture(source, index: 0)
        enc.setTexture(dst, index: 1)
        var r = Int32(radius)
        enc.setBytes(&r, length: MemoryLayout<Int32>.size, index: 0)
        let w = blurPipeline.threadExecutionWidth
        let h = max(1, blurPipeline.maxTotalThreadsPerThreadgroup / w)
        enc.dispatchThreads(MTLSize(width: source.width, height: source.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        enc.endEncoding()
        await submit(cb)
    }

    /// Private textures can't be read by the CPU — blit into a shared buffer first.
    private func readBack(_ texture: MTLTexture) async -> UIImage? {
        let bytesPerRow = texture.width * 4
        guard let staging = device.makeBuffer(length: bytesPerRow * texture.height,
                                              options: .storageModeShared),
              let cb = queue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder()
        else { return nil }

        blit.copy(from: texture,
                  sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: staging, destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: bytesPerRow * texture.height)
        blit.endEncoding()
        await submit(cb)

        let data = Data(bytes: staging.contents(), count: bytesPerRow * texture.height)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: texture.width, height: texture.height,
                               bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: bytesPerRow,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue:
                                    CGImageAlphaInfo.premultipliedFirst.rawValue |
                                    CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct MPSLabView: View {
    @State private var lab: MPSLab?
    @State private var loaded = false
    @State private var result: MPSResult?
    @State private var radius: Double = 4
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
        .navigationTitle("MPS")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded else { return }
            lab = MPSLab()
            loaded = true
        }
    }

    private var unsupported: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle)
            Text("Metal Performance Shaders unavailable on this device.")
                .multilineTextAlignment(.center)
            Text("MPSSupportsMTLDevice returned false. See the Capabilities screen.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.orange)
        .padding()
    }

    private var content: some View {
        VStack(spacing: 16) {
            Group {
                if let image = result?.image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Image(uiImage: ComputeLab.makeTestImage(side: 384))
                        .resizable().scaledToFit()
                }
            }
            .frame(width: 300, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Radius").font(.caption)
                    Spacer()
                    Text("\(Int(radius))").font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $radius, in: 1...12, step: 1)
            }

            Button("Run blur comparison") {
                guard let lab else { return }
                running = true
                Task {
                    let r = await lab.run(radius: Int(radius))
                    await MainActor.run { result = r; running = false }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(running)

            if let r = result {
                VStack(spacing: 6) {
                    row("MPSImageGaussianBlur", String(format: "%.2f ms", r.mpsMilliseconds))
                    row("Hand-written box blur", String(format: "%.2f ms", r.handMilliseconds))
                    Text(r.note)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.subheadline)
            }

            Text("Benchmark in Release — a Debug build inverted this conclusion in Part 3.")
                .font(.footnote).foregroundStyle(.orange)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }
}

#Preview {
    NavigationView { MPSLabView() }
}
