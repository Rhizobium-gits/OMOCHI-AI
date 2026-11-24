import AppKit

/// 「🔌 コネクタ」：この Mac のカレンダー・リマインダー・メールを、どの AI・どのモデルのおもちに、どこまで使わせるかを決める画面。
/// 上のワンタッチ設定のボタン 1 つで、すべてのコネクタをまとめて切り替えられる。メニューバーのおもち › 🔌 コネクタ から開く
final class ConnectorsWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    weak var manager: JellyManager?
    /// 見た目の確認用（OmochiAI --connectors-window）：manager が無いときに出す設定
    private var preview: ConnectorSettings?
    static let width: CGFloat = 900

    init(manager: JellyManager?, preview: ConnectorSettings? = nil) {
        self.manager = manager
        self.preview = preview
        window = ActiveSpace.make {
            NSWindow(contentRect: NSRect(x: 0, y: 0, width: ConnectorsWindowController.width, height: 600), styleMask: [.titled, .closable],
                     backing: .buffered, defer: false)
        }
        super.init()
        // 今いるスペース（ほかのアプリのフル画面でも）に出す
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.title = L("コネクタ")
        window.isReleasedWhenClosed = false
        window.delegate = self
    }

    func show() {
        rebuild()
        window.center()
        ActiveSpace.bringHere(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - デモの録画用（合言葉つきの自動化のときだけ omochi://connectors から）

    /// 前面化せずに、左上を topLeft（画面の左上が原点の座標）に合わせて出す。入力先は奪わない
    func showForDemo(topLeft: NSPoint?) {
        rebuild()
        if let p = topLeft {
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            window.setFrameTopLeftPoint(NSPoint(x: p.x, y: primaryHeight - p.y))
        } else {
            window.center()
        }
        window.orderFrontRegardless()
    }

    /// 識別子（ワンタッチ設定の名前・「calendar.gemini」など）のボタンを、押したように見せて押す
    @discardableResult
    func pressForDemo(_ id: String) -> Bool {
        func find(_ v: NSView) -> NSButton? {
            if let b = v as? NSButton, b.identifier?.rawValue == id, !(v is NSPopUpButton) { return b }
            for s in v.subviews { if let b = find(s) { return b } }
            return nil
        }
        guard let root = window.contentView, let b = find(root) else { return false }
        b.performClick(nil)
        return true
    }

    private var settings: ConnectorSettings { manager?.settings.connectors ?? preview ?? ConnectorSettings() }

    private func change(_ f: (inout ConnectorSettings) -> Void) {
        manager?.updateConnectors(f)
        // 押されたボタンの処理が終わってから作り直す（処理の途中でボタンごと消さない）
        DispatchQueue.main.async { [weak self] in self?.rebuild() }
    }

    // MARK: - 作る（変えるたびに作り直す）

    func rebuild() {
        let s = settings
        let title = NSTextField(labelWithString: L("🔌 コネクタ（カレンダー・リマインダー・メール）"))
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let intro = label(L("この Mac のカレンダー・リマインダー・メールを、エージェントのツールとして使えるようにします。Google カレンダーや Gmail は、システム設定 › インターネットアカウント に Google アカウントを追加すると Mac のアプリに出て、ここから使えます。OMOCHI AI は Google などのパスワード・トークン・API キーを扱いません。"), size: 12, secondary: true)
        let accounts = NSButton(title: L("インターネットアカウントを開く…"), target: self, action: #selector(openInternetAccounts))
        accounts.bezelStyle = .rounded
        accounts.controlSize = .small

        var views: [NSView] = [title, intro, row([accounts, NSView()])]

        // ワンタッチ設定
        let current = ConnectorPreset.matching(s)
        var presetButtons: [NSView] = [label(L("ワンタッチ設定:"), size: 12.5, bold: true, wrap: false)]
        for p in ConnectorPreset.allCases {
            let b = NSButton(title: "\(p.icon) \(p.label)", target: self, action: #selector(applyPreset(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(p.rawValue)
            b.bezelStyle = .rounded
            b.toolTip = p.detail
            // いまの設定と同じボタンは色をつける
            if p == current { b.bezelColor = .controlAccentColor; b.font = .systemFont(ofSize: 13, weight: .semibold) }
            presetButtons.append(b)
        }
        presetButtons.append(NSView())
        views.append(row(presetButtons, spacing: 6))
        let now = current.map { L("いまの設定: %@ — %@", "\($0.icon) \($0.label)", $0.detail) } ?? L("いまの設定: カスタム（下で決めた内容）")
        views.append(label(now, size: 11.5, secondary: true))
        views.append(separator())

        for k in ConnectorKind.allCases { views.append(section(k, s[k])) }

        views.append(label([
            L("・書き込み（予定・リマインダーの追加と完了）は、おもちの横に確認が出て、押したときだけ実行します。5 分押さなければ実行しません"),
            L("・メールは送信しません。下書きはメールアプリで開くので、確かめて送るのはあなたです"),
            L("・メールの本文は「外から来たデータ」として渡し、中の指示に従わないよう伝えます。PC 操作を使っているおもちにはメールを渡しません"),
            L("・仲間からの依頼で動いているおもちにも、その AI・モデルの決まりのとおりに渡します（渡した内容を仲間に頼むことはできます）"),
            L("・中身は、そのおもちの AI（Anthropic・OpenAI・Google）に送られます。使った記録は OMOCHI AI のログ（app.log）に、ツールの名前だけ残ります"),
        ].joined(separator: "\n"), size: 11, secondary: true))

        let close = NSButton(title: L("閉じる"), target: self, action: #selector(closeWindow))
        close.keyEquivalent = "\r"
        views.append(row([NSView(), close]))

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        var cs = [stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                  stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                  content.widthAnchor.constraint(equalToConstant: ConnectorsWindowController.width)]
        for v in views { cs.append(v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44)) }
        NSLayoutConstraint.activate(cs)
        let top = window.frame.maxY
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        let size = NSSize(width: ConnectorsWindowController.width, height: stack.fittingSize.height)
        window.setContentSize(size)
        // 上の端を動かさない（作り直すたびに窓が跳ねないように）
        if window.isVisible { window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top)) }
    }

    /// コネクタ 1 つの枠
    private func section(_ k: ConnectorKind, _ r: ConnectorRule) -> NSView {
        let head = label("\(k.icon) \(k.label)", size: 14, bold: true, wrap: false)
        let what = label(k.abilities, size: 11.5, secondary: true, wrap: false)
        let line0 = row([head, what, NSView()], spacing: 10)

        // 使わせる範囲
        let access = NSPopUpButton(frame: .zero, pullsDown: false)
        for a in ConnectorAccess.allCases {
            access.addItem(withTitle: a.label)
            access.lastItem?.representedObject = a.rawValue
        }
        access.selectItem(at: ConnectorAccess.allCases.firstIndex(of: r.access) ?? 0)
        access.identifier = NSUserInterfaceItemIdentifier(k.rawValue)
        access.target = self
        access.action = #selector(accessChanged(_:))

        // macOS の許可
        let perm = MacConnectors.permission(k)
        let permLabel = label(L("macOS の許可: %@", perm.label), size: 11.5, secondary: perm != .granted, wrap: false)
        if perm == .granted { permLabel.textColor = .systemGreen } else if perm == .denied { permLabel.textColor = .systemOrange }
        let ask = NSButton(title: L("許可する…"), target: self, action: #selector(requestPermission(_:)))
        ask.identifier = NSUserInterfaceItemIdentifier(k.rawValue)
        ask.bezelStyle = .rounded
        ask.controlSize = .small
        ask.isHidden = perm == .granted || perm == .denied
        let prefs = NSButton(title: L("システム設定…"), target: self, action: #selector(openPrivacy(_:)))
        prefs.identifier = NSUserInterfaceItemIdentifier(k.rawValue)
        prefs.bezelStyle = .rounded
        prefs.controlSize = .small

        // 見出しと範囲の選択は縮ませず、長い許可の文は末尾を省く（言語によって長さが違う）
        let accessLabel = label(L("使わせる範囲"), size: 12, wrap: false)
        accessLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        access.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        permLabel.lineBreakMode = .byTruncatingTail
        permLabel.toolTip = permLabel.stringValue
        permLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let line1 = row([accessLabel, access, NSView(), permLabel, ask, prefs], spacing: 8)

        // 使える AI と、その AI で使えるモデル
        let aiLabel = label(L("使える AI"), size: 12, wrap: false)
        aiLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        var aiViews: [NSView] = [aiLabel]
        for e in AgentEngine.allCases {
            let cb = NSButton(checkboxWithTitle: e.displayName, target: self, action: #selector(engineToggled(_:)))
            cb.identifier = NSUserInterfaceItemIdentifier("\(k.rawValue).\(e.rawValue)")
            cb.state = r.allows(e) ? .on : .off
            cb.isEnabled = r.access != .off
            let models = modelPicker(k, e, r)
            models.isEnabled = r.access != .off && r.allows(e)
            aiViews += [cb, models]
        }
        aiViews.append(NSView())
        let line2 = row(aiViews, spacing: 6)

        let summary = label(L("→ %@", ConnectorPolicy.summary(r)), size: 11, secondary: true)

        let inner = NSStackView(views: [line0, line1, line2, summary])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 6
        inner.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        inner.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        box.addSubview(inner)
        var cs = [inner.leadingAnchor.constraint(equalTo: box.leadingAnchor), inner.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                  inner.topAnchor.constraint(equalTo: box.topAnchor), inner.bottomAnchor.constraint(equalTo: box.bottomAnchor)]
        for v in [line0, line1, line2, summary] { cs.append(v.widthAnchor.constraint(equalTo: inner.widthAnchor, constant: -24)) }
        NSLayoutConstraint.activate(cs)
        return box
    }

    /// その AI で使えるモデルを選ぶボタン（押すと一覧。「すべてのモデル」か、選んだモデルだけ）
    private func modelPicker(_ k: ConnectorKind, _ e: AgentEngine, _ r: ConnectorRule) -> NSPopUpButton {
        let keys = r.models(for: e) ?? []
        let b = NSPopUpButton(frame: .zero, pullsDown: true)
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        let title = keys.isEmpty ? L("すべてのモデル") : ConnectorPolicy.modelLabels(keys, engine: e)
        b.addItem(withTitle: title.count > 22 ? String(title.prefix(22)) + "…" : title)
        b.toolTip = L("%@ のおもちのうち、このコネクタを使えるモデル", e.displayName)
        let all = NSMenuItem(title: L("すべてのモデル"), action: #selector(modelChosen(_:)), keyEquivalent: "")
        all.target = self
        all.state = keys.isEmpty ? .on : .off
        all.representedObject = ["\(k.rawValue)", e.rawValue, ""]
        b.menu?.addItem(all)
        b.menu?.addItem(.separator())
        let choices = ConnectorsWindowController.modelChoices(e, current: keys)
        if choices.isEmpty {
            let none = NSMenuItem(title: L("（モデルの一覧を読めていません。%@ を入れてログインすると出ます）", e.cliTitle), action: nil, keyEquivalent: "")
            none.isEnabled = false
            b.menu?.addItem(none)
        }
        for c in choices {
            let it = NSMenuItem(title: c.label, action: #selector(modelChosen(_:)), keyEquivalent: "")
            it.target = self
            it.state = keys.contains { $0.lowercased() == c.key.lowercased() } ? .on : .off
            it.representedObject = ["\(k.rawValue)", e.rawValue, c.key]
            b.menu?.addItem(it)
        }
        return b
    }

    /// 選べるモデル：Claude は系統（Fable・Opus・Sonnet・Haiku）、ほかの AI は CLI のモデルの一覧（＋いま選んでいるもの）
    static func modelChoices(_ e: AgentEngine, current: [String]) -> [(key: String, label: String)] {
        if e == .claude {
            var out = ConnectorPolicy.claudeFamilies.map { (key: $0.key, label: "Claude \($0.label)") }
            for k in current where !out.contains(where: { $0.key == k.lowercased() }) { out.append((k, k)) }
            return out
        }
        var out = EngineModelCatalog.shared.models(e).map { (key: $0.id, label: $0.name == $0.id ? $0.id : "\($0.name)（\($0.id)）") }
        for k in current where !out.contains(where: { $0.key == k }) { out.append((k, k)) }
        return out
    }

    // MARK: - 操作

    @objc private func applyPreset(_ sender: NSButton) {
        guard let p = sender.identifier.flatMap({ ConnectorPreset(rawValue: $0.rawValue) }) else { return }
        manager?.applyConnectorPreset(p)
    }

    @objc private func accessChanged(_ sender: NSPopUpButton) {
        guard let k = sender.identifier.flatMap({ ConnectorKind(rawValue: $0.rawValue) }),
              let raw = sender.selectedItem?.representedObject as? String, let a = ConnectorAccess(rawValue: raw) else { return }
        change { $0[k].access = a }
    }

    @objc private func engineToggled(_ sender: NSButton) {
        let parts = (sender.identifier?.rawValue ?? "").split(separator: ".").map(String.init)
        guard parts.count == 2, let k = ConnectorKind(rawValue: parts[0]), let e = AgentEngine(rawValue: parts[1]) else { return }
        change { $0[k].setEngine(e, allowed: sender.state == .on) }
    }

    @objc private func modelChosen(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? [String], v.count == 3,
              let k = ConnectorKind(rawValue: v[0]), let e = AgentEngine(rawValue: v[1]) else { return }
        change { s in
            if v[2].isEmpty { s[k].allModels(for: e) } else { s[k].toggleModel(v[2], for: e) }
        }
    }

    @objc private func requestPermission(_ sender: NSButton) {
        guard let k = sender.identifier.flatMap({ ConnectorKind(rawValue: $0.rawValue) }) else { return }
        sender.isEnabled = false
        MacConnectors.shared.requestPermission(k) { [weak self] _ in self?.rebuild() }
    }

    @objc private func openPrivacy(_ sender: NSButton) {
        guard let k = sender.identifier.flatMap({ ConnectorKind(rawValue: $0.rawValue) }) else { return }
        let anchor: String
        switch k {
        case .calendar: anchor = "Privacy_Calendars"
        case .reminders: anchor = "Privacy_Reminders"
        case .mail: anchor = "Privacy_Automation"
        }
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(u) }
    }

    @objc private func openInternetAccounts() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") { NSWorkspace.shared.open(u) }
    }

    @objc private func closeWindow() { window.performClose(nil) }

    func windowDidBecomeKey(_ notification: Notification) {
        // システム設定で許可を変えて戻ってきたときに、状態を読み直す
        rebuild()
    }

    // MARK: - 部品

    private func label(_ s: String, size: CGFloat, bold: Bool = false, secondary: Bool = false, wrap: Bool = true) -> NSTextField {
        let f = wrap ? NSTextField(wrappingLabelWithString: s) : NSTextField(labelWithString: s)
        f.font = bold ? .systemFont(ofSize: size, weight: .semibold) : .systemFont(ofSize: size)
        if secondary { f.textColor = .secondaryLabelColor }
        f.isSelectable = false
        return f
    }

    private func row(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = spacing
        for v in views where v is NSTextField { v.setContentHuggingPriority(.required, for: .horizontal) }
        return r
    }

    private func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }
}
