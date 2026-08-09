//
//  Effects.metal
//  BlutoothLan
//
//  Part 1 of the Metal roadmap: the shader language, with no Metal boilerplate.
//  Every function here is driven by a SwiftUI modifier in ShaderLabView.swift.
//
//  Read these top to bottom — each one adds exactly one new idea.
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;


// ---------------------------------------------------------------------------
// STEP 1 — colorEffect replaces the colour. It does not tint or blend.
//
//   [[ stitchable ]] half4 name(float2 position, half4 color, args...)
//
// You are handed WHERE you are and WHAT is already there. You return what
// should be there. No loop, no neighbours, no memory of the previous pixel —
// this function is the *body* of a per-pixel loop the GPU runs for you.
//
// Note `newColor.rgb * currentColor.a`: SwiftUI hands you PRE-MULTIPLIED
// colour, meaning rgb has already been multiplied by alpha, so rgb can never
// exceed alpha. Building half4(1,0,0, 0.5) would be invalid. Multiplying the
// incoming opaque red by alpha puts it back in that space.
// ---------------------------------------------------------------------------
[[ stitchable ]] half4 changeColor(float2 position, half4 currentColor, half4 newColor) {
    if (currentColor.a > 0.0h) {
        return half4(newColor.rgb * currentColor.a, currentColor.a);
    }
    return currentColor;
}


// ---------------------------------------------------------------------------
// STEP 2 — `position` is in user-space POINTS, not pixels and not 0…1.
// For a 300x300 view it runs (0,0) top-left to (300,300) bottom-right.
//
// The shader is never told how big the view is, so the width has to be passed
// in as a uniform. That is the whole reason uniforms exist.
//
// This ignores `color` entirely, which is why the source blue disappears.
// ---------------------------------------------------------------------------
[[ stitchable ]] half4 horizontalFade(float2 position, half4 color, float width) {
    float t = position.x / width;              // 0.0 left edge → 1.0 right edge
    return half4(half(t), 0.0h, 0.0h, 1.0h);   // RGBA: red ramps, no green/blue
}


// ---------------------------------------------------------------------------
// STEP 3 — branching. A hard edge instead of a ramp.
// Both halves are constructed from scratch; nothing survives from the source.
// ---------------------------------------------------------------------------
[[ stitchable ]] half4 halfAndHalf(float2 position, half4 color, float width) {
    if (position.x < width * 0.5) {
        return half4(1.0h, 0.0h, 0.0h, 1.0h);  // red
    }
    return half4(0.0h, 0.0h, 1.0h, 1.0h);      // blue
}


// ---------------------------------------------------------------------------
// STEP 4 — now actually READ the source colour.
// Rec.601 luma weights: green dominates because the eye is most sensitive to
// it. This is why a plain (r+g+b)/3 average looks wrong, and roughly what
// CGColorSpaceCreateDeviceGray does in ImageProcessor.convertToGrayscale.
//
// Luma of a pre-multiplied colour is itself pre-multiplied, so pairing it with
// the original alpha stays valid — no un-premultiply needed here.
// ---------------------------------------------------------------------------
[[ stitchable ]] half4 grayscale(float2 position, half4 color) {
    half y = dot(color.rgb, half3(0.299h, 0.587h, 0.114h));
    return half4(y, y, y, color.a);
}


// ---------------------------------------------------------------------------
// STEP 5 — uniforms driving real work. This is ImageProcessor.applyAdjustments
// (gamma → contrast → brightness) as a shader.
//
// Here the pre-multiplied thing DOES bite: pow() and the contrast multiply are
// non-linear, so they must run on true colour values. Un-premultiply, do the
// maths, re-premultiply. That is the general pattern for any non-trivial
// colour operation in a colorEffect.
// ---------------------------------------------------------------------------
[[ stitchable ]] half4 adjustments(float2 position, half4 color,
                                   float brightness, float contrast, float gamma) {
    half a = color.a;
    if (a <= 0.0h) { return color; }

    half3 rgb = color.rgb / a;                                   // un-premultiply

    rgb = pow(max(rgb, half3(0.0h)), half3(half(gamma)));        // gamma
    rgb = (rgb - 0.5h) * half(contrast) + 0.5h;                  // contrast about mid-grey
    rgb = rgb + half(brightness);                                // brightness
    rgb = clamp(rgb, 0.0h, 1.0h);

    return half4(rgb * a, a);                                    // re-premultiply
}


