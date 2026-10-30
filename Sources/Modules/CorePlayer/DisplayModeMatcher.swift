import Foundation

#if os(tvOS)
import AVKit
import CoreMedia
import UIKit

/// Apple TV "Match Content": asks tvOS to switch the TV to the video's frame rate and dynamic range
/// (SDR / HDR10 / HLG) through AVDisplayManager, the same mechanism AVPlayer uses.
/// Only acts when the user enabled Settings ▸ Video and Audio ▸ Match Content.
final class DisplayModeMatcher {
    private var applied: VideoSignal?

    /// Returns true when tvOS started a display mode switch (the caller should hold playback briefly).
    @discardableResult
    func match(_ signal: VideoSignal, window: UIWindow?) -> Bool {
        guard let manager = window?.avDisplayManager,
              manager.isDisplayCriteriaMatchingEnabled,
              signal.width > 0, signal.height > 0,
              signal != applied
        else { return false }
        guard let format = Self.formatDescription(for: signal) else { return false }
        applied = signal
        let rate = Float(signal.fps > 1 ? signal.fps : 60)
        manager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: rate, formatDescription: format)
        return manager.isDisplayModeSwitchInProgress
    }

    func isSwitching(window: UIWindow?) -> Bool {
        window?.avDisplayManager.isDisplayModeSwitchInProgress ?? false
    }

    func reset(window: UIWindow?) {
        applied = nil
        window?.avDisplayManager.preferredDisplayCriteria = nil
    }

    private static func formatDescription(for signal: VideoSignal) -> CMVideoFormatDescription? {
        let transfer: CFString
        switch signal.dynamicRange {
        case .hdr10, .dolbyVision: transfer = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case .hlg: transfer = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        case .sdr: transfer = kCMFormatDescriptionTransferFunction_ITU_R_709_2
        }
        let wide = signal.primaries.contains("2020") || signal.dynamicRange != .sdr
        let extensions: [String: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries as String:
                (wide ? kCMFormatDescriptionColorPrimaries_ITU_R_2020 : kCMFormatDescriptionColorPrimaries_ITU_R_709_2) as String,
            kCMFormatDescriptionExtension_TransferFunction as String: transfer as String,
            kCMFormatDescriptionExtension_YCbCrMatrix as String:
                (wide ? kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 : kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2) as String,
        ]
        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC,
            width: Int32(signal.width),
            height: Int32(signal.height),
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &format
        )
        return status == noErr ? format : nil
    }
}
#endif

#if os(iOS) || os(tvOS)
import AVFoundation

enum AudioSessionConfigurator {
    /// Long-form movie playback with as many output channels as the route offers
    /// (decoded TrueHD / DTS-HD go out as 5.1 / 7.1 multichannel LPCM over HDMI).
    static func activateForMoviePlayback() {
        let session = AVAudioSession.sharedInstance()
        do {
            #if os(iOS)
            try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo, options: [])
            #else
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            #endif
            try session.setSupportsMultichannelContent(true)
            try session.setActive(true)
            let channels = session.maximumOutputNumberOfChannels
            if channels > 2 {
                try session.setPreferredOutputNumberOfChannels(channels)
            }
        } catch {
            #if DEBUG
            print("[XT-Player] audio session: \(error)")
            #endif
        }
    }

    /// Music: keeps playing in the background and with the screen locked (UIBackgroundModes audio).
    static func activateForMusic() {
        let session = AVAudioSession.sharedInstance()
        do {
            #if os(iOS)
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            #else
            try session.setCategory(.playback, mode: .default, options: [])
            #endif
            try session.setActive(true)
        } catch {
            #if DEBUG
            print("[XT-Player] audio session (music): \(error)")
            #endif
        }
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
#endif
