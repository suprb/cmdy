import AppKit
import SwiftUI
import CmdyKit

extension Notification.Name {
    static let cmdyWorkspaceFrameChanged = Notification.Name("cmdy.workspaceFrameChanged")
}

enum WorkspaceChromeMetrics {
    static let titleFontSize: CGFloat = 11
    static let terminalTopSpacing: CGFloat = 8
}

struct WorkspaceRailAction: Identifiable {
    let id: String
    let title: String
    var enabled = true
    let action: () -> Void
}

struct WorkspaceRailPickerOption: Identifiable {
    let id: String
    let title: String
}

struct WorkspaceRailPicker {
    let selection: String
    let options: [WorkspaceRailPickerOption]
    let onChange: (String) -> Void
}

struct WorkspaceTabAppearanceControl {
    let theme: WorkspaceRailPicker
    let shader: WorkspaceRailPicker
    let font: WorkspaceRailPicker
}

enum WorkspaceRailItemPresentation {
    case standard
    case summary
}

/// A declarative row in either Adaptive Frame column. Built-in features and
/// Extensions are rendered through the same host-owned SwiftUI grammar.
struct WorkspaceRailItem: Identifiable {
    let id: String
    let title: String
    var detail: String? = nil
    var badge: String? = nil
    var status: WorkspaceRailStatus = .neutral
    var selected = false
    var enabled = true
    var presentation: WorkspaceRailItemPresentation = .standard
    var startedAt: Date? = nil
    var finishedAt: Date? = nil
    var actions: [WorkspaceRailAction] = []
    var picker: WorkspaceRailPicker? = nil
    var tabAppearance: WorkspaceTabAppearanceControl? = nil
    var tabPreview: WorkspaceTabPreview? = nil
    /// Starts a host-owned drag for a live sidebar tab. WindowDock moves the
    /// existing controller and PTY instead of serializing or recreating state.
    var tabDragAction: (() -> Void)? = nil
    var action: (() -> Void)? = nil
}

enum WorkspaceRailStatus { case neutral, active, attention, success, failure }

/// A lightweight, renderer-independent view of a live terminal tab. Each pane
/// contributes its current viewport and normalized position so split sessions
/// remain recognizable in the sidebar without duplicating a Metal surface.
struct WorkspaceTabPreview {
    struct Pane {
        let frame: CGRect
        let lines: [String]
    }

    let panes: [Pane]
    let background: NSColor
    let foreground: NSColor
    let divider: NSColor
}

struct WorkspaceRailSection: Identifiable {
    let id: String
    let title: String
    let items: [WorkspaceRailItem]
}

/// Mutable presentation state shared with an NSHostingController. Keeping the
/// model App-owned lets built-ins and Extensions update without replacing the
/// native sidebar or inspector view controllers.
final class WorkspaceRailModel: ObservableObject {
    private struct Snapshot {
        var sections: [WorkspaceRailSection]
        var emptyMessage: String
        var theme: Theme
    }

    enum Side {
        case navigator
        case inspector

        var title: String { self == .navigator ? "Tabs" : "Inspector" }
        var closeSymbol: String { self == .navigator ? "chevron.left" : "chevron.right" }
        var closeHelp: String { self == .navigator ? "Hide Tab Sidebar" : "Hide Inspector" }
    }

    let side: Side
    var onClose: (() -> Void)?
    var onCreate: (() -> Void)?

    @Published private var snapshot = Snapshot(
        sections: [], emptyMessage: "", theme: Preferences.shared.theme)
    var sections: [WorkspaceRailSection] { snapshot.sections }
    var emptyMessage: String { snapshot.emptyMessage }
    var theme: Theme { snapshot.theme }

    init(side: Side) {
        self.side = side
    }

    func update(sections: [WorkspaceRailSection], emptyMessage: String, theme: Theme) {
        snapshot = Snapshot(
            sections: sections.filter { !$0.items.isEmpty },
            emptyMessage: emptyMessage,
            theme: theme)
    }
}

/// SwiftUI content hosted inside AppKit's real sidebar and inspector split
/// items. AppKit owns geometry and material; this view owns only content.
struct WorkspaceRailView: View {
    @ObservedObject var model: WorkspaceRailModel

