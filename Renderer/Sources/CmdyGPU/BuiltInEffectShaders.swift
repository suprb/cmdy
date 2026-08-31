import Metal

/// Swift-side layout for `CmdySceneEffectUniforms` in the Metal source.
/// The independent renderer's larger uniform block has this exact 48-byte
/// prefix and may also be bound directly.
struct CmdySceneEffectUniforms: Sendable {
    var resolution: SIMD2<Float>
    var time: Float
    var curvature: Float
    var background: SIMD4<Float>
    var cursor: SIMD2<Float>
    var keypressAge: Float
    var typingRate: Float
}

/// Swift-side layout for the glyph-only mode-68 buffer.
struct CmdyDatabloomUniforms: Sendable {
    var energy: Float
    var velocity: Float
    var opacity: Float
    var passIndex: Float
}

/// Rendering scope is intentionally explicit: modes 1...67 consume the fully
/// composed scene, while mode 68 consumes glyph coverage only.
enum CmdyBuiltInEffectScope: Equatable, Sendable {
    case scenePostprocess
    case glyphCoverage
}

struct CmdyBuiltInEffectDescriptor: Equatable, Sendable {
    let mode: Int
    let name: String
    let scope: CmdyBuiltInEffectScope
}

struct CmdyBuiltInEffectPipelines {
    let scenePostprocess: MTLRenderPipelineState
    let databloomGlyph: MTLRenderPipelineState
}

enum CmdyBuiltInEffectShaderError: Error {
    case functionMissing(String)
}

/// Cmdy's independently namespaced built-in shader library.
///
/// Provenance: effect formulas come only from the Cmdy-authored regions
/// approved in docs/independence/PROVENANCE_INVENTORY.md. The glyph and scene
/// boundaries in this source are independently defined; no imported base
/// renderer declaration or entry-point body is present here.
enum CmdyBuiltInEffectShaders {
    static let sceneModes = 1...67
    static let databloomMode = 68

    static let descriptors: [CmdyBuiltInEffectDescriptor] = [
        .init(mode: 1, name: "crt", scope: .scenePostprocess),
        .init(mode: 2, name: "scanlines", scope: .scenePostprocess),
        .init(mode: 3, name: "glow", scope: .scenePostprocess),
        .init(mode: 4, name: "vhs", scope: .scenePostprocess),
        .init(mode: 5, name: "dither", scope: .scenePostprocess),
        .init(mode: 6, name: "neon", scope: .scenePostprocess),
        .init(mode: 7, name: "plasma", scope: .scenePostprocess),
        .init(mode: 8, name: "glitch", scope: .scenePostprocess),
        .init(mode: 9, name: "ripple", scope: .scenePostprocess),
        .init(mode: 10, name: "copper", scope: .scenePostprocess),
        .init(mode: 11, name: "starfield", scope: .scenePostprocess),
        .init(mode: 12, name: "matrix", scope: .scenePostprocess),
        .init(mode: 13, name: "fire", scope: .scenePostprocess),
        .init(mode: 14, name: "grid", scope: .scenePostprocess),
        .init(mode: 15, name: "tunnel", scope: .scenePostprocess),
        .init(mode: 16, name: "rotozoom", scope: .scenePostprocess),
        .init(mode: 17, name: "wobble", scope: .scenePostprocess),
        .init(mode: 18, name: "aurora", scope: .scenePostprocess),
        .init(mode: 19, name: "lava", scope: .scenePostprocess),
        .init(mode: 20, name: "boot", scope: .scenePostprocess),
        .init(mode: 21, name: "snow", scope: .scenePostprocess),
        .init(mode: 22, name: "bubbles", scope: .scenePostprocess),
        .init(mode: 23, name: "rain", scope: .scenePostprocess),
        .init(mode: 24, name: "tron", scope: .scenePostprocess),
        .init(mode: 25, name: "radar", scope: .scenePostprocess),
        .init(mode: 26, name: "maze", scope: .scenePostprocess),
        .init(mode: 27, name: "waves", scope: .scenePostprocess),
        .init(mode: 28, name: "plexus", scope: .scenePostprocess),
        .init(mode: 29, name: "vortex", scope: .scenePostprocess),
        .init(mode: 30, name: "blocks", scope: .scenePostprocess),
        .init(mode: 31, name: "lightning", scope: .scenePostprocess),
        .init(mode: 32, name: "scroller", scope: .scenePostprocess),
        .init(mode: 33, name: "rasterbars", scope: .scenePostprocess),
        .init(mode: 34, name: "ansi", scope: .scenePostprocess),
        .init(mode: 35, name: "floor", scope: .scenePostprocess),
        .init(mode: 36, name: "twister", scope: .scenePostprocess),
        .init(mode: 37, name: "moire", scope: .scenePostprocess),
        .init(mode: 38, name: "drift", scope: .scenePostprocess),
        .init(mode: 39, name: "breath", scope: .scenePostprocess),
        .init(mode: 40, name: "lagoon", scope: .scenePostprocess),
        .init(mode: 41, name: "silk", scope: .scenePostprocess),
        .init(mode: 42, name: "ember", scope: .scenePostprocess),
        .init(mode: 43, name: "fireflies", scope: .scenePostprocess),
        .init(mode: 44, name: "clouds", scope: .scenePostprocess),
        .init(mode: 45, name: "mist", scope: .scenePostprocess),
        .init(mode: 46, name: "deep", scope: .scenePostprocess),
        .init(mode: 47, name: "tide", scope: .scenePostprocess),
        .init(mode: 48, name: "zen", scope: .scenePostprocess),
        .init(mode: 49, name: "lanterns", scope: .scenePostprocess),
        .init(mode: 50, name: "snowfall", scope: .scenePostprocess),
        .init(mode: 51, name: "petals", scope: .scenePostprocess),
        .init(mode: 52, name: "koi", scope: .scenePostprocess),
        .init(mode: 53, name: "moss", scope: .scenePostprocess),
        .init(mode: 54, name: "dunes", scope: .scenePostprocess),
        .init(mode: 55, name: "horizon", scope: .scenePostprocess),
        .init(mode: 56, name: "rainfall", scope: .scenePostprocess),
        .init(mode: 57, name: "nebula", scope: .scenePostprocess),
        .init(mode: 58, name: "comet", scope: .scenePostprocess),
        .init(mode: 59, name: "meadow", scope: .scenePostprocess),
        .init(mode: 60, name: "ink", scope: .scenePostprocess),
        .init(mode: 61, name: "marble", scope: .scenePostprocess),
        .init(mode: 62, name: "prism", scope: .scenePostprocess),
        .init(mode: 63, name: "halo", scope: .scenePostprocess),
        .init(mode: 64, name: "waterline", scope: .scenePostprocess),
        .init(mode: 65, name: "slowscan", scope: .scenePostprocess),
        .init(mode: 66, name: "voronoi", scope: .scenePostprocess),
        .init(mode: 67, name: "eclipse", scope: .scenePostprocess),
        .init(mode: 68, name: "databloom", scope: .glyphCoverage)
    ]

    static let sceneVertexFunction = "cmdy_scene_effect_vertex"
    static let sceneFragmentFunction = "cmdy_scene_effect_fragment"
    static let databloomVertexFunction = "cmdy_databloom_glyph_vertex"
    static let databloomFragmentFunction = "cmdy_databloom_glyph_fragment"

