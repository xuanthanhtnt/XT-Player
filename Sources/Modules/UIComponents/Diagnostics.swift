import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

enum Clipboard {
    static var isAvailable: Bool {
        #if os(tvOS)
        return false
        #else
        return true
        #endif
    }

    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }
}

/// Monospaced log tail; errors in red, warnings in amber.
struct LogLines: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if lines.isEmpty {
                Text("Chưa có dòng nhật ký nào.").foregroundStyle(.secondary)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .foregroundStyle(color(for: line))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(.caption2, design: .monospaced))
        #if !os(tvOS)
        .textSelection(.enabled)
        #endif
        .padding(10)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("[error]") || line.hasPrefix("[fatal]") { return Theme.danger }
        if line.hasPrefix("[warn]") || line.hasPrefix("[xt]") { return Color(red: 1, green: 0.78, blue: 0.3) }
        return .white.opacity(0.75)
    }
}

struct LogActions: View {
    let lines: [String]
    let onRefresh: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            if Clipboard.isAvailable {
                Button {
                    Clipboard.copy(DiagnosticsReport.make(lines: lines))
                    copied = true
                } label: {
                    Label(copied ? "Đã sao chép" : "Sao chép nhật ký", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }
            Button(action: onRefresh) { Label("Làm mới", systemImage: "arrow.clockwise") }
            Button {
                MPVLogBuffer.shared.clear()
                onRefresh()
            } label: { Label("Xoá", systemImage: "trash") }
        }
        .font(.callout)
        #if !os(tvOS)
        .buttonStyle(.bordered)
        .controlSize(.small)
        #endif
        .onChange(of: lines.count) { _, _ in copied = false }
    }
}

enum DiagnosticsReport {
    static func make(lines: [String]) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return (["XT-Player \(version) (\(build)) — \(os)"] + lines).joined(separator: "\n")
    }
}

/// Settings ▸ Diagnostics: the whole buffered libmpv log.
struct DiagnosticsLogView: View {
    @State private var lines: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Ghi lại cảnh báo/lỗi của libmpv (âm thanh, giải mã, mạng) của các lần phát gần nhất. Phát lại video bị lỗi, rồi quay lại đây và sao chép.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LogActions(lines: lines, onRefresh: refresh)
                LogLines(lines: lines)
            }
            .padding(Theme.pagePadding)
        }
        .background(AppBackground())
        .navigationTitle("Nhật ký trình phát")
        .onAppear(perform: refresh)
    }

    private func refresh() { lines = MPVLogBuffer.shared.snapshot() }
}