    var body: some View {
        VStack(spacing: 0) {
            content
            if model.side == .navigator {
                navigatorFooter
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Both rails are structural columns in the same terminal workspace.
        // Paint the exact theme surface over AppKit's sidebar/inspector
        // materials so light themes do not produce dark or gray side columns.
        .background(Color(nsColor: model.theme.ns(model.theme.background)))
        .environment(\.colorScheme, themeColorScheme)
        .tint(Color(nsColor: model.theme.ns(model.theme.cursor)))
    }

    private var themeColorScheme: ColorScheme {
        let color = model.theme.ns(model.theme.background)
        let brightness = color.usingColorSpace(.deviceGray)?.whiteComponent ?? 0
        return brightness >= 0.5 ? .light : .dark
    }

    private var navigatorFooter: some View {
        HStack {
            Button {
                model.onCreate?()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .regular))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .help("New Tab")
            .accessibilityLabel("New Tab")
            .frame(width: 22, height: 22)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var content: some View {
        if model.sections.isEmpty {
            Text(model.emptyMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .topLeading)
                .padding(12)
        } else if model.side == .navigator {
            ScrollView {
                LazyVStack(spacing: 0) {
                    navigatorSections
                }
            }
        } else {
            WorkspaceInspectorForm(model: model)
        }
    }

    @ViewBuilder private var navigatorSections: some View {
        ForEach(model.sections) { section in
            if !section.title.isEmpty {
                Text(section.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.top, 9)
                    .padding(.bottom, 3)
            }
            ForEach(section.items) { item in
                if item.tabPreview != nil {
                    WorkspaceTabCardView(item: item, theme: model.theme)
                        .frame(maxWidth: .infinity)
                } else {
                    WorkspaceRailRowView(item: item, theme: model.theme)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(item.selected
                            ? Color.accentColor.opacity(0.14) : Color.clear)
                }
            }
        }
    }
}

/// The right rail is a real macOS form. SwiftUI supplies the AppKit-backed
/// controls, focus behavior, keyboard navigation, accessibility, and platform
/// spacing; Cmdy provides only the live values and actions.
private struct WorkspaceInspectorForm: View {
    @ObservedObject var model: WorkspaceRailModel
    @State private var sectionExpansion: [String: Bool] = [:]

    var body: some View {
        Form {
            ForEach(model.sections) { section in
                Section {
                    DisclosureGroup(isExpanded: expansionBinding(for: section.id)) {
                        ForEach(section.items) { item in
                            inspectorRow(item)
                                .padding(.vertical, 2)
                        }
                    } label: {
                        Text(section.title.isEmpty ? "Context" : section.title)
                            .font(.system(
                                size: WorkspaceChromeMetrics.titleFontSize,
                                weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 2)
                    }
                    .background {
                        inspectorCardTint
                    }
                }
            }
        }
        .formStyle(.grouped)
        // Grouped Form supplies a fixed 20 pt content margin on macOS.
        // Pull its container outward so the visible rail inset matches the
        // Navigator's 8 pt content rhythm while retaining the native form.
        .padding(.horizontal, -12)
        .padding(.top, -12)
        .font(.system(size: WorkspaceChromeMetrics.titleFontSize))
        .controlSize(.small)
        .scrollContentBackground(.hidden)
        .textSelection(.enabled)
        // Live values replace in place. Section insertions/removals should not
        // make the Inspector bounce or advertise every background refresh.
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    @ViewBuilder
    private var inspectorCardTint: some View {
        if model.theme.name == Theme.blackWhite.name {
            Color(nsColor:
                model.theme.ns(model.theme.background)
                    .blended(
                        withFraction: 0.06,
                        of: model.theme.ns(model.theme.foreground))!)
                // A grouped macOS Form clips section content to its native
                // rounded card after applying a 10 pt inset. Extend the tint
                // through that inset so it replaces the single card surface
                // instead of drawing a smaller rectangle inside it.
                .padding(-10)
        }
    }

    @ViewBuilder
    private func inspectorRow(_ item: WorkspaceRailItem) -> some View {
        if item.id == "now-ready" {
            readySummary(item)
        } else if item.id == "selected-text" {
            selectionSummary(item)
        } else if let picker = item.picker {
            Picker(item.title, selection: Binding(
                get: { picker.selection },
                set: picker.onChange
            )) {
                ForEach(picker.options) { option in
                    Text(option.title).tag(option.id)
                }
            }
            .pickerStyle(.menu)
            .disabled(!item.enabled)
            .opacity(item.enabled ? 1 : 0.5)
        } else if item.presentation == .summary || !item.actions.isEmpty {
            summaryRow(item)
        } else if let action = item.action {
            VStack(alignment: .leading, spacing: 4) {
                Button(item.title, action: action)
                    .disabled(!item.enabled)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(item.enabled ? 1 : 0.5)
        } else {
            LabeledContent {
                VStack(alignment: .trailing, spacing: 3) {
                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail)
                            .multilineTextAlignment(.trailing)
                    }
                    if let badge = item.badge, !badge.isEmpty {
                        Text(badge)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if item.status != .neutral {
                        Circle()
                            .fill(statusColor(item.status))
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                    Text(item.title)
                }
            }
            .disabled(!item.enabled)
            .opacity(item.enabled ? 1 : 0.5)
        }
    }

    private func readySummary(_ item: WorkspaceRailItem) -> some View {
        let needsAttention = item.status == .attention

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor(
                        needsAttention ? .attention : .success))
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)

                Text(item.title)
                    .font(.system(
                        size: WorkspaceChromeMetrics.titleFontSize,
                        weight: .medium))
            }

            if let detail = item.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(needsAttention ? 3 : 1)
                    .truncationMode(.middle)
                    .padding(.leading, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(item.enabled ? 1 : 0.5)
    }

    private func selectionSummary(_ item: WorkspaceRailItem) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if let detail = item.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(
                        size: WorkspaceChromeMetrics.titleFontSize - 1,
                        design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.55),
                                in: RoundedRectangle(cornerRadius: 7))
            }

            HStack(spacing: 4) {
                Text(item.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                ForEach(item.actions) { action in
                    Button(action: action.action) {
                        Image(systemName: selectionActionSymbol(action.id))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .disabled(!item.enabled || !action.enabled)
                    .help(action.title)
                    .accessibilityLabel(action.title)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(item.enabled ? 1 : 0.5)
    }

    private func selectionActionSymbol(_ id: String) -> String {
        switch id {
        case "copy": return "doc.on.doc"
        case "command": return "terminal"
        case "explain": return "sparkles"
        default: return "ellipsis.circle"
        }
    }

    @ViewBuilder
    private func summaryRow(_ item: WorkspaceRailItem) -> some View {
        if item.startedAt != nil, item.finishedAt == nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                summaryContent(item, now: context.date)
            }
        } else {
            summaryContent(item, now: Date())
        }
    }

    private func summaryContent(_ item: WorkspaceRailItem, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if !item.title.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if item.status != .neutral {
                        Circle()
                            .fill(statusColor(item.status))
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                    Text(item.title)
                        .font(.system(
                            size: WorkspaceChromeMetrics.titleFontSize,
                            weight: .medium))
                        .lineLimit(3)
                    Spacer(minLength: 4)
                    if let badge = item.badge, !badge.isEmpty {
                        Text(badge)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let detail = summaryDetail(item, now: now), !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !item.actions.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 76), spacing: 6)],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(item.actions) { action in
                        Button(action.title, action: action.action)
                            .disabled(!item.enabled || !action.enabled)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(item.enabled ? 1 : 0.5)
    }

    private func summaryDetail(_ item: WorkspaceRailItem, now: Date) -> String? {
        var parts: [String] = []
        if let detail = item.detail, !detail.isEmpty { parts.append(detail) }
        if let startedAt = item.startedAt {
            let end = item.finishedAt ?? now
            let duration = max(0, end.timeIntervalSince(startedAt))
            let text = duration < 60
                ? String(format: "%.1fs", duration)
                : "\(Int(duration) / 60)m \(Int(duration) % 60)s"
            parts.append(text)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func expansionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { sectionExpansion[id] ?? true },
            set: { sectionExpansion[id] = $0 })
    }

    private func statusColor(_ status: WorkspaceRailStatus) -> Color {
        let color: NSColor
        switch status {
        case .neutral: color = model.theme.ns(model.theme.foreground).withAlphaComponent(0.45)
        case .active: color = model.theme.ns(model.theme.cursor)
        case .attention: color = model.theme.ns(model.theme.ansi[3])
        case .success: color = model.theme.ns(model.theme.ansi[2])
        case .failure: color = model.theme.ns(model.theme.ansi[1])
        }
        return Color(nsColor: color)
    }
}

/// A native-feeling tab card whose content is a live miniature of the real
/// terminal viewport. TimelineView only invalidates these small cards; the
/// terminal renderer and its frame cadence stay untouched.
private struct WorkspaceTabCardView: View {
    let item: WorkspaceRailItem
    let theme: Theme
    @State private var cardDragActive = false
    @State private var cardFrame = CGRect.zero

    var body: some View {
        Group {
            if let appearance = item.tabAppearance {
                draggableCard
                    .contextMenu {
                        appearancePicker("Theme", picker: appearance.theme)
                        appearancePicker("Shader", picker: appearance.shader)
                        appearancePicker("Font", picker: appearance.font)
                    }
            } else {
                draggableCard
            }
        }
        .disabled(!item.enabled)
        .opacity(item.enabled ? 1 : 0.42)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: WorkspaceTabCardFrameKey.self,
                    value: geometry.frame(in: .global))
            }
        }
        .onPreferenceChange(WorkspaceTabCardFrameKey.self) {
            cardFrame = $0
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.detail ?? "")
    }

