import Foundation
import CoreGraphics

/// The gamma backend writes persistent display state. If this process dies
/// without restoring it, the user's display stays wrong until they log out.
/// Defence in depth: normal termination, atexit, and fatal signals all restore.
enum SafetyNet {

    /// Called before anything else at launch, to clear state stranded by a
    /// previous crash.
    static func restoreStrandedState() {
        CGDisplayRestoreColorSyncSettings()
        log("SafetyNet: restored colour sync settings at launch")
    }

    static func install() {
        atexit {
            CGDisplayRestoreColorSyncSettings()
        }

        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig) { _ in
                CGDisplayRestoreColorSyncSettings()
                _exit(0)
            }
        }
        log("SafetyNet: installed exit and signal handlers")
    }

    /// Unconditional restore. Safe to call repeatedly.
    static func restoreNow() {
        CGDisplayRestoreColorSyncSettings()
    }
}
