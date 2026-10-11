import AppKit
import SwiftUI
import CmdyKit
import ProductIdentity

/// Callbacks retain the pane the user inspected, so bringing Settings forward
/// cannot accidentally change a different pane in the responder chain.
struct CmdyFocusedSettingsContext {
    let title: String
    let paneOverrides: [String]
    let tabOverrides: [String]
    let resetPaneOverrides: (() -> Void)?
    let resetTabOverrides: (() -> Void)?
    var refreshOverrides: (() -> (pane: [String], tab: [String])?)? = nil
}

@MainActor
final class CmdySettingsWindowController: NSWindowController {
    private let model: CmdySettingsModel

    init(openConfig: @escaping () -> Void,
         focusedPane: @escaping () -> CmdyFocusedSettingsContext?) {
        model = CmdySettingsModel(openConfig: openConfig, focusedPane: focusedPane)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 660),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "\(ProductIdentity.current.titleName) Settings"
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("CmdySettings")
        window.contentViewController = NSHostingController(rootView: CmdySettingsView(model: model))
        super.init(window: window)
        shouldCascadeWindows = false
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func showSettings() {
        model.refresh(includeCredentialStatus: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class CmdySettingsModel: ObservableObject {
    let preferences = Preferences.shared
    let openConfig: () -> Void
    private let focusedPane: () -> CmdyFocusedSettingsContext?
    @Published private(set) var context: CmdyFocusedSettingsContext?
    @Published private(set) var credentialStatus = ""
    @Published private(set) var hasStoredKey = false
    @Published private var revision = 0
    private var observers: [NSObjectProtocol] = []

    init(openConfig: @escaping () -> Void,
         focusedPane: @escaping () -> CmdyFocusedSettingsContext?) {
        self.openConfig = openConfig
        self.focusedPane = focusedPane
        for name in [Notification.Name.cmdyPreferencesChanged, .cmdySettingsIssuesChanged] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    var diagnostics: [String] {
        ConfigFile.issues.map { "\($0.key): \($0.message)" }
            + [ConfigFile.persistenceError, preferences.credentialError].compactMap { $0 }
    }

    func refresh(includeCredentialStatus: Bool = false) {
        revision += 1
        // If Settings is the key window, the app keeps its last terminal
        // context; a subsequent explicit Settings action captures a new one.
        if let latest = focusedPane() {
            context = latest
        } else if let context, let refreshOverrides = context.refreshOverrides {
            if let latest = refreshOverrides() {
                self.context = CmdyFocusedSettingsContext(
                    title: context.title, paneOverrides: latest.pane,
                    tabOverrides: latest.tab, resetPaneOverrides: context.resetPaneOverrides,
                    resetTabOverrides: context.resetTabOverrides, refreshOverrides: refreshOverrides)
            } else {
                self.context = nil
            }
        }
        if includeCredentialStatus {
            hasStoredKey = preferences.anthropicKey != nil
            if preferences.credentialError != nil {
                credentialStatus = "Keychain needs attention. See the message below."
            } else if hasStoredKey {
                credentialStatus = preferences.usesIsolatedCredentialStorage
                    ? "Available for this isolated run only."
                    : "API key stored in Keychain."
            } else if ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?.isEmpty == false {
                credentialStatus = "Using ANTHROPIC_API_KEY from the launch environment."
            } else {
                credentialStatus = "No cloud API key configured."
            }
        }
    }

    func binding<Value>(_ keyPath: ReferenceWritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(get: { self.preferences[keyPath: keyPath] }, set: { value in
            self.preferences[keyPath: keyPath] = value
            self.refresh()
        })
    }

    func saveKey(_ value: String?) -> Bool {
        let saved = preferences.saveAnthropicKey(value)
        refresh(includeCredentialStatus: saved)
        return saved
    }

    func reload() {
        ConfigFile.applyIfPresent(force: true)
        preferences.migrateLegacyAssistantKey()
        refresh(includeCredentialStatus: true)
    }
}

@MainActor
private struct CmdySettingsView: View {
    @ObservedObject var model: CmdySettingsModel
    @State private var category: Category = .appearance
    @State private var newKey = ""
    @State private var modelDraft = Preferences.shared.aiModel
    @FocusState private var modelIsFocused: Bool

    private enum Category: String, CaseIterable, Identifiable {
        case appearance = "Appearance", input = "Input", sessions = "Sessions", assistant = "Assistant"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings category", selection: $category) {
                ForEach(Category.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 20)

            Text("Application defaults · panes follow these values unless overridden.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 12)

            Form {
                switch category {
                case .appearance: appearance
                case .input: input
                case .sessions: sessions
                case .assistant: assistant
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            if !model.diagnostics.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Settings need attention", systemImage: "exclamationmark.triangle")
                            .font(.subheadline.weight(.medium))
                        ForEach(Array(model.diagnostics.enumerated()), id: \.offset) { _, message in
                            Text(message)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
                .frame(maxHeight: 120)
                .background(Color(nsColor: .controlBackgroundColor))
            }

            Divider()
            HStack {
                Button("Open Config…", action: model.openConfig)
                Button("Reload Config", action: model.reload)
                Spacer()
                Text("Changes apply immediately")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .frame(width: 620, height: 660)
        .onReceive(NotificationCenter.default.publisher(for: .cmdyPreferencesChanged)) { _ in
            if !modelIsFocused { modelDraft = model.preferences.aiModel }
        }
    }

    private var fontNames: [String] {
        let installed = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        return ["System"] + Set(installed + bundledFonts.map(\.fontName)
            + [model.preferences.fontName]).filter { $0 != "System" }.sorted()
    }

    @ViewBuilder private var appearance: some View {
        Section("Text") {
            Picker("Theme", selection: model.binding(\.themeName)) {
                ForEach(Theme.names, id: \.self) { Text($0).tag($0) }
            }
            Picker("Font", selection: model.binding(\.fontName)) {
                ForEach(fontNames, id: \.self) { Text($0).tag($0) }
            }
            Stepper(value: model.binding(\.fontSize), in: 6...72, step: 1) {
                LabeledContent("Font size", value: "\(Int(model.preferences.fontSize)) pt")
            }
            Stepper(value: model.binding(\.lineHeight), in: 0.5...2, step: 0.05) {
                LabeledContent("Line height", value: String(format: "%.2f", model.preferences.lineHeight))
            }
            Picker("Cursor", selection: model.binding(\.cursorStyleName)) {
                Text("Blinking Block").tag("blinkBlock")
                Text("Steady Block").tag("steadyBlock")
                Text("Blinking Bar").tag("blinkBar")
                Text("Steady Bar").tag("steadyBar")
                Text("Blinking Underline").tag("blinkUnderline")
                Text("Steady Underline").tag("steadyUnderline")
            }
        }
        Section("Window") {
            Stepper(value: model.binding(\.contentMargin), in: 0...60, step: 1) {
                LabeledContent("Window inset", value: "\(Int(model.preferences.contentMargin)) pt")
            }
            LabeledContent("Opacity") {
                Slider(value: model.binding(\.opacity), in: 0.3...1)
                    .frame(width: 160)
                    .accessibilityLabel("Window opacity")
                Text("\(Int(model.preferences.opacity * 100))%")
                    .monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            Toggle("Blur behind translucent windows", isOn: model.binding(\.blur))
        }
        if let context = model.context {
            Section("Focused pane · \(context.title)") {
                overrideRow("Pane overrides", values: context.paneOverrides,
                            resetTitle: "Use Tab Defaults", reset: context.resetPaneOverrides)
                overrideRow("Tab overrides", values: context.tabOverrides,
                            resetTitle: "Use Application Defaults", reset: context.resetTabOverrides)
                Text("A pane follows its tab; a tab follows the application defaults above. Appearance menus and Inspector can override theme, font, or shader.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func overrideRow(_ title: String, values: [String],
                             resetTitle: String, reset: (() -> Void)?) -> some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 4) {
                Text(values.isEmpty ? "None" : values.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                if !values.isEmpty, let reset {
                    Button(resetTitle) { reset(); model.refresh() }
                }
            }
        } label: { Text(title) }
    }

    @ViewBuilder private var input: some View {
        Section("Keyboard and scrolling") {
            Toggle("Option sends Meta / Esc", isOn: model.binding(\.optionAsMeta))
            Toggle("Ghost text from shell history", isOn: model.binding(\.ghostText))
            Toggle("Smooth cursor", isOn: model.binding(\.smoothCursor))
            Toggle("Smooth scrollback", isOn: model.binding(\.smoothScroll))
            Stepper(value: model.binding(\.scrollSpeed), in: 0.2...5, step: 0.1) {
                LabeledContent("Scroll speed", value: String(format: "%.1f×", model.preferences.scrollSpeed))
            }
        }
        Section("Shell · new panes") {
            Toggle("Shell integration", isOn: model.binding(\.shellIntegration))
            Toggle("Minimal folder prompt", isOn: model.binding(\.cleanPrompt))
            Text("Shell integration adds command blocks, durations, and completion signals. These two settings take effect in new panes.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Assistant requests") {
            Text("Use Compose Command (⇧⌘K), or type # followed by a request. Regular prompt input always runs in the shell.")
                .font(.callout)
        }
    }

    @ViewBuilder private var sessions: some View {
        Section("Returning to work") {
            Toggle("Restore windows and panes on launch", isOn: model.binding(\.restoreSession))
            Text("Restores layout, folders, and saved scrollback. Each terminal starts a new shell; supported saved tool sessions offer an explicit Resume action.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Attention signals for work that finishes away", isOn: model.binding(\.attentionSignals))
        }
        Section("Finding work") {
            Toggle("Show workspace navigator", isOn: model.binding(\.workspaceNavigatorVisible))
            Toggle("Show Inspector", isOn: model.binding(\.workspaceInspectorVisible))
            Toggle("Arrange terminal windows in a grid", isOn: model.binding(\.windowGridEnabled))
            Text("Window Grid uses the Window Inset from Appearance as the gap between windows.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var assistant: some View {
        Section("Command help") {
            Toggle("Automatic help after failed commands", isOn: model.binding(\.automaticErrorHelp))
            Text("When enabled, CMDY explains failed commands automatically, using built-in diagnostics first, then Apple Intelligence or the configured cloud fallback. Explicit Compose requests remain available when this is off.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Anthropic cloud fallback") {
            Text(model.credentialStatus).font(.caption).foregroundStyle(.secondary)
            SecureField("New API key", text: $newKey)
                .textContentType(.password)
                .privacySensitive()
                .onSubmit(saveKey)
            HStack {
                Button("Save Key", action: saveKey)
                    .disabled(newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.hasStoredKey {
                    Button("Remove Stored Key") {
                        if model.saveKey(nil) { newKey = "" }
                    }
                }
            }
            Text("The existing key is never displayed. Saving does not contact Anthropic. An environment key stays in the launch environment and is not copied into settings.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Model", text: $modelDraft)
                    .focused($modelIsFocused)
                    .onSubmit(saveModel)
                Button("Apply", action: saveModel)
                    .disabled(modelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || modelDraft == model.preferences.aiModel)
            }
        }
    }

    private func saveKey() {
        guard !newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if model.saveKey(newKey) { newKey = "" }
    }

    private func saveModel() {
        let value = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        model.preferences.aiModel = value
        modelDraft = value
        model.refresh()
    }
}