    @ViewBuilder
    private var draggableCard: some View {
        if let beginDrag = item.tabDragAction {
            interactiveCard
                // This is deliberately a direct gesture rather than `.onDrag`.
                // Empty desktop space cannot accept a pasteboard drop, so
                // AppKit would animate its drag image back to the sidebar even
                // after WindowDock had successfully torn out the live window.
                .highPriorityGesture(
                    DragGesture(minimumDistance: 6, coordinateSpace: .global)
                        .onChanged { value in
                            guard !cardDragActive else { return }
                            cardDragActive = true
                            beginDrag()
                            let size = WindowDock.shared
                                .sidebarTabDragPreviewSize(
                                    measured: cardFrame.size)
                            let hasMeasuredFrame = cardFrame.width > 1
                                && cardFrame.height > 1
                            let anchor = hasMeasuredFrame ? CGPoint(
                                    x: min(max(
                                        (value.startLocation.x
                                            - cardFrame.minX) / size.width,
                                        0), 1),
                                    y: min(max(
                                        (value.startLocation.y
                                            - cardFrame.minY) / size.height,
                                        0), 1))
                                : CGPoint(x: 0.5, y: 0.5)
                            WindowDock.shared.showSidebarTabDragPreview(
                                AnyView(card.frame(
                                    width: size.width, height: size.height)),
                                size: size,
                                anchor: anchor)
                        }
                        .onEnded { _ in
                            guard cardDragActive else { return }
                            cardDragActive = false
                            WindowDock.shared.endSidebarTabDrag()
                        })
                .scaleEffect(cardDragActive ? 0.98 : 1)
                .opacity(cardDragActive ? 0.24 : 1)
                .animation(
                    .easeOut(duration: 0.1), value: cardDragActive)
                .help("Drag outside to make a window, or onto a terminal to split")
        } else {
            interactiveCard
        }
    }

