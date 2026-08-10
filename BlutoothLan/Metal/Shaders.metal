//
//  Shaders.metal
//  BlutoothLan
//
//  Part 2 of the roadmap: the REAL render pipeline.
//
//  These are not [[stitchable]] SwiftUI shaders. These are genuine vertex and
//  fragment functions, driven by Renderer.swift through MTLRenderCommandEncoder.
//
//  The pipeline is a fixed assembly line with exactly two programmable slots:
//
//      vertices → [VERTEX SHADER] → rasterizer → [FRAGMENT SHADER] → pixels
//                  you write this   fixed HW      you write this
//
//  The rasterizer in the middle is silicon. You don't program it — but it does
//  the single most important thing in this file (see STAGE 11).
//

#include <metal_stdlib>
using namespace metal;


// What the vertex shader passes down to the fragment shader.
//
// [[position]] is required and special: the rasterizer reads it to work out
// which pixels the triangle covers. Everything else in this struct is yours,
// and gets INTERPOLATED across the triangle on the way down.
struct RasterizerData {
    float4 position [[position]];
    float4 color;
};


// ---------------------------------------------------------------------------
// STAGE 10 — First triangle. No vertex buffer at all.
//
// [[vertex_id]] is the index of the vertex being processed: 0, 1, 2. The GPU
// runs this function once per vertex, in parallel, and they can't see each
// other — same rule as a fragment shader.
//
// Coordinates here are NDC (normalised device coordinates): -1…1 on both axes,
// (0,0) is the CENTRE, and +Y is UP. That last part is the opposite of UIKit
// and the reason your first triangle is often upside down.
// ---------------------------------------------------------------------------
vertex RasterizerData triangle_vertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = {
        float2( 0.0,  0.8),   // top
        float2(-0.8, -0.8),   // bottom left
        float2( 0.8, -0.8)    // bottom right
    };

    RasterizerData out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.color    = float4(1.0, 0.25, 0.3, 1.0);   // flat colour, same for all 3
    return out;
}

fragment float4 triangle_fragment(RasterizerData in [[stage_in]]) {
    return in.color;
}


// ---------------------------------------------------------------------------
// STAGE 11 — Vertex buffer + INTERPOLATION.
//
// Now the vertices come from an MTLBuffer the CPU filled in, bound at
// buffer index 0. This struct's memory layout must match the Swift one
// exactly — see LabVertex in Renderer.swift.
//
// The important part: each vertex carries a DIFFERENT colour, and the
// fragment shader receives a smooth blend. You did not write that blend.
// The rasterizer interpolates every non-[[position]] field across the
// triangle for free, in fixed-function hardware.
//
// That is the key idea of the whole render pipeline, and it's why fragment
// shaders are the natural home for image processing.
// ---------------------------------------------------------------------------
struct Vertex {
    float2 position;
    float4 color;
};

vertex RasterizerData interpolated_vertex(uint vertexID [[vertex_id]],
                                          constant Vertex *vertices [[buffer(0)]]) {
    RasterizerData out;
    out.position = float4(vertices[vertexID].position, 0.0, 1.0);
    out.color    = vertices[vertexID].color;
    return out;
}


// ---------------------------------------------------------------------------
// STAGE 12 — Texture on a full-screen quad.
//
// UV (texture) coordinates are 0…1 with origin TOP-LEFT. NDC is -1…1 with
// origin centre and Y up. Two different spaces in the same vertex — mixing
// them up is the second classic source of upside-down output.
//
// The fragment shader here does real image work: a grayscale mix driven by a
// uniform. This is Part 1's `grayscale` shader, but now running inside a
// pipeline you built yourself — which means you could render it to a texture
// and run another pass over the result. That's what SwiftUI shaders can't do.
// ---------------------------------------------------------------------------
struct TexVertex {
    float2 position;
    float2 uv;
};

struct TexRasterizerData {
    float4 position [[position]];
    float2 uv;
};

vertex TexRasterizerData quad_vertex(uint vertexID [[vertex_id]],
                                     constant TexVertex *vertices [[buffer(0)]]) {
    TexRasterizerData out;
    out.position = float4(vertices[vertexID].position, 0.0, 1.0);
    out.uv       = vertices[vertexID].uv;
    return out;
}

fragment float4 quad_fragment(TexRasterizerData in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              constant float &grayAmount [[buffer(0)]]) {
    // A sampler decides how to read between texels: filtering and edge behaviour.
    // constexpr means it's baked into the shader at compile time, no CPU setup.
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float4 c = tex.sample(s, in.uv);

    float y = dot(c.rgb, float3(0.299, 0.587, 0.114));
    return float4(mix(c.rgb, float3(y), grayAmount), c.a);
}
