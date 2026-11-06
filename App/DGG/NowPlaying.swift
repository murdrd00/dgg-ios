import MediaPlayer
import UIKit

/// The lock screen, Control Center and headphone buttons. It's all live, so there's
/// nothing to seek or pause: next and previous step through the embeds, the way
/// they'd skip tracks. Play stays, to pick up after a call or lost headphones.
@MainActor
final class NowPlaying {
    private static let art: MPMediaItemArtwork? = UIImage(named: "NowPlayingArt").map { image in
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    init(play: @escaping () -> Void, next: @escaping () -> Void,
         previous: @escaping () -> Void) {
        let center = MPRemoteCommandCenter.shared()
        func wire(_ command: MPRemoteCommand, _ action: @escaping () -> Void) {
            command.isEnabled = true
            command.addTarget { _ in
                MainActor.assumeIsolated { action() }
                return .success
            }
        }
        wire(center.playCommand, play)
        wire(center.nextTrackCommand, next)
        wire(center.previousTrackCommand, previous)
        for command: MPRemoteCommand in [
            center.pauseCommand, center.togglePlayPauseCommand, center.stopCommand,
            center.skipForwardCommand, center.skipBackwardCommand,
            center.seekForwardCommand, center.seekBackwardCommand,
            center.changePlaybackPositionCommand, center.changePlaybackRateCommand,
        ] {
            command.isEnabled = false
        }
    }

    /// `canGoNext` and `canGoBack` say whether there's another embed that way.
    func show(title: String, subtitle: String, playing: Bool, canGoNext: Bool, canGoBack: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = canGoNext
        center.previousTrackCommand.isEnabled = canGoBack
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: subtitle,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
        ]
        if let art = Self.art { info[MPMediaItemPropertyArtwork] = art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
