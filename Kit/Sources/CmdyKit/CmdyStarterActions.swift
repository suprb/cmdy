import Foundation

public struct CmdyStarterAction: Equatable, Sendable {
    public let id: String
    public let folderName: String
    public let title: String
    public let description: String
    fileprivate let manifestJSON: String
}

public struct CmdyStarterActionInstallResult: Equatable, Sendable {
    public let installed: [CmdyStarterAction]
    public let skipped: [CmdyStarterAction]
}

extension CmdyActionCatalog {
    /// Useful, non-destructive examples that exercise the real Action model.
    /// They are opt-in and installed as ordinary personal Actions so users can
    /// inspect, edit, or delete every line after installation.
    public static let starterActions: [CmdyStarterAction] = [
        CmdyStarterAction(
            id: "personal.cc",
            folderName: "cc",
            title: "cc — Continue Claude",
            description: "Continue the latest Claude conversation for this directory",
            manifestJSON: #"""
            {
              "manifestVersion": 1,
              "id": "personal.cc",
              "title": "cc — Continue Claude",
              "description": "Continue the latest Claude conversation for this directory",
              "group": "Agents",
              "command": "claude --continue",
              "pane": "focused",
              "mode": "run",
              "cwd": "focused",
              "guide": {
                "whatItDoes": [
                  "Starts Claude and continues the most recent conversation associated with the focused directory."
                ],
                "safety": [
                  "Runs visibly in the focused pane and keeps Claude's normal permission controls."
                ],
                "setup": [
                  "Requires the Claude CLI and an existing conversation for the current directory."
                ]
              }
            }
            """#),
        CmdyStarterAction(
            id: "personal.project-pulse",
            folderName: "project-pulse",
            title: "Project Pulse",
            description: "Open a live-sized snapshot of repository state and recent history",
            manifestJSON: #"""
            {
              "manifestVersion": 1,
              "id": "personal.project-pulse",
              "title": "Project Pulse",
              "description": "Open a snapshot of repository state and recent history",
              "group": "Project",
              "steps": [
                {
                  "command": "/bin/sh -c 'if /usr/bin/git rev-parse --is-inside-work-tree >/dev/null 2>&1; then printf \"PROJECT PULSE\\n\\n\"; /usr/bin/git status --short --branch; printf \"\\nCHANGED FILES\\n\\n\"; /usr/bin/git diff --stat; else printf \"Not inside a Git worktree.\\n\"; fi'",
                  "pane": "right",
                  "mode": "run",
                  "cwd": "project"
                },
                {
                  "command": "/bin/sh -c 'if /usr/bin/git rev-parse --is-inside-work-tree >/dev/null 2>&1; then printf \"RECENT HISTORY\\n\\n\"; /usr/bin/git log --graph --decorate --oneline -20; else printf \"Not inside a Git worktree.\\n\"; fi'",
                  "pane": "down",
                  "mode": "run",
                  "cwd": "project"
                }
              ],
              "whenFiles": [".git"],
              "guide": {
                "whatItDoes": [
                  "Opens a right split with branch, status, and diff statistics, plus a lower split with the last 20 commits."
                ],
                "safety": [
                  "Runs read-only Git status, diff-stat, and log commands; it does not modify the repository or contact a remote."
                ],
                "setup": [
                  "Appears only inside a Git project."
                ]
              }
            }
            """#),
        CmdyStarterAction(
            id: "personal.local-preview",
            folderName: "local-preview",
            title: "Local Preview",
            description: "Serve the focused folder on loopback and open it in the browser",
            manifestJSON: #"""
            {
              "manifestVersion": 1,
              "id": "personal.local-preview",
              "title": "Local Preview",
              "description": "Serve the focused folder on loopback and open it in the browser",
              "group": "Project",
              "confirmation": "Serve files from {{cwd}} at http://127.0.0.1:{{input.port}}?",
              "inputs": [
                {
                  "id": "port",
                  "label": "Port",
                  "kind": "text",
                  "default": "8000",
                  "required": true
                }
              ],
              "steps": [
                {
                  "command": "/usr/bin/python3 -m http.server {{input.port}} --bind 127.0.0.1",
                  "pane": "right",
                  "mode": "run",
                  "cwd": "focused"
                },
                {
                  "command": "/usr/bin/open http://127.0.0.1:{{input.port}}",
                  "pane": "focused",
                  "mode": "run",
                  "cwd": "focused"
                }
              ],
              "guide": {
                "whatItDoes": [
                  "Starts Python's static file server in a right split, bound to loopback, then opens the selected port in your default browser."
                ],
                "safety": [
                  "Serves the entire focused directory to this Mac only; it does not bind to the local network. Stop the server with Control-C."
                ],
                "setup": [
                  "Requires /usr/bin/python3 and a free local port; the default is 8000."
                ]
              }
            }
            """#),
        CmdyStarterAction(
            id: "personal.port-watch",
            folderName: "port-watch",
            title: "Port Watch",
            description: "Watch listening TCP ports in a dedicated split",
            manifestJSON: #"""
            {
              "manifestVersion": 1,
              "id": "personal.port-watch",
              "title": "Port Watch",
              "description": "Watch listening TCP ports in a dedicated split",
              "group": "System",
              "command": "/bin/sh -c 'while :; do clear; date \"+%Y-%m-%d %H:%M:%S\"; printf \"\\nLISTENING TCP PORTS\\n\\n\"; /usr/sbin/lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null || true; sleep 2; done'",
              "pane": "right",
              "mode": "run",
              "cwd": "focused",
              "guide": {
                "whatItDoes": [
                  "Opens a right split and refreshes the processes listening on TCP ports every two seconds."
                ],
                "safety": [
                  "Reads the local process and socket table only; it opens no connection and changes no process. Stop it with Control-C."
                ],
                "setup": [
                  "Uses the lsof tool included with macOS."
                ]
              }
            }
            """#),
        CmdyStarterAction(
            id: "personal.copy-handoff",
            folderName: "copy-handoff",
            title: "Copy Handoff Note",
            description: "Copy a concise repository handoff to the clipboard",
            manifestJSON: #"""
            {
              "manifestVersion": 1,
              "id": "personal.copy-handoff",
              "title": "Copy Handoff Note",
              "description": "Copy a concise repository handoff to the clipboard",
              "group": "Project",
              "confirmation": "Replace the clipboard with a project handoff for {{cwd}}?",
              "command": "/bin/sh -c '{ printf \"# Project handoff\\n\\nDirectory: %s\\n\\n\" \"$PWD\"; if /usr/bin/git rev-parse --is-inside-work-tree >/dev/null 2>&1; then printf \"## Branch\\n\\n\"; /usr/bin/git branch --show-current; printf \"\\n## Working tree\\n\\n\"; /usr/bin/git status --short; printf \"\\n## Recent commits\\n\\n\"; /usr/bin/git log -5 --pretty=\"- %h %s\"; printf \"\\n\\n## Diff summary\\n\\n\"; /usr/bin/git diff --stat; else printf \"Not a Git worktree.\\n\"; fi; } | /usr/bin/pbcopy; printf \"Copied a project handoff to the clipboard.\\n\"'",
              "pane": "focused",
              "mode": "run",
              "cwd": "project",
              "guide": {
                "whatItDoes": [
                  "Copies the directory, branch, working-tree status, five recent commits, and diff statistics as a Markdown handoff note."
                ],
                "safety": [
                  "Overwrites the macOS clipboard after confirmation. It includes paths and commit subjects, but not file contents, diff bodies, credentials, or network data."
                ],
                "setup": [
                  "Works best inside a Git project; outside one it copies only the directory and a clear warning."
                ]
              }
            }
            """#),
    ]

    public static func installStarterActions(
        at root: URL = personalDirectory,
        selectedIDs: Set<String>? = nil,
        fileManager: FileManager = .default
    ) throws -> CmdyStarterActionInstallResult {
        let selected = starterActions.filter { selectedIDs?.contains($0.id) ?? true }
        let existingIDs = Set(discover(in: root, fileManager: fileManager).actions.map(\.id))
        var installed: [CmdyStarterAction] = []
        var skipped: [CmdyStarterAction] = []
        var createdDirectories: [URL] = []

        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            for starter in selected {
                let directory = root.appendingPathComponent(starter.folderName, isDirectory: true)
                if existingIDs.contains(starter.id)
                    || fileManager.fileExists(atPath: directory.path) {
                    skipped.append(starter)
                    continue
                }
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
                createdDirectories.append(directory)
                let manifest = directory.appendingPathComponent("action.json")
                try Data(starter.manifestJSON.utf8).write(to: manifest, options: .atomic)
                _ = try load(from: manifest, fileManager: fileManager)
                installed.append(starter)
            }
            return CmdyStarterActionInstallResult(installed: installed, skipped: skipped)
        } catch {
            for directory in createdDirectories.reversed() {
                try? fileManager.removeItem(at: directory)
            }
            throw error
        }
    }
}