    private var interactiveCard: some View {
        Group {
            if let action = item.action {
                Button(action: action) { card }
                    .buttonStyle(.plain)
            } else {
                card
            }
        }
    }

    private func appearancePicker(
        _ title: String,
        picker: WorkspaceRailPicker
    ) -> some View {
        Picker(title, selection: Binding(
            get: { picker.selection },
            set: picker.onChange
        )) {
            ForEach(picker.options) { option in
                Text(option.title).tag(option.id)
            }
        }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(item.badge ?? "•")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(item.selected ? Color.primary : Color.secondary)
                .frame(width: 22, height: 22)
                .background(numberBackground, in: Circle())
                .padding(.top, 3)

            Group {
                if let preview = item.tabPreview {
                    WorkspaceTabMiniature(preview: preview)
                        .aspectRatio(1.72, contentMode: .fit)
                } else {
                    Rectangle()
                        .fill(Color(nsColor: theme.ns(theme.background)))
                        .aspectRatio(1.72, contentMode: .fit)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(item.selected
                        ? Color.accentColor.opacity(0.95)
                        : Color(nsColor: .separatorColor).opacity(0.48),
                        lineWidth: item.selected ? 2.5 : 0.5)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(item.selected
            ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
    }

    private var numberBackground: Color {
        if item.selected {
            return Color.accentColor.opacity(0.28)
        }
        if item.status != .neutral {
            return statusColor.opacity(0.24)
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var statusColor: Color {
        let color: NSColor
        switch item.status {
        case .neutral: color = theme.ns(theme.foreground).withAlphaComponent(0.45)
        case .active: color = theme.ns(theme.cursor)
        case .attention: color = theme.ns(theme.ansi[3])
        case .success: color = theme.ns(theme.ansi[2])
        case .failure: color = theme.ns(theme.ansi[1])
        }
        return Color(nsColor: color)
    }
}

private struct WorkspaceTabCardFrameKey: PreferenceKey {
    static var defaultValue = CGRect.zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct WorkspaceTabMiniature: View {
    let preview: WorkspaceTabPreview

    var body: some View {
        Canvas(opaque: true, colorMode: .nonLinear, rendersAsynchronously: true) {
            context, size in
            let bounds = CGRect(origin: .zero, size: size)
            context.fill(Path(bounds), with: .color(Color(nsColor: preview.background)))
            context.clip(to: Path(bounds))

            for pane in preview.panes {
                let rect = CGRect(
                    x: pane.frame.minX * size.width,
                    y: pane.frame.minY * size.height,
                    width: pane.frame.width * size.width,
                    height: pane.frame.height * size.height)
                context.fill(Path(rect), with: .color(Color(nsColor: preview.background)))
                context.stroke(Path(rect), with: .color(Color(nsColor: preview.divider)),
                               lineWidth: 0.5)

                guard !pane.lines.isEmpty, rect.width > 4, rect.height > 4 else { continue }
                let rowHeight = rect.height / CGFloat(pane.lines.count)
                let fontSize = max(2, min(4.5, rowHeight * 0.78))
                for (index, line) in pane.lines.enumerated() where !line.isEmpty {
                    let text = Text(line)
                        .font(.system(size: fontSize, weight: .regular, design: .monospaced))
                        .foregroundColor(Color(nsColor: preview.foreground))
                    context.draw(
                        text,
                        at: CGPoint(x: rect.minX + 2,
                                    y: rect.minY + CGFloat(index) * rowHeight),
                        anchor: .topLeading)
                }
            }
        }
    }
}

private struct WorkspaceRailRowView: View {
    let item: WorkspaceRailItem
    let theme: Theme

    var body: some View {
        Group {
            if let action = item.action {
                Button(action: action) { rowContent }
                    .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
        .disabled(!item.enabled)
        .opacity(item.enabled ? 1 : 0.42)
    }

    private var rowContent: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if item.status != .neutral {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(item.title)
                        .font(.system(size: 11,
                                      weight: item.selected ? .semibold : .regular,
                                      design: .default))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if let badge = item.badge, !badge.isEmpty {
                        Text(badge)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, 3)
    }

    private var statusColor: Color {
        let color: NSColor
        switch item.status {
        case .neutral: color = theme.ns(theme.foreground).withAlphaComponent(0.45)
        case .active: color = theme.ns(theme.cursor)
        case .attention: color = theme.ns(theme.ansi[3])
        case .success: color = theme.ns(theme.ansi[2])
        case .failure: color = theme.ns(theme.ansi[1])
        }
        return Color(nsColor: color)
    }
}
