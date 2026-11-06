import SwiftUI
import UIKit
import DGGKit

/// Chat, as a table rather than a SwiftUI list. At ~400 messages a minute this is
/// the hottest thing in the app, and it has to keep up with a finger at 120Hz:
/// rows are reused, each line is measured once, and a batch of new lines is one
/// small update instead of a redraw of the whole list.
struct ChatList: UIViewControllerRepresentable {
    var vm: BigscreenViewModel
    var emotes: EmoteImageStore
    var onLink: (String) -> Void

    func makeUIViewController(context: Context) -> ChatListController {
        ChatListController(vm: vm, emotes: emotes, onLink: onLink)
    }

    func updateUIViewController(_ c: ChatListController, context: Context) {
        c.onLink = onLink
    }
}

final class ChatCell: UITableViewCell {
    static let id = "line"
    let text: ChatTextView

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        // TextKit 1, which reports where each glyph landed so emote layers can
        // be placed over them.
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: CGSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        manager.addTextContainer(container)
        text = ChatTextView(frame: .zero, textContainer: container)
        text.isEditable = false
        text.isScrollEnabled = false
        text.isSelectable = false
        // Taps belong to the table, which works out whether one hit a link.
        text.isUserInteractionEnabled = false
        text.backgroundColor = .clear
        text.textContainerInset = .zero
        text.textContainer.lineFragmentPadding = 0
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        contentView.addSubview(text)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func show(_ s: NSAttributedString, width: CGFloat, height: CGFloat, dimmed: Bool) {
        text.textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        text.frame = CGRect(x: ChatListController.inset, y: 0, width: width, height: height)
        text.apply(s)
        contentView.alpha = dimmed ? 0.32 : 1
    }

    /// The link under a point in this cell, if there is one.
    func link(at point: CGPoint) -> String? {
        let p = contentView.convert(point, to: text)
        let manager = text.layoutManager
        var fraction: CGFloat = 0
        let i = manager.characterIndex(for: p, in: text.textContainer,
                                       fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard i < text.textStorage.length else { return nil }
        return text.textStorage.attribute(.chatLink, at: i, effectiveRange: nil) as? String
    }
}

@MainActor
final class ChatListController: UIViewController, UITableViewDelegate, UIGestureRecognizerDelegate {

    static let inset: CGFloat = 12
    private static let rowGap: CGFloat = 5

    private let vm: BigscreenViewModel
    private let emotes: EmoteImageStore
    var onLink: (String) -> Void

    private let table = UITableView(frame: .zero, style: .plain)
    private let jump = UIButton(configuration: .filled())
    private var source: UITableViewDiffableDataSource<Int, UUID>!
    private var timer: Timer?

    private var byID: [UUID: ChatItem] = [:]
    private var order: [UUID] = []
    private var heights: [UUID: CGFloat] = [:]
    private let lines = LineCache()

    /// False once a finger has taken chat back. New lines then wait in the model,
    /// so what's being read holds still.
    private var following = true
    /// A finger is on chat. Lines wait from the moment it lands, not once it starts
    /// to drag, or a link in fast chat would move out from under the tap.
    private var touching = false
    private var layoutWidth: CGFloat = 0
    private var generation = -1
    private var fontSize = 0.0

    init(vm: BigscreenViewModel, emotes: EmoteImageStore, onLink: @escaping (String) -> Void) {
        self.vm = vm
        self.emotes = emotes
        self.onLink = onLink
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        table.frame = view.bounds
        table.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.allowsSelection = false
        table.showsHorizontalScrollIndicator = false
        table.keyboardDismissMode = .interactive
        // Heights are known exactly, so there's nothing to estimate and the
        // scroll position never jumps as rows arrive.
        table.estimatedRowHeight = 0
        table.register(ChatCell.self, forCellReuseIdentifier: ChatCell.id)
        table.register(UITableViewCell.self, forCellReuseIdentifier: "combo")
        table.delegate = self
        view.addSubview(table)

        source = UITableViewDiffableDataSource(tableView: table) { [unowned self] table, path, id in
            self.cell(table, path, id)
        }
        source.defaultRowAnimation = .none

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        table.addGestureRecognizer(tap)

        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held))
        hold.minimumPressDuration = 0
        hold.cancelsTouchesInView = false
        hold.delegate = self
        table.addGestureRecognizer(hold)

