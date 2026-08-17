//
//  Capabilities.swift
//  BlutoothLan
//
//  What this GPU can actually do.
//
//  Metal's API surface is much larger than any one device supports, and the
//  failure mode for an unsupported feature is usually a nil pipeline or a
//  silently empty screen rather than an error. Ask first.
//
//  Run this on the simulator and on a real iPhone — the differences are the
//  point.
//

import Metal
import MetalPerformanceShaders
import SwiftUI

struct Capability: Identifiable {
    let id = UUID()
    let name: String
    let value: String
    let supported: Bool?      // nil = informational, not a yes/no
}

enum GPUCapabilities {

    static func probe() -> [Capability] {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return [Capability(name: "Metal device", value: "none", supported: false)]
        }

        var rows: [Capability] = [
            Capability(name: "Device", value: device.name, supported: nil),
            Capability(name: "Unified memory", value: yn(device.hasUnifiedMemory), supported: device.hasUnifiedMemory)
        ]

        // GPU families are cumulative: apple9 implies apple8 implies apple7…
        // Report the highest one this device claims.
        let families: [(String, MTLGPUFamily)] = [
            ("apple9", .apple9), ("apple8", .apple8), ("apple7", .apple7),
            ("apple6", .apple6), ("apple5", .apple5), ("apple4", .apple4)
        ]
        let highest = families.first { device.supportsFamily($0.1) }?.0 ?? "unknown"
        rows.append(Capability(name: "Highest GPU family", value: highest, supported: nil))

        // Ray tracing. supportsRaytracing means the API works; it does NOT mean
        // there is dedicated RT hardware — that arrived with A17 Pro / M3.
        rows.append(Capability(name: "Ray tracing (API)",
                               value: yn(device.supportsRaytracing),
                               supported: device.supportsRaytracing))
        rows.append(Capability(name: "RT hardware (apple9)",
                               value: yn(device.supportsFamily(.apple9)),
                               supported: device.supportsFamily(.apple9)))

        // Argument buffers: tier 2 is what allows plain structs of resource IDs.
        let tier: String
        switch device.argumentBuffersSupport {
        case .tier1: tier = "tier 1"
        case .tier2: tier = "tier 2"
        @unknown default: tier = "unknown"
        }
        rows.append(Capability(name: "Argument buffers", value: tier,
                               supported: device.argumentBuffersSupport == .tier2))

        // MPS historically was not built for the simulator at all.
        let mps = MPSSupportsMTLDevice(device)
        rows.append(Capability(name: "Metal Performance Shaders", value: yn(mps), supported: mps))

        // Metal 4 needs a COMPILE-TIME gate, not just @available: the MTL4* types
        // are absent from the iOS Simulator SDK entirely, so `MTL4CommandQueue`
        // won't even resolve there. Verified by type-checking the same probe
        // against the iphonesimulator and iphoneos SDKs.
        #if targetEnvironment(simulator)
        rows.append(Capability(name: "Metal 4", value: "absent from sim SDK", supported: false))
        #else
        if #available(iOS 26.0, *) {
            let hasMetal4 = device.makeMTL4CommandQueue() != nil
            rows.append(Capability(name: "Metal 4", value: yn(hasMetal4), supported: hasMetal4))
        } else {
            rows.append(Capability(name: "Metal 4", value: "needs iOS 26", supported: false))
        }
        #endif

        rows.append(Capability(name: "32-bit float filtering",
                               value: yn(device.supports32BitFloatFiltering),
                               supported: device.supports32BitFloatFiltering))
        rows.append(Capability(name: "Max threadgroup threads",
                               value: "\(device.maxThreadsPerThreadgroup.width)",
                               supported: nil))
        rows.append(Capability(name: "Max buffer length",
                               value: "\(device.maxBufferLength / (1024 * 1024)) MB",
                               supported: nil))

        #if targetEnvironment(simulator)
        rows.append(Capability(name: "Running on", value: "Simulator", supported: nil))
        #else
        rows.append(Capability(name: "Running on", value: "Real device", supported: nil))
        #endif

        return rows
    }

    private static func yn(_ b: Bool) -> String { b ? "yes" : "no" }
}

struct CapabilitiesView: View {
    private let rows = GPUCapabilities.probe()

    var body: some View {
        List(rows) { row in
            HStack {
                Text(row.name)
                Spacer()
                Text(row.value)
                    .font(.callout.monospaced())
                    .foregroundStyle(color(for: row.supported))
            }
        }
        .navigationTitle("Capabilities")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func color(for supported: Bool?) -> Color {
        switch supported {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return .secondary
        }
    }
}

#Preview {
    NavigationView { CapabilitiesView() }
}
