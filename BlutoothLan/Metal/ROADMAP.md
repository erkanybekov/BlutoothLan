# Metal Roadmap

Open the app → toolbar wand icon → **Shader Lab**. Pick a step from the menu, read the matching
function in `Effects.metal`, then change something and re-run. Learning happens in the tweaking.

---

## Part 1 — The shader language ✅ built

All eight run today. No `MTLDevice`, no command queue, no pipeline state — SwiftUI's
`colorEffect` / `distortionEffect` / `layerEffect` handle all of it.

| Step | Teaches | Try changing |
|---|---|---|
| 1 · Replace | A shader replaces colour; it doesn't tint. Pre-multiplied alpha. | Return `currentColor` instead. Then drop the `* currentColor.a` and apply it to a `.opacity(0.5)` view — watch it go wrong. |
| 2 · position | `position` is in **points**, `(0,0)` top-left → `(300,300)`. Size must be passed in. | Use `position.y` instead of `.x`. Then `(position.x + position.y) / (width * 2)`. |
| 3 · Branch | Hard edges via `if`. | Make 4 vertical stripes: `int(position.x / width * 4) % 2`. |
| 4 · Read source | Rec.601 luma. Green dominates. | Use `(r+g+b)/3` instead and compare — the greens go muddy. |
| 5 · Uniforms | Sliders → GPU each frame. Un-premultiply → maths → re-premultiply. | Push gamma to 0.2 and 3.0. Delete the `/ a` and `* a` and see what breaks at the edges. |
| 6 · Bayer dither | **The core constraint.** Per-pixel threshold from an x,y lookup — no pixel needs any other. | Swap in an 8×8 matrix. Or use `luma > 0.5` with no matrix and see why dithering exists at all. |
| 7 · Distortion | Returns a **position**, not a colour. Inverse mapping. | Flip the sign of `offset`. Change `0.08` to `0.3`. |
| 8 · layer | `layer.sample()` reads neighbours. Blur, sharpen, edges. | Make an edge detector: `abs(left - right) + abs(up - down)`. |

### The idea the whole part is built around

Steps 6 and 8 together are the point.

Your `ImageProcessor.applyAtkinsonDithering` pushes each pixel's quantisation error into six
**neighbours**, so pixel N+1 can't be computed until N is done. Bayer works on the GPU because
every pixel decides alone. `layerEffect` gets you neighbour *reads* — enough for sharpen — but
still no ordering and no writes into other pixels, so Atkinson is still impossible.

That constraint is the whole of GPU programming. Everything in Parts 2 and 3 is machinery for
working within it or around it.

---

## Part 2 — The real render pipeline ✅ built

Toolbar cube icon → **Metal Lab**. Code in `Renderer.swift` (host side) and `Shaders.metal`
(GPU side). This is what Part 1 was hiding from you.

