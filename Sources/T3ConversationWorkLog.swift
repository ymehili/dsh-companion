import SwiftUI
import UIKit

/// One tool invocation assembled from the durable `tool/call` and `tool/result`
/// transcript rows that share a callId. Nothing here is estimated: counts are
/// distinct call IDs, there are no durations, and "running" only means the tail
/// call has no recorded result while the session reports it is running.
/// Rows are audit-only: `openui_card` presentations never ride along here; they
/// are attached to the completed turn's final answer (`OpenUITurnLedger`).
struct ToolWorkRow: Identifiable, Equatable {
    let id: String
    var name: String
    var arguments: String?
    var output: String?
    var failed = false
    var hasResult = false

    var copyText: String {
        var parts = [name]
        if let arguments, !arguments.isEmpty { parts.append("Input:\n\(arguments)") }
        if let output, !output.isEmpty { parts.append("Output:\n\(output)") }
        return parts.joined(separator: "\n\n")
    }
}

enum ToolWork {
    /// Merges call/result rows by callId in first-seen order. Rows without a
    /// callId stay individual. Call vs result comes from the durable event type.
    static func rows(_ entries: [ChatEntry], events: [Int: JSONValue]) -> [ToolWorkRow] {
        var rows: [ToolWorkRow] = []
        var index: [String: Int] = [:]
        for entry in entries {
            let key = entry.callId.map { "call-\($0)" } ?? "seq-\(entry.id)"
            let isResult = events[entry.id]?["type"].string == "tool/result"
            let name = entry.tool ?? "Tool"
            let position: Int
            if let existing = index[key] { position = existing }
            else {
                position = rows.count
                index[key] = position
                rows.append(ToolWorkRow(id: key, name: name))
            }
            if isResult {
                rows[position].output = entry.detail
                rows[position].failed = entry.isError
                rows[position].hasResult = true
                if rows[position].name == "Tool" { rows[position].name = name }
            } else {
                rows[position].name = name
                rows[position].arguments = entry.detail
            }
        }
        return rows
    }

    static func symbol(for name: String) -> String {
        let key = name.lowercased()
        if key.contains("bash") || key.contains("shell") || key.contains("command") || key.contains("exec") || key.contains("terminal") { return "terminal" }
        if key.contains("grep") || key.contains("glob") || key.contains("search") || key.contains("find") { return "magnifyingglass" }
        if key.contains("edit") || key.contains("write") || key.contains("patch") { return "pencil" }
        if key.contains("read") || key.contains("view") || key.contains("open") { return "doc.text" }
        if key.contains("web") || key.contains("fetch") || key.contains("browser") || key.contains("http") { return "globe" }
        if key.contains("agent") || key.contains("task") { return "person.2" }
        if key.contains("question") { return "questionmark.bubble" }
        return "wrench.and.screwdriver"
    }
}

/// Inline grouped work disclosure (T3 thread-work-log): compact 28pt rows,
/// expandable details bounded to 210pt with copy. No shimmer, no timers; the
/// disclosure motion is a finite 180ms change that Reduce Motion removes.
/// The full trajectory remains in the session actions menu.
struct ToolWorkGroup: View {
    let groupID: Int
    let rows: [ToolWorkRow]
    let live: Bool
    let expanded: Set<String>
    let toggle: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var labelSize: CGFloat = 14
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = T3Metric.workRowHeight

    private var groupKey: String { "group-\(groupID)" }
    private var isOpen: Bool { expanded.contains(groupKey) }
    private var failures: Int { rows.filter(\.failed).count }
    private var pendingTail: Bool { live && rows.last?.hasResult == false }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if rows.count == 1, let row = rows.first {
                ToolWorkRowView(row: row, pending: pendingTail, expanded: expanded.contains(row.id), toggle: { animatedToggle(row.id) })
            } else {
                header
                if isOpen {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
                        ToolWorkRowView(row: row, pending: pendingTail && offset == rows.count - 1,
                                        expanded: expanded.contains(row.id), toggle: { animatedToggle(row.id) })
                            .padding(.leading, T3Metric.steps(2))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tool-group-\(groupID)")
    }

    private func animatedToggle(_ key: String) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { toggle(key) }
    }

    private var summary: String {
        if pendingTail, let last = rows.last { return "Running \(last.name) · \(rows.count) tool calls" }
        return "\(rows.count) tool calls"
    }

    private var names: String {
        var seen: [String] = []
        for row in rows where !seen.contains(row.name) { seen.append(row.name) }
        let shown = seen.prefix(2).joined(separator: ", ")
        return seen.count > 2 ? "\(shown) +\(seen.count - 2)" : shown
    }