    static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        try device.makeLibrary(source: metalSource, options: nil)
    }

    static func makePipelines(
        device: MTLDevice,
        pixelFormat: MTLPixelFormat,
        sampleCount: Int = 1
    ) throws -> CmdyBuiltInEffectPipelines {
        let library = try makeLibrary(device: device)
        let scene = try makePipeline(
            device: device,
            library: library,
            vertexName: sceneVertexFunction,
            fragmentName: sceneFragmentFunction,
            pixelFormat: pixelFormat,
            sampleCount: sampleCount,
            premultipliedBlending: false
        )
        let databloom = try makePipeline(
            device: device,
            library: library,
            vertexName: databloomVertexFunction,
            fragmentName: databloomFragmentFunction,
            pixelFormat: pixelFormat,
            sampleCount: sampleCount,
            premultipliedBlending: true
        )
        return CmdyBuiltInEffectPipelines(
            scenePostprocess: scene,
            databloomGlyph: databloom
        )
    }

    private static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertexName: String,
        fragmentName: String,
        pixelFormat: MTLPixelFormat,
        sampleCount: Int,
        premultipliedBlending: Bool
    ) throws -> MTLRenderPipelineState {
        guard let vertex = library.makeFunction(name: vertexName) else {
            throw CmdyBuiltInEffectShaderError.functionMissing(vertexName)
        }
        guard let fragment = library.makeFunction(name: fragmentName) else {
            throw CmdyBuiltInEffectShaderError.functionMissing(fragmentName)
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Cmdy built-in effect: \(fragmentName)"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.rasterSampleCount = max(1, sampleCount)

        if premultipliedBlending {
            let attachment = descriptor.colorAttachments[0]!
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }

        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    static let metalSource = #"""
#include <metal_stdlib>
using namespace metal;

// Independently defined input boundary for glyph-coverage rendering. It is
// layout-compatible with CmdyGPU's position/uv/color quad vertices.
struct CmdyDatabloomGlyphVertex {
    float2 position;
    float2 texCoord;
    float4 color;
};

struct CmdyDatabloomGlyphRasterUniforms {
    float2 resolution;
};

struct CmdyDatabloomGlyphVaryings {
    float4 position [[position]];
    float2 texCoord;
    float4 color;
};

vertex CmdyDatabloomGlyphVaryings cmdy_databloom_glyph_vertex(
        uint vertexID [[vertex_id]],
        const device CmdyDatabloomGlyphVertex *vertices [[buffer(0)]],
        constant CmdyDatabloomGlyphRasterUniforms &raster [[buffer(1)]]) {
    CmdyDatabloomGlyphVertex input = vertices[vertexID];
    float2 safeResolution = max(raster.resolution, float2(1.0));
    CmdyDatabloomGlyphVaryings out;
    out.position = float4(input.position.x / safeResolution.x * 2.0 - 1.0,
                          1.0 - input.position.y / safeResolution.y * 2.0,
                          0.0, 1.0);
    out.texCoord = input.texCoord;
    out.color = input.color;
    return out;
}

struct CmdyDatabloomUniforms {
    float energy;
    float velocity;
    float opacity;
    float passIndex;
};

static float cmdy_databloom_hash(float2 p) {
    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

static float3 cmdy_databloom_palette(float t) {
    return 0.5 + 0.5 * cos(6.28318 * (t + float3(0.0, 0.33, 0.67)));
}

/// Databloom runs on glyph quads themselves, not on the composed terminal
/// scene. Transparent glyph-coverage pixels remain transparent, which makes it
/// impossible for this effect to paint the terminal background or images.
fragment float4 cmdy_databloom_glyph_fragment(
        CmdyDatabloomGlyphVaryings in [[stage_in]],
        texture2d<float> glyphCoverage [[texture(0)]],
        sampler samp [[sampler(0)]],
        constant float &coveragePower [[buffer(0)]],
        constant CmdyDatabloomUniforms &u [[buffer(1)]]) {
    float coverage = pow(glyphCoverage.sample(samp, in.texCoord).r,
                         coveragePower);
    float energy = clamp(u.energy, 0.0, 1.0);
    float2 pixel = in.position.xy;
    float band = floor(pixel.y / 2.0);
    float segment = floor(pixel.x / 9.0);
    float seed = cmdy_databloom_hash(float2(segment + u.passIndex * 31.0,
                                            band + u.passIndex * 17.0));
    float slice = u.passIndex < 0.5 ? 1.0 : step(0.18 + u.passIndex * 0.06, seed);
    float alpha = coverage * in.color.a * u.opacity * slice;
    if (alpha <= 0.0001) {
        return float4(0.0);
    }

    float hue = fract(seed * 1.81 + band * 0.067 + segment * 0.109
                     + (u.velocity < 0.0 ? 0.12 : 0.0));
    float3 spectral = cmdy_databloom_palette(hue);
    float sourceLuma = max(0.76, dot(in.color.rgb,
        float3(0.299, 0.587, 0.114)));
    float chroma = clamp(energy * (u.passIndex < 0.5 ? 1.05 : 1.3), 0.0, 1.0);
    float3 base = in.color.rgb * (1.0 - 0.72 * energy);
    float3 tint = mix(base, spectral * sourceLuma * 1.38, chroma);
    return float4(tint * coverage * u.opacity * slice, alpha);
}


struct CmdySceneEffectVaryings {
    float4 position [[position]];
    float2 uv;
};

struct CmdySceneEffectUniforms {
    float2 resolution;
    float time;
    float curvature;
    float4 background;
    float2 cursor;       // cursor center in texture-space pixels (y-down)
    float keypressAge;   // seconds since the last keypress (10 = idle)
    float typingRate;    // keys/sec over the last 2 seconds
};

// Cheap hash for glitch/noise effects.
static float cmdy_effect_hash(float2 p) {
    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

// IQ-style cosine palette for plasma.
static float3 cmdy_effect_palette(float t) {
    return 0.5 + 0.5 * cos(6.28318 * (t + float3(0.0, 0.33, 0.67)));
}

// How far a pixel is from the theme background (0 = pure background,
// 1 = definitely text). Backgrounds render behind text with this mask.
static float cmdy_effect_textMask(float3 rgb, float3 bg) {
    float3 rel = abs(rgb - bg);
    return clamp(max(rel.r, max(rel.g, rel.b)) * 5.0, 0.0, 1.0);
}

// Bilinear value noise + 3-octave fbm — the calm pack's organic fields.
static float cmdy_effect_vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 s = f * f * (3.0 - 2.0 * f);
    float a = cmdy_effect_hash(i);
    float b = cmdy_effect_hash(i + float2(1.0, 0.0));
    float c = cmdy_effect_hash(i + float2(0.0, 1.0));
    float d = cmdy_effect_hash(i + float2(1.0, 1.0));
    return mix(mix(a, b, s.x), mix(c, d, s.x), s.y);
}
static float cmdy_effect_fbm(float2 p) {
    float v = 0.0, amp = 0.5;
    for (int i = 0; i < 3; i++) {
        v += cmdy_effect_vnoise(p) * amp;
        p = p * 2.03 + 17.31;
        amp *= 0.5;
    }
    return v;
}

vertex CmdySceneEffectVaryings cmdy_scene_effect_vertex(uint vid [[vertex_id]]) {
    // Fullscreen triangle, no vertex buffer.
    const float2 pos[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    CmdySceneEffectVaryings out;
    out.position = float4(pos[vid], 0.0, 1.0);
    out.uv = float2((pos[vid].x + 1.0) * 0.5, 1.0 - (pos[vid].y + 1.0) * 0.5);
    return out;
}

// Cmdy shader gallery, selected by `mode` (buffer 1):
//   1 = crt        curvature + scanlines + grille + vignette + glow + flicker
//   2 = scanlines  flat scanlines + a touch of glow (no curvature — seamless)
//   3 = glow       phosphor bloom only
//   4 = vhs        wobbling chroma split + tape noise + light scanlines
//   5 = dither     chunky ordered-dither quantization (1-bit C64 zine look)
//   6 = neon       realtime edge detection — glyph outlines burn, fills dim
//   7 = plasma     animated color field bleeding through the background
//   8 = glitch     slice displacement bursts + chroma tears + noise
//   9 = ripple     typing-reactive: shockwaves from the cursor, speed = energy
//  10 = copper     Amiga copper bars drifting behind the text
//  11 = starfield  parallax star stream; typing = warp speed
//  12 = matrix     digital rain columns behind the text
//  13 = fire       procedural flames rising from the bottom edge
//  14 = grid       synthwave horizon: perspective grid + striped sun
//  15 = tunnel     demoscene tunnel spiraling behind the text
//  16 = rotozoom   rotating/zooming checkerboard; typing pumps the zoom
//  17 = wobble     C64 demo sine-wobble on the whole picture
//  18 = aurora     northern-light curtains along the top
//  19 = lava       metaball lava lamp drifting behind the text
//  20 = boot       raster beam sweeps; every keypress fires one
//  21 = snow       analog static that grows while you idle; typing clears it
//  22 = bubbles    soda bubbles wobbling upward
//  23 = rain       slanted weather rain streaks
//  24 = tron       neon triangle lattice with a racing energy pulse
//  25 = radar      rotating sweep, afterglow, and blips
//  26 = maze       10 PRINT CHR$(205.5+RND(1)); — glowing C64 maze
//  27 = waves      layered ocean swell along the bottom
//  28 = plexus     drifting nodes linked when close
//  29 = vortex     three-armed spiral galaxy
//  30 = blocks     chunky colored tiles raining down
//  31 = lightning  a jagged bolt every few seconds + frame flash
//  32 = scroller   crack-tro sine scroller — CMDY waves by in rainbow pixels
//  33 = rasterbars hard-edged Amiga bars bouncing behind the text
//  34 = ansi       BBS mosaic: coarse half-blocks quantized to the EGA 16
//  35 = floor      infinite checkerboard rushing under the horizon
//  36 = twister    the classic demo twister column
//  37 = moire      two interference ring sources drifting
//  --- the calm set (38–67): slow, muted, ambient — nothing shouts ---
//  38 = drift      a dual-tone color field slowly folding over itself
//  39 = breath     the background inhales on an 8s cycle; idling deepens it
//  40 = lagoon     teal caustic light webs, pool-floor slow
//  41 = silk       translucent ribbons swaying, dusty violet
//  42 = ember      sparse warm motes rising and winking out
//  43 = fireflies  wandering green-gold points, soft blinking
//  44 = clouds     a pale cloud bank crossing at stratus pace
//  45 = mist       ground fog breathing along the bottom
//  46 = deep       abyssal gradient; a faint sonar ring every nine seconds
//  47 = tide       a waterline breathing at two-thirds height, foam whisper
//  48 = zen        raked sand rings around two slowly orbiting stones
//  49 = lanterns   five paper lanterns climbing on staggered loops
//  50 = snowfall   three parallax layers of unhurried flakes
//  51 = petals     pink petals drifting down-wind with a sway
//  52 = koi        three blurred koi gliding under frosted ice
//  53 = moss       green mottle creeping at lichen speed
//  54 = dunes      layered dune silhouettes, crest light, sand haze
//  55 = horizon    a dawn gradient whose mood shifts over three minutes
//  56 = rainfall   rain trails sliding down window glass
//  57 = nebula     slow-turning gas in magenta and indigo, dim stars
//  58 = comet      every ~17s one soft comet crosses the upper sky
//  59 = meadow     green ground glow + pollen adrift
//  60 = ink        ink blots blooming and dissolving in water
//  61 = marble     fine veins wandering through warped stone
//  62 = prism      one faint light shaft, spectrum-fringed, slowly swinging
//  63 = halo       a breathing glow that follows the cursor
//  64 = waterline  the scene reflects in water along the bottom edge
//  65 = slowscan   a luminous band sweeps down every twelve seconds
//  66 = voronoi    drifting cells, edges barely glowing
//  67 = eclipse    a dark disc with a breathing corona, upper right
//  68 = databloom  text-only chromatic fragments while the viewport scrolls
// Glow is DELTA-based (max(neighbors - self, 0)): flat areas keep their exact
// color, so the effect never shifts the background away from the theme.
fragment float4 cmdy_scene_effect_fragment(CmdySceneEffectVaryings in [[stage_in]],
                             texture2d<float> scene [[texture(0)]],
                             sampler s [[sampler(0)]],
                             constant CmdySceneEffectUniforms &u [[buffer(0)]],
                             constant int &mode [[buffer(1)]]) {
    float2 c = in.uv - 0.5;
    float r2 = dot(c, c);
    float2 uv = in.uv;
    bool oob = false;   // curved past the picture edge — treated as flat background

    if (mode == 8) {
        // Glitch: occasional horizontal slice displacement, re-rolled ~8x/sec.
        float tick = floor(u.time * 8.0);
        float slice = floor(uv.y * u.resolution.y / 22.0);
        float roll = cmdy_effect_hash(float2(slice, tick));
        if (roll > 0.90) {
            uv.x += (roll - 0.95) * 0.35;
            uv.x = fract(uv.x);   // wrap torn slices instead of clamping
        }
    }
    if (mode == 9) {
        // Ripple: an expanding shockwave from the cursor on every keypress.
        float2 pos = uv * u.resolution;
        float dist = distance(pos, u.cursor);
        float radius = u.keypressAge * 1400.0;                 // px/sec wavefront
        float wave = exp(-abs(dist - radius) / 28.0)           // ring profile
                   * exp(-u.keypressAge * 2.2);                // decay over time
        float2 dir = dist > 0.5 ? (pos - u.cursor) / dist : float2(0.0);
        uv -= dir * wave * 9.0 / u.resolution;                 // radial displacement
    }

    if (mode == 17) {
        // Wobble: the whole picture sways like a C64 demo sine-scroller.
        // Pixel-based frequencies so the wave shape doesn't stretch with the
        // window — same ripple density at any size.
        float2 pp = in.uv * u.resolution;
        uv.x += sin(pp.y / 26.0 + u.time * 2.1) * 2.5 / u.resolution.x;
        uv.y += sin(pp.x / 34.0 + u.time * 1.7) * 1.5 / u.resolution.y;
    }

    if (mode == 1) {
        // Barrel distortion. Out-of-bounds pixels DON'T return early: they run
        // the exact same scanline/grille/vignette pipeline on the background
        // color, so the pattern continues seamlessly across the picture edge
        // and the whole surface reads as one material.
        uv = 0.5 + c * (1.0 + u.curvature * r2 * 2.4);
        oob = (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0);
    }

    float4 col = oob ? u.background : scene.sample(s, uv);
    float3 rgb = col.rgb;
    float2 px = 1.6 / u.resolution;

    if (mode == 1 && !oob) {
        // Chromatic fringe, growing with distance from center.
        float2 fringe = c * r2 * 0.012;
        rgb = float3(scene.sample(s, uv + fringe).r,
                     col.g,
                     scene.sample(s, uv - fringe).b);
    }
    if (mode == 4) {
        // VHS: per-line chroma wobble + tape noise.
        float band = sin(uv.y * u.resolution.y * 0.7 + u.time * 6.3);
        float2 shift = float2((2.0 + band) * px.x, 0.0);
        rgb.r = scene.sample(s, uv + shift).r;
        rgb.b = scene.sample(s, uv - shift).b;
        float n = fract(sin(dot(uv * u.resolution, float2(12.9898, 78.233))
                            + u.time * 60.0) * 43758.5453);
        rgb += (n - 0.5) * 0.035;
    }

    if (!oob) {
        // Phosphor bloom around bright pixels (delta glow — flat areas untouched).
        float3 nb = (scene.sample(s, uv + float2(px.x, 0.0)).rgb +
                     scene.sample(s, uv - float2(px.x, 0.0)).rgb +
                     scene.sample(s, uv + float2(0.0, px.y)).rgb +
                     scene.sample(s, uv - float2(0.0, px.y)).rgb) * 0.25;
        rgb += max(nb - rgb, 0.0) * (mode == 3 ? 0.9 : 0.55);
    }

    if (mode == 1 || mode == 2 || mode == 4) {
        // uv is continuous across the picture edge, so the pattern carries on
        // into the margins without a visible boundary.
        float strength = (mode == 2) ? 0.12 : 0.16;
        float scan = 1.0 - strength * (0.5 + 0.5 * sin(uv.y * u.resolution.y * 3.14159265));
        rgb *= scan;
    }
    if (mode == 1) {
        // Aperture grille + gentle vignette + a whisper of mains flicker.
        float m = fmod(uv.x * u.resolution.x, 3.0);
        float3 mask = float3(m < 1.0 ? 1.04 : 0.97,
                             (m >= 1.0 && m < 2.0) ? 1.04 : 0.97,
                             m >= 2.0 ? 1.04 : 0.97);
        rgb *= mask;
        rgb *= 1.0 - 0.13 * smoothstep(0.45, 0.90, length(c));
        rgb *= 1.0 + 0.008 * sin(u.time * 100.0);
    }

    if (mode == 5) {
        // Ordered dither: 2x2-device-pixel blocks quantized to 4 luminance
        // levels through a Bayer 4x4 threshold — zine/1-bit C64 print look.
        const float bayer[16] = { 0.0, 8.0, 2.0, 10.0,
                                 12.0, 4.0, 14.0, 6.0,
                                  3.0, 11.0, 1.0, 9.0,
                                 15.0, 7.0, 13.0, 5.0 };
        float2 block = floor(uv * u.resolution / 2.0);
        int bi = int(fmod(block.x, 4.0)) + 4 * int(fmod(block.y, 4.0));
        float threshold = (bayer[bi] + 0.5) / 16.0;
        float3 rel = abs(rgb - u.background.rgb);
        float lum = max(rel.r, max(rel.g, rel.b)) * 1.6;       // distance from bg
        float levels = 3.0;
        float q = floor(lum * levels + threshold) / levels;
        // Re-tint with the pixel's own hue so themes survive the crunch.
        float3 tint = normalize(max(rgb, 0.02));
        rgb = u.background.rgb + tint * q * 0.9;
    }
    if (mode == 6) {
        // Neon: realtime contrast masking — luminance gradient turns glyph
        // EDGES into burning outlines while fills fade to embers.
        float3 gx = scene.sample(s, uv + float2(px.x, 0.0)).rgb
                  - scene.sample(s, uv - float2(px.x, 0.0)).rgb;
        float3 gy = scene.sample(s, uv + float2(0.0, px.y)).rgb
                  - scene.sample(s, uv - float2(0.0, px.y)).rgb;
        float edge = clamp((length(gx) + length(gy)) * 1.4, 0.0, 1.0);
        float3 ink = max(rgb, u.background.rgb + 0.06);        // glow tint from the glyph
        rgb = mix(u.background.rgb, rgb, 0.35) + ink * edge * 1.6;
        // Wider halo so the outlines actually bloom.
        float3 halo = (scene.sample(s, uv + 3.0 * float2(px.x, 0.0)).rgb +
                       scene.sample(s, uv - 3.0 * float2(px.x, 0.0)).rgb +
                       scene.sample(s, uv + 3.0 * float2(0.0, px.y)).rgb +
                       scene.sample(s, uv - 3.0 * float2(0.0, px.y)).rgb) * 0.25;
        rgb += max(halo - u.background.rgb, 0.0) * 0.5;
    }
    if (mode == 7) {
        // Plasma: an animated color field bleeds through wherever the pixel is
        // close to the background; text masks itself out in realtime.
        float2 p = uv * u.resolution / 240.0;
        float v = sin(p.x + u.time * 0.7) + sin(p.y - u.time * 0.55)
                + sin((p.x + p.y) * 0.7 + u.time * 0.4)
                + sin(length(p - 3.0) * 1.3 - u.time * 0.8);
        float3 plasma = cmdy_effect_palette(v * 0.18 + u.time * 0.03);
        float3 rel = abs(rgb - u.background.rgb);
        float textMask = clamp(max(rel.r, max(rel.g, rel.b)) * 5.0, 0.0, 1.0);
        rgb = mix(mix(u.background.rgb, plasma, 0.35), rgb, textMask);
    }
    if (mode == 8) {
        // Chroma tears + static, energy re-rolled with the slices.
        float tick = floor(u.time * 8.0);
        float burst = cmdy_effect_hash(float2(tick, 7.0));
        float2 shift = float2((1.5 + 6.0 * burst) * px.x, 0.0);
        rgb.r = scene.sample(s, uv + shift).r;
        rgb.b = scene.sample(s, uv - shift).b;
        rgb += (cmdy_effect_hash(uv * u.resolution + u.time * 60.0) - 0.5) * 0.10;
        // Rare full-frame luma jump.
        if (cmdy_effect_hash(float2(tick, 3.0)) > 0.96) { rgb *= 1.25; }
    }
    if (mode == 9) {
        // Energy feedback: the wavefront glows, fast typing electrifies the
        // whole frame with chroma split + brightness.
        float2 pos = uv * u.resolution;
        float dist = distance(pos, u.cursor);
        float radius = u.keypressAge * 1400.0;
        float wave = exp(-abs(dist - radius) / 28.0) * exp(-u.keypressAge * 2.2);
        float energy = clamp(u.typingRate / 8.0, 0.0, 1.0);
        float2 split = float2((0.6 + 3.0 * energy) * px.x, 0.0);
        rgb.r = scene.sample(s, uv + split * (1.0 + wave * 4.0)).r;
        rgb.b = scene.sample(s, uv - split * (1.0 + wave * 4.0)).b;
        rgb += wave * (0.10 + 0.35 * energy);                  // wavefront glow
        float aura = exp(-dist / 140.0) * (0.05 + 0.20 * energy);
        rgb += aura;                                           // cursor heat
    }

    // ---- The game-intro pack: rich animated backgrounds that mask
    // themselves behind text (same recipe as plasma), plus responsive bits.

    if (mode == 10) {
        // Copper bars: sine-drifting horizontal color bands (Amiga demo boot).
        float3 fx = float3(0.0);
        for (int i = 0; i < 5; i++) {
            float fi = float(i);
            float center = 0.5 + 0.42 * sin(u.time * (0.55 + fi * 0.13) + fi * 1.9);
            float bar = exp(-abs(uv.y - center) * 34.0);
            fx += cmdy_effect_palette(fi * 0.17 + u.time * 0.05) * bar * 0.6;
        }
        float mask = cmdy_effect_textMask(rgb, u.background.rgb);
        rgb = mix(u.background.rgb + fx, rgb, mask);
    }
    if (mode == 11) {
        // Starfield: three parallax layers streaming past; typing = warp.
        float warp = 1.0 + clamp(u.typingRate / 5.0, 0.0, 2.0);
        float3 stars = float3(0.0);
        for (int layer = 1; layer <= 3; layer++) {
            float depth = float(layer);
            float2 p = uv * u.resolution;
            p.x += u.time * 26.0 * depth * warp;
            float2 cell = floor(p / 26.0);
            float2 f = fract(p / 26.0) - 0.5;
            float h = cmdy_effect_hash(cell + depth * 17.0);
            float2 off = (float2(cmdy_effect_hash(cell + 3.1), cmdy_effect_hash(cell + 9.7)) - 0.5) * 0.8;
            float star = smoothstep(0.09, 0.0, length(f - off)) * step(0.80, h);
            // warp streaks: stretch bright stars horizontally as speed rises
            float streak = smoothstep(0.5, 0.0, abs(f.y - off.y)) *
                           smoothstep(0.5, 0.0, abs(f.x - off.x) / (1.0 + warp)) * step(0.93, h);
            stars += (star + streak * 0.6 * (warp - 1.0)) * (0.35 + 0.65 * h) / depth;
        }
        float mask = cmdy_effect_textMask(rgb, u.background.rgb);
        rgb = mix(u.background.rgb + stars, rgb, mask);
    }
    if (mode == 12) {
        // Matrix rain: per-column falling heads with fading trails.
        float2 pixel = uv * u.resolution;
        float colw = 14.0;
        float column = floor(pixel.x / colw);
        float speed = 70.0 + 110.0 * cmdy_effect_hash(float2(column, 1.0));
        float head = fmod(u.time * speed + cmdy_effect_hash(float2(column, 5.0)) * 2000.0,
                          u.resolution.y + 400.0) - 200.0;
        float dist = head - pixel.y;
        float trail = dist > 0.0 ? exp(-dist / 170.0) : (dist > -8.0 ? 1.5 : 0.0);
        float flicker = step(0.3, cmdy_effect_hash(floor(pixel / float2(colw, 20.0)) + floor(u.time * 8.0)));
        float3 rain = float3(0.15, 1.0, 0.35) * trail * flicker * 0.55;
        float mask = cmdy_effect_textMask(rgb, u.background.rgb);
        rgb = mix(u.background.rgb + rain, rgb, mask);
    }
    if (mode == 13) {
        // Fire: procedural flames licking up from the bottom edge.
        float base = smoothstep(0.55, 1.02, uv.y);
        float2 q = float2(uv.x * u.resolution.x / 90.0, uv.y * 6.0 - u.time * 2.2);
        float n = 0.0, amp = 0.5;
        for (int i = 0; i < 4; i++) {
            n += amp * sin(q.x * (1.0 + float(i)) + sin(q.y * (1.3 + float(i)) + u.time * (0.8 + 0.3 * float(i))));
            amp *= 0.55;
            q *= 1.9;
        }
        float heat = clamp(base * (0.65 + 0.5 * n), 0.0, 1.0);
        float3 fire = float3(1.1, 0.42, 0.06) * heat + float3(1.0, 0.9, 0.35) * pow(heat, 3.0);
        float mask = cmdy_effect_textMask(rgb, u.background.rgb);
        rgb = mix(u.background.rgb + fire * 0.6, rgb, mask);
    }
    if (mode == 14) {
        // Synthwave horizon: perspective grid rushing in + striped sun.
        float3 fx = float3(0.0);
        float horizon = 0.60;
        if (uv.y > horizon) {
            float d = (uv.y - horizon) / (1.0 - horizon);
            float z = 1.0 / max(d, 0.02);
            float xw = (uv.x - 0.5) * z * 2.0;
            // grid lines live at cell boundaries (fract ≈ 0/1 → |fract-0.5| ≈ 0.5)
            float lineX = smoothstep(0.42, 0.49, abs(fract(xw) - 0.5));
            float lineZ = smoothstep(0.42, 0.49, abs(fract(z * 1.5 + u.time * 2.4) - 0.5));
            fx = float3(0.85, 0.2, 0.9) * clamp(lineX + lineZ, 0.0, 1.0) * d * 1.1;
        } else {
            // Aspect-corrected so the sun is a circle in any window shape.
            float aspect = u.resolution.x / u.resolution.y;
            float2 sunC = float2(0.5, horizon - 0.15);
            float sd = length((uv - sunC) * float2(aspect, 1.0));
            float sun = smoothstep(0.145, 0.135, sd);
            float cut = step(0.45, fract(uv.y * 46.0));      // venetian stripes
            sun *= mix(1.0, cut, smoothstep(sunC.y - 0.02, sunC.y + 0.1, uv.y));
            fx = mix(float3(1.0, 0.75, 0.2), float3(1.0, 0.3, 0.55),
                     clamp((uv.y - sunC.y) * 6.0 + 0.5, 0.0, 1.0)) * sun;
        }
        float mask = cmdy_effect_textMask(rgb, u.background.rgb);
        rgb = mix(u.background.rgb + fx * 0.55, rgb, mask);
    }
    if (mode == 15) {
        // Tunnel: the classic angle/1-r mapping, rotating and rushing inward.
        float2 p = uv - 0.5;
        p.x *= u.resolution.x / u.resolution.y;
        float ang = atan2(p.y, p.x);
        float rad = length(p) + 0.0001;
        float stripes = sin(8.0 * ang + u.time * 0.6) * sin(6.28318 * (0.35 / rad - u.time * 0.9));
        float shade = clamp(0.5 + 0.5 * stripes, 0.0, 1.0) * smoothstep(0.02, 0.30, rad);
        float3 tun = cmdy_effect_palette(0.55 + 0.1 * sin(u.time * 0.2)) * shade * min(rad * 1.6, 1.0);
        float mask = cmdy_effect_textMask(rgb, u.background.rgb);
        rgb = mix(u.background.rgb + tun * 0.45, rgb, mask);
    }
    if (mode == 16) {
        // Rotozoom: rotating checkerboard; typing energy pumps the zoom.
        float a = u.time * 0.35;
        float zoom = 1.5 + 0.6 * sin(u.time * 0.5) + clamp(u.typingRate / 6.0, 0.0, 1.2);
        float2 p = (uv - 0.5) * u.resolution / 60.0 * zoom;
        float2 rp = float2(p.x * cos(a) - p.y * sin(a), p.x * sin(a) + p.y * cos(a));
        float checker = step(0.0, sin(rp.x * 3.14159) * sin(rp.y * 3.14159));
        float3 board = mix(cmdy_effect_palette(u.time * 0.02), cmdy_effect_palette(u.time * 0.02 + 0.45), checker);
        float mask = cmdy_effect_textMask(rgb, u.background.rgb);
        rgb = mix(mix(u.background.rgb, board, 0.30), rgb, mask);
    }
    if (mode == 18) {
        // Aurora: slow sine curtains breathing along the top of the screen.
        float3 fx = float3(0.0);
        for (int i = 0; i < 3; i++) {
            float fi = float(i);
            float sway = sin(uv.x * (2.2 + fi) + u.time * (0.25 + 0.1 * fi) + fi * 2.0) * 0.12;
            float d = abs(uv.y - (0.14 + 0.10 * fi + sway));
            fx += float3(0.10, 0.85 - 0.18 * fi, 0.55 + 0.15 * fi) * exp(-d * 16.0) * 0.5;
        }
        float mask = cmdy_effect_textMask(rgb, u.background.rgb);
        rgb = mix(u.background.rgb + fx, rgb, mask);
    }
    if (mode == 19) {
        // Lava lamp: five drifting metaballs with hot rims.
        float field = 0.0;
        for (int i = 0; i < 5; i++) {
            float fi = float(i) * 1.7;
            float2 bp = float2(0.5 + 0.36 * sin(u.time * (0.21 + 0.05 * fi) + fi * 2.3),
                               0.5 + 0.36 * cos(u.time * (0.17 + 0.04 * fi) + fi * 1.7));
            float2 d = (uv - bp) * float2(u.resolution.x / u.resolution.y, 1.0);
            field += 0.014 / max(dot(d, d), 0.0006);
        }
        float body = smoothstep(0.9, 1.4, field);
        float rim = smoothstep(0.85, 1.0, field) - smoothstep(1.15, 1.6, field);
        float3 lava = float3(0.85, 0.22, 0.05) * body + float3(1.0, 0.7, 0.2) * rim;
        float mask = cmdy_effect_textMask(rgb, u.background.rgb);
        rgb = mix(u.background.rgb + lava * 0.55, rgb, mask);
    }
    if (mode == 20) {
        // Boot: a slow ambient raster beam, plus a fast one on every keypress.
        float ambient = fract(u.time / 5.0);
        float beam = exp(-abs(uv.y - ambient) * 60.0) * 0.20;
        float sweep = u.keypressAge * 2.5;                    // top→bottom in 0.4s
        if (sweep < 1.2) {
            beam += exp(-abs(uv.y - sweep) * 40.0) * 0.55 * exp(-u.keypressAge * 1.5);
        }
        rgb += beam * (u.background.rgb * 0.4 + 0.6);
        rgb *= 1.0 + 0.010 * sin(u.time * 120.0);
    }
    if (mode == 21) {
        // Snow: the set detunes while you idle — static + a rolling hum bar
        // grow after a few quiet seconds; typing snaps it clean again.
        float idle = smoothstep(1.5, 8.0, u.keypressAge);
        float n = cmdy_effect_hash(uv * u.resolution + fract(u.time) * 371.0);
        rgb += (n - 0.5) * (0.02 + 0.30 * idle);
        rgb += exp(-abs(fract(uv.y - u.time * 0.11) - 0.5) * 30.0) * 0.06 * idle;
    }

    // ---- Pack two. Geometry is computed in square units (`sq`, aspect-
    // corrected, origin at center) or device pixels — never raw uv — so
    // nothing stretches with the window shape.
    if (mode >= 22) {
        float aspect = u.resolution.x / u.resolution.y;
        float2 sq = (uv - 0.5) * float2(aspect, 1.0);
        float2 pp = uv * u.resolution;
        float mask = cmdy_effect_textMask(rgb, u.background.rgb);
        float3 fx = float3(0.0);

        if (mode == 22) {
            // Bubbles: hollow soda bubbles wobbling upward, with a specular dot.
            for (int i = 0; i < 7; i++) {
                float fi = float(i);
                float2 bp = float2((cmdy_effect_hash(float2(fi, 2.0)) - 0.5) * aspect * 0.9,
                                   0.62 - fract(u.time * (0.05 + 0.05 * cmdy_effect_hash(float2(fi, 5.0))) + fi * 0.37) * 1.25);
                bp.x += sin(u.time * 0.8 + fi * 1.7) * 0.02;
                float r = 0.018 + 0.035 * cmdy_effect_hash(float2(fi, 9.0));
                float d = length(sq - bp);
                float ring = smoothstep(r, r * 0.86, d) - smoothstep(r * 0.72, r * 0.5, d);
                float spec = smoothstep(r * 0.28, 0.0, length(sq - bp + float2(r, r) * 0.35));
                fx += (ring * 0.45 + spec * 0.5) * float3(0.55, 0.8, 1.0);
            }
        }
        if (mode == 23) {
            // Rain: slanted streaks in thin pixel columns.
            float2 rp = float2(pp.x - pp.y * 0.12, pp.y);
            float colr = floor(rp.x / 4.0);
            float fall = fract(rp.y / u.resolution.y
                               - u.time * (0.8 + 0.7 * cmdy_effect_hash(float2(colr, 1.0)))
                               + cmdy_effect_hash(float2(colr, 3.0)));
            float streak = smoothstep(0.14, 0.0, fall) * step(0.75, cmdy_effect_hash(float2(colr, 7.0)));
            fx = float3(0.45, 0.6, 0.9) * streak * 0.45;
        }
        if (mode == 24) {
            // Tron: neon triangle lattice with an energy pulse racing across.
            float2 p = sq * 7.0;
            float l1 = smoothstep(0.44, 0.49, abs(fract(p.y) - 0.5));
            float l2 = smoothstep(0.44, 0.49, abs(fract(p.x * 0.866 + p.y * 0.5) - 0.5));
            float l3 = smoothstep(0.44, 0.49, abs(fract(p.x * 0.866 - p.y * 0.5) - 0.5));
            float g = max(l1, max(l2, l3));
            float pulse = 0.45 + 0.55 * pow(0.5 + 0.5 * sin(u.time * 2.0 - (p.x + p.y) * 0.8), 3.0);
            fx = float3(0.15, 0.85, 0.95) * g * pulse * 0.4;
        }
        if (mode == 25) {
            // Radar: a rotating sweep with afterglow and hash blips.
            float ang = atan2(sq.y, sq.x);
            float rad = length(sq);
            float sweep = fmod(u.time * 1.2, 6.28318);
            float da = fmod(sweep - ang + 6.28318, 6.28318);
            float trail = exp(-da * 2.2) * smoothstep(0.5, 0.45, rad);
            float rings = smoothstep(0.010, 0.004, abs(fract(rad * 8.0) - 0.5) * 0.125);
            float blipT = floor(u.time / 3.0);
            float2 blip = (float2(cmdy_effect_hash(float2(blipT, 1.0)), cmdy_effect_hash(float2(blipT, 2.0))) - 0.5) * 0.8;
            float b = exp(-length(sq - blip) * 60.0) * exp(-fract(u.time / 3.0) * 3.0) * 2.0;
            fx = float3(0.2, 0.9, 0.4) * (trail * 0.5 + rings * 0.10 + b);
        }
        if (mode == 26) {
            // Maze: 10 PRINT CHR$(205.5+RND(1)); — the C64 one-liner, glowing.
            float2 cell = floor(pp / 26.0);
            float2 f = fract(pp / 26.0);
            float dir = step(0.5, cmdy_effect_hash(cell));
            float d = mix(abs(f.x + f.y - 1.0), abs(f.x - f.y), dir);
            float lineM = smoothstep(0.16, 0.06, d);
            float pulse = 0.5 + 0.5 * sin(u.time * 1.2 - (cell.x + cell.y) * 0.25);
            fx = float3(0.35, 0.85, 0.65) * lineM * (0.25 + 0.45 * pulse);
        }
        if (mode == 27) {
            // Waves: layered ocean swell across the lower third.
            for (int i = 0; i < 3; i++) {
                float fi = float(i);
                float yl = 0.72 + 0.07 * fi
                         + 0.022 * sin(pp.x / (70.0 - 12.0 * fi) + u.time * (0.9 + 0.35 * fi) + fi * 2.0);
                float body = smoothstep(yl, yl + 0.015, uv.y) * (0.16 + 0.10 * fi);
                float crest = exp(-abs(uv.y - yl) * 220.0) * 0.35;
                fx += float3(0.10, 0.35, 0.75) * body + float3(0.5, 0.8, 1.0) * crest;
            }
        }
        if (mode == 28) {
            // Plexus: drifting nodes, linked when close — network constellations.
            float2 pt[6];
            for (int i = 0; i < 6; i++) {
                float fi = float(i);
                pt[i] = float2(sin(u.time * (0.13 + 0.05 * fi) + fi * 2.1) * 0.42 * aspect,
                               cos(u.time * (0.11 + 0.04 * fi) + fi * 1.3) * 0.40);
                fx += float3(0.6, 0.8, 1.0) * exp(-length(sq - pt[i]) * 90.0) * 0.8;
            }
            for (int i = 0; i < 6; i++) {
                for (int j = i + 1; j < 6; j++) {
                    float2 a = pt[i], b = pt[j], ab = b - a;
                    float linkLen = length(ab);
                    if (linkLen < 0.55) {
                        float t = clamp(dot(sq - a, ab) / dot(ab, ab), 0.0, 1.0);
                        float d = length(sq - (a + ab * t));
                        fx += float3(0.4, 0.6, 0.9) * exp(-d * 260.0) * (1.0 - linkLen / 0.55) * 0.5;
                    }
                }
            }
        }
        if (mode == 29) {
            // Vortex: a three-armed spiral galaxy slowly turning.
            float rad = length(sq) + 0.0001;
            float a2 = atan2(sq.y, sq.x) + 2.2 / (rad + 0.25) - u.time * 0.35;
            float arm = pow(0.5 + 0.5 * sin(a2 * 3.0), 2.0);
            float core = exp(-rad * 5.0) * 0.8;
            fx = (cmdy_effect_palette(0.68 + rad * 0.25) * arm * exp(-rad * 1.8) + core) * 0.55;
        }
        if (mode == 30) {
            // Blocks: chunky colored tiles raining down sparse columns.
            float tile = 20.0;
            float2 cell = floor(pp / tile);
            float colx = cell.x;
            float rows = u.resolution.y / tile;
            float yq = floor(fract(u.time * (0.10 + 0.14 * cmdy_effect_hash(float2(colx, 1.0)))
                                   + cmdy_effect_hash(float2(colx, 3.0))) * (rows + 8.0)) - 4.0;
            float hit = step(abs(cell.y - yq), 1.0) * step(0.55, cmdy_effect_hash(float2(colx, 7.0)));
            float2 f = fract(pp / tile);
            float inset = step(0.10, f.x) * step(f.x, 0.90) * step(0.10, f.y) * step(f.y, 0.90);
            fx = cmdy_effect_palette(cmdy_effect_hash(float2(colx, 9.0)) * 0.9) * hit * inset * 0.5;
        }
        if (mode == 31) {
            // Lightning: a jagged bolt every few seconds + full-frame flash.
            float tick = floor(u.time / 3.5);
            float phase = fract(u.time / 3.5);
            float energy = exp(-phase * 14.0) * (0.5 + 0.5 * cmdy_effect_hash(float2(tick, 2.0)))
                         * (0.7 + 0.3 * sin(u.time * 90.0));
            if (energy > 0.01) {
                float bx = (cmdy_effect_hash(float2(tick, 1.0)) - 0.5) * aspect * 0.8;
                float seg = floor(uv.y * 10.0);
                float jag = (cmdy_effect_hash(float2(seg, tick)) - 0.5) * 0.22
                          + (cmdy_effect_hash(float2(seg * 3.0, tick)) - 0.5) * 0.08;
                float d = abs(sq.x - (bx + jag));
                fx += float3(0.85, 0.85, 1.0) * (exp(-d * 90.0) * 1.6 + 0.12) * energy;
            }
        }

        rgb = mix(u.background.rgb + fx, rgb, mask);
    }

    // ---- Pack three: crack groups, BBS, demoscene floors.
    if (mode >= 32) {
        float aspect = u.resolution.x / u.resolution.y;
        float2 sq = (uv - 0.5) * float2(aspect, 1.0);
        float2 pp = uv * u.resolution;
        float mask = cmdy_effect_textMask(rgb, u.background.rgb);
        float3 fx = float3(0.0);

        if (mode == 32) {
            // Sine scroller: "CMDY " waves across the lower band in rainbow
            // pixels, spelled from a 5x7 font packed as column bitmasks
            // (bit0 = top row), retained pixel-for-pixel from the Cmdy-authored effect.
            // Eight packed glyph cells, including the trailing spacer.
            const uint colsCMDY[40] = {
                0x01,0x01,0x7F,0x01,0x01,   // glyph 0
                0x7F,0x49,0x49,0x49,0x41,   // glyph 1
                0x7F,0x09,0x19,0x29,0x46,   // glyph 2
                0x7F,0x02,0x0C,0x02,0x7F,   // glyph 3
                0x00,0x41,0x7F,0x41,0x00,   // glyph 4
                0x01,0x01,0x7F,0x01,0x01,   // glyph 5
                0x7F,0x49,0x49,0x49,0x41,   // glyph 6
                0x00,0x00,0x00,0x00,0x00,   // spacer
            };
            float px = 7.0;                             // logical pixel, device px
            float scroll = u.time * 26.0;               // columns/sec
            float colF = (pp.x / px + scroll);
            int colTotal = int(floor(colF));
            int stream = colTotal % 48;                 // 8 glyphs * (5+1) cols
            if (stream < 0) { stream += 48; }
            int glyphIx = stream / 6;
            int glyphCol = stream % 6;
            float baseY = u.resolution.y * 0.72
                        + sin(colF * 0.18 + u.time * 2.0) * u.resolution.y * 0.10;
            float rowF = (pp.y - baseY) / px + 3.5;
            int row = int(floor(rowF));
            if (glyphCol < 5 && row >= 0 && row < 7) {
                uint bits = colsCMDY[glyphIx * 5 + glyphCol];
                if ((bits >> uint(row)) & 1u) {
                    fx = cmdy_effect_palette(fract(colF * 0.02 + u.time * 0.1)) * 1.1;
                }
            }
        }
        if (mode == 33) {
            // Raster bars: hard-edged bright bands bouncing at staggered phases.
            for (int i = 0; i < 6; i++) {
                float fi = float(i);
                float center = 0.5 + 0.40 * sin(u.time * 1.1 + fi * 0.9);
                float d = abs(uv.y - center);
                float band = smoothstep(0.030, 0.028, d);
                float shade = 1.0 - abs(uv.y - center) / 0.030;         // inner gradient
                fx = max(fx, cmdy_effect_palette(fi * 0.13) * band * (0.35 + 0.45 * shade));
            }
        }
        if (mode == 34) {
            // ANSI/BBS mosaic: half-block cells quantized to the EGA sixteen.
            const float3 ega[16] = {
                float3(0,0,0), float3(0,0,0.67), float3(0,0.67,0), float3(0,0.67,0.67),
                float3(0.67,0,0), float3(0.67,0,0.67), float3(0.67,0.33,0), float3(0.67,0.67,0.67),
                float3(0.33,0.33,0.33), float3(0.33,0.33,1), float3(0.33,1,0.33), float3(0.33,1,1),
                float3(1,0.33,0.33), float3(1,0.33,1), float3(1,1,0.33), float3(1,1,1)
            };
            float2 cell = floor(pp / float2(9.0, 9.0));                 // half-block grid
            float v = sin(cell.x * 0.35 + u.time * 0.7) + sin(cell.y * 0.41 - u.time * 0.5)
                    + sin((cell.x + cell.y) * 0.23 + u.time * 0.3);
            int idx = int(fract(v * 0.16 + 0.5) * 15.99);
            fx = ega[idx] * 0.30;
        }
        if (mode == 35) {
            // Checker floor: the infinite scrolling perspective plane.
            float horizon = 0.55;
            if (uv.y > horizon) {
                float d = (uv.y - horizon) / (1.0 - horizon);
                float z = 1.0 / max(d, 0.02);
                float xw = sq.x * z * 1.6;
                float zw = z * 2.0 + u.time * 4.0;
                float checker = step(0.0, sin(xw * 3.14159) * sin(zw * 3.14159));
                fx = mix(float3(0.06, 0.05, 0.20), float3(0.55, 0.20, 0.75), checker) * d * 0.8;
            }
        }
        if (mode == 36) {
            // Twister: a twisting square column, drawn per-row from 4 rotating
            // edges (the classic effect, parked right of center).
            float ang = u.time * 1.2 + uv.y * 6.0 + sin(u.time * 0.7 + uv.y * 2.0);
            float cx = 0.22 * aspect;                                    // column center (sq space)
            float w = 0.11;
            float e0 = sin(ang) * w, e1 = sin(ang + 1.5708) * w;
            float e2 = sin(ang + 3.14159) * w, e3 = sin(ang + 4.7124) * w;
            float x = sq.x - cx;
            // faces between consecutive edges; shade by face
            if (x > min(e0, e1) && x < max(e0, e1)) { fx = cmdy_effect_palette(0.62) * (0.35 + 0.3 * fract(ang / 6.28)); }
            else if (x > min(e1, e2) && x < max(e1, e2)) { fx = cmdy_effect_palette(0.70) * 0.45; }
            else if (x > min(e2, e3) && x < max(e2, e3)) { fx = cmdy_effect_palette(0.78) * 0.35; }
            else if (x > min(e3, e0) && x < max(e3, e0)) { fx = cmdy_effect_palette(0.86) * 0.5; }
        }
        if (mode == 37) {
            // Moiré: two drifting ring sources interfering.
            float2 a = float2(sin(u.time * 0.31), cos(u.time * 0.23)) * 0.25;
            float2 b = float2(cos(u.time * 0.27), sin(u.time * 0.19)) * 0.25;
            float ra = sin(length(sq - a) * 90.0);
            float rb = sin(length(sq - b) * 90.0);
            float m = ra * rb;
            fx = cmdy_effect_palette(0.55 + m * 0.08) * smoothstep(0.2, 1.0, m) * 0.4;
        }

        rgb = mix(u.background.rgb + fx, rgb, mask);
    }

    // ---- Pack four: the calm set. Everything here whispers — small fx
    // magnitudes, glacial clocks, theme-anchored color. Meant to be lived
    // with for hours, not demoed for minutes.
    if (mode >= 38) {
        float aspect = u.resolution.x / u.resolution.y;
        float2 sq = (uv - 0.5) * float2(aspect, 1.0);
        float2 pp = uv * u.resolution;
        float mask = cmdy_effect_textMask(rgb, u.background.rgb);
        float3 fx = float3(0.0);

        if (mode == 38) {
            // Drift: two color fields folding over each other, barely moving.
            float n = cmdy_effect_fbm(sq * 1.3 + float2(u.time * 0.020, -u.time * 0.012));
            float m = cmdy_effect_fbm(sq * 1.3 - float2(u.time * 0.016, u.time * 0.010) + 5.2);
            fx = float3(0.05, 0.07, 0.14) * n + float3(0.10, 0.05, 0.12) * m;
        }
        if (mode == 39) {
            // Breath: an 8-second inhale/exhale; idling deepens the breath,
            // typing steadies it back down.
            float calm = clamp(u.keypressAge / 10.0, 0.0, 1.0);
            float b = 0.5 + 0.5 * sin(u.time * 0.785);
            b = b * b * (3.0 - 2.0 * b);
            float vign = 1.0 - dot(sq, sq) * 0.9;
            fx = (u.background.rgb * 0.5 + float3(0.03, 0.04, 0.06))
               * b * (0.05 + 0.11 * calm) * vign;
        }
        if (mode == 40) {
            // Lagoon: caustic light webs on a pool floor.
            float2 p = sq * 5.0;
            float t = u.time * 0.35;
            float ca = sin(p.x + sin(p.y + t)) * sin(p.y + sin(p.x - t * 0.8));
            float web = pow(clamp(1.0 - abs(ca), 0.0, 1.0), 6.0);
            fx = float3(0.05, 0.20, 0.22) * web * (0.6 + 0.4 * sin(t + p.x * 0.3));
            fx += float3(0.0, 0.03, 0.04) * (1.0 - uv.y) * 0.6;
        }
        if (mode == 41) {
            // Silk: three translucent ribbons swaying.
            for (int i = 0; i < 3; i++) {
                float fi = float(i);
                float y = sq.y + sin(sq.x * (1.6 + fi * 0.5) + u.time * (0.12 + fi * 0.05) + fi * 2.1) * 0.18;
                float band = exp(-abs(y - (fi - 1.0) * 0.16) * 9.0);
                fx += float3(0.09, 0.06, 0.13) * band * (0.5 + fi * 0.22);
            }
        }
        if (mode == 42) {
            // Ember: sparse warm motes rising, winking.
            for (int layer = 0; layer < 2; layer++) {
                float fl = float(layer);
                float scale = 26.0 - fl * 9.0;
                float2 g = float2(uv.x * aspect, uv.y + u.time * (0.020 + fl * 0.012)) * scale;
                float2 cell = floor(g), f = fract(g);
                float h = cmdy_effect_hash(cell + fl * 51.0);
                if (h > 0.93) {
                    float2 c = float2(cmdy_effect_hash(cell + 1.7), cmdy_effect_hash(cell + 3.1)) * 0.6 + 0.2;
                    float d = length(f - c);
                    float tw = 0.6 + 0.4 * sin(u.time * (1.0 + h * 3.0) + h * 40.0);
                    fx += float3(0.30, 0.12, 0.03) * exp(-d * 14.0) * tw * (0.5 + fl * 0.5);
                }
            }
        }
        if (mode == 43) {
            // Fireflies: wandering points that blink in soft green-gold.
            float2 g = float2(uv.x * aspect, uv.y) * 7.0;
            float2 cell = floor(g);
            float h = cmdy_effect_hash(cell);
            if (h > 0.72) {
                float2 wander = float2(sin(u.time * (0.15 + h * 0.2) + h * 31.0),
                                       cos(u.time * (0.11 + h * 0.25) + h * 17.0)) * 0.32 + 0.5;
                float d = length(fract(g) - wander);
                float blink = smoothstep(0.35, 1.0, sin(u.time * (0.5 + h) + h * 90.0) * 0.5 + 0.5);
                fx += float3(0.17, 0.23, 0.08) * exp(-d * 18.0) * blink;
            }
        }
        if (mode == 44) {
            // Clouds: a pale bank crossing at stratus pace.
            float n = cmdy_effect_fbm(float2(sq.x * 1.1 + u.time * 0.012, sq.y * 2.2));
            float cloud = smoothstep(0.45, 0.75, n);
            fx = float3(0.10, 0.11, 0.13) * cloud * (0.6 + 0.4 * n);
        }
        if (mode == 45) {
            // Mist: ground fog breathing along the bottom.
            float ground = smoothstep(0.45, 1.0, uv.y);
            float n = cmdy_effect_fbm(float2(sq.x * 2.0 + u.time * 0.03, uv.y * 3.0 - u.time * 0.008));
            fx = float3(0.09, 0.10, 0.12) * ground * (0.35 + 0.65 * n);
        }
        if (mode == 46) {
            // Deep: abyssal gradient, a sonar ring every nine seconds.
            fx = float3(0.0, 0.02, 0.06) * (1.0 - uv.y);
            float tick = floor(u.time / 9.0);
            float ph = fract(u.time / 9.0);
            float2 src = float2((cmdy_effect_hash(float2(tick, 4.0)) - 0.5) * aspect * 0.7,
                                (cmdy_effect_hash(float2(tick, 8.0)) - 0.5) * 0.7);
            float ring = exp(-abs(length(sq - src) - ph * 0.9) * 26.0) * exp(-ph * 3.0);
            fx += float3(0.04, 0.10, 0.12) * ring;
        }
        if (mode == 47) {
            // Tide: a waterline breathing at two-thirds height.
            float line = 0.68 + sin(u.time * 0.18) * 0.05 + sin(sq.x * 2.4 + u.time * 0.5) * 0.012;
            float below = smoothstep(line, line + 0.02, uv.y);
            fx = float3(0.03, 0.08, 0.11) * below * (1.0 - (uv.y - line) * 0.8);
            float foam = exp(-abs(uv.y - line) * 120.0) * (0.5 + 0.5 * sin(sq.x * 40.0 + u.time * 1.2));
            fx += float3(0.09, 0.11, 0.12) * foam * 0.6;
        }
        if (mode == 48) {
            // Zen: raked sand around two slowly orbiting stones.
            float2 c1 = float2(sin(u.time * 0.05) * 0.15, cos(u.time * 0.037) * 0.10);
            float rings = sin(length(sq - c1) * 42.0 - u.time * 0.15);
            fx = float3(0.055) * smoothstep(0.2, 0.9, rings);
            float rings2 = sin(length(sq + c1 * 1.6) * 42.0 + u.time * 0.10);
            fx = max(fx, float3(0.045) * smoothstep(0.3, 0.9, rings2));
        }
        if (mode == 49) {
            // Lanterns: five paper lanterns climbing on staggered loops.
            for (int i = 0; i < 5; i++) {
                float fi = float(i);
                float seed = fi * 13.7;
                float y = fract(cmdy_effect_hash(float2(fi, 5.0)) - u.time * (0.014 + cmdy_effect_hash(float2(fi, 2.0)) * 0.012));
                float x = (cmdy_effect_hash(float2(fi, 9.0)) - 0.5) * aspect * 0.9 + sin(u.time * 0.2 + seed) * 0.03;
                float2 d = sq - float2(x, y - 0.5);
                float glow = exp(-dot(d, d) * 90.0);
                float warm = 0.55 + 0.45 * sin(u.time * 0.8 + seed);
                fx += float3(0.28, 0.15, 0.05) * glow * (0.45 + 0.30 * warm);
            }
        }
        if (mode == 50) {
            // Snowfall: three parallax layers of unhurried flakes.
            for (int layer = 0; layer < 3; layer++) {
                float fl = float(layer);
                float scale = 14.0 + fl * 10.0;
                float2 g = float2(uv.x * aspect + sin(uv.y * 2.0 + u.time * 0.2 + fl) * 0.01,
                                  uv.y - u.time * (0.030 - fl * 0.008)) * scale;
                float2 cell = floor(g), f = fract(g);
                float h = cmdy_effect_hash(cell + fl * 91.0);
                if (h > 0.80) {
                    float2 c = float2(cmdy_effect_hash(cell + 1.3), cmdy_effect_hash(cell + 7.7)) * 0.5 + 0.25;
                    c.x += sin(u.time * (0.4 + h) + h * 20.0) * 0.08;
                    float d = length(f - c);
                    fx += float3(0.15, 0.16, 0.18) * exp(-d * 20.0) * (1.0 - fl * 0.25);
                }
            }
        }
        if (mode == 51) {
            // Petals: pink flecks drifting down-wind with a sway.
            float2 g = float2(uv.x * aspect - u.time * 0.008, uv.y - u.time * 0.020) * 9.0;
            float2 cell = floor(g), f = fract(g);
            float h = cmdy_effect_hash(cell);
            if (h > 0.78) {
                float2 c = float2(cmdy_effect_hash(cell + 2.2), cmdy_effect_hash(cell + 6.4)) * 0.5 + 0.25;
                c += float2(sin(u.time * 0.6 + h * 50.0), cos(u.time * 0.45 + h * 30.0)) * 0.06;
                float2 d = (f - c) * float2(1.0, 1.6);
                fx += float3(0.20, 0.09, 0.11) * exp(-dot(d, d) * 60.0);
            }
        }
        if (mode == 52) {
            // Koi: three blurred bodies gliding under frosted ice.
            for (int i = 0; i < 3; i++) {
                float fi = float(i);
                float2 path = float2(sin(u.time * 0.09 + fi * 2.4) * 0.32 * aspect,
                                     sin(u.time * 0.13 + fi * 4.1 + 1.2) * 0.30);
                float2 vel = float2(cos(u.time * 0.09 + fi * 2.4) * 0.09,
                                    cos(u.time * 0.13 + fi * 4.1 + 1.2) * 0.13);
                float2 dirv = vel / max(length(vel), 0.001);
                float2 rel = sq - path;
                float2 lo = float2(dot(rel, dirv), dot(rel, float2(-dirv.y, dirv.x))) * float2(3.2, 9.0);
                float body = exp(-dot(lo, lo) * 4.0);
                fx += mix(float3(0.28, 0.14, 0.05), float3(0.22, 0.20, 0.18), fract(fi * 0.618)) * body * 0.8;
            }
        }
        if (mode == 53) {
            // Moss: green mottle creeping at lichen speed.
            float n = cmdy_effect_fbm(sq * 3.2 + float2(0.0, u.time * 0.004));
            float n2 = cmdy_effect_fbm(sq * 8.6 + 13.1 - float2(u.time * 0.006, 0.0));
            float mossy = smoothstep(0.42, 0.72, n * 0.65 + n2 * 0.35);
            fx = float3(0.04, 0.11, 0.05) * mossy * (0.5 + n2 * 0.5);
        }
        if (mode == 54) {
            // Dunes: layered silhouettes with crest light.
            for (int i = 0; i < 3; i++) {
                float fi = float(i);
                float depth = 1.0 - fi * 0.28;
                float ridge = 0.55 + fi * 0.13
                            + sin(sq.x * (1.2 + fi * 0.8) + fi * 7.0 + u.time * (0.02 + fi * 0.01)) * 0.06
                            + sin(sq.x * (2.7 + fi) + fi * 3.0) * 0.025;
                float under = smoothstep(ridge, ridge + 0.01, uv.y);
                fx = mix(fx, float3(0.15, 0.10, 0.05) * (0.4 + 0.6 * depth), under * 0.85);
                fx += float3(0.05, 0.03, 0.01) * exp(-abs(uv.y - ridge) * 90.0) * depth;
            }
        }
        if (mode == 55) {
            // Horizon: a dawn whose mood shifts over three minutes.
            float hue = u.time / 180.0;
            float3 low = cmdy_effect_palette(hue) * float3(0.5, 0.35, 0.30) * 0.5;
            float3 high = cmdy_effect_palette(hue + 0.45) * 0.18;
            fx = mix(high, low, smoothstep(0.15, 0.95, uv.y)) * 0.7;
            float d = length(sq - float2(0.0, 0.32));
            fx += cmdy_effect_palette(hue) * exp(-d * 9.0) * 0.10;
        }
        if (mode == 56) {
            // Rainfall: trails sliding down window glass.
            float2 g = float2(uv.x * aspect * 22.0, uv.y);
            float colId = floor(g.x);
            float h = cmdy_effect_hash(float2(colId, 5.0));
            if (h > 0.45) {
                float phase = fract(u.time * (0.035 + h * 0.05) + h * 9.0 - uv.y * (0.8 + h * 0.4));
                float streak = exp(-phase * 9.0);
                float lat = exp(-abs(fract(g.x) - 0.5) * 7.0);
                fx += float3(0.09, 0.11, 0.14) * streak * lat * 0.8;
            }
        }
        if (mode == 57) {
            // Nebula: slow-turning gas, a few dim stars.
            float ang = u.time * 0.01;
            float2 rp = float2(sq.x * cos(ang) - sq.y * sin(ang),
                               sq.x * sin(ang) + sq.y * cos(ang));
            float n = cmdy_effect_fbm(rp * 2.2 + 3.7);
            float n2 = cmdy_effect_fbm(rp * 4.4 - 1.3);
            fx = float3(0.13, 0.05, 0.15) * smoothstep(0.35, 0.80, n)
               + float3(0.04, 0.06, 0.15) * smoothstep(0.40, 0.85, n2) * 0.8;
            float sh = cmdy_effect_hash(floor(pp / 3.0));
            if (sh > 0.9975) { fx += float3(0.45) * (0.4 + 0.3 * sin(u.time + sh * 99.0)); }
        }
        if (mode == 58) {
            // Comet: one soft visitor crosses the upper sky every ~17s.
            float ph = fract(u.time / 17.0);
            if (ph < 0.28) {
                float tick = floor(u.time / 17.0);
                float tp = ph / 0.28;
                float2 a = float2(-0.62 * aspect, -0.42 + cmdy_effect_hash(float2(tick, 1.0)) * 0.5);
                float2 b = float2( 0.62 * aspect, -0.30 + cmdy_effect_hash(float2(tick, 2.0)) * 0.4);
                float2 head = mix(a, b, tp);
                float2 dirv = (b - a) / max(length(b - a), 0.001);
                float2 rel = sq - head;
                float along = dot(rel, dirv);
                float side = dot(rel, float2(-dirv.y, dirv.x));
                float tail = exp(along * 7.0) * step(along, 0.0) * exp(-side * side * 400.0);
                float headGlow = exp(-dot(rel, rel) * 700.0);
                float fade = sin(tp * 3.14159);
                fx += (float3(0.32, 0.35, 0.42) * headGlow + float3(0.11, 0.13, 0.19) * tail) * fade;
            }
        }
        if (mode == 59) {
            // Meadow: ground glow and pollen adrift.
            fx = float3(0.03, 0.09, 0.03) * smoothstep(0.55, 1.05, uv.y);
            float2 g = float2(uv.x * aspect + sin(u.time * 0.05) * 0.02, uv.y + u.time * 0.006) * 12.0;
            float2 cell = floor(g), f = fract(g);
            float h = cmdy_effect_hash(cell + 40.0);
            if (h > 0.86) {
                float2 c = 0.3 + 0.4 * float2(cmdy_effect_hash(cell + 3.0), cmdy_effect_hash(cell + 9.0));
                c += float2(sin(u.time * 0.5 + h * 60.0), cos(u.time * 0.4 + h * 80.0)) * 0.08;
                fx += float3(0.15, 0.14, 0.07) * exp(-length(f - c) * 26.0);
            }
        }
        if (mode == 60) {
            // Ink: blots bloom and dissolve.
            for (int i = 0; i < 2; i++) {
                float fi = float(i);
                float period = 7.0 + fi * 3.0;
                float tick = floor(u.time / period + fi * 0.5);
                float ph = fract(u.time / period + fi * 0.5);
                float2 c = float2((cmdy_effect_hash(float2(tick, fi + 1.0)) - 0.5) * aspect * 0.8,
                                  (cmdy_effect_hash(float2(tick, fi + 5.0)) - 0.5) * 0.8);
                float rad = sqrt(ph) * 0.5;
                float d = length(sq - c);
                float edge = exp(-abs(d - rad) * 26.0);
                float body = smoothstep(rad, rad * 0.2, d) * 0.5;
                fx += float3(0.10, 0.10, 0.12) * (edge * 0.8 + body * 0.4) * (1.0 - ph);
            }
        }
        if (mode == 61) {
            // Marble: veins wandering through warped stone.
            float2 p = sq * 3.0;
            float warp = cmdy_effect_fbm(p * 1.5 + u.time * 0.006);
            float vein = sin(p.x * 2.0 + p.y * 1.2 + warp * 5.0);
            fx = float3(0.10, 0.10, 0.11) * pow(1.0 - abs(vein), 5.0) * 0.8 + float3(0.02) * warp;
        }
        if (mode == 62) {
            // Prism: one faint shaft, spectrum-fringed, slowly swinging.
            float ang = 0.7 + sin(u.time * 0.03) * 0.15;
            float2 dirv = float2(cos(ang), sin(ang));
            float side = dot(sq - float2(-0.5 * aspect, -0.5), float2(-dirv.y, dirv.x));
            float beam = exp(-side * side * 60.0);
            float3 spectrum = cmdy_effect_palette(clamp(side * 2.0 + 0.5, 0.0, 1.0) * 0.8);
            fx = (float3(0.09, 0.09, 0.10) + spectrum * 0.09) * beam;
        }
        if (mode == 63) {
            // Halo: a breathing glow that follows the cursor.
            float2 cq = (u.cursor / u.resolution - 0.5) * float2(aspect, 1.0);
            float d = length(sq - cq);
            float breathe = 0.85 + 0.15 * sin(u.time * 0.6);
            float typing = clamp(u.typingRate / 6.0, 0.0, 1.0);
            fx = float3(0.09, 0.10, 0.14) * exp(-d * (5.5 - typing * 1.5)) * breathe;
        }
        if (mode == 64) {
            // Waterline: the scene reflects in water along the bottom edge.
            float yl = 0.82;
            if (uv.y > yl) {
                float depth = (uv.y - yl) / (1.0 - yl);
                float wob = sin(pp.x * 0.05 + u.time * 1.1) * 0.004 * depth
                          + sin(pp.x * 0.013 - u.time * 0.7) * 0.006 * depth;
                float3 refl = scene.sample(s, float2(uv.x + wob, 2.0 * yl - uv.y)).rgb;
                fx = (refl - u.background.rgb) * (1.0 - depth) * 0.35;
                fx += float3(0.01, 0.02, 0.03) * depth;
            }
        }
        if (mode == 65) {
            // Slowscan: a luminous band sweeps down every twelve seconds.
            float y = fract(u.time / 12.0) * 1.3 - 0.15;
            float d = uv.y - y;
            float lead = exp(-abs(d) * 60.0);
            float trail = exp(-max(-d, 0.0) * 9.0) * 0.5;
            fx = float3(0.07, 0.10, 0.09) * (lead + trail * 0.5);
        }
        if (mode == 66) {
            // Voronoi: drifting cells, edges barely glowing.
            float2 g = sq * 4.0 + float2(u.time * 0.015, 0.0);
            float2 cell = floor(g), f = fract(g);
            float f1 = 8.0, f2 = 8.0;
            for (int yy = -1; yy <= 1; yy++) {
                for (int xx = -1; xx <= 1; xx++) {
                    float2 nb = float2(xx, yy);
                    float2 pt = nb + 0.5
                              + 0.35 * float2(sin(u.time * 0.12 + cmdy_effect_hash(cell + nb) * 6.28),
                                              cos(u.time * 0.10 + cmdy_effect_hash(cell + nb + 3.3) * 6.28));
                    float d = length(pt - f);
                    if (d < f1) { f2 = f1; f1 = d; } else if (d < f2) { f2 = d; }
                }
            }
            fx = float3(0.06, 0.08, 0.10) * exp(-(f2 - f1) * 9.0)
               + float3(0.02, 0.03, 0.04) * (1.0 - f1);
        }
        if (mode == 67) {
            // Eclipse: a dark disc, corona breathing, upper right.
            float2 c = float2(aspect * 0.30, -0.26);
            float d = length(sq - c);
            float rad = 0.16;
            float corona = exp(-max(d - rad, 0.0) * (9.0 - sin(u.time * 0.3) * 2.0));
            float disc = smoothstep(rad, rad - 0.01, d);
            fx = float3(0.26, 0.15, 0.07) * corona * (1.0 - disc) * 0.8
               - u.background.rgb * disc * 0.35;
        }

        rgb = mix(u.background.rgb + fx, rgb, mask);
    }

    return float4(rgb, col.a);
}
"""#
}
