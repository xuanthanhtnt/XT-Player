#if !os(tvOS)
import SwiftUI

/// Shown on this device while the video plays on the TV (like Infuse's AirPlay screen).
struct AirPlayActiveView: View {
    @ObservedObject var controller: AirPlayController
    let title: String
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 22) {
                Image(systemName: "airplayvideo")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(Theme.brandGradient)
                VStack(spacing: 6) {
                    Text("Đang phát trên \(controller.deviceName)")
                        .font(.title2.weight(.bold))
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                VStack(spacing: 6) {
                    ProgressLine(value: controller.duration > 0 ? controller.position / controller.duration : 0)
                    HStack {
                        Text(TimeFormat.clock(controller.position))
                        Spacer()
                        Text("-" + TimeFormat.clock(max(0, controller.duration - controller.position)))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                }
                .frame(maxWidth: 420)
                HStack(spacing: 36) {
                    transport("gobackward.10", size: 24) { controller.seek(by: -10) }
                    transport(controller.isPlaying ? "pause.fill" : "play.fill", size: 34) { controller.togglePlayback() }
                    transport("goforward.30", size: 24) { controller.seek(by: 30) }
                }
                HStack(spacing: 14) {
                    AirPlayButton(controller: controller, size: 34)
                    Button("Phát trên thiết bị này") { controller.stop() }
                        .buttonStyle(.bordered)
                    Button("Đóng", action: onClose)
                        .buttonStyle(.bordered)
                }
            }
            .padding(32)
            .foregroundStyle(.white)
        }
        .environment(\.colorScheme, .dark)
    }

    private func transport(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 56, height: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
