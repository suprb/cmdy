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

import CmdyNative

enum IndependentMetalSource {
    static var core: String { String(cString: cmdy_gpu_shader_source(0)) }
    static var userWrapper: String { String(cString: cmdy_gpu_shader_source(3)) }
}
