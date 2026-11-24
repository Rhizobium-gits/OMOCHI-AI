import AppKit

/// 🎊 餅まき：1 つの指示を何体ものおもち（Claude・ChatGPT・Gemini、今いるおもち）にまいて、答えを並べて比べる。
/// いちばん良いものを「拾う」と、そのおもちが残り、まくために作ったほかのおもちは片付く（チェックを外せば残す）
final class MochiMakiWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    weak var manager: JellyManager?

    private let prompt = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 60))
    private var engineBoxes: [AgentEngine: NSButton] = [:]
    private let mochiStack = NSStackView()
    private var mochiBoxes: [(UUID, NSButton)] = []
    private let throwButton = NSButton(title: L("🎊 まく"), target: nil, action: nil)
    private let cleanup = NSButton(checkboxWithTitle: L("拾わなかった、まくために作ったおもちを片付ける"), target: nil, action: nil)
    private let columns = NSStackView()
    private let status = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var source: JellyController?

    /// まいた相手 1 体ぶん
    private struct Catch {
        let agent: UUID
        /// まくために作ったおもち（拾わなければ片付ける）
        let spawned: Bool
        /// まいたときの履歴の長さ（それより後のターンが答え）
        let turnIndex: Int
        let startedAt: Date
        var view: ColumnView
    }
    private var catches: [Catch] = []
    private var picked: UUID?

    init(manager: JellyManager) {
        self.manager = manager
        window = ActiveSpace.make {
            NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                     backing: .buffered, defer: false)
        }
        super.init()
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.title = L("🎊 餅まき")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 620, height: 420)
        build()
    }

    private func build() {
        let title = NSTextField(labelWithString: L("1 つの指示を何体ものおもちにまいて、答えを比べる"))
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: L("同じ指示を、選んだ AI のおもちと今いるおもちに同時に送ります。答えが横に並ぶので、いちばん良いものを「🙌 拾う」で選んでください。拾ったおもちで、そのまま続きを頼めます。"))
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor

        prompt.font = .systemFont(ofSize: 13)
        prompt.isRichText = false
        prompt.textContainerInset = NSSize(width: 6, height: 6)
        prompt.autoresizingMask = [.width]
        prompt.isVerticallyResizable = true
        prompt.textContainer?.widthTracksTextView = true
        let pscroll = NSScrollView()
        pscroll.documentView = prompt
        pscroll.hasVerticalScroller = true
        pscroll.borderType = .bezelBorder

        let engLabel = NSTextField(labelWithString: L("新しいおもちにまく:"))
        engLabel.font = .systemFont(ofSize: 12, weight: .medium)
        var engViews: [NSView] = [engLabel]
        for e in AgentEngine.allCases {
            let b = NSButton(checkboxWithTitle: e.displayName, target: nil, action: nil)
            b.state = e == .claude ? .on : .off
            engineBoxes[e] = b
            engViews.append(b)
        }
        engViews.append(NSView())
        let engRow = NSStackView(views: engViews)
        engRow.orientation = .horizontal
        engRow.spacing = 12

        let mochiLabel = NSTextField(labelWithString: L("今いるおもちにもまく:"))
        mochiLabel.font = .systemFont(ofSize: 12, weight: .medium)
        mochiStack.orientation = .horizontal
        mochiStack.spacing = 10
        let mscroll = NSScrollView()
        mscroll.documentView = mochiStack
        mscroll.hasHorizontalScroller = true
        mscroll.autohidesScrollers = true
        mscroll.drawsBackground = false
        mochiStack.translatesAutoresizingMaskIntoConstraints = false
        let mochiRow = NSStackView(views: [mochiLabel, mscroll])
        mochiRow.orientation = .horizontal
        mochiRow.spacing = 8

        throwButton.target = self
        throwButton.action = #selector(throwMochi)
        throwButton.keyEquivalent = "\r"
        throwButton.keyEquivalentModifierMask = [.command]
        throwButton.bezelStyle = .rounded
        throwButton.toolTip = L("まく（⌘↩）")
        cleanup.state = .on
        status.font = .systemFont(ofSize: 11.5)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        let actions = NSStackView(views: [cleanup, status, NSView(), throwButton])
        actions.orientation = .horizontal
        actions.spacing = 10
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        columns.orientation = .horizontal
        columns.alignment = .top
        columns.distribution = .fillEqually
        columns.spacing = 10
        columns.translatesAutoresizingMaskIntoConstraints = false
        let cscroll = NSScrollView()
        cscroll.documentView = columns
        cscroll.hasHorizontalScroller = true
        cscroll.autohidesScrollers = true
        cscroll.drawsBackground = false

        let views: [NSView] = [title, intro, pscroll, engRow, mochiRow, actions, cscroll]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        var cs = [stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                  stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                  pscroll.heightAnchor.constraint(equalToConstant: 72),
                  mscroll.heightAnchor.constraint(equalToConstant: 24),
                  mochiStack.heightAnchor.constraint(equalTo: mscroll.contentView.heightAnchor),
                  cscroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
                  columns.heightAnchor.constraint(equalTo: cscroll.contentView.heightAnchor),
                  columns.widthAnchor.constraint(greaterThanOrEqualTo: cscroll.contentView.widthAnchor)]
        for v in views { cs.append(v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40)) }
        NSLayoutConstraint.activate(cs)
        cscroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = content
    }

    // MARK: - 表示

    func show(from c: JellyController?) {
        source = c
        refreshChoices()
        if !window.isVisible { window.center() }
        ActiveSpace.bringHere(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(prompt)
    }

    /// まける相手（使える AI と、手の空いているおもち）
    private func refreshChoices() {
        guard let m = manager else { return }
        for (e, b) in engineBoxes {
            let s = EngineAuth.shared.cached(e)
            let usable = s.map { JellyManager.preflightMessage(e, $0, allowAPI: m.settings.allowAPIBilling) == nil } ?? true
            b.isEnabled = usable
            if !usable { b.state = .off; b.toolTip = s?.summary } else { b.toolTip = e.teamStrengths }
        }
        mochiStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        mochiBoxes = []
        let busy = Set(catches.map(\.agent))
        for c in m.controllers.sorted(by: { $0.record.number < $1.record.number }) where !busy.contains(c.record.id) {
            let b = NSButton(checkboxWithTitle: c.record.title, target: nil, action: nil)
            // 名前の前に、おもちの色の点（チェックの四角はそのまま）
            let t = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: c.record.color.nsColor, .font: NSFont.systemFont(ofSize: 12)])
            t.append(NSAttributedString(string: c.record.title, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]))
            b.attributedTitle = t
            b.state = c === source ? .on : .off
            b.isEnabled = m.runtime(for: c)?.isRunning != true
            mochiStack.addArrangedSubview(b)
            mochiBoxes.append((c.record.id, b))
        }
    }

    // MARK: - まく

    /// 自動化（omochi://maki）用：指示・AI・今いるおもちを選んで、まく
    func debugThrow(text: String, engines: [AgentEngine], agents: [UUID]) {
        prompt.string = text
        for (e, b) in engineBoxes { b.state = engines.contains(e) ? .on : .off }
        for (id, b) in mochiBoxes { b.state = agents.contains(id) ? .on : .off }
        throwMochi()
    }

    /// 自動化用：その答えを拾う
    func debugPick(_ id: UUID) { pick(id) }

    @objc private func throwMochi() {
        guard let m = manager else { return }
        let text = prompt.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { status.stringValue = L("まく指示を書いてください"); NSSound.beep(); return }
        let engines = AgentEngine.allCases.filter { engineBoxes[$0]?.state == .on && engineBoxes[$0]?.isEnabled == true }
        let existing = mochiBoxes.filter { $0.1.state == .on && $0.1.isEnabled }.compactMap { m.controller(id: $0.0) }
        guard engines.count + existing.count >= 1 else { status.stringValue = L("まく相手を選んでください"); NSSound.beep(); return }
        guard m.controllers.count + engines.count <= TeamCoordinator.maxAgents else {
            status.stringValue = L("おもちは %ld 体までです", TeamCoordinator.maxAgents); NSSound.beep(); return
        }
        // 前の餅まきの片付け
        finishRound(keepAll: true)
        if m.settings.allHidden { m.setAllHidden(false) }
        var targets: [(JellyController, Bool)] = existing.map { ($0, false) }
        let base = source ?? existing.first
        for e in engines {
            var rec = m.makeRecord()
            rec.name = m.uniqueName(L("まき %@", e.displayName))
            rec.origin = targets.last.map { m.adjacentOrigin(near: $0.0) } ?? base.map { m.adjacentOrigin(near: $0) }
            let c = m.addController(rec)
            if let rt = m.runtime(for: c) {
                rt.changeEngine(e == m.settings.engine ? nil : e)
                if let b = base, let brt = m.runtime(for: b) { rt.changeFolder(brt.cwd) }
            }
            c.show(animated: true)
            targets.append((c, true))
        }
        m.save()
        m.onChange?()
        // お餅を投げる（窓の下のまん中から）→ 落ちたら受け止めて、指示を送る
        let f = window.frame
        let from = CGPoint(x: f.midX, y: f.minY + 40)
        m.team?.overlay.throwPieces(from: from, to: targets.map { ($0.0.anchorPoint, $0.0.record.color.nsColor) })
        columns.arrangedSubviews.forEach { $0.removeFromSuperview() }
        catches = []
        picked = nil
        for (i, (c, spawned)) in targets.enumerated() {
            guard let rt = m.runtime(for: c) else { continue }
            let v = ColumnView(title: c.record.title, color: c.record.color.nsColor)
            v.onPick = { [weak self] in self?.pick(c.record.id) }
            v.onOpen = { [weak self, weak c] in if let c { self?.manager?.openChat(for: c) } }
            columns.addArrangedSubview(v)
            v.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
            v.heightAnchor.constraint(equalTo: columns.heightAnchor).isActive = true
            catches.append(Catch(agent: c.record.id, spawned: spawned, turnIndex: rt.turns.count, startedAt: Date(), view: v))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7 + Double(i) * 0.09) { [weak c] in
                guard let c else { return }
                c.avatar.absorb()
                if !rt.submit(text) { AppLog.write("maki: agent \(c.record.number) refused") }
            }
        }
        AppLog.write("maki: \(targets.count) (\(engines.map(\.rawValue).joined(separator: ",")) + \(existing.count) existing)")
        DevJournal.log("maki", ["engines": engines.map(\.rawValue), "existing": existing.count, "chars": text.count])
        status.stringValue = L("%ld 体にまきました", targets.count)
        startTimer()
        refreshChoices()
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        update()
    }

    /// それぞれの答えと状態を見直す
    private func update() {
        guard let m = manager else { return }
        var allDone = true
        for c in catches {
            guard let jc = m.controller(id: c.agent), let rt = m.runtime(for: jc) else {
                c.view.set(state: L("（いません）"), body: "", done: true, picked: false)
                continue
            }
            let mine = rt.turns.count > c.turnIndex ? rt.turns[c.turnIndex] : nil
            let ai = (mine?.engine.flatMap(AgentEngine.init(rawValue:)) ?? rt.effectiveEngine).displayName
            let model = rt.activeModel.map { " · " + $0 } ?? ""
            if let t = mine, t.state.isTerminal || t.state == .error, !rt.isRunning {
                let secs = Int((t.endedAt ?? Date()).timeIntervalSince(t.startedAt))
                let cost = t.costUSD.map { String(format: " · $%.3f", $0) } ?? ""
                let head = "\(ai)\(model) · \(t.state.label) · \(secs)s\(cost)"
                let body = t.state == .completed ? (t.result ?? "") : (t.error ?? t.result ?? "")
                c.view.set(state: head, body: body, done: true, picked: picked == c.agent)
            } else {
                allDone = false
                let secs = Int(Date().timeIntervalSince(c.startedAt))
                c.view.set(state: "\(ai)\(model) · \(rt.activity ?? L("作業中")) · \(secs)s", body: "", done: false, picked: false)
            }
        }
        if allDone, !catches.isEmpty {
            timer?.invalidate()
            timer = nil
            if picked == nil { status.stringValue = L("そろいました。いちばん良いものを 🙌 拾ってください") }
        }
    }

    /// 拾う：そのおもちを残して、チャットを開く。まくために作ったほかのおもちは（チェックがあれば）片付ける
    private func pick(_ id: UUID) {
        guard let m = manager, let c = m.controller(id: id) else { return }
        picked = id
        c.avatar.poke()
        AppLog.write("maki: picked agent \(c.record.number)")
        let order = catches.sorted { a, b in
            (m.runtime(for: m.controller(id: a.agent) ?? c)?.turns.last?.endedAt ?? .distantFuture) < (m.runtime(for: m.controller(id: b.agent) ?? c)?.turns.last?.endedAt ?? .distantFuture)
        }.map(\.agent)
        DevJournal.log("maki-pick", ["engine": m.runtime(for: c)?.effectiveEngine.rawValue ?? "-", "spawned": catches.first { $0.agent == id }?.spawned ?? false,
                                     "finishRank": (order.firstIndex(of: id) ?? -1) + 1, "of": catches.count, "cleanup": cleanup.state == .on])
        finishRound(keepAll: cleanup.state != .on)
        update()
        status.stringValue = L("%@ を拾いました。チャットで続きを頼めます", c.record.title)
        m.openChat(for: c)
    }

    /// 餅まきを終える：まくために作ったおもちのうち、拾わなかった・手の空いているものを片付ける
    private func finishRound(keepAll: Bool) {
        guard let m = manager, !keepAll else { return }
        for c in catches where c.spawned && c.agent != picked {
            guard let jc = m.controller(id: c.agent), m.runtime(for: jc)?.isRunning != true else { continue }
            m.remove(jc)
        }
        catches.removeAll { c in c.spawned && c.agent != picked && m.controller(id: c.agent) == nil }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}

