//
//  MetalLabsView.swift
//  BlutoothLan
//
//  Single entry point for the three labs.
//
//  Why an index screen instead of three toolbar buttons: multiple
//  NavigationLinks living directly in a legacy NavigationView's toolbar can
//  activate the wrong destination — the same ambiguity that made two hidden
//  isActive links push a blank screen. A List handles many links correctly.
//

import SwiftUI

struct MetalLabsView: View {
    var body: some View {
        List {
            Section("What this GPU supports") {
                NavigationLink {
                    CapabilitiesView()
                } label: {
                    Label("Capabilities", systemImage: "info.circle")
                }
            }

            Section("Part 1 — shader language") {
                NavigationLink {
                    ShaderLabView()
                } label: {
                    Label("Shader Lab", systemImage: "wand.and.stars")
                }
            }

            Section("Part 2 + 4 — render pipeline") {
                NavigationLink {
                    MetalLabView()
                } label: {
                    Label("Metal Lab", systemImage: "cube.transparent")
                }
            }

            Section("Part 3 + 4 — compute") {
                NavigationLink {
                    ComputeLabView()
                } label: {
                    Label("Compute Lab", systemImage: "square.grid.3x3.fill")
                }
            }

            Section("Part 5 — the rest") {
                NavigationLink {
                    MPSLabView()
                } label: {
                    Label("Metal Performance Shaders", systemImage: "speedometer")
                }

                NavigationLink {
                    RayTracingLabView()
                } label: {
                    Label("Ray tracing", systemImage: "light.beacon.max")
                }

                NavigationLink {
                    Metal4LabView()
                } label: {
                    Label("Metal 4", systemImage: "4.square")
                }
            }
        }
        .navigationTitle("Metal")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationView { MetalLabsView() }
}
