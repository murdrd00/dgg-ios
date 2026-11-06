import SwiftUI
import DGGKit

/// The site's user menu: who someone is, what they've just said, and the things
/// you can do about them.
struct UserCard: View {
    let nick: String
    var vm: BigscreenViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// Nil until Stalk is pressed.
    @State private var stalked: [StalkedLine]?
    @State private var stalking = false
    @State private var stalkFailed = false

    private var said: [DisplayLine] {
        vm.lines.filter { $0.line.nick.lowercased() == nick.lowercased() && $0.whisper == nil }
            .suffix(10).reversed()
    }

    private var flairs: [String] { said.first?.style.labels ?? [] }
    private var nameColor: Color {
        Color(uiColor: ChatText.uiColor(hex: said.first?.style.colorHex))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(nick).font(.title3.weight(.bold)).foregroundStyle(nameColor)
                if !flairs.isEmpty {
                    Text(flairs.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            actions
            Divider()
            history
        }
        .padding(.horizontal, 18).padding(.top, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            action("Stalk", "eye", on: stalked != nil) { Task { await stalk() } }
            action("Highlight", vm.isHighlighted(nick) ? "star.fill" : "star",
                   on: vm.isHighlighted(nick)) { vm.toggleHighlight(nick) }
            if !vm.isMe(nick) {
                action("Whisper", "envelope", on: false) {
                    vm.composerPrefill = "/w \(nick) "
                    dismiss()
                }
                .disabled(vm.accountName == nil)
                action("Ignore", "eye.slash", on: false) {
                    vm.setIgnored(nick, true)
                    dismiss()
                }
            }
            action("Logs", "doc.text", on: false) {
                var parts = URLComponents(string: "https://rustlesearch.dev/")!
                parts.queryItems = [URLQueryItem(name: "username", value: nick)]
                if let url = parts.url { openURL(url) }
            }
        }
    }

    private func action(_ title: String, _ symbol: String, on: Bool,
                        run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 17)).frame(height: 21)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity).frame(height: 56)
            .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .background(Color.raised, in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var history: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if stalking {
                    ProgressView().frame(maxWidth: .infinity)
                } else if stalkFailed {
                    note(vm.hasLoginKey ? "The site didn't answer. Try again later."
                                        : "Sign in to stalk someone.")
                }
                if let stalked {
                    if stalked.isEmpty { note("No messages from \(nick).") }
                    ForEach(stalked.reversed()) { line(text: $0.text, at: $0.at) }
                } else {
                    if said.isEmpty, !stalking, !stalkFailed { note("Nothing from \(nick) in this session.") }
                    ForEach(said) { line(text: $0.line.text, at: $0.line.at) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
    }

    private func line(text: String, at: Date) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(at, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.caption2).foregroundStyle(.secondary)
            Text(text).font(.subheadline)
        }
    }

    private func stalk() async {
        guard !stalking else { return }
        stalking = true
        stalkFailed = false
        let found = await vm.stalk(nick)
        stalking = false
        stalked = found
        stalkFailed = found == nil
    }
}
