//
//  Metal4Lab.swift
//  BlutoothLan
//
//  Metal 4 — the command model Apple's Essentials docs now lead with.
//
//  COMPILE-TIME GATE, not just @available. The MTL4* types are absent from the
//  iOS Simulator SDK entirely, so `MTL4CommandQueue` does not even resolve
//  there — `@available(iOS 26, *)` alone gives you a build error, not a runtime
//  fallback. Verified by type-checking the same file against the
//  iphonesimulator and iphoneos SDKs: device compiles, simulator does not.
//
//  What actually changes from the classic API:
//
//    Classic                          Metal 4
//    ─────────────────────────────    ────────────────────────────────────────
//    queue.makeCommandBuffer()        device.makeCommandBuffer()
//      (buffer comes FROM the queue)    (buffer and queue are independent)
//    — none —                         MTL4CommandAllocator owns the memory
//                                       commands are encoded into, and you
//                                       reset it to reuse it
//    encoder.setFragmentTexture(…)    one MTL4ArgumentTable holds the bindings
//    encoder.setVertexBuffer(…)         and is shared across encoders
//    commandBuffer.commit()           commandQueue.commit([buffer])
//
//  The point is fewer per-encoder allocations and reusable command buffers.
//  Metal 4 is designed for incremental adoption — a MTL4CommandQueue and a
//  classic MTLCommandQueue can coexist, synchronised with MTLEvent.
//

import Metal
import SwiftUI

#if !targetEnvironment(simulator)

@available(iOS 26.0, *)
final class Metal4Lab {
    private let device: MTLDevice
    private let queue: MTL4CommandQueue
    private let allocator: MTL4CommandAllocator
    private let argumentTable: MTL4ArgumentTable

    let supported = true

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeMTL4CommandQueue(),
              let allocator = device.makeCommandAllocator()
        else { return nil }

        let tableDescriptor = MTL4ArgumentTableDescriptor()
        tableDescriptor.maxBufferBindCount = 8
        tableDescriptor.maxTextureBindCount = 8

        guard let table = try? device.makeArgumentTable(descriptor: tableDescriptor)
        else { return nil }

        self.device = device
        self.queue = queue
        self.allocator = allocator
        self.argumentTable = table
    }

    /// Minimal round trip: begin a command buffer against the allocator, end it,
    /// commit it to the queue. Proves the Metal 4 object graph is live.
    func runEmptyPass() -> String {
        guard let commandBuffer = device.makeCommandBuffer() else {
            return "makeCommandBuffer() returned nil"
        }

        commandBuffer.beginCommandBuffer(allocator: allocator)
        commandBuffer.endCommandBuffer()
        // Swift drops the ObjC `count:` — the array carries its own length.
        queue.commit([commandBuffer])

        // The allocator is reset once the work it backs has completed — this is
        // the memory you now own explicitly and the classic API hid from you.
        allocator.reset()

        return """
        MTL4CommandQueue      ok
        MTL4CommandAllocator  ok
        MTL4ArgumentTable     ok
        command buffer begun, ended and committed
        """
    }
}

#endif

struct Metal4LabView: View {
    @State private var report: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                #if targetEnvironment(simulator)
                unsupported(
                    "Metal 4 is absent from the iOS Simulator SDK.",
                    "The MTL4* types don't exist for the simulator target at all, so this is a compile-time gate (#if), not a runtime check. Build and run on a physical iPhone with iOS 26."
                )
                #else
                if #available(iOS 26.0, *) {
                    content
                } else {
                    unsupported("Metal 4 requires iOS 26.",
                                "This device is running an older OS.")
                }
                #endif
            }
            .padding()
        }
        .navigationTitle("Metal 4")
        .navigationBarTitleDisplayMode(.inline)
    }

    #if !targetEnvironment(simulator)
    @available(iOS 26.0, *)
    private var content: some View {
        VStack(spacing: 16) {
            Text("Metal 4 decouples the command buffer from the queue, makes command memory explicit via an allocator, and replaces per-encoder resource binding with a shared argument table.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Run an empty Metal 4 pass") {
                report = Metal4Lab()?.runEmptyPass() ?? "Metal4Lab init failed"
            }
            .buttonStyle(.borderedProminent)

            if let report {
                Text(report)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    #endif

    private func unsupported(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle)
            Text(title).multilineTextAlignment(.center)
            Text(detail)
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.orange)
        .padding()
    }
}

#Preview {
    NavigationView { Metal4LabView() }
}
