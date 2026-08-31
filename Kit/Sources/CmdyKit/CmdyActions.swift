import Foundation
import ProductIdentity

public enum CmdyActionError: LocalizedError, Equatable {
    case unreadable(String)
    case invalid(String)
    case unsafePath(String)
    case missingEntrypoint(String)
    case missingInput(String)

    public var errorDescription: String? {
        let product = ProductIdentity.current.titleName
        switch self {
        case .unreadable(let path): return "Could not read \(product) Action at \(path)"
        case .invalid(let detail): return "Invalid \(product) Action: \(detail)"
        case .unsafePath(let path): return "\(product) Action path escapes its folder: \(path)"
        case .missingEntrypoint(let path): return "\(product) Action entrypoint is missing: \(path)"
        case .missingInput(let id): return "\(product) Action needs a value for '\(id)'"
        }
    }
}

public struct CmdyActionShortcut: Equatable, Sendable {
    public enum Modifier: String, CaseIterable, Sendable {
        case command, shift, option, control
    }

    public let key: String
    public let modifiers: Set<Modifier>

    public init(_ descriptor: String) throws {
        let parts = descriptor.lowercased().split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parts.count >= 2, let rawKey = parts.last, rawKey.count == 1,
              rawKey.unicodeScalars.allSatisfy({ $0.isASCII }) else {
            throw CmdyActionError.invalid(
                "shortcut '\(descriptor)' must look like cmd+shift+r")
        }
        var parsed = Set<Modifier>()
        for raw in parts.dropLast() {
            let modifier: Modifier?
            switch raw {
            case "cmd", "command": modifier = .command
            case "shift": modifier = .shift
            case "opt", "option", "alt": modifier = .option
            case "ctrl", "control": modifier = .control
            default: modifier = nil
            }
            guard let modifier else {
                throw CmdyActionError.invalid("unknown shortcut modifier '\(raw)'")
            }
            parsed.insert(modifier)
        }
        guard parsed.contains(.command) || parsed.contains(.option)
                || parsed.contains(.control) else {
            throw CmdyActionError.invalid(
                "shortcut '\(descriptor)' needs command, option, or control")
        }
        key = rawKey
        modifiers = parsed
    }

    public var descriptor: String {
        let order: [Modifier] = [.control, .option, .shift, .command]
        let names: [Modifier: String] = [
            .control: "ctrl", .option: "option", .shift: "shift", .command: "cmd",
        ]
        return (order.filter(modifiers.contains).compactMap { names[$0] } + [key])
            .joined(separator: "+")
    }

    public var display: String {
        let symbols: [Modifier: String] = [
            .control: "⌃", .option: "⌥", .shift: "⇧", .command: "⌘",
        ]
        return [Modifier.control, .option, .shift, .command]
            .filter(modifiers.contains).compactMap { symbols[$0] }.joined()
            + key.uppercased()
    }
}

public struct CmdyActionInput: Equatable, Sendable {
    public enum Kind: String, Sendable { case text, secure, toggle, choice }

    public let id: String
    public let label: String
    public let kind: Kind
    public let defaultValue: String?
    public let placeholder: String?
    public let options: [String]
    public let required: Bool
}

public struct CmdyActionStep: Equatable, Sendable {
    public enum Pane: String, Sendable { case focused, right, down }
    public enum Mode: String, Sendable { case run, type }
    public enum WorkingDirectory: String, Sendable { case focused, project, action }

    public let command: String?
    public let entrypoint: String?
    public let pane: Pane
    public let mode: Mode
    public let workingDirectory: WorkingDirectory
}

public struct ResolvedCmdyActionStep: Equatable, Sendable {
    public let pane: CmdyActionStep.Pane
    public let mode: CmdyActionStep.Mode
    public let command: String
}

public struct CmdyActionContext: Equatable, Sendable {
    public let cwd: String
    public let projectRoot: URL?