Doc: [Using a Render Pipeline to Render Primitives](https://developer.apple.com/documentation/metal/using-a-render-pipeline-to-render-primitives)

| Step | Teaches | Try changing |
|---|---|---|
| 9 · Clear colour | The object graph runs end to end with nothing drawn. `MTLDevice` → `MTLCommandQueue` → `MTLCommandBuffer` → `MTLRenderCommandEncoder` → `commit`. | Change `view.clearColor`. Then comment out `commandBuffer.commit()` and watch it freeze. |
| 10 · Triangle | `[[vertex_id]]` with no buffer at all. NDC: −1…1, origin centre, **+Y up** (opposite of UIKit). | Move a vertex past 1.0 and watch it clip. Add a 4th and change `vertexCount` to 6 for a quad. |
| 11 · Vertex buffer | **Interpolation.** You write 3 colours; the rasterizer generates every pixel between them in fixed-function hardware. | Set all three vertex colours identical — the gradient vanishes, proving where it came from. |
| 12 · Texture + quad | `MTKTextureLoader`, samplers, UV space (0…1, origin **top-left** — different from NDC again). Uniform via `setFragmentBytes`. | Set uv to `[0,1]`/`[0,0]` on the left two vertices to flip it. Swap `filter::linear` for `filter::nearest` and zoom in. |

### The split that matters

`Renderer.swift` builds device, queue, pipeline states, buffers and texture **once** in `init`.
It builds command buffers and encoders **every frame** in `draw`. Creating a pipeline state
inside `draw` is the classic Metal performance bug — it recompiles shaders 60× a second.

### What this unlocks that Part 1 couldn't

You own the pipeline now, so you can render *into a texture* instead of the screen and run
another pass over the result. That's multi-pass — adjustments in pass 1, dithering in pass 2,
with the intermediate never leaving the GPU. `colorEffect` has no way to express that.

## Part 3 — Compute ✅ built

Toolbar grid icon → **Compute Lab**. Code in `Compute.metal` and `ComputeLab.swift`.

Docs: [Performing calculations on a GPU](https://developer.apple.com/documentation/metal/performing-calculations-on-a-gpu) ·
[Processing a texture in a compute function](https://developer.apple.com/documentation/metal/hello_compute)

| Step | Teaches | Try changing |
|---|---|---|
| 13 · Bayer (compute) | `MTLComputeCommandEncoder`, `[[thread_position_in_grid]]`, threadgroup sizing from `threadExecutionWidth`. Same maths as the colorEffect version — per-pixel work ports over unchanged. | Hardcode `threadsPerThreadgroup` to 32×32 and watch pipeline creation fail on the limit. |
| 13 · ESC/POS packing | One thread produces one output **byte** from 8 input pixels — the grid is shaped like the *output*. Impossible in render, where the grid is always one-invocation-per-pixel-drawn. | Flip `1 << bit` to `1 << (7 - bit)` for MSB-first printers. |
| 14 · Atkinson wavefront | Error diffusion **on the GPU**, via `k = x + 4y` scheduling and a `.serial` encoder. | Change `4` to `2` in both the kernel and the host loop. Output still looks plausible but goes non-deterministic — that's the race. |

### Why k = x + 4y

Pixel (x,y) pushes error into six neighbours, so it must run after everything feeding it. Pick a
schedule `k = x + b·y` where every pixel depends only on smaller k. The six sources of a target sit
at k offsets `-1, -2, (1-b), -b, (-1-b), -2b`:

- `b=1` → `-1,-2,0,-1,-2,-2` — a `0` means a dependency inside the same wavefront ✗
- `b=2` → `-1,-2,-1,-2,-3,-4` — duplicates: two pixels in one wavefront write the same cell ✗
- `b=3` → `-1,-2,-2,-3,-4,-6` — still duplicated ✗
- `b=4` → `-1,-2,-3,-4,-5,-8` — all distinct ✓ no atomics needed

### Measured (384×384, simulator)

| | Release | Debug |
|---|---|---|
| CPU, scan order | **1.7 ms** | 71.7 ms |
| GPU, 1,916 wavefronts | **18.9 ms** | 16.5 ms |

Two conclusions, and the second one bit me while building this:

1. **The GPU loses by ~11×.** Each wavefront is a sync point; at 384px the synchronisation costs
   far more than the parallel arithmetic saves. Wavefront Atkinson is a correctness demo, not an
   optimisation — the CPU version in `ImageProcessor` is the right choice for this app.
2. **Benchmark in Release.** In Debug the CPU looked 42× slower than it is, and the GPU appeared to
   *win* by 4×. Unoptimised Swift bounds-checks every array access. Same code, opposite conclusion.

Output is **bit-identical** between CPU and GPU — compare the ESC/POS hex rows. The schedule is
exact, not an approximation.

---

## Part 4 — the things Parts 2 and 3 cut corners on ✅ built

Folded into the existing labs rather than a new one, so the code you already had became correct.
All three labs now live behind the toolbar wand icon → **Metal**.

| Step | Where | Teaches | Try changing |
|---|---|---|---|
| 15 · 3D cube | Metal Lab | `MTLVertexDescriptor` + `[[stage_in]]` instead of a raw `constant Vertex*`; an index buffer (8 corners → 36 triangle vertices); a depth buffer + `MTLDepthStencilState`; MVP matrices. | Flip **Depth testing** off — the cube falls apart, back faces drawn over front. |
| 16 · Multi-pass | Metal Lab | Pass 1 renders into an **offscreen texture** you allocate (`usage: [.renderTarget, .shaderRead]`); pass 2 reads it and draws to the drawable. Two encoders, one command buffer. | Set pass 1's `storeAction` to `.dontCare` and watch pass 2 read garbage. |
| — · Private storage | Compute Lab | Every working buffer is `.storageModePrivate` — GPU-only. Reading results back needs `MTLBlitCommandEncoder`, the third encoder type. | Call `.contents()` on a private buffer: garbage, not an error. |
| — · Non-blocking submit | Compute Lab | `addCompletedHandler` + async/await replaces `waitUntilCompleted()`, which parks the calling thread until the GPU finishes. In a render loop that's a dropped frame. | — |
| 19 · Threadgroup reduction | Compute Lab | `threadgroup` shared memory + `threadgroup_barrier`. Tree reduction: 256 → 128 → … → 1 in 8 rounds instead of 256 sequential adds. | Delete the barrier inside the loop. The answer changes between runs. |

### Two bugs worth keeping

**`setDepthStencilState(nil)` aborts the Metal simulator** — `Invalid depth stencil state`. "Depth
off" has to be a real object: `depthCompareFunction = .always`, `isDepthWriteEnabled = false`. The
nil version looks equivalent and isn't.

**Multiple `NavigationLink`s in a legacy `NavigationView` toolbar activate the wrong destination.**
Same family as two hidden `isActive` links pushing a blank screen. Fixed by collapsing to a single
link into `MetalLabsView`, where a `List` handles them correctly.

### Reduction result

```
GPU mean luma  0.449828
CPU mean luma  0.449636
576 groups × 256 threads, 8 rounds each
```

They differ in the 4th decimal because of summation order — and the **GPU is the more accurate
one**. Pairwise tree summation accumulates less float error than a sequential loop over 147,456
values.

### Still not covered

Blending, face culling, MSAA, argument buffers, indirect command buffers, ray tracing, Metal
Performance Shaders, the Metal debugger / frame capture — and **Metal 4**, which is what Apple's
Essentials docs now lead with and whose command model differs from everything here.

---

## Part 5 — bug fixes + the rest ✅ built

Start at **Capabilities** (top of the Metal list). Most of Part 5 is device-dependent, and that
screen is the ground truth for what your hardware actually does.

### Bugs fixed

| Was | Why it mattered |
|---|---|
| `@State private var lab = ComputeLab()` | SwiftUI evaluates a `@State` default on **every** View init — this rebuilt 5 pipelines and reloaded a texture each time, then discarded them. Exactly the mistake these labs teach against. Now lazy in `.task`. |
| `angle += 0.01` | Frame-rate dependent; twice as fast on 120 Hz. Now driven by a `CACurrentMediaTime()` delta. |
| MTKView pinned to 60 fps | Static stages redrew constantly. Now `isPaused` + `enableSetNeedsDisplay` for everything but the cube. |
| `TimelineView(.animation)` on all effects | Only the ripple needs a clock. |

### New

| Step | Where | Teaches |
|---|---|---|
| Capabilities | own screen | `supportsRaytracing`, GPU family, argument-buffer tier, `MPSSupportsMTLDevice`, Metal 4. Ask before you use. |
| 20 · Blending | Metal Lab | Blending is **pipeline state**, so each mode is its own PSO. Alpha vs additive vs off. |
| 21 · Culling | Metal Lab (cube) | `setCullMode` is an **encoder** setting, unlike blending. A different mechanism from depth — culling discards by winding before rasterisation; depth resolves what's in front. |
| 22 · MSAA | Metal Lab | Sample count is baked into the view *and* every pipeline used with it, so they must agree — hence a pipeline per count. |
| 23 · Argument buffer | Metal Lab | Texture + sampler + uniform in one struct, bound once. `useResource()` is mandatory: Metal can't see through the buffer to know the texture is live. |
| 25 · MPS | own lab | `MPSImageGaussianBlur` vs a naive hand-written kernel. |
| 26 · Ray tracing | own lab | `MTLPrimitiveAccelerationStructure`, `MTLAccelerationStructureCommandEncoder`, `ray_query` in a compute kernel. |
| 27 · Metal 4 | own lab | `MTL4CommandQueue`, `MTL4CommandAllocator`, `MTL4ArgumentTable`. |

### What this M1 simulator actually reports

```
Ray tracing (API)     no          Argument buffers   tier 1
RT hardware (apple9)  no          MPS                yes
Highest GPU family    unknown     Metal 4            absent from sim SDK
```

**Metal 4 needs a compile-time `#if`, not `@available`.** The `MTL4*` types don't exist in the iOS
Simulator SDK at all, so the code won't compile there — verified by type-checking the same file
against `iphonesimulator` (fails) and `iphoneos` (succeeds).

### Verification status — honest

| Feature | Simulator | Notes |
|---|---|---|
| All four bug fixes | ✅ verified | |
| Capabilities | ✅ verified | |
| 20 · Blending | ✅ verified | alpha blending visible |
| 21 · Culling | ✅ builds | toggle present; pairs with depth |
| 22 · MSAA | ✅ verified | thin sliver, clean edges |
| 23 · Argument buffer | ❌ **device-only** | tier 1 here → command buffer aborts (error 3) |
| 25 · MPS | ✅ verified | 1.59 ms vs 1.46 ms hand-written |
| 26 · Ray tracing | ❌ **device-only** | `supportsRaytracing == false` |
| 27 · Metal 4 | ❌ **device-only** | absent from simulator SDK |

Device-only items **compile clean for `generic/platform=iOS`** but have not been run. Treat them as
unverified until you launch on your iPhone.

### The MPS benchmark trap

First measurement said MPS 64.68 ms vs hand-written 1.63 ms — MPS 40× *slower*. That was a
measurement bug: `MPSImageGaussianBlur(device:sigma:)` was being constructed inside the timed
region, and MPS compiles its kernels lazily on first use. Moving construction out and adding a
warm-up pass gives **1.59 ms vs 1.46 ms**.

Two lessons, both general: exclude one-time setup from benchmarks, and warm up before measuring.
At 384px on a simulator both are dominated by command-buffer overhead, so MPS's algorithmic
advantage doesn't show — re-run on device with a larger image.

### Still not covered

Indirect command buffers, frame capture (`MTLCaptureManager` needs `MetalCaptureEnabled` in
Info.plist, which is outside `Metal/` — raise it if you want it), tile shaders, mesh shaders,
sparse textures, and the machine-learning encoders new in Metal 4.

---

## Reference

- [Metal Shading Language Spec](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf) — lookup, not reading
- [ShaderLibrary](https://developer.apple.com/documentation/swiftui/shaderlibrary) · [colorEffect](https://developer.apple.com/documentation/swiftui/view/coloreffect(_:isenabled:)) · [distortionEffect](https://developer.apple.com/documentation/swiftui/view/distortioneffect(_:maxsampleoffset:isenabled:))
- WWDC: [Create custom visual effects with SwiftUI](https://developer.apple.com/videos/play/wwdc2024/10151/)

## Gotchas that will cost you an hour

- MSL errors appear at **build** time. A wrong `ShaderLibrary` **argument list** fails at
  **runtime**, silently — the view just renders unmodified. If nothing happens, count your arguments.
- `float` and `half` don't mix implicitly. `half(x)` to convert, `0.0h` for half literals.
- Colour is **pre-multiplied**: rgb is already multiplied by alpha and can never exceed it.
- Everything here needs **iOS 17+**. The app target was bumped from 16.6 to 17.0 for this.

## Not touched by any of this

`processForPrinting`, `convertToESCPOS`, and the CPU Atkinson / Floyd–Steinberg code are
unchanged. Nothing here alters what gets sent to the printer.
