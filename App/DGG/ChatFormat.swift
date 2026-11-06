import UIKit
import DGGKit

/// Turns a chat row into the text that gets drawn. Runs once per line: the result
/// is cached by `LineCache`, and the row's height with it.
@MainActor
enum ChatFormat {

    static func attributed(_ item: ChatItem, emotes: EmoteImageStore) -> NSAttributedString {
        let out = NSMutableAttributedString()

        switch item {
        case .combo(_, let emote, let count, _):
            out.append(ChatText.plain("\(emote) x\(count)", .white, bold: true))
            return out

        case .message(let dl):
            // As on the site: `/me` is italic with no colon, and someone
            // following themselves gets a `>` in place of their name.
            let action = dl.line.text.lowercased().hasPrefix("/me ")
            let text = action ? String(dl.line.text.dropFirst(4)) : dl.line.text
            let continued = dl.previousNick?.lowercased() == dl.line.nick.lowercased()

            if continued {
                out.append(ChatText.plain("> ", UIColor.white.withAlphaComponent(0.35)))
            } else {
                for url in dl.style.badges {
                    if let img = emotes.badge(url) {
                        out.append(ChatText.attachment(img, height: ChatText.size * 1.15))
                        out.append(ChatText.plain(" ", .clear))
                    }
                }
                out.append(dl.style.rainbow
                           ? ChatText.rainbowNick(dl.line.nick)
                           : ChatText.plain(dl.line.nick,
                                            ChatText.uiColor(hex: dl.style.colorHex),
                                            bold: true))
                out.append(ChatText.plain(action ? " " : ": ",
                                          UIColor.white.withAlphaComponent(0.6)))
            }

            let words = text.split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)
            // Greentext is a perk: subscribers and staff only, as on the site.
            let green = text.hasPrefix(">")
                && !Set(dl.line.features).isDisjoint(with: ["subscriber", "moderator", "protected", "admin"])
            let textColor = green ? ChatText.greentext : UIColor.white
            // Every emote in the message at once: how each is drawn can depend
            // on the others beside it.
            var looks = emotes.looks(EmoteContext(
                username: dl.line.nick, flairs: dl.line.features,
                previousUsername: dl.previousNick,
                emotes: words.filter(emotes.isEmote)))[...]

            for (i, word) in words.enumerated() {
                if i > 0 { out.append(ChatText.plain(" ", textColor, italic: action)) }
                if emotes.isEmote(word), let look = looks.popFirst() {
                    out.append(ChatText.emote(look, store: emotes))
                } else if ChatText.isLink(word) {
                    out.append(ChatText.link(word))
                } else {
                    out.append(ChatText.plain(word, textColor, italic: action))
                }
            }
            return out
        }
    }
}
