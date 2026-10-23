import SwiftUI

struct OpenURLSheet: View {
    let onOpen: (MediaSource) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var invalid = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Mở URL / NAS", systemImage: "network")
                .font(.title2.weight(.bold))
            Text("Dán đường dẫn trực tiếp tới tệp phim, ví dụ http://192.168.1.10:5005/Movies/Dune.2160p.DV.mkv. Tài khoản có thể ghi kèm: http://user:pass@nas.local/…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("http://", text: $text)
                .focused($fieldFocused)
                .autocorrectionDisabled()
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                #if !os(tvOS)
                .textFieldStyle(.roundedBorder)
                #endif
                .onSubmit(submit)

            if invalid {
                Text("URL chưa hợp lệ. Hỗ trợ: http, https, ftp, rtsp, rtmp.")
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
            }

            HStack {
                Button("Huỷ", role: .cancel) { dismiss() }
                Spacer()
                Button(action: submit) {
                    Label("Phát", systemImage: "play.fill")
                }
                #if !os(tvOS)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                #endif
            }
        }
        .padding(28)
        #if os(macOS)
        .frame(width: 520)
        #endif
        .onAppear { fieldFocused = true }
    }

    private func submit() {
        guard let source = MediaSource.fromUserInput(text) else {
            invalid = true
            return
        }
        invalid = false
        onOpen(source)
    }
}