        jump.configuration?.cornerStyle = .capsule
        jump.configuration?.baseBackgroundColor = UIColor(white: 0.16, alpha: 0.95)
        jump.configuration?.baseForegroundColor = .white
        jump.configuration?.buttonSize = .small
        jump.translatesAutoresizingMaskIntoConstraints = false
        jump.isHidden = true
        jump.addAction(UIAction { [weak self] _ in self?.resume() }, for: .touchUpInside)
        view.addSubview(jump)
        NSLayoutConstraint.activate([
            jump.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            jump.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard timer == nil else { return }
        // In the common modes, so chat doesn't stop dead during a scroll flick.
        let t = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        timer?.invalidate()
        timer = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.bounds.width
        guard width != layoutWidth, width > 0 else {
            if following { pinToBottom() }
            return
        }
        // Rotating re-wraps everything.
        layoutWidth = width
        heights = [:]
        table.reloadData()
        if following { pinToBottom() }
    }

    // MARK: - Updates

    private func tick() {
        if following, !touching { vm.flush() }
        if generation != emotes.generation || fontSize != vm.chatFontSize {
            generation = emotes.generation
            fontSize = vm.chatFontSize
            ChatText.size = fontSize
            heights = [:]
            table.reloadData()
        }
        sync()
        updateJump()
    }

    /// Applies whatever changed since last time. Only ever touches the rows that
    /// did: new ones at the end, old ones off the top, and any combo that grew.
    private func sync() {
        let items = vm.items
        let ids = items.map(\.id)
        var grew: [UUID] = []
        for item in items {
            if case .combo(_, _, let count, _) = item,
               case .combo(_, _, let old, _)? = byID[item.id], old != count {
                grew.append(item.id)
            }
        }
        guard ids != order || !grew.isEmpty else { return }
        byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        order = ids
        heights = heights.filter { byID[$0.key] != nil }

        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        snapshot.reconfigureItems(grew)
        source.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self, self.following else { return }
            self.pinToBottom()
        }
    }

    private func pinToBottom() {
        let bottom = table.contentSize.height + table.adjustedContentInset.bottom - table.bounds.height
        table.contentOffset.y = max(-table.adjustedContentInset.top, bottom)
    }

    private var atBottom: Bool {
        let bottom = table.contentSize.height + table.adjustedContentInset.bottom - table.bounds.height
        return table.contentOffset.y >= bottom - 24
    }

    private func resume() {
        following = true
        vm.flush()
        sync()
        pinToBottom()
        updateJump()
    }

    private func updateJump() {
        jump.isHidden = following
        guard !following else { return }
        let n = vm.pendingCount
        let title = n > 0 ? "\(n) new" : "Back to live"
        if jump.configuration?.title != title { jump.configuration?.title = title }
    }

    // MARK: - Rows

    private func text(_ item: ChatItem) -> NSAttributedString {
        lines.string(id: item.id, generation: emotes.generation, size: vm.chatFontSize) {
            ChatFormat.attributed(item, emotes: emotes)
        }
    }

    private var textWidth: CGFloat { max(40, layoutWidth - Self.inset * 2) }

    private func cell(_ table: UITableView, _ path: IndexPath, _ id: UUID) -> UITableViewCell {
        guard let item = byID[id] else { return UITableViewCell() }
        let dimmed = vm.isOffTopic(item)
        if case .combo(_, let emote, let count, _) = item {
            let c = table.dequeueReusableCell(withIdentifier: "combo", for: path)
            c.backgroundColor = .clear
            c.selectionStyle = .none
            c.contentConfiguration = UIHostingConfiguration {
                ComboRow(emote: emote, count: count, height: vm.chatFontSize, store: emotes)
                    .opacity(dimmed ? 0.32 : 1)
            }
            .margins(.vertical, 0)
            .margins(.horizontal, Self.inset)
            return c
        }
        let c = table.dequeueReusableCell(withIdentifier: ChatCell.id, for: path) as! ChatCell
        c.show(text(item), width: textWidth, height: height(id) - Self.rowGap, dimmed: dimmed)
        return c
    }

    private func height(_ id: UUID) -> CGFloat {
        if let known = heights[id] { return known }
        guard let item = byID[id] else { return 0 }
        let h: CGFloat
        if case .combo = item {
            // Room for the biggest the count gets, so a climbing combo never
            // changes the row's height and moves chat under the reader.
            h = ceil(max(ChatText.emoteHeight * 1.2 * 1.22, ChatText.size * 2 * 1.15)) + Self.rowGap
        } else {
            let box = text(item).boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            h = ceil(box.height) + Self.rowGap
        }
        heights[id] = h
        return h
    }

    func tableView(_ tableView: UITableView, heightForRowAt path: IndexPath) -> CGFloat {
        guard let id = source.itemIdentifier(for: path) else { return 0 }
        return height(id)
    }

    // MARK: - Touch

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        following = false
        updateJump()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate, atBottom { resume() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if atBottom { resume() }
    }

    @objc private func held(_ hold: UILongPressGestureRecognizer) {
        touching = hold.state == .began || hold.state == .changed
    }

    /// It only watches, so scrolling and tapping carry on as normal.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        let p = tap.location(in: table)
        guard let path = table.indexPathForRow(at: p),
              let cell = table.cellForRow(at: path) as? ChatCell,
              let word = cell.link(at: tap.location(in: cell.contentView)) else { return }
        onLink(word)
    }
}
