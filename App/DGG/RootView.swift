import SwiftUI
import DGGKit

@main
struct DGGApp: App {
    init() {
        // Emotes rarely change, and the default cache is too small to hold them,
        // so every launch would fetch them all again.
        URLCache.shared = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)
    }

    var body: some Scene {
        WindowGroup {
            RootView().preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @State private var vm = BigscreenViewModel()
    @State private var emotes = EmoteImageStore()
    @State private var showSettings = false
    @State private var chatShown = true
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    private let rank = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    private let liveness = Timer.publish(every: 25, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { box in
            let landscape = box.size.width > box.size.height
            let layout = landscape ? AnyLayout(HStackLayout(spacing: 0))
                                   : AnyLayout(VStackLayout(spacing: 0))
            layout {
                if vm.selected != nil {
                    PlayerArea(vm: vm, landscape: landscape, chatShown: $chatShown, onClose: close)
                        .aspectRatio(landscape ? nil : 16 / 9, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: landscape ? .infinity : nil)
                        .ignoresSafeArea(.container, edges: landscape ? .all : [])
                }
                if !landscape || chatShown || vm.selected == nil {
                    chatColumn
                        .frame(width: landscape && vm.selected != nil ? min(320, box.size.width * 0.38) : nil)
                }
            }
        }
        .background(Color(white: 0.06).ignoresSafeArea())
        .task {
            ChatText.size = vm.chatFontSize
            vm.start()
            await emotes.load()
            vm.emotePrefixes = emotes.allPrefixes
        }
        .onReceive(rank) { _ in vm.tick() }
        .onReceive(liveness) { _ in vm.refreshLiveness() }
        // YouTube plays in a web view, which the player state knows nothing about.
        .onChange(of: vm.isPlaying || vm.selected?.platform == .youtube, initial: true) { _, on in
            UIApplication.shared.isIdleTimerDisabled = on
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: vm.suspend()
            case .active:
                vm.foregrounded()
                vm.resume()
            default: break
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(vm: vm)
                .presentationDetents([.large])
        }
    }

    private var chatColumn: some View {
        VStack(spacing: 0) {
            EmbedStrip(vm: vm, onPick: watch, onSettings: { showSettings = true })
            if let pin = vm.shownPin { PinCard(pin: pin, vm: vm, emotes: emotes) }
            PollCard(vm: vm)
            ChatList(vm: vm, emotes: emotes, onLink: follow)
            Composer(vm: vm, emotes: emotes, onSignIn: { showSettings = true })
        }
    }

    private func watch(_ ref: EmbedRef) {
        vm.isWatching = true
        vm.select(ref)
    }

    private func close() {
        vm.isWatching = false
        vm.stopPlayback()
    }

    /// An embed link plays here, and anything else opens outside the app.
    private func follow(_ word: String) {
        if let ref = EmbedRef.scan(word).first, ref.playsInApp || ref.platform == .youtube {
            watch(ref)
            return
        }
        let text = word.contains("://") ? word : "https://\(word)"
        if let url = URL(string: text) { openURL(url) }
    }
}

/// What's on, as a row of pills, with the connection state and Settings at the end.
struct EmbedStrip: View {
    var vm: BigscreenViewModel
    var onPick: (EmbedRef) -> Void
    var onSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 6) {
                        ForEach(vm.switchableEmbeds) { entry in
                            pill(entry).id(entry.ref)
                        }
                    }
                    .padding(.leading, 10)
                }
                .scrollIndicators(.hidden)
                .onChange(of: vm.selected) { _, ref in
                    guard let ref else { return }
                    withAnimation(.snappy(duration: 0.28)) {
                        proxy.scrollTo(ref, anchor: .center)
                    }
                }
            }
            if vm.pinIsHidden {
                Button { vm.togglePin() } label: {
                    Image(systemName: "pin").foregroundStyle(.secondary)
                }
            }
            Circle().fill(vm.connected ? .green : .orange).frame(width: 7, height: 7)
            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
            }
            .padding(.trailing, 4)
        }
        .frame(height: 44)
    }

    private func pill(_ entry: EmbedTracker.Entry) -> some View {
        let on = entry.ref == vm.selected
        return Button { onPick(entry.ref) } label: {
            HStack(spacing: 5) {
                PlatformIcon(platform: entry.ref.platform).frame(width: 13, height: 13)
                Text(vm.name(for: entry.ref))
                    .font(.footnote.weight(on ? .semibold : .regular))
                    .lineLimit(1)
                Text("\(entry.viewers)")
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(on ? AnyShapeStyle(.black.opacity(0.6)) : AnyShapeStyle(.secondary))
            }
            .foregroundStyle(on ? .black : .white)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(on ? Color.white : Color.white.opacity(0.1), in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

/// Tap to hide, as the site's close button does.
struct PinCard: View {
    let pin: DisplayLine
    var vm: BigscreenViewModel
    var emotes: EmoteImageStore
    /// The same text object each redraw, or its emotes would restart.
    @State private var cache = LineCache()

    var body: some View {
        GeometryReader { box in
            ChatLineLabel(
                attributed: cache.string(id: pin.id, generation: emotes.generation,
                                         size: vm.chatFontSize) {
                    ChatFormat.attributed(.message(pin), emotes: emotes)
                },
                width: box.size.width)
        }
        .frame(height: vm.chatFontSize * 3.3)
        .clipped()
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.white.opacity(0.07))
        .overlay(alignment: .topTrailing) {
            Button { vm.togglePin() } label: {
                Image(systemName: "xmark").font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary).padding(8)
            }
        }
    }
}

struct PollCard: View {
    var vm: BigscreenViewModel

    var body: some View {
        if let poll = vm.poll {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(poll.question).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    if poll.ended {
                        Text("Ended").font(.caption).foregroundStyle(.secondary)
                    } else if poll.ends > .now {
                        Text(timerInterval: Date.now...poll.ends, countsDown: true)
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                ForEach(poll.options.indices, id: \.self) { row($0, poll) }
            }
            .padding(10)
            .background(Color.white.opacity(0.07))
        }
    }

    private func row(_ i: Int, _ poll: ChatPoll) -> some View {
        let share = poll.votes > 0 ? Double(poll.totals[i]) / Double(poll.votes) : 0
        let mine = poll.myVote == i + 1 || vm.sentVote == i + 1
        return Button { vm.vote(i) } label: {
            HStack(spacing: 6) {
                if mine { Image(systemName: "checkmark").font(.caption) }
                Text(poll.options[i]).lineLimit(1)
                Spacer(minLength: 8)
                if !poll.hidden { Text("\(Int((share * 100).rounded()))%").monospacedDigit() }
            }
            .font(.footnote)
            .foregroundStyle(.white)
            .padding(.horizontal, 10).frame(height: 32)
            .background {
                GeometryReader { box in
                    ZStack(alignment: .leading) {
                        Color.white.opacity(0.08)
                        if !poll.hidden {
                            Color.white.opacity(0.2).frame(width: box.size.width * share)
                        }
                    }
                }
            }
            .clipShape(.rect(cornerRadius: 8))
            .animation(.easeOut(duration: 0.2), value: share)
        }
        .buttonStyle(.plain)
        .disabled(!vm.pollTakesRemote)
    }
}

/// The message box, with emotes offered as you type.
struct Composer: View {
    var vm: BigscreenViewModel
    var emotes: EmoteImageStore
    var onSignIn: () -> Void

    @State private var draft = ""
    @FocusState private var typing: Bool
    private static let longest = 512

    private var lastWord: Substring {
        draft.split(separator: " ", omittingEmptySubsequences: false).last ?? ""
    }

    private var suggestions: [String] {
        guard lastWord.count >= 2 else { return [] }
        let start = lastWord.lowercased()
        return emotes.allPrefixes
            .filter { $0.lowercased().hasPrefix(start) && $0 != lastWord }
            .sorted().prefix(12).map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let notice = vm.chatNotice {
                Text(notice).font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.top, 4)
            }
            if typing, !suggestions.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(suggestions, id: \.self) { name in
                            Button(name) { complete(name) }
                                .font(.footnote).buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .scrollIndicators(.hidden)
                .padding(.top, 6)
            }
            if vm.accountName != nil {
                field
            } else {
                Button(action: onSignIn) {
                    Text(vm.hasLoginKey ? vm.accountLabel : "Sign in to chat")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).frame(height: 38)
                }
            }
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .font(.subheadline)
                .focused($typing)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.send)
                .onChange(of: draft) { _, new in
                    // Return sends, which a multi-line field reports as a newline.
                    if new.contains("\n") {
                        draft = new.replacingOccurrences(of: "\n", with: "")
                        send()
                    } else if new.count > Self.longest {
                        draft = String(new.prefix(Self.longest))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.white.opacity(0.1), in: .rect(cornerRadius: 18))
            if !draft.isEmpty {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func complete(_ name: String) {
        draft = String(draft.dropLast(lastWord.count)) + name + " "
    }

    private func send() {
        vm.send(draft)
        draft = ""
    }
}

struct SettingsView: View {
    @Bindable var vm: BigscreenViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""

    private static let keyPage = URL(string: "https://www.destiny.gg/profile/developer")!

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Account", value: vm.accountLabel)
                    if vm.hasLoginKey {
                        Button("Sign out", role: .destructive) { vm.setLoginKey(nil) }
                    } else {
                        SecureField("Login Key", text: $key)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Sign in") {
                            vm.setLoginKey(key)
                            key = ""
                        }
                        .disabled(key.isEmpty)
                        Link("Get a Login Key", destination: Self.keyPage)
                    }
                } header: {
                    Text("Account")
                } footer: {
                    Text("Create a key under Profile, then Developer. It stays in this phone's Keychain and is only sent to destiny.gg chat. Treat it like a password.")
                }

                Section("Chat") {
                    LabeledContent("Text size") {
                        Stepper("\(Int(vm.chatFontSize))", value: $vm.chatFontSize, in: 12...22)
                    }
                    Toggle("Darken other embeds' chat", isOn: $vm.darkensOtherEmbeds)
                }

                Section {
                    Toggle("Hide offline channels", isOn: $vm.hideOffline)
                    Toggle("Latency counter", isOn: $vm.latencyShown)
                    LabeledContent("Low delay") {
                        Text(vm.liveCushion >= BigscreenViewModel.liveDelayOff
                             ? "Off" : "\(Int(vm.liveCushion))s buffer")
                    }
                    Slider(value: $vm.liveCushion, in: 1...BigscreenViewModel.liveDelayOff, step: 1)
                } header: {
                    Text("Streams")
                } footer: {
                    Text("Low delay applies to Kick. If a stream buffers a lot, raise it: more seconds means more delay but fewer stalls.")
                }

                Section("About") {
                    LabeledContent("Version", value: version)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
