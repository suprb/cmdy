import CoreGraphics
import Foundation
import XCTest
@testable import sim

final class SimAPIMirrorTests: XCTestCase {
    func testMirrorForwardsWindowAndDeviceToSessionOwner() async throws {
        let api = SimAPI()
        var receivedWindow: CGWindowID?
        var receivedDevice: String?
        api.startMirror = { windowNumber, device in
            receivedWindow = windowNumber
            receivedDevice = device
            return [
                "success": true,
                "window": Int(windowNumber ?? 0),
                "port": 3204,
            ]
        }

        let result = try await execute(
            api, tool: "mirror",
            arguments: ["device": "iPhone 16 Pro"],
            windowNumber: 404)

        XCTAssertEqual(receivedWindow, 404)
        XCTAssertEqual(receivedDevice, "iPhone 16 Pro")
        XCTAssertEqual(result["window"] as? Int, 404)
        XCTAssertEqual(result["port"] as? Int, 3204)
    }

    func testMirrorStopTargetsOneWindowUnlessAllWasRequested() async throws {
        let api = SimAPI()
        var received: [(CGWindowID?, Bool)] = []
        api.stopMirror = { windowNumber, all in
            received.append((windowNumber, all))
            return ["success": true]
        }

        _ = try await execute(
            api, tool: "mirror_stop", arguments: [:], windowNumber: 101)
        _ = try await execute(
            api, tool: "mirror_stop",
            arguments: ["all": true], windowNumber: 202)

        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0].0, 101)
        XCTAssertFalse(received[0].1)
        XCTAssertEqual(received[1].0, 202)
        XCTAssertTrue(received[1].1)
    }

    private func execute(
        _ api: SimAPI,
        tool: String,
        arguments: [String: Any],
        windowNumber: CGWindowID
    ) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: [
            "tool": tool,
            "arguments": arguments,
            "window": Int(windowNumber),
        ])
        let request = SimHTTPServer.Request(
            method: "POST", path: "/execute", body: body)
        return try await withCheckedThrowingContinuation { continuation in
            api.routeForTesting(request) { status, payload in
                guard status == 200,
                      let envelope = payload as? [String: Any] else {
                    continuation.resume(throwing: MirrorRouteError.invalidResponse)
                    return
                }
                if let message = envelope["error"] as? String {
                    continuation.resume(throwing: MirrorRouteError.tool(message))
                    return
                }
                guard let result = envelope["result"] as? [String: Any] else {
                    continuation.resume(throwing: MirrorRouteError.invalidResponse)
                    return
                }
                continuation.resume(returning: result)
            }
        }
    }
}

private enum MirrorRouteError: Error {
    case invalidResponse
    case tool(String)
}
