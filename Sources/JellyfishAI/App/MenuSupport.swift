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

    @objc private func fire() { handler() }
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

    /// メニューバー用のクラゲ「もち」のシルエット（テンプレート画像、目は抜き）
    static func statusIcon() -> NSImage { statusFrame(StatusPose()) }

    /// メニューバーのアイコンのコマ（16×13 の「もち」。目はくり抜き、テンプレート画像なので明暗に追従）
    struct StatusPose: Hashable {
        var lift = 0          // 0 / 1（1 段浮く）
        var blink = false
        var legs = 0          // 0 = まっすぐ, 1 / 2 = 触手が左右に揺れる
        var dots = 0          // 考え中の「…」（0〜3）
        var arms = false      // 作業中に腕を上げる
    }

    private static var frameCache: [StatusPose: NSImage] = [:]

    /// アイコンの点の配置（上から。# = 塗る）
    static func statusRows(_ p: StatusPose) -> [String] {
        var g: [[Character]] = [
            ".....######.....",
            "...##########...",
            "..############..",
            ".##############.",
            ".##############.",
            ".###..####..###.",
            ".###..####..###.",
            ".##############.",
            "..############..",
            "................",
            "................",
            "................",
            "................",
        ].map(Array.init)
        func set(_ x: Int, _ y: Int, _ c: Character = "#") { if y >= 0, y < g.count, x >= 0, x < 16 { g[y][x] = c } }
        // まばたき：目を下の 1 段だけに
        if p.blink { for x in [4, 5, 10, 11] { set(x, 5) } }
        // 腕（かさの下の角から外へ。作業中は上へ）
        if p.arms { set(1, 9); set(0, 8); set(14, 9); set(15, 8) } else { set(1, 9); set(0, 10); set(14, 9); set(15, 10) }
        // 触手 2 本（下の 2 段が揺れる）
        let sway: [[Int]]
        switch p.legs {
        case 1: sway = [[6, 9], [6, 9], [5, 8], [4, 7]]
        case 2: sway = [[6, 9], [6, 9], [7, 10], [8, 11]]
        default: sway = [[6, 9], [6, 9], [6, 9], [5, 10]]
        }
        for (i, xs) in sway.enumerated() { for x in xs { set(x, 9 + i) } }
        return g.map { String($0) }
    }

    static func statusFrame(_ p: StatusPose) -> NSImage {
        if let img = frameCache[p] { return img }
        let rows = statusRows(p)
        let dots = p.dots
        let lift = CGFloat(p.lift)
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            let ox: CGFloat = 1, oy: CGFloat = 4 - lift
            for i in 0..<min(dots, 3) {
                NSRect(x: ox + CGFloat(3 + i * 4), y: 0, width: 2, height: 2).fill()
            }
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where ch == "#" {
                    NSRect(x: ox + CGFloat(x), y: oy + CGFloat(y), width: 1, height: 1).fill()
                }
            }
            return true
        }
        img.isTemplate = true
        frameCache[p] = img
        return img
    }
}
