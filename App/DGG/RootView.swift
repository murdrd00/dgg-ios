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
            RootView()
                .tint(Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
                    // The light blue from the icon, deeper on a light page.
                    ? UIColor(red: 0.36, green: 0.68, blue: 0.95, alpha: 1)
                    : UIColor(red: 0.05, green: 0.42, blue: 0.78, alpha: 1) }))
        }
    }
}

extension Color {
    /// The page behind chat.
    static let page = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.06, alpha: 1) : .systemBackground })
    /// Pills, cards and fields, a step off the page in either mode.
    static let raised = Color.primary.opacity(0.08)
}

/// Who the user card is open for.
struct ChatUserRef: Identifiable {
    let nick: String
    var id: String { nick }
}

struct RootView: View {
    @State private var vm = BigscreenViewModel()
    @State private var emotes = EmoteImageStore()
    @State private var showSettings = false
    @State private var chatShown = true
    @State private var card: ChatUserRef?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    private let rank = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    private let liveness = Timer.publish(every: 25, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { box in
            let landscape = box.size.width > box.size.height
            // Audio only has no picture to sit beside, so chat keeps the full width.
            let sideBySide = landscape && !vm.audioMode
            let layout = sideBySide ? AnyLayout(HStackLayout(spacing: 0))
                                    : AnyLayout(VStackLayout(spacing: 0))
            layout {
                // `streamURL` alone means the test stream hook, with nothing selected.
                if vm.audioMode, vm.selected != nil {
                    AudioBar(vm: vm, onClose: close)
                } else if vm.selected != nil || vm.streamURL != nil {
                    PlayerArea(vm: vm, landscape: sideBySide, chatShown: $chatShown, onClose: close)
                        .aspectRatio(sideBySide ? nil : 16 / 9, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: sideBySide ? .infinity : nil)
                        // Up to the screen edge, past the island, in landscape.
                        .ignoresSafeArea(.container, edges: sideBySide ? [.leading, .vertical] : [])
                }
                if !sideBySide || chatShown || vm.selected == nil {
                    chatColumn
                        .frame(width: sideBySide && vm.selected != nil ? min(320, box.size.width * 0.38) : nil)
                }
            }
        }
        .background(Color.page.ignoresSafeArea())
        .task {
            ChatText.size = vm.chatFontSize
            vm.start()
            #if DEBUG
            runTestHooks()
            #endif
            await emotes.load()
            vm.emotePrefixes = emotes.allPrefixes
            #if DEBUG
            vm.stageChat()
            #endif
        }
        .onReceive(rank) { _ in vm.tick() }
        .onReceive(liveness) { _ in vm.refreshLiveness() }
        // YouTube plays in a web view, which the player state knows nothing about.
        // Audio only leaves the phone free to lock, which saves the battery.
        .onChange(of: (vm.isPlaying && !vm.audioMode) || vm.selected?.platform == .youtube,
                  initial: true) { _, on in
            UIApplication.shared.isIdleTimerDisabled = on
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: vm.enteredBackground()
            case .active:     vm.enteredForeground()
            default: break
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(vm: vm)
                .presentationDetents([.large])
        }
        .sheet(item: $card) { user in
            UserCard(nick: user.nick, vm: vm)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var chatColumn: some View {
        VStack(spacing: 0) {
            EmbedStrip(vm: vm, onPick: watch, onSettings: { showSettings = true })
            if let pin = vm.shownPin { PinCard(pin: pin, vm: vm, emotes: emotes) }
            PollCard(vm: vm)
            ChatList(vm: vm, emotes: emotes, onLink: follow,
                     onUser: { card = ChatUserRef(nick: $0) })
            Composer(vm: vm, emotes: emotes, onSignIn: { showSettings = true })
        }
    }

    #if DEBUG
    private func runTestHooks() {
        let env = ProcessInfo.processInfo.environment
        if let nick = env["DGG_TEST_SIGNED_IN"] { vm.pretendToSignIn(as: nick) }
        if env["DGG_TEST_POLL"] != nil { vm.runFakePoll() }
        if let id = env["DGG_TEST_YOUTUBE"] { watch(EmbedRef(platform: .youtube, path: id)) }
    }
    #endif

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
                // Pills fade out at the end instead of being cut off.
                .mask {
                    HStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .leading,
                                       endPoint: .trailing).frame(width: 18)
                    }
                }
                .onChange(of: vm.selected) { _, ref in
                    guard let ref else { return }
                    withAnimation(.snappy(duration: 0.28)) {
                        proxy.scrollTo(ref, anchor: .center)
                    }
                }
            }
            if vm.pinIsHidden {
                Button { vm.togglePin() } label: {
                    Image(systemName: "pin").foregroundStyle(Color.primary.opacity(0.65))
                }
            }
            HStack(spacing: 4) {
                Circle().fill(vm.connected ? .green : .orange).frame(width: 7, height: 7)
                if vm.connected {
                    Text(vm.viewerCount.formatted())
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(vm.connected ? "\(vm.viewerCount) connected" : vm.link.label)
            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(Color.primary.opacity(0.65))
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
                    .foregroundStyle(on ? AnyShapeStyle(Color.page.opacity(0.65)) : AnyShapeStyle(.secondary))
            }
            .foregroundStyle(on ? Color.page : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(on ? Color.primary : Color.raised, in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

private struct PinHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Tap to read the whole pin, and the cross hides it, as on the site.
struct PinCard: View {
    let pin: DisplayLine
    var vm: BigscreenViewModel
    var emotes: EmoteImageStore
    /// The same text object each redraw, or its emotes would restart.
    @State private var cache = LineCache()
    @State private var open = false
    @State private var fullHeight: CGFloat = 0

    /// Two whole lines, so a long pin never stops halfway through one.
    private var collapsed: CGFloat { (vm.chatFontSize * 1.62).rounded() * 2 }

    private var text: NSAttributedString {
        cache.string(id: pin.id, generation: emotes.generation, size: vm.chatFontSize) {
            ChatFormat.attributed(.message(pin), emotes: emotes)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            GeometryReader { box in
                let full = ceil(text.boundingRect(
                    with: CGSize(width: box.size.width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin], context: nil).height)
                ChatLineLabel(attributed: text, width: box.size.width)
                    .preference(key: PinHeight.self, value: full)
            }
            .onPreferenceChange(PinHeight.self) { fullHeight = $0 }
            .frame(height: open ? max(collapsed, fullHeight) : min(collapsed, max(fullHeight, 1)))
            .clipped()
            Button { vm.togglePin() } label: {
                Image(systemName: "xmark").font(.caption2.weight(.bold))
                    .foregroundStyle(Color.primary.opacity(0.65))
                    .frame(width: 22, height: 22)
            }
        }
        // Line height puts its slack above the text, so less padding goes on top
        // for the card to look even.
        .padding(.leading, 12).padding(.trailing, 8)
        .padding(.top, 2).padding(.bottom, 10)
        .background(Color.raised)
        .contentShape(.rect)
        // A long pin was cut off with no way to read the rest.
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                            to: nil, from: nil, for: nil)
            guard fullHeight > collapsed else { return }
            withAnimation(.snappy(duration: 0.25)) { open.toggle() }
        }
    }
}

struct PollCard: View {
    var vm: BigscreenViewModel
    private static let rowHeight: CGFloat = 40
    private static let gap: CGFloat = 6
    // The site's `$color-darkred` and `$color-blue`.
    private static let bar = Color(red: 0x85 / 255, green: 0, blue: 0)
    private static let timer = Color(red: 0, green: 0x79 / 255, blue: 0xbf / 255)

    var body: some View {
        if let poll = vm.poll, !vm.pollDismissed {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Text(poll.question).font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { vm.pollDismissed = true } label: {
                        Image(systemName: "xmark").font(.caption2.weight(.bold))
                            .foregroundStyle(Color.primary.opacity(0.65))
                            .frame(width: 22, height: 22)
                    }
                }
                HStack {
                    Text(summary(poll)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(poll.votes == 1 ? "1 vote" : "\(poll.votes.formatted()) votes").monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
                // A long poll scrolls, or under the video it would leave no
                // room for chat. Half a row showing says there's more.
                ScrollView {
                    VStack(spacing: Self.gap) {
                        ForEach(poll.options.indices, id: \.self) { row($0, poll) }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
                .frame(height: min(Double(poll.options.count), 2.5) * (Self.rowHeight + Self.gap) - Self.gap)
                if !poll.ended { timeLeft(poll) }
            }
            .padding(10)
            .background(Color.raised)
        }
    }

    private func summary(_ poll: ChatPoll) -> String {
        let kind = poll.weighted ? "Sub-weighted poll" : poll.hidden ? "Hidden poll" : "Poll"
        guard !poll.ended else { return "\(kind) ended" }
        let seconds = Int(poll.length.rounded())
        return "\(kind) started by \(poll.startedBy) for \(seconds) second\(seconds == 1 ? "" : "s")."
    }

    /// Runs down with the clock. Its own small view, so only this redraws.
    private func timeLeft(_ poll: ChatPoll) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let left = poll.ends.timeIntervalSince(context.date)
            let share = poll.length > 0 ? min(1, max(0, left / poll.length)) : 0
            GeometryReader { box in
                Self.timer.frame(width: box.size.width * share)
            }
        }
        .frame(height: 4)
        .background(Color.primary.opacity(0.12))
        .clipShape(.capsule)
    }

    private func winner(_ poll: ChatPoll) -> Int? {
        guard poll.ended, !poll.hidden, let top = poll.totals.max(), top > 0 else { return nil }
        return poll.totals.firstIndex(of: top)
    }

    private func row(_ i: Int, _ poll: ChatPoll) -> some View {
        let share = poll.votes > 0 ? Double(poll.totals[i]) / Double(poll.votes) : 0
        let mine = poll.myVote == i + 1 || vm.sentVote == i + 1
        let votes = poll.totals[i]
        return Button { vm.vote(i) } label: {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Text("\(i + 1)").font(.footnote.weight(.bold)).monospacedDigit()
                    Text(poll.options[i]).font(.footnote.weight(.semibold)).lineLimit(1)
                    if mine { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
                    Spacer(minLength: 8)
                    if !poll.hidden {
                        Text("\(Int((share * 100).rounded()))% (\(votes.formatted()) vote\(votes == 1 ? "" : "s"))")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                GeometryReader { box in
                    ZStack(alignment: .leading) {
                        Color.primary.opacity(0.12)
                        if !poll.hidden {
                            (winner(poll) == i ? Color.green.opacity(0.7) : Self.bar)
                                .frame(width: box.size.width * share)
                        }
                    }
                }
                .frame(height: 8)
                .clipShape(.capsule)
                .animation(.easeOut(duration: 0.2), value: share)
            }
            .frame(height: Self.rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
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
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .prefix(12).map { $0 }
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
                            Button { complete(name) } label: { suggestion(name) }
                                .buttonStyle(.plain)
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
                        .font(.footnote.weight(.medium))
                        .frame(maxWidth: .infinity).frame(height: 38)
                }
            }
        }
    }

    /// The emote itself beside its name, so you can see what you're picking.
    private func suggestion(_ name: String) -> some View {
        HStack(spacing: 5) {
            if let look = emotes.preview(name) {
                let box: CGFloat = 26
                let size = min(box / CGFloat(max(look.base.height, 1)), 64 / CGFloat(look.advance))
                EmoteView(look: look, scale: size, store: emotes)
                    .frame(width: CGFloat(look.advance) * size, height: box)
                    .clipped()
            }
            Text(name).font(.footnote).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(Color.raised, in: .capsule)
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
                .background(Color.raised, in: .rect(cornerRadius: 18))
            if !draft.isEmpty {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .onChange(of: vm.composerPrefill, initial: true) { _, _ in takePrefill() }
    }

    /// Whisper, from the user card, fills the box and hands over the keyboard.
    private func takePrefill() {
        guard let text = vm.composerPrefill else { return }
        vm.composerPrefill = nil
        draft = text
        typing = true
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
                    LabeledContent("Signed in as", value: vm.accountLabel)
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
                    Text("Create a key under Profile, then Developer. It stays in this phone's Keychain and is only sent to destiny.gg. Treat it like a password.")
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
                    Toggle("Keep playing in the background", isOn: $vm.backgroundAudio)
                    Toggle("Picture in Picture on leaving", isOn: $vm.pipOnLeave)
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

                if !vm.ignored.isEmpty {
                    Section("Ignored") {
                        ForEach(vm.ignored.sorted(), id: \.self) { nick in
                            HStack {
                                Text(nick)
                                Spacer()
                                Button("Unignore") { vm.setIgnored(nick, false) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
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
