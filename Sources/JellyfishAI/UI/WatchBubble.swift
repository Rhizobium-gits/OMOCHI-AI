import AppKit

/// クラゲが出す吹き出し：見守りの「エラーっぽいのが出たよ、見る？」と、アップデートの「新しい版が出たよ」。
/// 前面に出ても入力先は奪わない（キーにならないパネル）。押せるのは「見る」「✕」と、右の小さなボタン（このアプリでは聞かない・この版は知らせない）だけ
final class WatchBubble: NSObject {
    /// 吹き出しの文言（既定は見守り）
    struct Text {
        var title: String
        var detail: String
        var show: String = L("見る")
        var closeTip: String = L("閉じる（この画像は送らずに消します）")
        var ignore: String = L("このアプリでは聞かない")
        var note: String? = L("押すと、このウィンドウの 1 枚だけを送ります")
        /// 中身の最大の行数（コネクタの確認は多め）
        var detailLines: Int = 2
        /// 閉じるボタンの文字（コネクタの確認は「やめる」）
        var closeTitle: String = "✕"

        static func watch(appName: String, snippet: String) -> Text {
            Text(title: L("エラーっぽいのが出たよ、見る？"), detail: "\(appName)：\(snippet)")
        }
    }

    private let panel: NSPanel
    private var timer: Timer?
    private weak var showButton: NSButton?
    private weak var closeButton: NSButton?
    private var onShow: (() -> Void)?
    private var onDismiss: (() -> Void)?
    private var onIgnoreApp: (() -> Void)?

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private let autoClose: TimeInterval

    init(_ text: Text, accent: NSColor, near anchor: NSRect, autoClose: TimeInterval = 90,
         onShow: @escaping () -> Void, onDismiss: @escaping () -> Void, onIgnoreApp: @escaping () -> Void) {
        self.autoClose = autoClose
        self.onShow = onShow
        self.onDismiss = onDismiss
        self.onIgnoreApp = onIgnoreApp
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 110), styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSVisualEffectView()
        bg.material = .popover
        bg.state = .active
        // すりガラスを角丸に切る（NSVisualEffectView は maskImage で）。縁はクラゲの色
        bg.maskImage = WatchBubble.roundedMask(radius: 12)
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 1.5
        bg.layer?.borderColor = accent.withAlphaComponent(0.8).cgColor

        let title = NSTextField(labelWithString: text.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(labelWithString: text.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines = text.detailLines
        detail.cell?.wraps = true
        detail.preferredMaxLayoutWidth = 270

        let show = NSButton(title: text.show, target: self, action: #selector(showTapped))
        show.bezelStyle = .rounded
        show.keyEquivalent = "\r"
        let close = NSButton(title: text.closeTitle, target: self, action: #selector(dismissTapped))
        close.bezelStyle = .rounded
        close.toolTip = text.closeTip
        let ignore = NSButton(title: text.ignore, target: self, action: #selector(ignoreTapped))
        ignore.isBordered = false
        ignore.font = .systemFont(ofSize: 10.5)
        ignore.contentTintColor = .secondaryLabelColor
        // 右の小さなボタンは、文字があるときだけ（コネクタの確認には無い）
        let buttons = NSStackView(views: text.ignore.isEmpty ? [show, close, NSView()] : [show, close, NSView(), ignore])
        showButton = show
        closeButton = close
        buttons.orientation = .horizontal
        buttons.spacing = 6

        var rows: [NSView] = [title, detail, buttons]
        if let n = text.note {
            let note = NSTextField(labelWithString: n)
            note.font = .systemFont(ofSize: 10)
            note.textColor = .tertiaryLabelColor
            rows.append(note)
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 9, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor), stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bg.topAnchor), stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            stack.widthAnchor.constraint(equalToConstant: 300),
        ])
        panel.contentView = bg
        bg.layoutSubtreeIfNeeded()
        let size = NSSize(width: 300, height: max(96, stack.fittingSize.height))
        panel.setContentSize(size)
        panel.setFrameOrigin(WatchBubble.origin(for: size, near: anchor))
    }

    static func roundedMask(radius r: CGFloat) -> NSImage {
        let edge = r * 2 + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }

    /// クラゲの上（入らなければ左）に、画面の中に収まるように
    static func origin(for size: NSSize, near a: NSRect, screens: [NSRect] = NSScreen.screens.map(\.visibleFrame)) -> NSPoint {
        let screen = screens.first { $0.intersects(a) } ?? screens.first ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var p = NSPoint(x: a.midX - size.width / 2, y: a.maxY + 6)
        if p.y + size.height > screen.maxY { p = NSPoint(x: a.minX - size.width - 8, y: a.midY - size.height / 2) }
        p.x = min(max(p.x, screen.minX + 6), screen.maxX - size.width - 6)
        p.y = min(max(p.y, screen.minY + 6), screen.maxY - size.height - 6)
        return p
    }

    /// 出す（前面に出すが、入力先は奪わない）。autoClose 秒（見守りは 90 秒）で自動で閉じる（「✕」と同じ）
    func present() {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.2; panel.animator().alphaValue = 1 }
        timer = Timer.scheduledTimer(withTimeInterval: autoClose, repeats: false) { [weak self] _ in self?.dismissTapped() }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
        onShow = nil; onDismiss = nil; onIgnoreApp = nil
    }

    /// デモの録画用：「見る」（または閉じる）を押したように見せて押す
    func pressForDemo(_ approve: Bool) { (approve ? showButton : closeButton)?.performClick(nil) }

    @objc private func showTapped() { let f = onShow; close(); f?() }
    @objc private func dismissTapped() { let f = onDismiss; close(); f?() }
    @objc private func ignoreTapped() { let f = onIgnoreApp; close(); f?() }
}