    private var header: some View {
        Button { animatedToggle(groupKey) } label: {
            HStack(spacing: T3Metric.steps(1.5)) {
                Image(systemName: failures > 0 ? "exclamationmark.circle" : "square.stack.3d.up")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(failures > 0 ? ChatAppearance.danger : DSHTheme.tertiary)
                    .frame(width: T3Metric.steps(6), height: T3Metric.steps(6))
                Text("\(Text(summary).foregroundStyle(DSHTheme.secondary))  \(Text(names).foregroundStyle(DSHTheme.tertiary))")
                    .font(.system(size: labelSize))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                T3DisclosureChevron(expanded: isOpen)
            }
            .padding(.horizontal, T3Metric.steps(0.5))
            .frame(minHeight: rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(T3WorkRowButtonStyle())
        .accessibilityLabel(failures > 0 ? "\(summary), \(failures) failed" : summary)
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
        .accessibilityHint("Double tap to \(isOpen ? "hide" : "show") \(rows.count) tool calls")
    }
}

private struct ToolWorkRowView: View {
    let row: ToolWorkRow
    let pending: Bool
    let expanded: Bool
    let toggle: () -> Void
    @ScaledMetric(relativeTo: .subheadline) private var labelSize: CGFloat = 14
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = T3Metric.workRowHeight

    private var label: String {
        if row.failed { return "\(row.name) failed" }
        if pending { return "Running \(row.name)" }
        return row.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: T3Metric.steps(1.5)) {
                    Image(systemName: ToolWork.symbol(for: row.name))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(row.failed ? ChatAppearance.danger : DSHTheme.tertiary)
                        .frame(width: T3Metric.steps(6), height: T3Metric.steps(6))
                    Text(label)
                        .font(.system(size: labelSize, weight: row.failed ? .medium : .regular))
                        .foregroundStyle(row.failed ? ChatAppearance.danger : DSHTheme.secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    T3DisclosureChevron(expanded: expanded)
                }
                .padding(.horizontal, T3Metric.steps(0.5))
                .frame(minHeight: rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(T3WorkRowButtonStyle())
            .contextMenu {
                Button("Copy details", systemImage: "doc.on.doc") { UIPasteboard.general.string = row.copyText }
            }
            .accessibilityLabel(row.failed ? "\(row.name), tool call failed" : label)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Double tap to \(expanded ? "hide" : "show") details")
            if expanded {
                ToolWorkDetail(row: row, pending: pending)
                    .padding(.leading, T3Metric.steps(7.5))
                    .padding(.top, T3Metric.steps(0.5)).padding(.bottom, T3Metric.steps(1))
                    .transition(.opacity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tool-row-\(row.id)")
    }
}

/// Bounded expanded output (T3 `max-h-60` = 210pt) with an explicit Copy.
private struct ToolWorkDetail: View {
    let row: ToolWorkRow
    let pending: Bool
    @ScaledMetric(relativeTo: .caption) private var monoSize: CGFloat = 12
    @ScaledMetric(relativeTo: .caption2) private var captionSize: CGFloat = 11
    @State private var contentHeight: CGFloat = 0
    @State private var copied = false
    /// Rendering limit only; Copy always uses the complete text.
    private static let displayLimit = 16_000

    var body: some View {
        VStack(alignment: .leading, spacing: T3Metric.steps(1.5)) {
            ScrollView {
                VStack(alignment: .leading, spacing: T3Metric.steps(1.5)) {
                    section("Input", row.arguments)
                    if row.hasResult {
                        section(row.failed ? "Error" : "Output", row.output.flatMap { $0.isEmpty ? nil : $0 } ?? "No text output")
                    } else {
                        Text(pending ? "Waiting for the result…" : "No result is recorded in this conversation.")
                            .font(.system(size: captionSize)).foregroundStyle(DSHTheme.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, T3Metric.steps(2))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(contentHeight, 1), T3Metric.workDetailMaxHeight))
            Button {
                UIPasteboard.general.string = row.copyText
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: captionSize, weight: .medium))
                    .foregroundStyle(DSHTheme.secondary)
                    .frame(minWidth: T3Metric.actionTarget, minHeight: T3Metric.steps(8), alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copied ? "Copied" : "Copy tool details")
        }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)); copied = false } catch {}
        }
    }

    @ViewBuilder private func section(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: T3Metric.steps(0.5)) {
                Text(title.uppercased())
                    .font(.system(size: captionSize, weight: .bold)).tracking(0.8)
                    .foregroundStyle(DSHTheme.tertiary)
                Text(value.count > Self.displayLimit ? String(value.prefix(Self.displayLimit)) + "\n… truncated here; Copy includes everything." : value)
                    .font(.system(size: monoSize, design: .monospaced))
                    .foregroundStyle(row.failed && title == "Error" ? ChatAppearance.danger : DSHTheme.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct T3DisclosureChevron: View {
    let expanded: Bool
    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DSHTheme.tertiary)
            .rotationEffect(.degrees(expanded ? 180 : 0))
            .frame(width: T3Metric.steps(4), height: T3Metric.steps(4))
            .accessibilityHidden(true)
    }
}

struct T3WorkRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? ChatAppearance.subtle : .clear,
                        in: RoundedRectangle(cornerRadius: T3Metric.steps(1.5), style: .continuous))
    }
}