    public init(cwd: String, projectRoot: URL? = nil) {
        self.cwd = cwd
        self.projectRoot = projectRoot
    }
}

public struct CmdyAction: Equatable, Sendable {
    public enum Scope: Equatable, Sendable { case personal, project(URL) }

    public let manifestVersion: Int
    public let id: String
    public let title: String
    public let description: String
    public let guide: CmdyProductGuide
    public let group: String
    public let shortcut: CmdyActionShortcut?
    public let confirmation: String?
    public let inputs: [CmdyActionInput]
    public let steps: [CmdyActionStep]
    public let whenFiles: [String]
    public let sourceURL: URL
    public let directory: URL
    public let scope: Scope

    public var projectRoot: URL? {
        if case .project(let root) = scope { return root }
        return nil
    }

    public func isAvailable(in context: CmdyActionContext,
                            fileManager: FileManager = .default) -> Bool {
        guard !whenFiles.isEmpty else { return true }
        let root = context.projectRoot ?? URL(fileURLWithPath: context.cwd, isDirectory: true)
        return whenFiles.allSatisfy {
            fileManager.fileExists(atPath: root.appendingPathComponent($0).path)
        }
    }

    public var defaultInputValues: [String: String] {
        Dictionary(uniqueKeysWithValues: inputs.compactMap { input in
            input.defaultValue.map { (input.id, $0) }
        })
    }

