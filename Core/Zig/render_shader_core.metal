#include <metal_stdlib>
using namespace metal;

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
struct RasterOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float2 pixel;
};

vertex RasterOut cmdy_independent_vertex(
    uint vertexID [[vertex_id]],
    const device QuadVertex *vertices [[buffer(0)]],
    constant RasterUniforms &u [[buffer(1)]]) {
    QuadVertex v = vertices[vertexID];
    RasterOut out;
    float2 safeResolution = max(u.resolution, float2(1.0));
    out.position = float4(v.position.x / safeResolution.x * 2.0 - 1.0,
                          1.0 - v.position.y / safeResolution.y * 2.0,
                          0.0, 1.0);
    out.uv = v.uv;
    out.color = v.color;
    out.pixel = v.position;
    return out;
}

fragment float4 cmdy_independent_solid(RasterOut in [[stage_in]]) {
    return in.color;
}

fragment float4 cmdy_independent_coverage(
    RasterOut in [[stage_in]],
    texture2d<float> coverage [[texture(0)]],
    sampler smp [[sampler(0)]],
    constant RasterUniforms &u [[buffer(0)]]) {
    float a = coverage.sample(smp, in.uv).r;
    float exponent = 1.0 / max(0.1, u.coveragePower);
    a = pow(clamp(a, 0.0, 1.0), exponent);
    if (u.databloomEnergy > 0.0) {
        float flicker = 0.88 + 0.12 * sin(in.pixel.y * 0.21 + in.pixel.x * 0.013);
        a *= mix(1.0, flicker, clamp(u.databloomEnergy, 0.0, 1.0));
    }
    // Frozen CmdyGPU coverage is premultiplied by glyph coverage, but not
    // by the attributed foreground alpha. Preserve that observable blend:
    // alpha dims the destination contribution while the glyph RGB remains
    // at its delivered intensity.
    return float4(in.color.rgb * a, in.color.a * a);
}

fragment float4 cmdy_independent_image(
    RasterOut in [[stage_in]],
    texture2d<float> image [[texture(0)]],
    sampler smp [[sampler(0)]]) {
    return image.sample(smp, in.uv) * in.color;
}

fragment float4 cmdy_independent_post(
    RasterOut in [[stage_in]],
    texture2d<float> scene [[texture(0)]],
    sampler smp [[sampler(0)]],
    constant CmdyUniforms &u [[buffer(0)]]) {
    float2 uv = in.uv;
    float4 base = scene.sample(smp, uv);
    uint mode = u.passIndex;
    float2 aspect = float2(max(1.0, u.resolution.x / max(1.0, u.resolution.y)), 1.0);
    float2 p = (uv - 0.5) * aspect;
    float phase = u.time * (0.025 + float(mode % 11) * 0.006);
    float field = sin((p.x + phase) * (3.0 + float(mode % 7)))
                * cos((p.y - phase) * (4.0 + float(mode % 5)));
    float3 tint = 0.5 + 0.5 * cos(float3(0.0, 2.1, 4.2)
                                 + field + float(mode) * 0.19);
    float textMask = smoothstep(0.025, 0.22,
        distance(base.rgb, u.background.rgb));
    float strength = 0.025 + float(mode % 9) * 0.004;
    float3 behind = mix(base.rgb, base.rgb + tint * strength, 1.0 - textMask);
    if ((mode % 6) == 0) {
        float vignette = smoothstep(0.9, 0.15, length(p));
        behind *= mix(0.88, 1.0, vignette);
    }
    return float4(behind, base.a * u.opacity);
}
