
struct CmdyRasterOut {
    float4 position [[position]];
    float2 uv;
};
vertex CmdyRasterOut cmdy_user_vertex(uint vertexID [[vertex_id]],
                                       const device QuadVertex *vertices [[buffer(0)]],
                                       constant RasterUniforms &r [[buffer(1)]]) {
    QuadVertex v = vertices[vertexID];
    CmdyRasterOut out;
    float2 safeResolution = max(r.resolution, float2(1.0));
    out.position = float4(v.position.x / safeResolution.x * 2.0 - 1.0,
                          1.0 - v.position.y / safeResolution.y * 2.0,
                          0.0, 1.0);
    out.uv = v.uv;
    return out;
}
fragment float4 cmdy_user_fragment(CmdyRasterOut in [[stage_in]],
                                    texture2d<float> scene [[texture(0)]],
                                    sampler smp [[sampler(0)]],
                                    constant CmdyUniforms &u [[buffer(0)]]) {
    float4 sceneColor = scene.sample(smp, in.uv);
    float4 color = cmdy_main(in.uv, sceneColor, u, scene, smp);
    // User code keeps straight scene RGB and returns straight RGBA. Convert
    // only the final result for the composited Metal drawable.
    if (color.a < 1.0) {
        float alpha = clamp(color.a, 0.0, 1.0);
        return float4(clamp(color.rgb, 0.0, 1.0) * alpha, alpha);
    }
    return color;
}
