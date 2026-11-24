import AppKit

/// 🍡 串だんご：おもちを串に刺して並べ、上から順に仕事を流す（前の段の結果が次の段に渡る）。
/// 名前を付けて保存すると、レシピとして何度でも使える（みたらし＝調べてまとめる など）
final class DangoWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    weak var manager: JellyManager?

    /// 段のおもち：新しく作る（AI）か、今いるおもちか
    enum Who: Equatable { case new(AgentEngine?), existing(UUID) }
    private struct Row {
        var who: Who
        var step: DangoStep
    }
    private var rows: [Row] = []
    /// いま編集している串（nil = まだ刺していない）
    private var skewerID: UUID?
    private var recipeName: String?

    private let recipePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rowsStack = NSStackView()
    private let input = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 60))
    private let status = NSTextField(wrappingLabelWithString: "")
    private let skewerButton = NSButton(title: L("串に刺す"), target: nil, action: nil)
    private let runButton = NSButton(title: L("▶ 流す"), target: nil, action: nil)
    private let saveButton = NSButton(title: L("レシピとして保存…"), target: nil, action: nil)
    private let deleteButton = NSButton(title: L("レシピを消す"), target: nil, action: nil)
    private var recipeChoices: [DangoRecipe?] = []

    init(manager: JellyManager) {
        self.manager = manager
        window = ActiveSpace.make {
            NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 460), styleMask: [.titled, .closable, .resizable],
                     backing: .buffered, defer: false)
        }
        super.init()
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.title = L("🍡 串だんご")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 560, height: 360)
        build()
    }

    private func build() {
        let title = NSTextField(labelWithString: L("おもちを串に刺して、順番に仕事を流す"))
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: L("段ごとに、どのおもちが何をするかを決めます。1 段目に「最初に渡すこと」を渡し、終わったら結果が 2 段目へ、さらに次へと流れます（止める・再開は 1 段目のおもちのチャットの予約から）。名前を付けて保存すれば、レシピとして何度でも使えます。"))
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor

        recipePopup.target = self
        recipePopup.action = #selector(recipeChosen)
        recipePopup.controlSize = .regular
        let recipeLabel = NSTextField(labelWithString: L("レシピ:"))
        let recipeRow = NSStackView(views: [recipeLabel, recipePopup, NSView()])
        recipeRow.orientation = .horizontal
        recipeRow.spacing = 8

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 6
        let add = NSButton(title: L("＋ 段を足す"), target: self, action: #selector(addRow))
        add.bezelStyle = .accessoryBarAction
        add.controlSize = .small

        let inputLabel = NSTextField(labelWithString: L("最初に渡すこと（1 段目への指示に添える）"))
        inputLabel.font = .systemFont(ofSize: 12, weight: .medium)
        input.font = .systemFont(ofSize: 13)
        input.isRichText = false
        input.textContainerInset = NSSize(width: 6, height: 6)
        let scroll = NSScrollView()
        scroll.documentView = input
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        input.autoresizingMask = [.width]
        input.isVerticallyResizable = true
        input.textContainer?.widthTracksTextView = true

        status.font = .systemFont(ofSize: 11.5)
        status.textColor = .secondaryLabelColor
        for b in [skewerButton, runButton, saveButton, deleteButton] { b.target = self; b.bezelStyle = .rounded }
        skewerButton.action = #selector(skewerOnly)
        runButton.action = #selector(run)
        runButton.keyEquivalent = "\r"
        saveButton.action = #selector(saveRecipe)
        deleteButton.action = #selector(deleteRecipe)
        skewerButton.toolTip = L("おもちを横一列に並べて串に刺すだけ（流すのはあとで。1 段目のおもちのチャットの「🍡 串に流す」からも流せます）")
        let footer = NSStackView(views: [saveButton, deleteButton, NSView(), skewerButton, runButton])
        footer.orientation = .horizontal
        footer.spacing = 8

        let addRow = NSStackView(views: [add, NSView()])
        addRow.orientation = .horizontal
        let views: [NSView] = [title, intro, recipeRow, rowsStack, addRow, inputLabel, scroll, status, footer]
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
                  scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 70)]
        for v in views { cs.append(v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40)) }
        NSLayoutConstraint.activate(cs)
        // 余った高さは「最初に渡すこと」の欄へ（段の一覧の下に空きを作らない）
        for v in [title, intro, recipeRow, rowsStack, addRow, inputLabel, status, footer] as [NSView] {
            v.setContentHuggingPriority(.required, for: .vertical)
        }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        stack.distribution = .fill
        window.contentView = content
    }

    // MARK: - 表示

    /// start：このおもちから（串に刺さっていればその串を開く）。recipe：レシピを読み込む
    func show(start: JellyController?, recipe: DangoRecipe?) {
        guard let m = manager else { return }
        if let recipe {
            load(recipe)
        } else if let c = start, let s = m.skewer(containing: c.record.id) {
            load(s)
        } else if let c = start {
            skewerID = nil
            recipeName = nil
            rows = [Row(who: .existing(c.record.id), step: DangoStep(title: L("調べる"))),
                    Row(who: .new(nil), step: DangoStep(title: L("まとめる")))]
        } else if rows.isEmpty {
            load(JellyManager.builtinRecipes[0])
        }
        rebuild()
        window.center()
        ActiveSpace.bringHere(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(input)
    }

    private func load(_ r: DangoRecipe) {
        skewerID = nil
        recipeName = r.name
        rows = r.steps.map { Row(who: .new($0.engine.flatMap(AgentEngine.init(rawValue:))), step: $0) }
    }

    private func load(_ s: Skewer) {
        skewerID = s.id
        recipeName = s.name
        rows = s.members.enumerated().map { i, id in Row(who: .existing(id), step: i < s.steps.count ? s.steps[i] : DangoStep(title: "")) }
    }

    private func rebuild() {
        guard let m = manager else { return }
        // レシピの一覧
        recipePopup.removeAllItems()
        recipeChoices = [nil]
        recipePopup.addItem(withTitle: skewerID != nil ? L("いまの串") : (recipeName.map { L("「%@」", $0) } ?? L("新しい串")))
        recipePopup.menu?.addItem(.separator())
        recipeChoices.append(nil)
        for r in m.allRecipes {
            recipePopup.addItem(withTitle: r.name)
            recipeChoices.append(r)
        }
        recipePopup.selectItem(at: 0)
        deleteButton.isHidden = !(m.recipes.contains { $0.name == recipeName })

        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, r) in rows.enumerated() { rowsStack.addArrangedSubview(rowView(i, r)) }
        updateStatus()
    }

    private func rowView(_ i: Int, _ r: Row) -> NSView {
        let num = NSTextField(labelWithString: "\(i + 1)")
        num.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        num.textColor = .secondaryLabelColor
        let who = NSPopUpButton(frame: .zero, pullsDown: false)
        who.controlSize = .small
        who.font = .systemFont(ofSize: 11.5)
        who.tag = i
        who.target = self
        who.action = #selector(whoChanged(_:))
        var whoChoices: [Who] = []
        who.addItem(withTitle: L("✨ 新しいおもち（既定の AI）")); whoChoices.append(.new(nil))
        for e in AgentEngine.allCases { who.addItem(withTitle: L("✨ 新しいおもち（%@）", e.displayName)); whoChoices.append(.new(e)) }
        for c in (manager?.controllers ?? []).sorted(by: { $0.record.number < $1.record.number }) {
            who.addItem(withTitle: "\(c.record.title) · \(c.record.color.name)")
            who.lastItem?.image = MenuImages.dot(c.record.color, state: c.record.state)
            whoChoices.append(.existing(c.record.id))
        }
        who.selectItem(at: whoChoices.firstIndex(of: r.who) ?? 0)
        who.identifier = NSUserInterfaceItemIdentifier(whoChoices.map { w -> String in
            switch w { case .new(let e): return "new:" + (e?.rawValue ?? ""); case .existing(let id): return "id:" + id.uuidString }
        }.joined(separator: "|"))
        let title = NSTextField(string: r.step.title)
        title.placeholderString = L("段の名前（調べる など）")
        title.controlSize = .small
        title.font = .systemFont(ofSize: 12)
        title.tag = i
        title.target = self
        title.action = #selector(titleEdited(_:))
        title.delegate = self
        title.identifier = NSUserInterfaceItemIdentifier("title")
        let ins = NSTextField(string: r.step.instruction)
        ins.placeholderString = L("この段への指示")
        ins.controlSize = .small
        ins.font = .systemFont(ofSize: 12)
        ins.tag = i
        ins.delegate = self
        ins.identifier = NSUserInterfaceItemIdentifier("instruction")
        ins.lineBreakMode = .byTruncatingTail
        let up = smallButton("↑", #selector(moveUp(_:)), i)
        let down = smallButton("↓", #selector(moveDown(_:)), i)
        let del = smallButton("✕", #selector(removeRow(_:)), i)
        up.isEnabled = i > 0
        down.isEnabled = i < rows.count - 1
        del.isEnabled = rows.count > 2
        let row = NSStackView(views: [num, who, title, ins, up, down, del])
        row.orientation = .horizontal
        row.spacing = 6
        title.widthAnchor.constraint(equalToConstant: 110).isActive = true
        who.widthAnchor.constraint(equalToConstant: 170).isActive = true
        ins.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func smallButton(_ t: String, _ a: Selector, _ i: Int) -> NSButton {
        let b = NSButton(title: t, target: self, action: a)
        b.bezelStyle = .accessoryBarAction
        b.controlSize = .small
        b.tag = i
        return b
    }

    private func updateStatus() {
        guard let m = manager else { return }
        if let id = skewerID, let s = m.skewers.first(where: { $0.id == id }) {
            let names = s.members.compactMap { m.controller(id: $0)?.record.title }.joined(separator: " → ")
            status.stringValue = L("いまの串: %@", names)
        } else {
            let new = rows.filter { if case .new = $0.who { return true }; return false }.count
            status.stringValue = new > 0 ? L("刺すときに、新しいおもちを %ld 体作ります", new) : ""
        }
    }

    // MARK: - 操作

    @objc private func recipeChosen() {
        let i = recipePopup.indexOfSelectedItem
        guard i > 0, i < recipeChoices.count, let r = recipeChoices[i] else { return }
        load(r)
        rebuild()
    }

    @objc private func whoChanged(_ p: NSPopUpButton) {
        guard p.tag < rows.count, let raw = p.identifier?.rawValue.split(separator: "|").map(String.init),
              p.indexOfSelectedItem < raw.count else { return }
        let v = raw[p.indexOfSelectedItem]
        if v.hasPrefix("new:") {
            rows[p.tag].who = .new(AgentEngine(rawValue: String(v.dropFirst(4))))
        } else if let id = UUID(uuidString: String(v.dropFirst(3))) {
            rows[p.tag].who = .existing(id)
        }
        skewerID = nil
        updateStatus()
    }

    @objc private func titleEdited(_ f: NSTextField) { if f.tag < rows.count { rows[f.tag].step.title = f.stringValue } }

    @objc private func addRow() {
        commitFields()
        guard rows.count < TeamCoordinator.maxTeamSize else { NSSound.beep(); return }
        rows.append(Row(who: .new(nil), step: DangoStep(title: "")))
        skewerID = nil
        rebuild()
    }

    @objc private func removeRow(_ b: NSButton) {
        commitFields()
        guard rows.count > 2, b.tag < rows.count else { return }
        rows.remove(at: b.tag)
        skewerID = nil
        rebuild()
    }

    @objc private func moveUp(_ b: NSButton) { commitFields(); guard b.tag > 0 else { return }; rows.swapAt(b.tag, b.tag - 1); skewerID = nil; rebuild() }
    @objc private func moveDown(_ b: NSButton) { commitFields(); guard b.tag < rows.count - 1 else { return }; rows.swapAt(b.tag, b.tag + 1); skewerID = nil; rebuild() }

    /// 入力中の欄の文字を rows に入れる
    private func commitFields() {
        for case let row as NSStackView in rowsStack.arrangedSubviews {
            for case let f as NSTextField in row.arrangedSubviews where f.isEditable && f.tag < rows.count {
                if f.identifier?.rawValue == "title" { rows[f.tag].step.title = f.stringValue }
                if f.identifier?.rawValue == "instruction" { rows[f.tag].step.instruction = f.stringValue }
            }
        }
    }

    /// 段のおもちをそろえて串に刺す（新しいおもちはここで作る）。刺した串を返す
    private func ensureSkewer() -> Skewer? {
        commitFields()
        guard let m = manager else { return nil }
        if let id = skewerID, var s = m.skewers.first(where: { $0.id == id }), s.members.count == rows.count {
            s.steps = rows.map(\.step)
            m.updateSkewer(s)
            return s
        }
        let newCount = rows.filter { if case .new = $0.who { return true }; return false }.count
        guard m.controllers.count + newCount <= TeamCoordinator.maxAgents else {
            status.stringValue = L("おもちは %ld 体までです", TeamCoordinator.maxAgents)
            return nil
        }
        var members: [JellyController] = []
        var anchor = rows.compactMap { r -> JellyController? in if case .existing(let id) = r.who { return m.controller(id: id) }; return nil }.first
        for r in rows {
            switch r.who {
            case .existing(let id):
                guard let c = m.controller(id: id) else { status.stringValue = L("串のおもちが見つかりません"); return nil }
                guard !members.contains(where: { $0 === c }) else { status.stringValue = L("同じおもちは 1 本の串に 1 回だけ刺せます"); return nil }
                members.append(c)
            case .new(let e):
                var rec = m.makeRecord()
                rec.name = m.uniqueName(String((r.step.title.isEmpty ? L("だんご") : r.step.title).prefix(24)))
                rec.origin = members.last.map { NSPoint(x: $0.panel.frame.maxX, y: $0.panel.frame.minY) } ?? anchor.map { m.adjacentOrigin(near: $0) }
                let c = m.addController(rec)
                if let e, let rt = m.runtime(for: c) { rt.changeEngine(e) }
                if let base = anchor ?? members.first, let brt = m.runtime(for: base) { m.runtime(for: c)?.changeFolder(brt.cwd) }
                c.show(animated: true)
                members.append(c)
                if anchor == nil { anchor = c }
            }
        }
        m.save()
        m.onChange?()
        guard let s = m.makeSkewer(members, steps: rows.map(\.step), name: recipeName) else { return nil }
        skewerID = s.id
        rows = s.members.enumerated().map { i, id in Row(who: .existing(id), step: s.steps[i]) }
        rebuild()
        return s
    }

    @objc private func skewerOnly() {
        guard ensureSkewer() != nil else { NSSound.beep(); return }
        status.stringValue = L("串に刺しました。1 段目のおもちのチャットの「🍡 串に流す」でも流せます")
    }

    @objc private func run() {
        let text = input.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            status.stringValue = L("「最初に渡すこと」を書いてください")
            window.makeFirstResponder(input)
            NSSound.beep()
            return
        }
        guard let s = ensureSkewer(), let m = manager else { NSSound.beep(); return }
        if let err = m.runSkewer(s, input: text) {
            status.stringValue = err
            NSSound.beep()
            return
        }
        input.string = ""
        status.stringValue = L("流しました。1 段目から順に進みます（1 段目のおもちのチャットで、予約として止める・再開できます）")
    }

    @objc private func saveRecipe() {
        commitFields()
        guard let m = manager else { return }
        let a = NSAlert()
        a.messageText = L("レシピの名前")
        a.informativeText = L("段の名前・指示・AI を保存します（おもちは保存しません。使うたびに新しいおもちを作ります）。")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        f.stringValue = recipeName ?? ""
        f.placeholderString = L("例: みたらし")
        a.accessoryView = f
        a.addButton(withTitle: L("保存"))
        a.addButton(withTitle: L("キャンセル"))
        a.window.initialFirstResponder = f
        guard ActiveSpace.runModal(a) == .alertFirstButtonReturn else { return }
        let name = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let steps = rows.map { r -> DangoStep in
            var st = r.step
            switch r.who {
            case .new(let e): st.engine = e?.rawValue
            case .existing(let id): st.engine = m.controller(id: id).flatMap { m.runtime(for: $0) }?.engine?.rawValue
            }
            return st
        }
        if let i = m.recipes.firstIndex(where: { $0.name == name }) { m.recipes[i].steps = steps } else { m.recipes.append(DangoRecipe(name: name, steps: steps)) }
        m.saveRecipes()
        recipeName = name
        rebuild()
        status.stringValue = L("レシピ「%@」を保存しました（メニューバーのおもち › 🍡 串だんご から使えます）", name)
    }

    @objc private func deleteRecipe() {
        guard let m = manager, let name = recipeName, let r = m.recipes.first(where: { $0.name == name }) else { return }
        m.deleteRecipe(r.id)
        recipeName = nil
        rebuild()
    }

    func windowWillClose(_ notification: Notification) { commitFields() }
}

extension DangoWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSTextField, f.tag < rows.count else { return }
        if f.identifier?.rawValue == "title" { rows[f.tag].step.title = f.stringValue }
        if f.identifier?.rawValue == "instruction" { rows[f.tag].step.instruction = f.stringValue }
    }
}
