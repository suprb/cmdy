import Foundation
import XCTest
@testable import CmdyKit

final class PluginCredentialTests: XCTestCase {
    func testServerDrainsConcurrentConnectionBurst() async throws {
        let server = LocalHTTPServer()
        server.route("GET", "/ping") { _ in .ok(["ok": true]) }
        server.start(preferredPort: 49_220)
        defer { server.stop() }
        XCTAssertGreaterThan(server.port, 0)

        let token = UUID().uuidString
        server.registerPluginCredential(token, id: "dev.cmdy.burst", name: "Burst")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 48
        configuration.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let port = server.port

        let statuses = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
            for index in 0..<48 {
                group.addTask {
                    var request = URLRequest(url: URL(
                        string: "http://127.0.0.1:\(port)/ping?request=\(index)")!)
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    do {
                        let (_, response) = try await session.data(for: request)
                        return (response as? HTTPURLResponse)?.statusCode ?? 0
                    } catch {
                        return -1
                    }
                }
            }
            var results: [Int] = []
            for await status in group { results.append(status) }
            return results
        }
        XCTAssertEqual(statuses.count, 48)
        XCTAssertEqual(statuses.filter { $0 == 200 }.count, 48)
    }

    func testPluginCredentialCarriesOwnershipAndRevokesExactly() async throws {
        let server = LocalHTTPServer()
        server.backgroundRoute("GET", "/identity") { request in
            .ok([
                "owner": request.pluginOwner.map { $0 as Any } ?? NSNull(),
                "id": request.pluginID.map { $0 as Any } ?? NSNull(),
                "name": request.pluginName.map { $0 as Any } ?? NSNull(),
                "capabilities": request.extensionCapabilities?.map(\.rawValue).sorted() ?? [],
            ])
        }
        server.streamRoute("/events", capability: .events)
        server.start(preferredPort: 49_200)
        defer { server.stop() }
        XCTAssertGreaterThan(server.port, 0)

        let token = UUID().uuidString
        let authenticated = expectation(description: "per-launch credential reports readiness")
        server.onPluginAuthenticated = { owner in
            XCTAssertEqual(owner, token)
            authenticated.fulfill()
        }
        server.registerPluginCredential(token, id: "dev.cmdy.test", name: "Test",
                                        capabilities: [.panesRead])

        let owned = try await get(port: server.port, token: token)
        await fulfillment(of: [authenticated], timeout: 1)
        server.onPluginAuthenticated = nil
        XCTAssertEqual(owned.status, 200)
        XCTAssertEqual(owned.json["owner"] as? String, token)
        XCTAssertEqual(owned.json["id"] as? String, "dev.cmdy.test")
        XCTAssertEqual(owned.json["name"] as? String, "Test")
        XCTAssertEqual(owned.json["capabilities"] as? [String], ["panes.read"])

        let deniedStream = try await get(port: server.port, token: token, path: "/events")
        XCTAssertEqual(deniedStream.status, 403)

        let nearMatch = try await get(port: server.port, token: token + "-wrong")
        XCTAssertEqual(nearMatch.status, 401)

        let discovery = try await get(port: server.port, token: server.authToken)
        XCTAssertEqual(discovery.status, 200)
        XCTAssertTrue(discovery.json["owner"] is NSNull)

        server.revokePluginCredential(token)
        let revoked = try await get(port: server.port, token: token)
        XCTAssertEqual(revoked.status, 401)
    }

    private func get(port: Int, token: String, path: String = "/identity") async throws
        -> (status: Int, json: [String: Any]) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.timeoutInterval = 3
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (status, json)
    }
}
