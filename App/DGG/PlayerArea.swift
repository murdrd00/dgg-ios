import SwiftUI
import WebKit
import AVKit
import DGGKit

/// YouTube can't be resolved to a stream on the device, but iOS has a web engine,
/// so its own player does the job. Loaded under the site's address because
/// YouTube refuses to play for a page with no origin.
struct YouTubePlayer: UIViewRepresentable {
    let videoID: String

    final class Coordinator { var loaded: String? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard context.coordinator.loaded != videoID else { return }
        context.coordinator.loaded = videoID
        let html = """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <style>html,body{margin:0;height:100%;background:#000}iframe{border:0;width:100%;height:100%}</style>
        </head><body><iframe allow="autoplay; encrypted-media; picture-in-picture" allowfullscreen
        referrerpolicy="strict-origin-when-cross-origin"
        src="https://www.youtube.com/embed/\(videoID)?autoplay=1&playsinline=1&rel=0"></iframe></body></html>
        """
        web.loadHTMLString(html, baseURL: URL(string: "https://www.destiny.gg"))
    }
}

/// The picture, and everything done to it by touch. A sideways drag follows the
/// finger and shows what's next; only going far enough changes stream.
struct PlayerArea: View {
    var vm: BigscreenViewModel
    var landscape: Bool
    @Binding var chatShown: Bool
    var onClose: () -> Void

    @State private var drag: CGFloat = 0
    @State private var controls = true
    @State private var hideControls: Task<Void, Never>?
    @State private var pipRequest = 0

    private static let toSwitch: CGFloat = 110

    private var isYouTube: Bool { vm.selected?.platform == .youtube }

    private var neighbour: EmbedTracker.Entry? {
        guard drag != 0 else { return nil }
        let list = vm.switchableEmbeds
        guard let at = list.firstIndex(where: { $0.ref == vm.selected }) else { return nil }
        let next = at + (drag < 0 ? 1 : -1)
        return list.indices.contains(next) ? list[next] : nil
    }

    /// Eases off past the switch point, and sooner if there's nothing that way.
    private var stretch: CGFloat {
        let limit: CGFloat = neighbour == nil ? 40 : 150
        let d = abs(drag)
        return (drag < 0 ? -1 : 1) * limit * (1 - exp(-d / limit))
    }

    var body: some View {
        ZStack {
            Color.black
            picture
                .offset(x: stretch)
            if let next = neighbour {
                nextLabel(next)
            }
            if let error = vm.playerError {
                errorCard(error)
            } else if vm.noPicture, !isYouTube {
                errorCard("No picture from this stream yet.")
            }
            // YouTube's player takes taps for itself, so one couldn't bring
            // these back. It keeps them up.
            if controls || isYouTube { controlsLayer.transition(.opacity) }
        }
        .clipped()
        .contentShape(.rect)
        .onTapGesture { toggleControls() }
        .simultaneousGesture(swipe)
        .onAppear { pokeControls() }
    }

