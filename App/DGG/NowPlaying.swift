import MediaPlayer
import UIKit

/// The lock screen, Control Center and headphone buttons. Next and previous step
/// through the embeds, the way they'd skip tracks.
@MainActor
final class NowPlaying {
    private static let art: MPMediaItemArtwork? = UIImage(named: "NowPlayingArt").map { image in
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    init(play: @escaping () -> Void, pause: @escaping () -> Void,
         next: @escaping () -> Void, previous: @escaping () -> Void) {
        let center = MPRemoteCommandCenter.shared()
        func wire(_ command: MPRemoteCommand, _ action: @escaping () -> Void) {
            command.isEnabled = true
            command.addTarget { _ in
                MainActor.assumeIsolated { action() }
                return .success
            }
        }
        wire(center.playCommand, play)
        wire(center.pauseCommand, pause)
        wire(center.nextTrackCommand, next)
        wire(center.previousTrackCommand, previous)
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.playing == true { pause() } else { play() }
            }
            return .success
        }
    }

    private var playing = false

    func show(title: String, subtitle: String, playing: Bool) {
        self.playing = playing
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
        playing = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
