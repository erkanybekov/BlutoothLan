//
//  ComputeLabView.swift
//  BlutoothLan
//
//  Part 3 + 4 UI. Run each method, compare the output and the clock.
//

import SwiftUI

struct ComputeLabView: View {
    // NOT `= ComputeLab()`. SwiftUI evaluates a @State default expression on
    // EVERY View init, not just the first — so that form rebuilt five compute
    // pipelines and reloaded a texture each time, then threw them away. Exactly
    // the "build once, not per frame" rule these labs are about.
    @State private var lab: ComputeLab?
    @State private var labLoaded = false
    @State private var result: ComputeResult?
    @State private var label: String = ""
    @State private var running = false
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if !labLoaded {
                    ProgressView().frame(height: 300)
                } else if lab == nil {
                    Text("No Metal device available.")
                        .foregroundStyle(.red)
                } else {
                    imagePanel
                    buttons
                    if let result {
                        stats(result)
                    } else if failed {
                        Text("\(label) returned nil — a pipeline, buffer or encoder failed to create.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    notes
                }
            }
            .padding()
        }
        .navigationTitle("Compute Lab")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Runs once per appearance instead of once per View struct init.
            guard !labLoaded else { return }
            lab = ComputeLab()
            labLoaded = true
        }
    }

    private var imagePanel: some View {
        Group {
            if let image = result?.image {
                Image(uiImage: image)
                    .interpolation(.none)          // show the real 1-bit pixels
                    .resizable()
                    .scaledToFit()
            } else {
                Image(uiImage: ComputeLab.makeTestImage(side: 384))
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: 300, height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var buttons: some View {
        VStack(spacing: 8) {
            Button("13 · Bayer (compute)") {
                run("Bayer · compute") { await $0.runBayer() }
            }
            Button("14 · Atkinson — GPU wavefront") {
                run("Atkinson · GPU wavefront") { await $0.runAtkinsonGPU() }
            }
            Button("14 · Atkinson — CPU scan order") {
                run("Atkinson · CPU") { await $0.runAtkinsonCPU() }
            }
            Button("19 · Threadgroup reduction") {
                run("Parallel reduction") { await $0.runReduction() }
            }
        }
        .buttonStyle(.bordered)
        .disabled(running)
    }

    private func stats(_ r: ComputeResult) -> some View {
        VStack(spacing: 6) {
            Text(label).font(.headline)

            HStack {
                Text("Time").foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f ms", r.milliseconds)).monospacedDigit()
            }
            if r.dispatchCount > 0 {
                HStack {
                    Text("Dispatches").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(r.dispatchCount)").monospacedDigit()
                }
            }
            if !r.escposPreview.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ESC/POS bytes").foregroundStyle(.secondary)
                    Text(r.escposPreview.map { String(format: "%02X", $0) }.joined(separator: " "))
                        .font(.caption.monospaced())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let note = r.note {
                Text(note)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.subheadline)
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Both Atkinson runs produce bit-identical ESC/POS bytes — run each and compare the hex row. That's the real result: wavefront scheduling is correct, not an approximation.")

            Text("Measured at 384×384, Release, simulator: CPU 1.7 ms · GPU 18.9 ms over 1,916 dispatches. The GPU loses by ~11×. Each wavefront is a sync point, and at this size synchronisation costs far more than the arithmetic saves.")

            Text("In a DEBUG build the same code measured CPU 71.7 ms and the GPU appeared to win by 4×. Unoptimised Swift bounds-checks every array access. Benchmark in Release or you'll draw the opposite conclusion.")
                .foregroundStyle(.orange)

            Text("Part 4: every working buffer here is .storageModePrivate, read back through a blit encoder, and submitted with addCompletedHandler instead of waitUntilCompleted — so no call blocks a thread on the GPU.")
        }
        .font(.footnote)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func run(_ name: String,
                     _ work: @escaping (ComputeLab) async -> ComputeResult?) {
        guard let lab else { return }
        running = true
        label = name
        Task {
            let r = await work(lab)
            await MainActor.run {
                result = r
                failed = (r == nil)
                running = false
            }
        }
    }
}

#Preview {
    NavigationView { ComputeLabView() }
}
