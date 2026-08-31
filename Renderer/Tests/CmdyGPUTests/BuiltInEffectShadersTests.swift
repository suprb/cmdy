import Metal
import XCTest
@testable import CmdyGPU

final class BuiltInEffectShadersTests: XCTestCase {
    func testDescriptorsCoverEveryBuiltInModeExactlyOnce() {
        let descriptors = CmdyBuiltInEffectShaders.descriptors
        XCTAssertEqual(descriptors.count, 68)
        XCTAssertEqual(descriptors.map(\.mode), Array(1...68))
        XCTAssertEqual(Set(descriptors.map(\.mode)).count, 68)
        XCTAssertEqual(Set(descriptors.map(\.name)).count, 68)
    }

    func testModesOneThroughSixtySevenAreScenePostprocessOnly() {
        let scene = CmdyBuiltInEffectShaders.descriptors.filter {
            $0.scope == .scenePostprocess
        }
        XCTAssertEqual(scene.map(\.mode), Array(1...67))
        XCTAssertEqual(CmdyBuiltInEffectShaders.sceneModes, 1...67)

        let source = CmdyBuiltInEffectShaders.metalSource
        for mode in 1...67 {
            XCTAssertNotNil(
                source.range(
                    of: #"mode == \#(mode)\b"#,
                    options: .regularExpression
                ),
                "Missing scene formula for mode \(mode)"
            )
        }
    }

    func testModeSixtyEightIsGlyphOnlyDatabloom() throws {
        let descriptor = try XCTUnwrap(
            CmdyBuiltInEffectShaders.descriptors.first { $0.mode == 68 }
        )
        XCTAssertEqual(descriptor.name, "databloom")
        XCTAssertEqual(descriptor.scope, .glyphCoverage)
        XCTAssertEqual(CmdyBuiltInEffectShaders.databloomMode, 68)
    }

    func testIndependentNamespaceHasNoLegacyShaderSymbols() {
        let source = CmdyBuiltInEffectShaders.metalSource
        let excludedSymbols = [
            "t64_",
            "CRTVaryings",
            "CRTUniforms",
            "crt_vertex",
            "crt_fragment",
            "terminal_atlas_text_fragment_gray_databloom",
            "GlyphOut"
        ]
        for symbol in excludedSymbols {
            XCTAssertFalse(source.contains(symbol), "Found excluded symbol \(symbol)")
        }
    }

    func testDatabloomContractRetainsAllFourControls() {
        let source = CmdyBuiltInEffectShaders.metalSource
        XCTAssertTrue(source.contains("struct CmdyDatabloomUniforms"))
        XCTAssertTrue(source.contains("float energy;"))
        XCTAssertTrue(source.contains("float velocity;"))
        XCTAssertTrue(source.contains("float opacity;"))
        XCTAssertTrue(source.contains("float passIndex;"))
        XCTAssertEqual(MemoryLayout<CmdyDatabloomUniforms>.size, 16)
        XCTAssertEqual(MemoryLayout<CmdyDatabloomUniforms>.stride, 16)
    }

    func testSceneUniformPrefixMatchesMetalLayout() {
        XCTAssertEqual(MemoryLayout<CmdySceneEffectUniforms>.size, 48)
        XCTAssertEqual(MemoryLayout<CmdySceneEffectUniforms>.stride, 48)
    }

    func testAllFunctionsAndBothPipelinesCompile() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try CmdyBuiltInEffectShaders.makeLibrary(device: device)
        let names = [
            CmdyBuiltInEffectShaders.sceneVertexFunction,
            CmdyBuiltInEffectShaders.sceneFragmentFunction,
            CmdyBuiltInEffectShaders.databloomVertexFunction,
            CmdyBuiltInEffectShaders.databloomFragmentFunction
        ]
        for name in names {
            XCTAssertNotNil(library.makeFunction(name: name), name)
        }

        let pipelines = try CmdyBuiltInEffectShaders.makePipelines(
            device: device,
            pixelFormat: .bgra8Unorm_srgb
        )
        XCTAssertEqual(
            pipelines.scenePostprocess.label,
            "Cmdy built-in effect: \(CmdyBuiltInEffectShaders.sceneFragmentFunction)"
        )
        XCTAssertEqual(
            pipelines.databloomGlyph.label,
            "Cmdy built-in effect: \(CmdyBuiltInEffectShaders.databloomFragmentFunction)"
        )
    }
}