    public func resolve(in context: CmdyActionContext,
                        values suppliedValues: [String: String]) throws
        -> [ResolvedCmdyActionStep] {
        let inputIDs = Set(inputs.map(\.id))
        guard suppliedValues.keys.allSatisfy(inputIDs.contains) else {
            let unknown = suppliedValues.keys.filter { !inputIDs.contains($0) }.sorted()
            throw CmdyActionError.invalid(
                "unknown input\(unknown.count == 1 ? "" : "s"): \(unknown.joined(separator: ", "))")
        }
        guard suppliedValues.values.allSatisfy({ $0.utf8.count <= 16 * 1024 }) else {
            throw CmdyActionError.invalid("input values may not exceed 16 KB")
        }
        var values = defaultInputValues
        for (key, value) in suppliedValues { values[key] = value }
        for input in inputs {
            let value = values[input.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if input.required && value.isEmpty { throw CmdyActionError.missingInput(input.id) }
            if input.kind == .choice, !value.isEmpty, !input.options.contains(value) {
                throw CmdyActionError.invalid("'\(value)' is not an option for \(input.id)")
            }
            if input.kind == .toggle, !value.isEmpty,
               !["true", "false", "1", "0", "yes", "no"].contains(value.lowercased()) {
                throw CmdyActionError.invalid("\(input.id) must be true or false")
            }
        }

        let project = context.projectRoot ?? projectRoot
        return try steps.map { step in
            let workingDirectory: URL
            switch step.workingDirectory {
            case .focused: workingDirectory = URL(fileURLWithPath: context.cwd, isDirectory: true)
            case .project:
                workingDirectory = project
                    ?? URL(fileURLWithPath: context.cwd, isDirectory: true)
            case .action: workingDirectory = directory
            }

            let baseCommand: String
            if let command = step.command {
                baseCommand = try render(command, context: context, project: project,
                                         values: values)
            } else if let entrypoint = step.entrypoint {
                baseCommand = try Self.invocation(
                    for: safeEntrypoint(entrypoint), fileManager: .default)
            } else {
                throw CmdyActionError.invalid("a workflow step has no command or entrypoint")
            }

            var environment: [String: String] = [:]
            for prefix in ProductIdentity.current.compatibleEnvironmentPrefixes {
                environment["\(prefix)_ACTION_ID"] = id
                environment["\(prefix)_ACTION_CWD"] = context.cwd
                environment["\(prefix)_ACTION_PROJECT"] = project?.path ?? ""
                environment["\(prefix)_ACTION_SOURCE"] = sourceURL.path
                for input in inputs {
                    environment[
                        "\(prefix)_ACTION_INPUT_\(Self.environmentID(input.id))"] =
                        values[input.id] ?? ""
                }
            }
            let assignments = environment.keys.sorted().map {
                "\($0)=\(Self.shellQuote(environment[$0] ?? ""))"
            }.joined(separator: " ")
            let command = "cd -- \(Self.shellQuote(workingDirectory.path)) && env \(assignments) \(baseCommand)"
            return ResolvedCmdyActionStep(pane: step.pane, mode: step.mode,
                                             command: command)
        }
    }

    private func render(_ template: String, context: CmdyActionContext,
                        project: URL?, values: [String: String]) throws -> String {
        var rendered = template
            .replacingOccurrences(of: "{{cwd}}", with: Self.shellQuote(context.cwd))
            .replacingOccurrences(of: "{{project}}",
                                  with: Self.shellQuote(project?.path ?? context.cwd))
        for input in inputs {
            rendered = rendered.replacingOccurrences(
                of: "{{input.\(input.id)}}",
                with: Self.shellQuote(values[input.id] ?? ""))
        }
        if rendered.contains("{{") || rendered.contains("}}") {
            throw CmdyActionError.invalid("unknown placeholder in '\(template)'")
        }
        return rendered
    }

    private func safeEntrypoint(_ relative: String) throws -> URL {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let candidate = directory.appendingPathComponent(relative).standardizedFileURL
        guard candidate.resolvingSymlinksInPath().path.hasPrefix(root) else {
            throw CmdyActionError.unsafePath(relative)
        }
        return candidate
    }

    nonisolated private static func invocation(for source: URL,
                                               fileManager: FileManager) throws -> String {
        guard fileManager.fileExists(atPath: source.path) else {
            throw CmdyActionError.missingEntrypoint(source.path)
        }
        let quoted = shellQuote(source.path)
        if fileManager.isExecutableFile(atPath: source.path) { return quoted }
        switch source.pathExtension.lowercased() {
        case "sh": return "/bin/sh \(quoted)"
        case "bash": return "/bin/bash \(quoted)"
        case "zsh": return "/bin/zsh \(quoted)"
        case "py": return "/usr/bin/env python3 \(quoted)"
        case "js", "mjs": return "/usr/bin/env node \(quoted)"
        case "swift": return "/usr/bin/env swift \(quoted)"
        default: throw CmdyActionError.missingEntrypoint(
            "\(source.path) is not executable and has no supported interpreter")
        }
    }

    nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated private static func environmentID(_ value: String) -> String {
        String(value.uppercased().map {
            $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_"
        })
    }
}

public struct CmdyActionIssue: Equatable, Sendable {
    public let path: String
    public let message: String
}

public struct CmdyActionDiscovery: Equatable, Sendable {
    public let actions: [CmdyAction]
    public let issues: [CmdyActionIssue]
}

/// Filesystem contract for personal and project Actions. A folder containing
/// `action.json` is the full form; dropping a supported script directly into
/// the Actions directory creates a zero-config, one-shot Action.
public enum CmdyActionCatalog {
    public static var personalDirectory: URL {
        ConfigFile.directory.appendingPathComponent("actions", isDirectory: true)
    }

