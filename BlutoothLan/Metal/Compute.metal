//
//  Compute.metal
//  BlutoothLan
//
//  Part 3: compute kernels. No triangles, no rasterizer, no pixels-on-screen.
//
//  A `kernel` function is dispatched over a GRID of threads you define, and it
//  can write ANYWHERE in a buffer or texture. That last part is the whole point:
//  a fragment shader may only produce the one pixel it was invoked for, which is
//  exactly why error diffusion was impossible in Parts 1 and 2.
//

#include <metal_stdlib>
using namespace metal;


// ---------------------------------------------------------------------------
// STEP 13a — the "hello world" of compute.
//
// [[thread_position_in_grid]] is this thread's coordinate in the grid you
// dispatched. It replaces both [[vertex_id]] and the implicit per-pixel
// invocation of a fragment shader.
//
// The bounds check matters: grids get rounded up to whole threadgroups, so
// threads outside your data really do run.
// ---------------------------------------------------------------------------
kernel void textureToGray(texture2d<float, access::read> src [[texture(0)]],
                          device float *gray                 [[buffer(0)]],
                          constant int &width                [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= src.get_width() || gid.y >= src.get_height()) { return; }

    float4 c = src.read(gid);
    gray[int(gid.y) * width + int(gid.x)] = dot(c.rgb, float3(0.299, 0.587, 0.114));
}


// ---------------------------------------------------------------------------
// STEP 13b — Bayer dithering again, but as compute.
//
// Identical maths to the colorEffect version in Effects.metal. The point of
// repeating it is that it ports over unchanged: work that was already
// per-pixel-independent doesn't care which pipeline runs it.
// ---------------------------------------------------------------------------
constant float bayer4[16] = {
     0.0,  8.0,  2.0, 10.0,
    12.0,  4.0, 14.0,  6.0,
     3.0, 11.0,  1.0,  9.0,
    15.0,  7.0, 13.0,  5.0
};

kernel void bayerCompute(device const float *gray [[buffer(0)]],
                         device uchar *outBits    [[buffer(1)]],
                         constant int2 &size      [[buffer(2)]],
                         uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= size.x || y >= size.y) { return; }

    float threshold = (bayer4[(y & 3) * 4 + (x & 3)] + 0.5) / 16.0;
    outBits[y * size.x + x] = gray[y * size.x + x] > threshold ? 0 : 1;   // 1 = black
}


// ---------------------------------------------------------------------------
// STEP 14 — Atkinson error diffusion on the GPU, via WAVEFRONT scheduling.
//
// The dependency problem: pixel (x,y) pushes 1/8 of its error into six
// neighbours — (x+1,y) (x+2,y) (x-1,y+1) (x,y+1) (x+1,y+1) (x,y+2) — so it must
// run after every pixel that feeds it. Scan order is inherently sequential.
//
// The trick: find a schedule k(x,y) where every pixel in a given k depends only
// on pixels with SMALLER k. Then all pixels sharing a k can run in parallel,
// and we just dispatch k = 0, 1, 2, … in order.
//
// Why k = x + 4y and not the obvious x + y? Work out the six pixels that feed
// target (x,y) — they sit at k offsets:
//
//     -1, -2, (1-b), -b, (-1-b), -2b        where k = x + b*y
//
//     b=1 → -1,-2, 0,-1,-2,-2   0 means a dependency in the SAME wavefront ✗
//     b=2 → -1,-2,-1,-2,-3,-4   duplicates: two sources in one wavefront
//                                write to the same pixel — a data race ✗
//     b=3 → -1,-2,-2,-3,-4,-6   still duplicated ✗
//     b=4 → -1,-2,-3,-4,-5,-8   all distinct ✓
//
// b=4 is the smallest slope where no two pixels in a wavefront ever touch the
// same memory, so no atomics are needed. Getting this wrong gives you output
// that looks *almost* right and changes between runs.
//
// The cost: W + 4H wavefronts, each a separate dispatch. See ComputeLab.swift
// for what that does to the clock.
// ---------------------------------------------------------------------------
kernel void atkinsonWavefront(device float *gray      [[buffer(0)]],
                              device uchar *outBits   [[buffer(1)]],
                              constant int2 &size     [[buffer(2)]],
                              constant int2 &kAndYMin [[buffer(3)]],
                              constant float &threshold [[buffer(4)]],
                              uint tid [[thread_position_in_grid]]) {
    int W = size.x, H = size.y;
    int k = kAndYMin.x;
    int y = kAndYMin.y + int(tid);
    int x = k - 4 * y;

    if (y < 0 || y >= H || x < 0 || x >= W) { return; }

    int idx = y * W + x;

    float oldV = gray[idx];
    float newV = oldV > threshold ? 1.0 : 0.0;
    outBits[idx] = (newV < 0.5) ? 1 : 0;              // 1 = black

    float err = (oldV - newV) / 8.0;                  // Atkinson keeps only 6/8

    if (x + 1 < W) { gray[idx + 1] = clamp(gray[idx + 1] + err, 0.0, 1.0); }
    if (x + 2 < W) { gray[idx + 2] = clamp(gray[idx + 2] + err, 0.0, 1.0); }

    if (y + 1 < H) {
        int n = idx + W;
        if (x - 1 >= 0) { gray[n - 1] = clamp(gray[n - 1] + err, 0.0, 1.0); }
        gray[n] = clamp(gray[n] + err, 0.0, 1.0);
        if (x + 1 < W) { gray[n + 1] = clamp(gray[n + 1] + err, 0.0, 1.0); }
    }

    if (y + 2 < H) { gray[idx + 2 * W] = clamp(gray[idx + 2 * W] + err, 0.0, 1.0); }
}


