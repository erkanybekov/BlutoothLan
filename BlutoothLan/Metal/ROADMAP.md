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

## Part 2 — The real render pipeline (not built yet)

You'd move here when you hit Part 1's ceiling: no multi-pass, no render-to-texture, no control
over geometry, can't read your own output.

Doc: [Using a Render Pipeline to Render Primitives](https://developer.apple.com/documentation/metal/using-a-render-pipeline-to-render-primitives)

- **9** — Object graph, clear colour only. `MTLDevice` → `MTLCommandQueue` → `MTLCommandBuffer` →
  `MTLRenderCommandEncoder` → `commit`. The once-vs-per-frame split: pipeline state built once,
  encoders thrown away every frame.
- **10** — First triangle. `[[vertex_id]]`, no buffer. NDC space is −1…1 with **y up**, unlike UIKit.
- **11** — Vertex buffers + interpolation. Three corner colours → a gradient, in fixed-function
  hardware. This is why fragment shaders are where image work lives.
- **12** — Textures + full-screen quad. `MTKTextureLoader`, samplers, UV space 0…1 origin top-left
  (*different again* from NDC). Multi-pass: adjustments → dither as separate passes.

## Part 3 — Compute (not built yet)

Docs: [Performing calculations on a GPU](https://developer.apple.com/documentation/metal/performing-calculations-on-a-gpu) ·
[Processing a texture in a compute function](https://developer.apple.com/documentation/metal/hello_compute)

- **13** — `MTLComputeCommandEncoder`, threadgroups, `threadgroup` memory, arbitrary writes.
  Worked example: bit-packing to ESC/POS (`ImageProcessor.convertToESCPOS`).
- **14** — The wavefront / diagonal-sweep trick that genuinely does parallelise error diffusion —
  and an honest look at whether it's worth it at 384px wide.

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
