import AppKit

/// クロージャで動く NSMenuItem
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command],
         checked: Bool = false, image: NSImage? = nil, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
        state = checked ? .on : .off
        self.image = image
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 開発用の使い方の記録に、項目の名前を残してよいか（会話の題名など、指示の文から作った項目は false）
    var journalTitle = true

    @objc private func fire() {
        DevJournal.log("menu", ["item": journalTitle ? title : "(conversation)"])
        handler()
    }
}

extension NSMenuItem {
    static func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

enum MenuImages {
    /// エージェント色の丸
    static func dot(_ c: JellyColor, state: AgentState) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        return NSImage(size: size, flipped: false) { rect in
            let col: NSColor
            switch state {
            case .error: col = NSColor(srgbRed: 1, green: 0.32, blue: 0.28, alpha: 1)
            case .cancelled: col = NSColor(white: 0.6, alpha: 1)
            default: col = NSColor(srgbRed: CGFloat(c.base.x), green: CGFloat(c.base.y), blue: CGFloat(c.base.z), alpha: 1)
            }
            col.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
    }

    /// メニューバー用のお餅「まるもち」のシルエット（テンプレート画像、目は抜き）
    static func statusIcon() -> NSImage { statusFrame(StatusPose()) }

    /// メニューバーのアイコンのコマ（ドット絵と同じ「まるもち」を 1 マス 1.5pt で。目はくり抜き、影は描かない。
    /// テンプレート画像なので明暗に追従）
    struct StatusPose: Hashable {
        var lift = 0          // 0 / 1（1 マス跳ねる）
        var blink = false
        var puff = 0          // -1〜3（ふくらみ）
        var dots = 0          // 考え中の「…」（0〜3）
    }

    private static var frameCache: [StatusPose: NSImage] = [:]

    /// アイコンのマス（上から 1〜10 行目、15 列。# = 塗る）
    static func statusRows(_ p: StatusPose) -> [String] {
        var pose = JellyPose()
        pose.eyes = p.blink ? .closed : .open(dx: 0, dy: 0)
        pose.puff = p.puff
        pose.lift = p.lift
        pose.mark = p.dots > 0 ? .dots(p.dots) : .none
        let g = MochiSprite.grid(pose)
        let s = MochiSprite.sub
        return (1...MochiSprite.floor).map { r in
            String((0..<MochiSprite.cols).map { c -> Character in
                var filled = 0, eye = 0
                for i in 0..<s { for j in 0..<s {
                    switch g[c * s + i, r * s + j] {
                    case .body?, .mark?: filled += 1
                    case .eye?: eye += 1
                    default: break
                    }
                } }
                // 開いた目（1 マスまるごと）だけくり抜く。閉じた目は細すぎるので、まばたきは目をふさいで見せる
                return eye >= 3 ? "." : (filled + eye > 0 ? "#" : ".")
            })
        }
    }

    static func statusFrame(_ p: StatusPose) -> NSImage {
        if let img = frameCache[p] { return img }
        let rows = statusRows(p)
        let img = NSImage(size: NSSize(width: 23, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            let c: CGFloat = 1.5, ox: CGFloat = 0.5, oy: CGFloat = 1.5
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where ch == "#" {
                    NSRect(x: ox + CGFloat(x) * c, y: oy + CGFloat(y) * c, width: c, height: c).fill()
                }
            }
            return true
        }
        img.isTemplate = true
        frameCache[p] = img
        return img
    }
}