// ---------------------------------------------------------------------------
// STEP 13c — pack 1-bit pixels into ESC/POS bytes.
//
// This is ImageProcessor.convertToESCPOS as a kernel. One thread produces one
// OUTPUT BYTE from eight input pixels — so the grid is shaped like the output,
// not the input. That reshaping is normal in compute and impossible in render,
// where the grid is always "one invocation per pixel you're drawing".
//
// X6h wants LSB first: the leftmost pixel is bit 0.
// ---------------------------------------------------------------------------
kernel void packToESCPOS(device const uchar *bits [[buffer(0)]],
                         device uchar *out        [[buffer(1)]],
                         constant int2 &size      [[buffer(2)]],
                         constant int &bytesPerRow [[buffer(3)]],
                         uint2 gid [[thread_position_in_grid]]) {
    int byteX = int(gid.x), y = int(gid.y);
    if (byteX >= bytesPerRow || y >= size.y) { return; }

    uchar packed = 0;
    for (int bit = 0; bit < 8; bit++) {
        int x = byteX * 8 + bit;
        if (x >= size.x) { break; }
        if (bits[y * size.x + x] != 0) {
            packed |= (uchar(1) << bit);          // LSB first
        }
    }
    out[y * bytesPerRow + byteX] = packed;
}


// ---------------------------------------------------------------------------
// STEP 19 — THREADGROUP MEMORY and parallel reduction.
//
// Every kernel so far had threads that ignored each other. This one makes them
// cooperate.
//
// `threadgroup` memory is a small, fast scratchpad SHARED by all threads in a
// threadgroup — much faster than device memory, and invisible to other groups.
//
// The pattern is a tree reduction: 256 values → 128 → 64 → … → 1, halving each
// round. log2(256) = 8 rounds instead of 256 sequential adds.
//
// threadgroup_barrier is mandatory. It makes every thread in the group wait
// until all of them have finished writing. Remove it and you read values your
// neighbours haven't written yet — the result is wrong and varies per run.
// ---------------------------------------------------------------------------
kernel void reduceSum(device const float *values  [[buffer(0)]],
                      device float *partials      [[buffer(1)]],
                      constant int &count         [[buffer(2)]],
                      uint gid  [[thread_position_in_grid]],
                      uint lid  [[thread_position_in_threadgroup]],
                      uint tgid [[threadgroup_position_in_grid]],
                      uint tgSize [[threads_per_threadgroup]]) {

    threadgroup float scratch[256];

    scratch[lid] = (int(gid) < count) ? values[gid] : 0.0;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint stride = tgSize / 2; stride > 0; stride >>= 1) {
        if (lid < stride) {
            scratch[lid] += scratch[lid + stride];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    // One thread per group writes that group's total.
    if (lid == 0) {
        partials[tgid] = scratch[0];
    }
}


// ---------------------------------------------------------------------------
// STEP 25 — a hand-written separable-ish box blur, purely so there's something
// honest to benchmark Metal Performance Shaders against.
//
// This is the naive version: (2r+1)^2 texture reads per pixel, no separation
// into two passes, no threadgroup tiling, no vectorisation. Exactly what you'd
// write first — and what MPSImageGaussianBlur exists to beat.
// ---------------------------------------------------------------------------
kernel void boxBlurCompute(texture2d<float, access::read>  src [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           constant int &radius [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    int w = int(src.get_width()), h = int(src.get_height());
    if (int(gid.x) >= w || int(gid.y) >= h) { return; }

    float4 sum = float4(0.0);
    int count = 0;

    for (int dy = -radius; dy <= radius; dy++) {
        for (int dx = -radius; dx <= radius; dx++) {
            int x = clamp(int(gid.x) + dx, 0, w - 1);
            int y = clamp(int(gid.y) + dy, 0, h - 1);
            sum += src.read(uint2(x, y));
            count++;
        }
    }

    dst.write(sum / float(count), gid);
}
