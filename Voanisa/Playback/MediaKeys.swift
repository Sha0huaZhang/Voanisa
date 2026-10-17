import Foundation
import MediaPlayer

/// Claims the system “now playing” position and routes F7/F8/F9 (and the
/// Control Center buttons) into the same actions as the on-screen controls.
enum MediaKeys {
    static func install(
        onPrevious: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onTogglePlayPause: @escaping () -> Void
    ) {
        let center = MPRemoteCommandCenter.shared()

        func onMain(_ action: @escaping () -> Void) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
            { _ in
                DispatchQueue.main.async { action() }
                return .success
            }
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget(handler: onMain(onPrevious))

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget(handler: onMain(onNext))

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget(handler: onMain(onTogglePlayPause))

        center.playCommand.isEnabled = true
        center.playCommand.addTarget(handler: onMain(onTogglePlayPause))

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget(handler: onMain(onTogglePlayPause))

        MPNowPlayingInfoCenter.default().playbackState = .paused
        Diagnostics.log("媒体键已注册")
    }
}
