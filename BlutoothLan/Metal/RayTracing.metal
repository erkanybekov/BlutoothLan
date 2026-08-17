//
//  RayTracing.metal
//  BlutoothLan
//
//  Ray tracing inverts the render pipeline.
//
//  Rasterisation asks, for each TRIANGLE, "which pixels do you cover?" — which
//  is why a fragment shader only ever produces the one pixel it was invoked for.
//
//  Ray tracing asks, for each PIXEL, "what do you see?" — you fire a ray and the
//  hardware walks an acceleration structure to find what it hits. That reversal
//  is what makes shadows, reflections and global illumination expressible at
//  all: a ray can ask about geometry that isn't on screen, which a fragment
//  shader fundamentally cannot.
//
//  This kernel uses `ray_query`, the inline form — no separate intersection
//  functions or shader tables, just a loop inside an ordinary compute kernel.
//

#include <metal_stdlib>
#include <metal_raytracing>
using namespace metal;
using namespace raytracing;

struct RTUniforms {
    float3 cameraPosition;
    float  time;
    uint2  size;
};

kernel void rayTraceKernel(texture2d<float, access::write> out [[texture(0)]],
                           primitive_acceleration_structure accel [[buffer(0)]],
                           constant RTUniforms &u [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {

    if (gid.x >= u.size.x || gid.y >= u.size.y) { return; }

    // Pixel → normalised device coords → a direction through the image plane.
    float2 uv = (float2(gid) + 0.5) / float2(u.size);
    float2 ndc = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);

    ray r;
    r.origin = u.cameraPosition;
    r.direction = normalize(float3(ndc.x, ndc.y, -1.5));
    r.min_distance = 0.001;
    r.max_distance = 100.0;

    // The inline query. `intersector` + intersection functions are the other
    // form; this one keeps everything in the kernel.
    intersector<triangle_data> isect;
    isect.assume_geometry_type(geometry_type::triangle);

    intersection_result<triangle_data> hit =
        isect.intersect(r, accel);

    float3 colour = float3(0.05, 0.06, 0.12);      // background

    if (hit.type == intersection_type::triangle) {
        // Barycentrics come back for free from the intersection.
        float2 bary = hit.triangle_barycentric_coord;
        float3 bary3 = float3(1.0 - bary.x - bary.y, bary.x, bary.y);

        // Shade by barycentric + primitive index so each face is distinct and
        // the geometry is unmistakably being intersected, not faked.
        float3 tint = float3(
            fract(float(hit.primitive_id) * 0.37 + 0.1),
            fract(float(hit.primitive_id) * 0.61 + 0.4),
            fract(float(hit.primitive_id) * 0.83 + 0.7)
        );

        float shade = 0.35 + 0.65 * bary3.x;
        colour = tint * shade;
    }

    out.write(float4(colour, 1.0), gid);
}
