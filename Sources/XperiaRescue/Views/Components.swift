import SwiftUI
import XperiaRescueCore

extension USBConnectionMode {
    var color: Color {
        switch self {
        case .flashMode: return .green
        case .fastboot: return .blue
        case .android: return .orange
        case .notConnected: return .secondary
        }
    }

    var systemImage: String {
        switch self {
        case .flashMode: return "bolt.circle.fill"
        case .fastboot: return "terminal.fill"
        case .android: return "iphone"
        case .notConnected: return "cable.connector.slash"
        }
    }
}

struct ModeBadge: View {
    let mode: USBConnectionMode

    var body: some View {
        Label(mode.title, systemImage: mode.systemImage)
            .font(.callout.weight(.semibold))
            .foregroundStyle(mode == .notConnected ? Color.secondary : mode.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(mode.color.opacity(0.12), in: Capsule())
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.largeTitle.weight(.semibold))
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Page<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: title, subtitle: subtitle)
                content
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct Card<Content: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            if let systemImage {
                Label(title, systemImage: systemImage).font(.headline)
            } else {
                Text(title).font(.headline)
            }
        }
    }
}

struct CheckRow: View {
    let check: PreflightCheck

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusIcon(status: check.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title).font(.body.weight(.semibold))
                Text(check.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct StatusIcon: View {
    let status: PreflightCheck.Status

    var body: some View {
        switch status {
        case .pass: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .fail: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

struct IssueRow: View {
    let issue: FirmwareIssue

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch issue.severity {
            case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .info: Image(systemName: "info.circle.fill").foregroundStyle(.blue)
            }
            Text(issue.message).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A numbered instruction step.
struct StepRow: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .frame(width: 20, height: 20)
                .background(Color.accentColor.opacity(0.18), in: Circle())
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct KeyValueGrid: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0).foregroundStyle(.secondary)
                    Text(row.1).textSelection(.enabled)
                }
            }
        }
    }
}

struct CommandText: View {
    let command: String

    var body: some View {
        Text(command)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct Callout: View {
    enum Style { case info, warning, danger }

    let style: Style
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private var icon: String {
        switch style {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .danger: return "exclamationmark.octagon.fill"
        }
    }

    private var color: Color {
        switch style {
        case .info: return .blue
        case .warning: return .orange
        case .danger: return .red
        }
    }
}

extension Int64 {
    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
