import AppKit

/// 予約の 1 行の文の欄。Enter で書き終わり（次の欄へ）、⇧⏎ / ⌥⏎ で改行、Esc でも書き終わり
final class QueueTextView: NSTextView {
    var onDone: (() -> Void)?
    var placeholder = "" { didSet { needsDisplay = true } }

    override func keyDown(with e: NSEvent) {
        if hasMarkedText() { super.keyDown(with: e); return }
        switch e.keyCode {
        case 36, 76:
            if e.modifierFlags.contains(.shift) || e.modifierFlags.contains(.option) { insertNewlineIgnoringFieldEditor(nil); return }
            onDone?()
            return
        case 53:
            onDone?()
            return
        default:
            super.keyDown(with: e)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let pad = textContainer?.lineFragmentPadding ?? 0
        (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width + pad, y: textContainerInset.height),
                                       withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor])
    }
}

/// 上から下へ並べる入れ物（スクロールの中身）
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// チャットの「予約」の欄：いまの作業が終わったら送る指示の一覧。
/// 送るまでは文を書き換えたり、送り先のクラゲ・前の結果を渡すか・順番を変えたり、消したりできる
final class PromptQueueView: NSView, NSTextViewDelegate {
    struct Agent: Equatable {
        let id: UUID
        let title: String
        let color: NSColor
    }