    public static func discover(in directory: URL,
                                scope: CmdyAction.Scope = .personal,
                                fileManager: FileManager = .default) -> CmdyActionDiscovery {
        guard let children = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else {
            return CmdyActionDiscovery(actions: [], issues: [])
        }
        let resolvedRoot = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        var actions: [CmdyAction] = []
        var issues: [CmdyActionIssue] = []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let resolved = child.standardizedFileURL.resolvingSymlinksInPath().path
                guard resolved.hasPrefix(resolvedRoot) else {
                    throw CmdyActionError.unsafePath(child.path)
                }
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if values.isDirectory == true {
                    let manifest = child.appendingPathComponent("action.json")
                    guard fileManager.fileExists(atPath: manifest.path) else { continue }
                    actions.append(try load(from: manifest, scope: scope, fileManager: fileManager))
                } else if values.isRegularFile == true, child.pathExtension.lowercased() == "json" {
                    actions.append(try load(from: child, scope: scope, fileManager: fileManager))
                } else if values.isRegularFile == true,
                          fileManager.isExecutableFile(atPath: child.path)
                            || supportedScriptExtensions.contains(child.pathExtension.lowercased()) {
                    actions.append(try standaloneScript(child, scope: scope,
                                                        fileManager: fileManager))
                }
            } catch {
                issues.append(CmdyActionIssue(
                    path: child.path, message: error.localizedDescription))
            }
        }
        var seen = Set<String>()
        let unique = actions.filter { seen.insert($0.id).inserted }
        for duplicate in actions where unique.contains(where: { $0.id == duplicate.id
                && $0.sourceURL != duplicate.sourceURL }) {
            issues.append(CmdyActionIssue(
                path: duplicate.sourceURL.path,
                message: "Duplicate \(ProductIdentity.current.titleName) Action id '\(duplicate.id)'"))
        }
        return CmdyActionDiscovery(actions: unique, issues: issues)
    }

    public static func load(from manifestURL: URL,
                            scope: CmdyAction.Scope = .personal,
                            fileManager: FileManager = .default) throws -> CmdyAction {
        let data: Data
        do { data = try BoundedFileReader.data(at: manifestURL, maxBytes: 1024 * 1024) }
        catch { throw CmdyActionError.unreadable(manifestURL.path) }
        let raw: RawManifest
        do { raw = try JSONDecoder().decode(RawManifest.self, from: data) }
        catch { throw CmdyActionError.invalid(error.localizedDescription) }

        let version = raw.manifestVersion ?? 1
        guard version == 1 else {
            throw CmdyActionError.invalid("unsupported manifestVersion \(version)")
        }
        guard let id = raw.id?.trimmingCharacters(in: .whitespacesAndNewlines),
              validID(id) else {
            throw CmdyActionError.invalid("id must use letters, numbers, dots, dashes, or underscores")
        }
        guard let title = raw.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, title.utf8.count <= 160 else {
            throw CmdyActionError.invalid("title is missing or too long")
        }
        let directory = manifestURL.deletingLastPathComponent().standardizedFileURL
        var steps = try (raw.steps ?? []).map { try decodeStep($0) }
        let topLevelSources = [raw.command != nil, raw.entrypoint != nil, !steps.isEmpty]
            .filter { $0 }.count
        guard topLevelSources == 1 else {
            throw CmdyActionError.invalid(
                "provide exactly one of command, entrypoint, or steps")
        }
        if let command = raw.command {
            steps = [try decodeStep(RawStep(
                command: command, entrypoint: nil, pane: raw.pane,
                mode: raw.mode, cwd: raw.cwd))]
        } else if let entrypoint = raw.entrypoint {
            steps = [try decodeStep(RawStep(
                command: nil, entrypoint: entrypoint, pane: raw.pane,
                mode: raw.mode, cwd: raw.cwd))]
        }
        guard !steps.isEmpty, steps.count <= 32 else {
            throw CmdyActionError.invalid("an Action needs 1 to 32 steps")
        }
        try steps.forEach { try validate($0, in: directory, fileManager: fileManager) }

        let inputs = try (raw.inputs ?? []).map { try decodeInput($0) }
        guard inputs.count <= 32, Set(inputs.map(\.id)).count == inputs.count else {
            throw CmdyActionError.invalid("input ids must be unique; at most 32 are allowed")
        }
        let shortcut = try raw.shortcut.map(CmdyActionShortcut.init)
        let whenFiles = raw.whenFiles ?? []
        guard whenFiles.count <= 32, whenFiles.allSatisfy(safeRelativePath) else {
            throw CmdyActionError.invalid("whenFiles must contain safe relative paths")
        }
        let confirmation = raw.confirmation?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let confirmation, confirmation.utf8.count > 512 {
            throw CmdyActionError.invalid("confirmation is too long")
        }
        let description = String((raw.description ?? "").prefix(1_024))
        let guide = actionGuide(
            raw: raw.guide, description: description, steps: steps,
            inputs: inputs, confirmation: confirmation, whenFiles: whenFiles,
            scope: scope)
        return CmdyAction(
            manifestVersion: version, id: id, title: title,
            description: description, guide: guide,
            group: String((raw.group ?? defaultGroup(scope)).prefix(80)),
            shortcut: shortcut, confirmation: confirmation,
            inputs: inputs, steps: steps, whenFiles: whenFiles,
            sourceURL: manifestURL.standardizedFileURL, directory: directory, scope: scope)
    }

    @discardableResult
    public static func createSample(at directory: URL, title: String? = nil,
                                    command: String? = nil,
                                    fileManager: FileManager = .default) throws -> URL {
        guard !fileManager.fileExists(atPath: directory.path) else {
            throw CmdyActionError.invalid("\(directory.path) already exists")
        }
        let rawName = (title ?? humanTitle(directory.lastPathComponent))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawName.isEmpty, rawName.utf8.count <= 160 else {
            throw CmdyActionError.invalid("title is missing or too long")
        }
        if let command {
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  command.utf8.count <= 64 * 1024 else {
                throw CmdyActionError.invalid("a command is empty or exceeds 64 KB")
            }
        }
        let id = safeID(directory.lastPathComponent)
        guard validID(id) else {
            throw CmdyActionError.invalid("could not create a valid Action id")
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var object: [String: Any] = [
                "manifestVersion": 1,
                "id": id,
                "title": rawName,
                "description": command == nil
                    ? "A personal \(ProductIdentity.current.titleName) Action"
                    : "Saved from a terminal command block",
                "group": "Personal",
            ]
            if let command {
                object["command"] = command
                object["mode"] = "run"
            } else {
                object["entrypoint"] = "run.sh"
                object["cwd"] = "focused"
                let actionID = ProductIdentity.current.environmentKey("ACTION_ID")
                let script =
                    "#!/bin/sh\nset -eu\nprintf 'hello from %s\\n' \"$\(actionID)\"\n"
                let scriptURL = directory.appendingPathComponent("run.sh")
                try script.write(to: scriptURL, atomically: true, encoding: .utf8)
                try fileManager.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: scriptURL.path)
            }
            let data = try JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            let manifest = directory.appendingPathComponent("action.json")
            try data.write(to: manifest, options: .atomic)
            return manifest
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    public static func projectDirectory(for root: URL) -> URL {
        let identity = ProductIdentity.current
        let names = [identity.projectDirectoryName]
            + identity.legacyProjectDirectoryNames
        let marker = names.first(where: {
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent($0, isDirectory: true).path)
        }) ?? identity.projectDirectoryName
        return root.appendingPathComponent(marker, isDirectory: true)
            .appendingPathComponent("actions", isDirectory: true)
    }

    private static let supportedScriptExtensions = Set(["sh", "bash", "zsh", "py", "js", "mjs", "swift"])

    private struct RawManifest: Decodable {
        let manifestVersion: Int?
        let id: String?
        let title: String?
        let description: String?
        let guide: RawGuide?
        let group: String?
        let shortcut: String?
        let confirmation: String?
        let command: String?
        let entrypoint: String?
        let pane: String?
        let mode: String?
        let cwd: String?
        let inputs: [RawInput]?
        let steps: [RawStep]?
        let whenFiles: [String]?
    }

    private struct RawGuide: Decodable {
        let whatItDoes: [String]?
        let safety: [String]?
        let setup: [String]?
    }

    private struct RawInput: Decodable {
        let id: String?
        let label: String?
        let kind: String?
        let defaultValue: String?
        let placeholder: String?
        let options: [String]?
        let required: Bool?

        enum CodingKeys: String, CodingKey {
            case id, label, kind, placeholder, options, required
            case defaultValue = "default"
        }
    }

    private struct RawStep: Decodable {
        let command: String?
        let entrypoint: String?
        let pane: String?
        let mode: String?
        let cwd: String?
    }

    private static func decodeInput(_ raw: RawInput) throws -> CmdyActionInput {
        guard let id = raw.id, validID(id), !id.contains("."),
              let label = raw.label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty, label.utf8.count <= 160,
              let kind = CmdyActionInput.Kind(rawValue: raw.kind ?? "text") else {
            throw CmdyActionError.invalid("an input has an invalid id, label, or kind")
        }
        let options = raw.options ?? []
        if kind == .choice, options.isEmpty {
            throw CmdyActionError.invalid("choice input '\(id)' has no options")
        }
        if options.count > 256 || options.contains(where: { $0.utf8.count > 512 }) {
            throw CmdyActionError.invalid("input '\(id)' has too many or oversized options")
        }
        if let value = raw.defaultValue, kind == .choice, !options.contains(value) {
            throw CmdyActionError.invalid("default for '\(id)' is not one of its options")
        }
        return CmdyActionInput(
            id: id, label: label, kind: kind, defaultValue: raw.defaultValue,
            placeholder: raw.placeholder.map { String($0.prefix(512)) },
            options: options, required: raw.required ?? false)
    }

    private static func decodeStep(_ raw: RawStep) throws -> CmdyActionStep {
        guard (raw.command == nil) != (raw.entrypoint == nil) else {
            throw CmdyActionError.invalid(
                "each step needs exactly one command or entrypoint")
        }
        if let command = raw.command,
           command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || command.utf8.count > 64 * 1024 {
            throw CmdyActionError.invalid("a command is empty or exceeds 64 KB")
        }
        guard let pane = CmdyActionStep.Pane(rawValue: raw.pane ?? "focused"),
              let mode = CmdyActionStep.Mode(rawValue: raw.mode ?? "run"),
              let cwd = CmdyActionStep.WorkingDirectory(rawValue: raw.cwd ?? "focused") else {
            throw CmdyActionError.invalid("step pane, mode, or cwd is invalid")
        }
        return CmdyActionStep(command: raw.command, entrypoint: raw.entrypoint,
                                 pane: pane, mode: mode, workingDirectory: cwd)
    }

    private static func validate(_ step: CmdyActionStep, in directory: URL,
                                 fileManager: FileManager) throws {
        guard let relative = step.entrypoint else { return }
        guard safeRelativePath(relative) else { throw CmdyActionError.unsafePath(relative) }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let entrypoint = directory.appendingPathComponent(relative).standardizedFileURL
        guard entrypoint.resolvingSymlinksInPath().path.hasPrefix(root) else {
            throw CmdyActionError.unsafePath(relative)
        }
        guard fileManager.fileExists(atPath: entrypoint.path),
              fileManager.isExecutableFile(atPath: entrypoint.path)
                || supportedScriptExtensions.contains(entrypoint.pathExtension.lowercased()) else {
            throw CmdyActionError.missingEntrypoint(entrypoint.path)
        }
    }

    private static func standaloneScript(_ source: URL, scope: CmdyAction.Scope,
                                         fileManager: FileManager) throws -> CmdyAction {
        let directory = source.deletingLastPathComponent().standardizedFileURL
        let title = humanTitle(source.deletingPathExtension().lastPathComponent)
        let step = CmdyActionStep(
            command: nil, entrypoint: source.lastPathComponent,
            pane: .focused, mode: .run, workingDirectory: .focused)
        try validate(step, in: directory, fileManager: fileManager)
        return CmdyAction(
            manifestVersion: 1, id: safeID(source.deletingPathExtension().lastPathComponent),
            title: title, description: "One-shot script",
            guide: actionGuide(
                raw: nil, description: "One-shot script", steps: [step], inputs: [],
                confirmation: nil, whenFiles: [], scope: scope),
            group: defaultGroup(scope),
            shortcut: nil, confirmation: nil, inputs: [], steps: [step], whenFiles: [],
            sourceURL: source.standardizedFileURL, directory: directory, scope: scope)
    }

    private static func validID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128,
              value.first != ".", value.last != ".", !value.contains("..") else { return false }
        return value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_")
        }
    }

    private static func safeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.hasPrefix("~") else { return false }
        return !value.split(separator: "/", omittingEmptySubsequences: false)
            .contains(where: { $0 == ".." || $0.isEmpty })
    }

    private static func safeID(_ value: String) -> String {
        let mapped = value.lowercased().map {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "-"
        }
        let id = String(mapped.prefix(128))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return id.isEmpty ? "action" : id
    }

    private static func humanTitle(_ value: String) -> String {
        value.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func actionGuide(
        raw: RawGuide?, description: String, steps: [CmdyActionStep],
        inputs: [CmdyActionInput], confirmation: String?, whenFiles: [String],
        scope: CmdyAction.Scope
    ) -> CmdyProductGuide {
        let authored = CmdyProductGuide(
            whatItDoes: raw?.whatItDoes ?? [],
            safety: raw?.safety ?? [],
            setup: raw?.setup ?? [])

        var behavior = authored.whatItDoes
        if behavior.isEmpty {
            if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                behavior.append(description)
            }
            let runCount = steps.filter { $0.mode == .run }.count
            let typeCount = steps.count - runCount
            var parts: [String] = []
            if runCount > 0 {
                parts.append("runs \(runCount) shell step\(runCount == 1 ? "" : "s")")
            }
            if typeCount > 0 {
                parts.append("types \(typeCount) step\(typeCount == 1 ? "" : "s") for review")
            }
            let newPanes = steps.filter { $0.pane != .focused }.count
            if newPanes > 0 {
                parts.append("opens \(newPanes) split pane\(newPanes == 1 ? "" : "s")")
            }
            if !parts.isEmpty {
                behavior.append("This Action " + parts.joined(separator: ", ") + ".")
            }
        }

        var safety = authored.safety
        if safety.isEmpty {
            if steps.contains(where: { $0.mode == .run }) {
                safety.append("Run steps submit their resolved command to the shell immediately.")
            }
            if steps.contains(where: { $0.mode == .type }) {
                safety.append("Type steps leave their command visible at the prompt for you to review and press Enter.")
            }
            safety.append(confirmation?.isEmpty == false
                ? "The manifest requires a confirmation before any step runs."
                : "The manifest declares no extra confirmation; choosing the Action starts it.")
            if inputs.contains(where: { $0.kind == .secure }) {
                safety.append("Secure inputs are masked while entered, then passed to the Action environment and any templates that reference them.")
            }
            if case .project = scope {
                safety.append("This project Action is available only after you trust the project's executable automation.")
            }
        }

        var setup = authored.setup
        if setup.isEmpty {
            if !inputs.isEmpty {
                let labels = inputs.map {
                    $0.label + ($0.required ? " (required)" : "")
                }.joined(separator: ", ")
                setup.append("Inputs: \(labels).")
            } else {
                setup.append("No input is required.")
            }
            if !whenFiles.isEmpty {
                setup.append("Shown only when these project paths exist: \(whenFiles.joined(separator: ", ")).")
            }
            if case .project = scope {
                setup.append(
                    "Loaded from this project's "
                        + "\(ProductIdentity.current.projectDirectoryName)/actions folder.")
            } else {
                setup.append(
                    "Loaded from your personal "
                        + "\(ProductIdentity.current.titleName) Actions folder.")
            }
        }
        return CmdyProductGuide(whatItDoes: behavior, safety: safety, setup: setup)
    }

    private static func defaultGroup(_ scope: CmdyAction.Scope) -> String {
        if case .project = scope { return "Project" }
        return "Personal"
    }
}
