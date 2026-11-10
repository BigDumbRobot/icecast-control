import AppKit
import SwiftUI

/// Large status light shown at the top of the panel.
struct StatusLight: View {
    let phase: ServerPhase

    var body: some View {
        ZStack {
            Circle().fill(phase.color.opacity(0.14))
            if phase == .live {
                // Expanding ring while on air.
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                    Circle()
                        .stroke(phase.color.opacity(0.6 * (1 - t)), lineWidth: 2)
                        .scaleEffect(0.45 + 0.55 * t)
                }
            }
            Circle()
                .fill(phase.color.gradient)
                .frame(width: 24, height: 24)
                .shadow(color: phase.color.opacity(phase == .live ? 0.7 : 0), radius: 6)
            if phase.isBusy {
                ProgressView().controlSize(.small).tint(.white)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: phase)
        .accessibilityLabel(phase.title)
    }
}

/// A titled, rounded group of rows.
struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        }
    }
}

/// Label on the left, value on the right, with optional copy button.
struct InfoRow: View {
    let label: String
    let value: String
    var copyable = false
    var secret = false
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(secret && !revealed ? String(repeating: "•", count: max(6, min(value.count, 12))) : value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .font(secret || copyable ? .body.monospaced() : .body)
            if secret {
                Button { revealed.toggle() } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealed ? "Hide" : "Show")
            }
            if copyable { CopyButton(text: value) }
        }
        .font(.callout)
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .frame(width: 14)
        }
        .buttonStyle(.borderless)
        .help("Copy")
    }
}

/// Password field with a show/hide toggle, for use inside a Form.
struct PasswordField: View {
    let title: String
    @Binding var text: String
    @State private var revealed = false

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Group {
                    if revealed {
                        TextField("", text: $text)
                    } else {
                        SecureField("", text: $text)
                    }
                }
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                Button { revealed.toggle() } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealed ? "Hide password" : "Show password")
            }
        }
    }
}

struct Banner: View {
    let text: String
    var systemImage = "exclamationmark.triangle.fill"
    var tint: Color = .orange

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.12)))
    }
}

enum Format {
    static func duration(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        let days = seconds / 86_400, hours = (seconds % 86_400) / 3600, minutes = (seconds % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }
}

/// Asks the user to pick a file. Returns nil if cancelled.
@MainActor
func chooseFile(title: String, startingAt path: String) -> String? {
    NSApp.activate(ignoringOtherApps: true)
    let panel = NSOpenPanel()
    panel.title = title
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
    return panel.runModal() == .OK ? panel.url?.path : nil
}