    var onText: ((UUID, String) -> Void)?
    var onEndEditing: ((UUID) -> Void)?
    var onTarget: ((UUID, UUID) -> Void)?
    var onPass: ((UUID, Bool) -> Void)?
    var onMove: ((UUID, Int) -> Void)?
    var onRemove: ((UUID) -> Void)?
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?
    var onSkip: (() -> Void)?
    var onClear: (() -> Void)?
    /// 行の文を書き終えた（Enter）：入力欄に戻る
    var onDoneEditing: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let pauseButton = NSButton(title: "", target: nil, action: nil)
    private let skipButton = NSButton(title: L("⏭ 止めて次へ"), target: nil, action: nil)
    private let clearButton = NSButton(title: L("すべて消す"), target: nil, action: nil)
    private let scroll = NSScrollView()
    private let list = NSStackView()
    private var rows: [UUID: Row] = [:]
    private var order: [UUID] = []
    private var agents: [Agent] = []
    private var owner = UUID()
    private var paused = false
    private var listHeight: NSLayoutConstraint!
    /// 行の文の欄が書き換えている途中か（表示の更新で上書きしない）
    private var editingID: UUID?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.35).cgColor

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.font = .systemFont(ofSize: 11.5)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for b in [pauseButton, skipButton, clearButton] {
            b.bezelStyle = .accessoryBarAction
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11.5)
            b.target = self
            b.setContentCompressionResistancePriority(.init(700), for: .horizontal)
        }
        pauseButton.action = #selector(pauseTapped)
        skipButton.action = #selector(skipTapped)
        clearButton.action = #selector(clearTapped)
        skipButton.toolTip = L("いまの作業を止めて、一時停止せずに次の予約を送ります")
        clearButton.toolTip = L("まだ送っていない予約をすべて消します（作業中のものは止めません）")
        let header = NSStackView(views: [titleLabel, statusLabel, NSView(), skipButton, pauseButton, clearButton])
        header.orientation = .horizontal
        header.spacing = 6
        header.setClippingResistancePriority(.defaultLow, for: .horizontal)

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        list.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(list)
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let stack = NSStackView(views: [header, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        listHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
            listHeight,
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            list.topAnchor.constraint(equalTo: doc.topAnchor),
            list.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
    }

    /// 表示を予約に合わせる（書き換えている途中の欄は上書きしない）
    func update(queue: PromptQueue?, owner: UUID, agents: [Agent], status: String?, canSkip: Bool) {
        self.owner = owner
        let items = queue?.items ?? []
        let agentsChanged = agents != self.agents
        self.agents = agents
        paused = queue?.isPaused ?? false
        titleLabel.stringValue = items.isEmpty ? L("⏭ 予約") : L("⏭ 予約 %ld 件", items.count)
        statusLabel.stringValue = status ?? ""
        statusLabel.toolTip = status
        pauseButton.title = paused ? L("▶ 再開") : L("⏸ 一時停止")
        pauseButton.toolTip = paused ? L("止めていた予約を、上から順に送ります") : L("予約を送るのを止めます（いまの作業は止めません）")
        pauseButton.isHidden = items.isEmpty && !paused
        clearButton.isHidden = items.isEmpty
        skipButton.isHidden = !canSkip || items.isEmpty

        // 行を作る・消す・並べ替える
        let ids = items.map(\.id)
        for (id, r) in rows where !ids.contains(id) {
            r.view.removeFromSuperview()
            rows[id] = nil
            if editingID == id { editingID = nil }
        }
        for (i, it) in items.enumerated() {
            let r = rows[it.id] ?? makeRow(it.id)
            rows[it.id] = r
            r.number.stringValue = "\(i + 1)."
            if editingID != it.id, r.text.string != it.text {
                r.text.string = it.text
                r.relayout()
            }
            if agentsChanged || r.target.numberOfItems != agents.count { fillTargets(r) }
            let t = it.target ?? owner
            r.target.selectItem(at: agents.firstIndex { $0.id == t } ?? 0)
            r.pass.state = it.passResult ? .on : .off
            r.pass.toolTip = L("前の手順の結果（前の行を作業したクラゲの最後の返答）を、この指示に添えて渡します")
            r.up.isEnabled = i > 0
            r.down.isEnabled = i < items.count - 1
            r.attach.isHidden = it.attachmentCount == 0 && it.suffix == nil
            r.attach.stringValue = it.attachmentCount > 0 ? "📎\(it.attachmentCount)" : "📷"
        }
        if ids != order {
            for v in list.arrangedSubviews { list.removeArrangedSubview(v) }
            for id in ids {
                guard let r = rows[id] else { continue }
                list.addArrangedSubview(r.view)
                if !r.widthSet { r.view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true; r.widthSet = true }
            }
            order = ids
        }
        relayoutList()
    }

    /// 行の高さの合計（4 行ぶんまで。それより多ければスクロール）
    private func relayoutList() {
        list.layoutSubtreeIfNeeded()
        let h = list.fittingSize.height
        listHeight.constant = order.isEmpty ? 0 : min(h, 168)
    }

    // MARK: 行

    private final class Row {
        let id: UUID
        let view = NSStackView()
        let number = NSTextField(labelWithString: "")
        let text = QueueTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        let textScroll = NSScrollView()
        let target = NSPopUpButton(frame: .zero, pullsDown: false)
        let pass = NSButton(checkboxWithTitle: L("前の結果を渡す"), target: nil, action: nil)
        let attach = NSTextField(labelWithString: "")
        let up = NSButton(title: "↑", target: nil, action: nil)
        let down = NSButton(title: "↓", target: nil, action: nil)
        let remove = NSButton(title: "✕", target: nil, action: nil)
        var textHeight: NSLayoutConstraint!
        var widthSet = false
        init(id: UUID) { self.id = id }

        func relayout() {
            guard let lm = text.layoutManager, let tc = text.textContainer else { return }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc).height + text.textContainerInset.height * 2
            let line = (text.font?.boundingRectForFont.height ?? 16) + text.textContainerInset.height * 2
            textHeight.constant = min(max(used, line), 76)
        }
    }

    private func makeRow(_ id: UUID) -> Row {
        let r = Row(id: id)
        r.number.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        r.number.textColor = .secondaryLabelColor
        r.number.setContentHuggingPriority(.required, for: .horizontal)

        let tv = r.text
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.font = .systemFont(ofSize: 13)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 4, height: 3)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.placeholder = L("（空の予約は送りません）")
        tv.delegate = self
        tv.onDone = { [weak self] in self?.onDoneEditing?() }
        r.textScroll.documentView = tv
        r.textScroll.hasVerticalScroller = true
        r.textScroll.autohidesScrollers = true
        r.textScroll.drawsBackground = false
        r.textScroll.borderType = .noBorder
        r.textScroll.wantsLayer = true
        r.textScroll.layer?.cornerRadius = 6
        r.textScroll.layer?.borderWidth = 1
        r.textScroll.layer?.borderColor = NSColor.separatorColor.cgColor
        r.textScroll.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.6).cgColor
        r.textScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        r.textScroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        r.textHeight = r.textScroll.heightAnchor.constraint(equalToConstant: 22)
        r.textHeight.isActive = true

        r.target.controlSize = .small
        r.target.font = .systemFont(ofSize: 11.5)
        r.target.bezelStyle = .accessoryBarAction
        r.target.target = self
        r.target.action = #selector(targetChanged(_:))
        r.target.toolTip = L("この指示を送るクラゲ。ほかのクラゲにすると、そのクラゲの会話で作業します")
        (r.target.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        r.target.setContentCompressionResistancePriority(.init(600), for: .horizontal)
        r.pass.controlSize = .small
        r.pass.font = .systemFont(ofSize: 11.5)
        r.pass.target = self
        r.pass.action = #selector(passChanged(_:))
        r.attach.font = .systemFont(ofSize: 11)
        r.attach.textColor = .secondaryLabelColor
        r.attach.toolTip = L("予約したときの添付・画面を一緒に送ります")
        for (b, sel, tip) in [(r.up, #selector(upTapped(_:)), L("ひとつ上へ")), (r.down, #selector(downTapped(_:)), L("ひとつ下へ")),
                              (r.remove, #selector(removeTapped(_:)), L("この予約を消す"))] {
            b.bezelStyle = .accessoryBarAction
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11.5)
            b.target = self
            b.action = sel
            b.toolTip = tip
            b.setContentHuggingPriority(.required, for: .horizontal)
        }
        // 1 段目：番号・文・消す。2 段目：送り先・結果を渡す・添付・並べ替え
        let line1 = NSStackView(views: [r.number, r.textScroll, r.remove])
        line1.orientation = .horizontal
        line1.alignment = .top
        line1.spacing = 6
        let line2 = NSStackView(views: [r.target, r.pass, r.attach, NSView(), r.up, r.down])
        line2.orientation = .horizontal
        line2.spacing = 6
        line2.setClippingResistancePriority(.defaultLow, for: .horizontal)
        r.view.orientation = .vertical
        r.view.alignment = .leading
        r.view.spacing = 2
        r.view.addArrangedSubview(line1)
        r.view.addArrangedSubview(line2)
        line1.widthAnchor.constraint(equalTo: r.view.widthAnchor).isActive = true
        line2.leadingAnchor.constraint(equalTo: r.view.leadingAnchor, constant: 22).isActive = true
        line2.trailingAnchor.constraint(equalTo: r.view.trailingAnchor, constant: -26).isActive = true
        for v in [r.target, r.pass, r.up, r.down, r.remove] as [NSView] { v.identifier = NSUserInterfaceItemIdentifier(id.uuidString) }
        return r
    }

    private func fillTargets(_ r: Row) {
        r.target.removeAllItems()
        for a in agents {
            let title = a.id == owner ? L("→ このクラゲ（%@）", a.title) : "→ " + a.title
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.image = PromptQueueView.dot(a.color)
            r.target.menu?.addItem(item)
        }
    }

    static func dot(_ c: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            c.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    private func rowID(_ sender: NSView) -> UUID? { sender.identifier.flatMap { UUID(uuidString: $0.rawValue) } }
    private func rowID(text: NSTextView) -> UUID? { rows.first { $0.value.text === text }?.key }

    @objc private func targetChanged(_ s: NSPopUpButton) {
        guard let id = rowID(s), s.indexOfSelectedItem >= 0, s.indexOfSelectedItem < agents.count else { return }
        onTarget?(id, agents[s.indexOfSelectedItem].id)
    }
    @objc private func passChanged(_ s: NSButton) { if let id = rowID(s) { onPass?(id, s.state == .on) } }
    @objc private func upTapped(_ s: NSButton) { if let id = rowID(s) { onMove?(id, -1) } }
    @objc private func downTapped(_ s: NSButton) { if let id = rowID(s) { onMove?(id, 1) } }
    @objc private func removeTapped(_ s: NSButton) { if let id = rowID(s) { onRemove?(id) } }
    @objc private func pauseTapped() { if paused { onResume?() } else { onPause?() } }
    @objc private func skipTapped() { onSkip?() }
    @objc private func clearTapped() { onClear?() }

    // MARK: 文の欄

    func textDidBeginEditing(_ n: Notification) {
        if let tv = n.object as? NSTextView { editingID = rowID(text: tv) }
    }

    func textDidChange(_ n: Notification) {
        guard let tv = n.object as? NSTextView, let id = rowID(text: tv) else { return }
        editingID = id
        rows[id]?.relayout()
        relayoutList()
        onText?(id, tv.string)
    }

    func textDidEndEditing(_ n: Notification) {
        guard let tv = n.object as? NSTextView, let id = rowID(text: tv) else { return }
        if editingID == id { editingID = nil }
        onEndEditing?(id)
    }

    /// テスト・自動化用：いま出している行の文
    var shownTexts: [String] { order.compactMap { rows[$0]?.text.string } }
}
