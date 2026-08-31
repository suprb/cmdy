import Foundation

/// Analyzes a project directory to determine type and available commands.
struct ProjectAnalyzer {

    struct ProjectInfo {
        let type: ProjectType
        let name: String
        let commands: [ProjectCommand]
        let hasIndexHtml: Bool
        let isDesktopApp: Bool
    }

    enum ProjectType: String {
        case node = "Node.js"
        case swift = "Swift"
        case python = "Python"
        case rust = "Rust"
        case go = "Go"
        case staticWeb = "Static Web"
        case unknown = "Unknown"
    }

    struct ProjectCommand {
        let name: String
        let command: String
        let description: String
    }

    /// Pick the first runnable command (dev/start/serve/run/runserver). Returns
    /// nil if none qualify — e.g. a Swift package only exposes "build" / "test".
    /// Used by the popover to surface a one-click "Run" affordance per bound session.
    static func primaryRunCommand(for info: ProjectInfo) -> ProjectCommand? {
        let priority = ["dev", "start", "serve", "runserver", "run"]
        for name in priority {
            if let cmd = info.commands.first(where: { $0.name == name }) {
                return cmd
            }
        }
        return nil
    }

    /// Analyze a project directory.
    static func analyze(path: String) -> ProjectInfo {
        let fm = FileManager.default

        var type: ProjectType = .unknown
        var name = (path as NSString).lastPathComponent
        var commands: [ProjectCommand] = []
        var hasIndexHtml = false
        var isDesktopApp = false

        // Check for index.html
        hasIndexHtml = fm.fileExists(atPath: (path as NSString).appendingPathComponent("index.html"))

        // Node.js (package.json)
        let packageJsonPath = (path as NSString).appendingPathComponent("package.json")
        if fm.fileExists(atPath: packageJsonPath) {
            type = .node
            if let data = try? BridgeBoundedFileReader.data(
                    at: URL(fileURLWithPath: packageJsonPath),
                    maxBytes: 1024 * 1024),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                name = (json["name"] as? String) ?? name

                // Check for desktop app
                let deps = (json["dependencies"] as? [String: Any]) ?? [:]
                let devDeps = (json["devDependencies"] as? [String: Any]) ?? [:]
                isDesktopApp = deps["electron"] != nil || devDeps["electron"] != nil
                    || deps["tauri"] != nil || devDeps["tauri"] != nil

                // Extract scripts
                if let scripts = json["scripts"] as? [String: String] {
                    let commandOrder = ["dev", "start", "serve", "build", "test", "lint"]
                    for cmd in commandOrder {
                        if let script = scripts[cmd] {
                            let runner = fm.fileExists(atPath: (path as NSString).appendingPathComponent("bun.lockb")) ? "bun" :
                                         fm.fileExists(atPath: (path as NSString).appendingPathComponent("yarn.lock")) ? "yarn" :
                                         fm.fileExists(atPath: (path as NSString).appendingPathComponent("pnpm-lock.yaml")) ? "pnpm" : "npm"
                            commands.append(ProjectCommand(
                                name: cmd,
                                command: "\(runner) run \(cmd)",
                                description: script
                            ))
                        }
                    }
                }
            }
        }

        // Swift (Package.swift)
        if fm.fileExists(atPath: (path as NSString).appendingPathComponent("Package.swift")) {
            type = .swift
            commands.append(ProjectCommand(name: "build", command: "swift build", description: "Build the package"))
            commands.append(ProjectCommand(name: "run", command: "swift run", description: "Build and run"))
            commands.append(ProjectCommand(name: "test", command: "swift test", description: "Run tests"))
        }

        // Python
        if fm.fileExists(atPath: (path as NSString).appendingPathComponent("requirements.txt"))
            || fm.fileExists(atPath: (path as NSString).appendingPathComponent("pyproject.toml")) {
            type = .python
            if fm.fileExists(atPath: (path as NSString).appendingPathComponent("manage.py")) {
                commands.append(ProjectCommand(name: "runserver", command: "python manage.py runserver", description: "Django dev server"))
            }
            if fm.fileExists(atPath: (path as NSString).appendingPathComponent("app.py")) {
                commands.append(ProjectCommand(name: "run", command: "python app.py", description: "Run Flask app"))
            }
        }

        // Rust (Cargo.toml)
        if fm.fileExists(atPath: (path as NSString).appendingPathComponent("Cargo.toml")) {
            type = .rust
            commands.append(ProjectCommand(name: "build", command: "cargo build", description: "Build the project"))
            commands.append(ProjectCommand(name: "run", command: "cargo run", description: "Build and run"))
            commands.append(ProjectCommand(name: "test", command: "cargo test", description: "Run tests"))
        }

        // Go (go.mod)
        if fm.fileExists(atPath: (path as NSString).appendingPathComponent("go.mod")) {
            type = .go
            commands.append(ProjectCommand(name: "build", command: "go build", description: "Build the project"))
            commands.append(ProjectCommand(name: "run", command: "go run .", description: "Run the project"))
            commands.append(ProjectCommand(name: "test", command: "go test ./...", description: "Run tests"))
        }

        // Static web fallback
        if type == .unknown && hasIndexHtml {
            type = .staticWeb
        }

        return ProjectInfo(
            type: type,
            name: name,
            commands: commands,
            hasIndexHtml: hasIndexHtml,
            isDesktopApp: isDesktopApp
        )
    }
}