// ---------------------------------------------------------------------------
// STEP 6 — Bayer 4x4 ORDERED dithering.
//
// Each pixel looks up a threshold from a fixed matrix based on its own (x,y)
// and compares its own brightness to it. Nothing is shared between pixels,
// so it parallelises perfectly.
//
// Contrast this with ImageProcessor.applyAtkinsonDithering: that pushes each
// pixel's quantisation error into six NEIGHBOURS, so pixel N+1 cannot be
// computed until N is done. A colorEffect has no way to write to another
// pixel and no guaranteed ordering — the impossibility is visible in the
// function signature. That constraint is the core of GPU programming.
// ---------------------------------------------------------------------------
constant float bayer4x4[16] = {
     0.0,  8.0,  2.0, 10.0,
    12.0,  4.0, 14.0,  6.0,
     3.0, 11.0,  1.0,  9.0,
    15.0,  7.0, 13.0,  5.0
};

[[ stitchable ]] half4 bayerDither(float2 position, half4 color) {
    half a = color.a;
    if (a <= 0.0h) { return color; }

    half3 rgb = color.rgb / a;
    half luma = dot(rgb, half3(0.299h, 0.587h, 0.114h));

    int ix = int(position.x) & 3;                    // & 3 == % 4
    int iy = int(position.y) & 3;
    half threshold = half((bayer4x4[iy * 4 + ix] + 0.5) / 16.0);

    half v = luma > threshold ? 1.0h : 0.0h;         // 1-bit output, like the printer
    return half4(half3(v) * a, a);
}


// ---------------------------------------------------------------------------
// STEP 7 — distortionEffect. Different signature: returns a POSITION, not a
// colour.
//
//   [[ stitchable ]] float2 name(float2 position, args...)
//
// The direction is inverted from what you expect: you return where to SAMPLE
// FROM, not where this pixel should move to. "For the pixel at `position`, go
// fetch the colour that lives over there."
// ---------------------------------------------------------------------------
[[ stitchable ]] float2 ripple(float2 position, float2 size, float time, float amplitude) {
    float2 center = size * 0.5;
    float2 delta  = position - center;
    float  dist   = length(delta);

    if (dist < 0.001) { return position; }

    float offset = sin(dist * 0.08 - time * 3.0) * amplitude;
    return position + normalize(delta) * offset;
}


// ---------------------------------------------------------------------------
// STEP 8 — layerEffect. Now you can READ other pixels.
//
//   [[ stitchable ]] half4 name(float2 position, SwiftUI::Layer layer, args...)
//
// layer.sample(p) fetches the composited view at any point, so neighbourhood
// operations — blur, sharpen, edge detection — become possible.
//
// But note what you STILL don't get: no ordering, and no writing to other
// pixels. Sharpen works because it only needs to read. Atkinson still does
// not, because it needs to write into its neighbours and needs them processed
// in sequence. The constraint got weaker, not gone.
// ---------------------------------------------------------------------------
[[ stitchable ]] half4 boxBlur(float2 position, SwiftUI::Layer layer, float radius) {
    half4 sum = half4(0.0h);
    for (int dy = -2; dy <= 2; dy++) {
        for (int dx = -2; dx <= 2; dx++) {
            sum += layer.sample(position + float2(dx, dy) * radius);
        }
    }
    return sum / 25.0h;
}

// Unsharp mask: original + (original - blurred) * amount.
// This is ImageProcessor's CISharpenLuminance, by hand.
[[ stitchable ]] half4 sharpen(float2 position, SwiftUI::Layer layer, float amount) {
    half4 c = layer.sample(position);
    half4 blur = (layer.sample(position + float2(-1.0,  0.0)) +
                  layer.sample(position + float2( 1.0,  0.0)) +
                  layer.sample(position + float2( 0.0, -1.0)) +
                  layer.sample(position + float2( 0.0,  1.0))) * 0.25h;

    return clamp(c + (c - blur) * half(amount), 0.0h, 1.0h);
}
