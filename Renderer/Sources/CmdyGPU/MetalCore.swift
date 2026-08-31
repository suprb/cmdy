import AppKit
import Foundation
import Metal
import MetalKit

public enum MetalError: Error, CustomStringConvertible, Sendable {
    case metalKitUnavailable
    case deviceUnavailable
    case commandQueueUnavailable
    case atlasUnavailable
    case shaderLibraryMissing
    case shaderLibraryLoadFailed(String)
    case shaderFunctionMissing(String)
    case shaderSourceMissing(String)
    case shaderCompilationFailed(String)
    case pipelineCreationFailed(String)
    case samplerUnavailable

    public var description: String {
        switch self {
        case .metalKitUnavailable: "MetalKit is unavailable"
        case .deviceUnavailable: "No compatible Metal device is available"
        case .commandQueueUnavailable: "Unable to create a Metal command queue"
        case .atlasUnavailable: "Unable to allocate compatibility glyph storage"
        case .shaderLibraryMissing: "The renderer shader library is missing"
        case .shaderLibraryLoadFailed(let reason): "Unable to load renderer shaders: \(reason)"
        case .shaderFunctionMissing(let name): "Renderer shader function is missing: \(name)"
        case .shaderSourceMissing(let name): "Renderer shader source is missing: \(name)"
        case .shaderCompilationFailed(let reason): "Shader compilation failed: \(reason)"
        case .pipelineCreationFailed(let reason): "Pipeline creation failed: \(reason)"
        case .samplerUnavailable: "Unable to create a Metal texture sampler"
        }
    }
}

struct IndependentQuadVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
    var color: SIMD4<Float>
}

struct IndependentRasterUniforms {
    var resolution: SIMD2<Float>
    var coveragePower: Float
    var databloomEnergy: Float
}

struct IndependentCmdyUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var curvature: Float
    var background: SIMD4<Float>
    var cursor: SIMD2<Float>
    var keypressAge: Float
    var typingRate: Float
    var opacity: Float
    var passIndex: UInt32
    var padding: SIMD2<UInt32> = .zero
}

final class IndependentSharedCore {
    let commandQueue: MTLCommandQueue
    let solidPipeline: MTLRenderPipelineState
    let coveragePipeline: MTLRenderPipelineState
    let imagePipeline: MTLRenderPipelineState
    let postPipeline: MTLRenderPipelineState
    let builtInEffects: CmdyBuiltInEffectPipelines
    let linearSampler: MTLSamplerState
    let nearestSampler: MTLSamplerState

    init(device: MTLDevice, pixelFormat: MTLPixelFormat,
         sampleCount: Int) throws {
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalError.commandQueueUnavailable
        }
        self.commandQueue = commandQueue

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: IndependentMetalSource.core,
                                             options: nil)
        } catch {
            throw MetalError.shaderLibraryLoadFailed(error.localizedDescription)
        }
        guard let vertex = library.makeFunction(name: "cmdy_independent_vertex") else {
            throw MetalError.shaderFunctionMissing("cmdy_independent_vertex")
        }
        solidPipeline = try Self.makePipeline(
            device: device, vertex: vertex,
            fragment: library.makeFunction(name: "cmdy_independent_solid"),
            fragmentName: "cmdy_independent_solid", pixelFormat: pixelFormat,
            sampleCount: sampleCount, premultiplied: false)
        coveragePipeline = try Self.makePipeline(
            device: device, vertex: vertex,
            fragment: library.makeFunction(name: "cmdy_independent_coverage"),
            fragmentName: "cmdy_independent_coverage", pixelFormat: pixelFormat,
            sampleCount: sampleCount, premultiplied: true)
        imagePipeline = try Self.makePipeline(
            device: device, vertex: vertex,
            fragment: library.makeFunction(name: "cmdy_independent_image"),
            fragmentName: "cmdy_independent_image", pixelFormat: pixelFormat,
            sampleCount: sampleCount, premultiplied: true)
        postPipeline = try Self.makePipeline(
            device: device, vertex: vertex,
            fragment: library.makeFunction(name: "cmdy_independent_post"),
            fragmentName: "cmdy_independent_post", pixelFormat: pixelFormat,
            sampleCount: sampleCount, premultiplied: true,
            blending: false)
        do {
            builtInEffects = try CmdyBuiltInEffectShaders.makePipelines(
                device: device, pixelFormat: pixelFormat,
                sampleCount: sampleCount)
        } catch {
            throw MetalError.pipelineCreationFailed(error.localizedDescription)
        }

        let linear = MTLSamplerDescriptor()
        linear.minFilter = .linear
        linear.magFilter = .linear
        linear.sAddressMode = .clampToEdge
        linear.tAddressMode = .clampToEdge
        guard let linearSampler = device.makeSamplerState(descriptor: linear) else {
            throw MetalError.samplerUnavailable
        }
        self.linearSampler = linearSampler

        let nearest = MTLSamplerDescriptor()
        nearest.minFilter = .nearest
        nearest.magFilter = .nearest
        nearest.sAddressMode = .clampToEdge
        nearest.tAddressMode = .clampToEdge
        guard let nearestSampler = device.makeSamplerState(descriptor: nearest) else {
            throw MetalError.samplerUnavailable
        }
        self.nearestSampler = nearestSampler
    }

    private static func makePipeline(
        device: MTLDevice,
        vertex: MTLFunction,
        fragment: MTLFunction?,
        fragmentName: String,
        pixelFormat: MTLPixelFormat,
        sampleCount: Int,
        premultiplied: Bool,
        blending: Bool = true
    ) throws -> MTLRenderPipelineState {
        guard let fragment else {
            throw MetalError.shaderFunctionMissing(fragmentName)
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "cmdy independent \(fragmentName)"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.rasterSampleCount = max(1, sampleCount)
        if blending {
            let attachment = descriptor.colorAttachments[0]!
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = premultiplied ? .one : .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw MetalError.pipelineCreationFailed(error.localizedDescription)
        }
    }
}

enum IndependentMetalSource {
    static let core = #"""
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
    """#

    static let userWrapper = #"""

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
        return cmdy_main(in.uv, sceneColor, u, scene, smp);
    }
    """#
}