/// 答え 1 つぶんの列（名前・状態・答え・拾う）
private final class ColumnView: NSView {
    var onPick: (() -> Void)?
    var onOpen: (() -> Void)?
    private let header = NSTextField(labelWithString: "")
    private let state = NSTextField(labelWithString: "")
    private let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
    private let pickButton = NSButton(title: L("🙌 拾う"), target: nil, action: nil)
    private let openButton = NSButton(title: L("チャット"), target: nil, action: nil)
    private let copyButton = NSButton(title: L("コピー"), target: nil, action: nil)
    private var shown = ""
    private let color: NSColor

    init(title: String, color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1.5
        layer?.borderColor = color.withAlphaComponent(0.6).cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.5).cgColor
        header.stringValue = title
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = color.blended(withFraction: 0.35, of: .labelColor)
        state.font = .systemFont(ofSize: 11)
        state.textColor = .secondaryLabelColor
        state.lineBreakMode = .byTruncatingTail
        state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.isEditable = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 4, height: 4)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        for b in [pickButton, openButton, copyButton] {
            b.bezelStyle = .accessoryBarAction
            b.controlSize = .small
            b.target = self
        }
        pickButton.action = #selector(pickTapped)
        openButton.action = #selector(openTapped)
        copyButton.action = #selector(copyTapped)
        pickButton.isEnabled = false
        let buttons = NSStackView(views: [pickButton, NSView(), copyButton, openButton])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [header, state, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            state.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -20),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(state s: String, body: String, done: Bool, picked: Bool) {
        state.stringValue = s
        pickButton.isEnabled = done && !body.isEmpty
        pickButton.title = picked ? L("🙌 拾った") : L("🙌 拾う")
        layer?.borderWidth = picked ? 3 : 1.5
        layer?.borderColor = (picked ? color : color.withAlphaComponent(0.6)).cgColor
        let shownText = done ? body : "…"
        guard shownText != shown else { return }
        shown = shownText
        text.textStorage?.setAttributedString(Markdown.render(shownText, size: 12.5))
    }

    @objc private func pickTapped() { onPick?() }
    @objc private func openTapped() { onOpen?() }
    @objc private func copyTapped() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shown, forType: .string)
    }
}
