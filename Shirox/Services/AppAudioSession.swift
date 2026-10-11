#if os(iOS)
import Foundation
import AVFoundation

/// The app's use of `AVAudioSession`, which is left alone on a Mac.
///
/// A Mac has no audio session to share: playback just plays, and the app isn't suspended in the
/// background. Touching the session there makes macOS ask for access to Apple Music, your music
/// and video activity and your media library. A build without a stable signature can't keep the
/// answer, so it asked again for every call: four or five times in a row as a player opened.
enum AppAudioSession {
    /// False on a Mac, for the Mac Catalyst app and the iPhone app alike.
    static var isManaged: Bool { !ProcessInfo.processInfo.isMacCatalystApp }

    /// Declares playback at launch. It doesn't interrupt other apps' audio; activation waits for
    /// a player to open.
    static func configureForPlayback() throws {
        guard isManaged else { return }
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    /// Takes audio focus. `notifyingOthers` lets other apps resume theirs when it's given up.
    static func activate(notifyingOthers: Bool = true) {
        guard isManaged else { return }
        try? AVAudioSession.sharedInstance().setActive(true, options: notifyingOthers ? .notifyOthersOnDeactivation : [])
    }

    /// Gives up audio focus so other apps' audio can resume.
    static func deactivate() {
        guard isManaged else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Whether audio is going to an AirPlay device. Never on a Mac, where the route isn't read.
    static var isAirPlayRouteActive: Bool {
        guard isManaged else { return false }
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
    }
}
#endif
