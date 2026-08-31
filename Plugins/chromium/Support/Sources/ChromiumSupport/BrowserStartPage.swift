import Foundation
import CmdySDK

public enum BrowserStartPage {
    public static func install(in directory: String) -> String {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let page = root.appendingPathComponent(
            "\(HostProductIdentity.slug)-start.html")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? html.write(to: page, atomically: true, encoding: .utf8)
        return page.absoluteString
    }

    private static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="color-scheme" content="light">
      <title>\#(HostProductIdentity.titleName)</title>
      <style>
        :root {
          color-scheme: light;
          --bg: #ffffff;
          --text: #232323;
          --muted: #6f6f73;
        }
        * { box-sizing: border-box; }
        html, body { height: 100%; }
        body {
          margin: 0;
          background: var(--bg);
          color: var(--text);
          display: grid;
          place-items: center;
          font: 15px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
          -webkit-font-smoothing: antialiased;
        }
        main {
          margin-top: -1.5vh;
          text-align: center;
          user-select: none;
        }
        .globe {
          position: relative;
          width: 48px;
          height: 48px;
          margin: 0 auto 28px;
          border: 4px solid var(--muted);
          border-radius: 50%;
        }
        .globe::before {
          content: "";
          position: absolute;
          inset: -4px 11px;
          border: 4px solid var(--muted);
          border-top-color: transparent;
          border-bottom-color: transparent;
          border-radius: 50%;
        }
        .globe::after {
          content: "";
          position: absolute;
          left: 0;
          right: 0;
          top: 18px;
          border-top: 4px solid var(--muted);
        }
        h1 {
          margin: 0;
          font-size: 24px;
          font-weight: 600;
          letter-spacing: 0;
        }
        p {
          margin: 22px 0 0;
          color: var(--muted);
          font-size: 19px;
        }
      </style>
    </head>
    <body>
      <main>
        <div class="globe" aria-hidden="true"></div>
        <h1>Start browsing</h1>
        <p>Enter a URL to open a page</p>
      </main>
    </body>
    </html>
    """#
}
