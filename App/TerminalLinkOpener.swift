import AppKit
import Foundation
import ProductIdentity
import CmdyKit

/// Opens Command-clicked terminal links in the Browser sidecar attached to
/// the originating Cmdy window. If Browser is unavailable, fall back to
/// the user's normal macOS URL handler.
enum TerminalLinkOpener {
    private static let discoveryURL = ProductIdentity.current
        .configurationDirectory().appendingPathComponent("browser-api.json")

    static func open(_ url: URL, windowNumber: Int?) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let data = try? BoundedFileReader.data(
                at: discoveryURL, maxBytes: 64 * 1024),
              let discovery = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = discovery["port"] as? Int,
              let token = discovery["token"] as? String,
              (1...65_535).contains(port),
              !token.isEmpty, token.count <= 4_096,
              let endpoint = URL(string: "http://127.0.0.1:\(port)/execute") else {
            NSWorkspace.shared.open(url)
            return
        }

        var body: [String: Any] = [
            "tool": "navigate",
            "arguments": ["url": url.absoluteString],
        ]
        if let windowNumber, windowNumber > 0 { body["window"] = windowNumber }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, response, error in
            let okStatus = (response as? HTTPURLResponse)?.statusCode == 200
            let payload = data.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            let opened = error == nil && okStatus && payload?["error"] == nil
            guard !opened else { return }
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }.resume()
    }
}
