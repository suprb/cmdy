import AppKit
import CmdyKit

/// One parsed agent step from the model.
struct AgentStep {
    let thought: String
    let command: String?
    let done: Bool
    let summary: String?

    /// Parse the model's JSON reply (tolerating stray code fences).
    static func parse(_ raw: String) -> AgentStep? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.split(separator: "\n").dropFirst().joined(separator: "\n")
            if let r = s.range(of: "```", options: .backwards) { s = String(s[..<r.lowerBound]) }
        }
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return AgentStep(thought: obj["thought"] as? String ?? "",
                         command: (obj["command"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                         done: obj["done"] as? Bool ?? false,
                         summary: obj["summary"] as? String)
    }
}

/// Agent mode: give Claude a goal; it proposes ONE command at a time, typed at
/// the prompt. The user runs each step by pressing Enter in the terminal (or
/// edits it first — the agent sees what actually ran). Output + exit code feed
/// back automatically for the next step. Nothing ever auto-executes.
@MainActor
final class AgentSession {
    enum State {
        case thinking
        case awaitingRun
        case finished
        case failed
    }

    private(set) var state: State = .thinking
    /// Stable completion data for Channel Work Items and other host-owned
    /// callers. UI log glyphs are presentation, not an integration contract.
    private(set) var resultSummary: String?
    private(set) var failureReason: String?
    let goal: String
    private(set) weak var pane: TerminalPane?
    private var messages: [[String: Any]] = []
    private var steps = 0
    private let maxSteps = 15
    private var stopped = false

    /// UI feed: a new log line (thought, status, summary…).
    var onLog: ((String) -> Void)?
    /// State changed (update status line / buttons).
    var onStateChange: ((AgentSession) -> Void)?
    /// Session over (done, failed, or stopped).
    var onEnd: (() -> Void)?

    private static let system = """
    You operate a macOS terminal (zsh) as an agent, pursuing the user's goal one \
    shell command at a time. The user reviews every command and presses Enter to \
    run it — you never execute anything yourself.
    Respond with ONLY a JSON object, no markdown fences:
    {"thought": "one short sentence shown to the user",
     "command": "the single next command, or omit when done",
     "done": false,
     "summary": "only when done: what was accomplished or why you stopped"}
    Rules: one command per step; prefer safe, read-only commands when possible; \
    never propose destructive commands unless the goal explicitly requires it; \
    no interactive programs (vim, less, top) — use cat, sed -n, head instead; \
    keep output small (head/tail/grep) when a command could be verbose; \
    set done=true as soon as the goal is achieved or clearly impossible.
    """

    init(goal: String, pane: TerminalPane) {
        self.goal = goal
        self.pane = pane
    }

    func start() {
        let cwd = pane?.currentCwd ?? "unknown"
        messages.append(["role": "user",
                         "content": "Goal: \(goal)\nWorking directory: \(cwd)"])
        requestStep()
    }

    /// The user ran a command in the agent's pane — feed the result back.
    func commandFinished(block: Block, output: String) {
        guard case .awaitingRun = state, !stopped else { return }
        var out = output
        if out.count > 6000 {   // keep the transcript lean
            out = out.prefix(2800) + "\n…[output truncated]…\n" + out.suffix(2800)
        }
        messages.append(["role": "user", "content": """
        Command run: \(block.commandText)
        Exit code: \(block.exitCode.map(String.init) ?? "unknown")
        Output:
        \(out.isEmpty ? "(no output)" : out)
        """])
        state = .thinking
        onStateChange?(self)
        requestStep()
    }

    func stop(reason: String = "Stopped by the user") {
        guard !stopped else { return }
        switch state {
        case .finished, .failed: return
        case .thinking, .awaitingRun: break
        }
        stopped = true
        state = .failed
        failureReason = reason
        onLog?(reason == "Stopped by the user" ? "⏹ stopped" : "✗ \(reason)")
        onStateChange?(self)
        onEnd?()
    }

    private func requestStep() {
        guard !stopped else { return }
        steps += 1
        guard steps <= maxSteps else {
            state = .failed
            let reason = "Reached the \(maxSteps)-step limit"
            failureReason = reason
            onLog?("\(reason) — stopping. Restart with a narrower goal to continue.")
            onStateChange?(self)
            onEnd?()
            return
        }
        let transcript = messages
        Task { [weak self] in
            do {
                let raw = try await LLMClient.chat(system: Self.system, messages: transcript, maxTokens: 1024)
                await MainActor.run { self?.handleReply(raw) }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    guard let self, !self.stopped else { return }
                    self.state = .failed
                    self.failureReason = msg
                    self.onLog?("✗ \(msg)")
                    self.onStateChange?(self)
                    self.onEnd?()
                }
            }
        }
    }

    private func handleReply(_ raw: String) {
        guard !stopped else { return }
        messages.append(["role": "assistant", "content": raw])
        guard let step = AgentStep.parse(raw) else {
            state = .failed
            failureReason = "Could not parse the model's reply"
            onLog?("✗ couldn't parse the model's reply")
            onStateChange?(self)
            onEnd?()
            return
        }
        if !step.thought.isEmpty { onLog?("💭 \(step.thought)") }
        if step.done || step.command == nil {
            state = .finished
            resultSummary = step.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            if resultSummary?.isEmpty != false { resultSummary = "Agent session completed" }
            onLog?("✅ \(resultSummary ?? "Agent session completed")")
            onStateChange?(self)
            onEnd?()
            return
        }
        guard let pane else {
            state = .failed
            failureReason = "The terminal pane closed"
            onStateChange?(self)
            onEnd?()
            return
        }
        guard let command = step.command else {
            state = .failed
            failureReason = "The agent returned no next command"
            onStateChange?(self)
            onEnd?()
            return
        }
        onLog?("→ \(command)")
        pane.replacePromptInput(with: command)   // typed, not run
        pane.focus()
        state = .awaitingRun
        onStateChange?(self)
    }
}
