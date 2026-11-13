import Foundation
#if os(macOS)
import IOKit.pwr_mgt
#else
import UIKit
#endif

/// Keeps the screen on while a video plays. mpv's own screensaver inhibition only works in its own window, so
/// without this macOS dims, sleeps and locks the display after the idle timeout in the middle of a film.
@MainActor
enum DisplaySleepBlocker {
    #if os(macOS)
    private static var assertion: IOPMAssertionID = 0
    #endif

    static func set(_ active: Bool) {
        #if os(macOS)
        if active, assertion == 0 {
            var id: IOPMAssertionID = 0
            let status = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "XT-Player đang phát video" as CFString, &id)
            if status == kIOReturnSuccess { assertion = id }
        } else if !active, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        #else
        UIApplication.shared.isIdleTimerDisabled = active
        #endif
    }
}
