import Metal
import CmdyNative

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

    static var metalSource: String { String(cString: cmdy_gpu_shader_source(1)) }

    static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        var error = [CChar](repeating: 0, count: 4096)
        guard let pointer = cmdy_gpu_shader_library(Unmanaged.passUnretained(device as AnyObject).toOpaque(), 1, &error, error.count) else {
            throw MetalError.shaderCompilationFailed(String(cString: error))
        }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue() as! MTLLibrary
    }

    static func makePipelines(device: MTLDevice, pixelFormat: MTLPixelFormat, sampleCount: Int = 1) throws -> CmdyBuiltInEffectPipelines {
        func pipeline(glyph: UInt8) throws -> MTLRenderPipelineState {
            var error = [CChar](repeating: 0, count: 4096)
            guard let pointer = cmdy_gpu_effect_pipeline(Unmanaged.passUnretained(device as AnyObject).toOpaque(), UInt64(pixelFormat.rawValue), sampleCount, glyph, &error, error.count) else {
                throw MetalError.pipelineCreationFailed(String(cString: error))
            }
            return Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue() as! MTLRenderPipelineState
        }
        return try CmdyBuiltInEffectPipelines(scenePostprocess: pipeline(glyph: 0), databloomGlyph: pipeline(glyph: 1))
    }
}