    @ViewBuilder
    private var picture: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { i in
                LivePlayerView(player: vm.players[i], isCurrent: i == vm.active,
                               pipOnLeave: vm.pipOnLeave, pipRequest: pipRequest,
                               onPipChange: { vm.pipActive = $0 }) { vm.setDisplayReady($0, player: i) }
                    .opacity(vm.fadingOut == i ? 0 : 1)
                    .zIndex(i == vm.top ? 1 : 0)
            }
            #if DEBUG
            if let poster = vm.stagePoster {
                Image(uiImage: poster).resizable().scaledToFill().zIndex(3)
            }
            #endif
            if vm.pipActive {
                Label("Playing in Picture in Picture", systemImage: "pip")
                    .font(.footnote).foregroundStyle(.white.opacity(0.7)).zIndex(2)
            } else if let ref = vm.selected, ref.platform == .youtube {
                YouTubePlayer(videoID: ref.path).zIndex(2)
            } else if vm.selected != nil, !vm.isPlaying, vm.playerError == nil {
                ProgressView().tint(.white).zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: vm.fadingOut)
    }

    private func nextLabel(_ entry: EmbedTracker.Entry) -> some View {
        let ready = abs(drag) >= Self.toSwitch
        return HStack(spacing: 6) {
            PlatformIcon(platform: entry.ref.platform).frame(width: 14, height: 14)
            Text(vm.name(for: entry.ref)).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        .foregroundStyle(ready ? .black : .white)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(ready ? AnyShapeStyle(.white) : AnyShapeStyle(.black.opacity(0.6)), in: .capsule)
        .scaleEffect(ready ? 1.06 : 1)
        .animation(.snappy(duration: 0.16), value: ready)
        .allowsHitTesting(false)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 10) {
            Text(message).font(.subheadline).foregroundStyle(.white).multilineTextAlignment(.center)
            Button("Try again") { vm.retryStream() }
                .buttonStyle(.bordered).tint(.white)
        }
        .padding()
    }

    private var controlsLayer: some View {
        VStack {
            HStack {
                roundButton("xmark", action: onClose)
                Spacer()
                if vm.latencyShown, vm.selected?.platform != .youtube {
                    LatencyBadge(player: vm.player)
                }
                if !isYouTube {
                    roundButton("headphones") {
                        withAnimation(.snappy(duration: 0.25)) { vm.audioOnly = true }
                    }
                    if AVPictureInPictureController.isPictureInPictureSupported() {
                        roundButton(vm.pipActive ? "pip.exit" : "pip.enter") { pipRequest += 1 }
                    }
                }
                if landscape {
                    roundButton(chatShown ? "bubble.left.fill" : "bubble.left") {
                        withAnimation(.snappy(duration: 0.25)) { chatShown.toggle() }
                    }
                }
            }
            Spacer()
        }
        .padding(10)
    }

    private func roundButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.black.opacity(0.5), in: .circle)
        }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // Mostly-vertical drags aren't for this.
                guard drag != 0 || abs(value.translation.width) > abs(value.translation.height) else { return }
                drag = value.translation.width
            }
            .onEnded { value in
                let flicked = abs(value.predictedEndTranslation.width) > Self.toSwitch * 2
                if drag != 0, abs(drag) >= Self.toSwitch || flicked {
                    vm.step(drag < 0 ? 1 : -1)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                withAnimation(.snappy(duration: 0.24)) { drag = 0 }
            }
    }

    private func toggleControls() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        withAnimation(.easeOut(duration: 0.18)) { controls.toggle() }
        if controls { pokeControls() }
    }

    private func pokeControls() {
        hideControls?.cancel()
        hideControls = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { controls = false }
        }
    }
}

/// Audio only: a slim bar in place of the picture, so chat gets the room. Drags the
/// same way the picture does, following the finger before it switches.
struct AudioBar: View {
    var vm: BigscreenViewModel
    var onClose: () -> Void

    @State private var drag: CGFloat = 0
    private static let toSwitch: CGFloat = 90

    private var name: String { vm.selected.map(vm.name(for:)) ?? "" }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Color.raised, in: .circle)
            }
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, isActive: vm.isPlaying)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(vm.isPlaying ? "Audio only" : "Connecting…")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .offset(x: 60 * (1 - exp(-abs(drag) / 60)) * (drag < 0 ? -1 : 1))
            Spacer(minLength: 8)
            Button {
                withAnimation(.snappy(duration: 0.25)) { vm.audioOnly = false }
            } label: {
                Label("Video", systemImage: "play.rectangle.fill")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(Color.raised, in: .capsule)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(height: 54)
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { drag = $0.translation.width }
                .onEnded { _ in
                    if abs(drag) >= Self.toSwitch {
                        vm.step(drag < 0 ? 1 : -1)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    withAnimation(.snappy(duration: 0.24)) { drag = 0 }
                })
    }
}
