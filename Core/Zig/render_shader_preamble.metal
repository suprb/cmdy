#include <metal_stdlib>
using namespace metal;

struct CmdyUniforms {
    float2 resolution;
    float time;
    float curvature;
    float4 background;
    float2 cursor;
    float keypressAge;
    float typingRate;
    float opacity;
    uint passIndex;
    uint2 padding;
};
struct QuadVertex {
    float2 position;
    float2 uv;
    float4 color;
};
struct RasterUniforms {
    float2 resolution;
    float coveragePower;
    float databloomEnergy;
};

static float cmdy_hash(float2 p) {
    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}
static float3 cmdy_palette(float t) {
    return 0.5 + 0.5 * cos(6.28318 * (t + float3(0.0, 0.33, 0.67)));
}
static float cmdy_textMask(float3 rgb, float3 background) {
    float3 delta = abs(rgb - background);
    return clamp(max(delta.r, max(delta.g, delta.b)) * 5.0, 0.0, 1.0);
}
