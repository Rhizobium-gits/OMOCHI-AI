import CoreGraphics
import Foundation

/// ドット絵のお餅「まるもち」の表情とポーズ。
/// キャンバスは 15×12 マス（上 3 マスは「…」「!」「✓」などの表示用、いちばん下の行は足元の影）で、1 マスを 2×2 のサブピクセルで描く。
/// 体はマス単位の四角だけ。目だけは半マス単位で動かせる。
struct JellyPose: Hashable {
    enum Eyes: Hashable { case open(dx: Int, dy: Int), closed, happy, cross }
    enum Arms: Hashable { case normal, up, down, leftUp, rightUp, raised }
    enum Legs: Hashable { case stand, walkA, walkB, crouch, dangle }
    enum Mark: Hashable { case none, dots(Int), exclaim, check }
    enum Tone: Hashable { case normal, error, cancelled }

    var eyes: Eyes = .open(dx: 0, dy: 0)
    /// 前のキャラの腕のポーズ（お餅には腕が無いので絵には使わない。状態の組み立てとの互換のため残す）
    var arms: Arms = .normal
    /// crouch = ぎゅっとつぶれる（着地・長押し）、dangle = つままれて「のび〜」と伸びる。ほかは形を変えない
    var legs: Legs = .stand
    var mark: Mark = .none
    var tone: Tone = .normal
    /// 体を何マス持ち上げるか（ぴょんと跳ねるコマ。影は床に残る）
    var lift: Int = 0
    /// ふくらみ：-1 しぼむ（横にぺたん）、0 ふつう、1〜3 ふくらむ（上へ丸く盛り上がる）
    var puff: Int = 0
}

/// ドット絵の色（体の色はエージェントの色。エラーは赤、中止は濃い灰色）
struct SpriteColors {
    let flat: SIMD3<Double>

    static func from(_ c: JellyColor) -> SpriteColors {
        SpriteColors(flat: SIMD3(Double(c.flat.x), Double(c.flat.y), Double(c.flat.z)))
    }

    static let errorBody = SIMD3<Double>(0.90, 0.33, 0.30)
    /// 中止：既定の灰色のお餅と見分けられるよう、濃い灰色
    static let cancelledBody = SIMD3<Double>(0.40, 0.39, 0.38)
    static let warn = SIMD3<Double>(1.00, 0.78, 0.27)
    static let eye = SIMD3<Double>(0.09, 0.07, 0.06)

    /// 役割ごとの色（頭上の記号はいつもエージェントの色）。影は shadowAlpha の黒
    func color(_ role: MochiSprite.Role, tone: JellyPose.Tone) -> SIMD3<Double> {
        switch role {
        case .body:
            switch tone {
            case .normal: return flat
            case .error: return SpriteColors.errorBody
            case .cancelled: return SpriteColors.cancelledBody
            }
        case .eye: return SpriteColors.eye
        case .shadow: return SIMD3(0, 0, 0)
        case .mark: return flat
        case .warn: return SpriteColors.warn
        }
    }
    static let shadowAlpha: CGFloat = 0.32
}

/// お餅のドット絵「まるもち」：床にぽてっと座った丸餅。体と目だけ。
/// ふくらむと上へ丸く盛り上がり、しぼむと横にぺたんと広がる。足元に影（宙には浮かない）
enum MochiSprite {
    static let cols = 15
    static let rows = 12
    static let sub = 2                       // 1 マス = 2×2 サブピクセル
    static var pixelWidth: Int { cols * sub }
    static var pixelHeight: Int { rows * sub }
    /// 体のいちばん下の行（その下の行に影）
    static let floor = 10

    /// ドットの役割（色は SpriteColors が決める）
    enum Role: UInt8 { case body, eye, shadow, mark, warn }

    /// サブピクセルの格子（y は上から）。nil = 透明
    struct Grid {
        static var W: Int { MochiSprite.pixelWidth }
        static var H: Int { MochiSprite.pixelHeight }
        private(set) var cells = [Role?](repeating: nil, count: MochiSprite.pixelWidth * MochiSprite.pixelHeight)

        subscript(x: Int, y: Int) -> Role? {
            guard x >= 0, y >= 0, x < Grid.W, y < Grid.H else { return nil }
            return cells[y * Grid.W + x]
        }
        mutating func px(_ x: Int, _ y: Int, _ r: Role) {
            guard x >= 0, y >= 0, x < Grid.W, y < Grid.H else { return }
            cells[y * Grid.W + x] = r
        }
        mutating func cell(_ c: Int, _ r: Int, _ role: Role) {
            for i in 0..<MochiSprite.sub { for j in 0..<MochiSprite.sub { px(c * MochiSprite.sub + i, r * MochiSprite.sub + j, role) } }
        }
    }

    // MARK: - 形

    /// 形ごとの段の幅（上から。奇数マス、列 7 が中心）
    static func widths(_ p: JellyPose) -> [Int] {
        switch p.legs {
        case .crouch: return [13, 15]
        case .dangle: return [5, 7, 7, 7, 7, 7, 7, 5]
        default: break
        }
        switch max(-1, min(3, p.puff)) {
        case -1: return [11, 15, 15]
        case 1: return [7, 11, 13, 13, 13, 13, 11]
        case 2: return [5, 9, 11, 13, 13, 13, 13, 11]
        case 3: return [7, 11, 13, 15, 15, 15, 15, 13]
        default: return [7, 11, 13, 13, 13, 11]
        }
    }

    /// 描く部分（アプリは体・頭上の記号・影を別のレイヤーにして、体だけを伸び縮みさせる）
    enum Part: Hashable { case all, body, marks }

    /// そのポーズのドットの配置。shadow = 足元の影も描く（アプリは影を別のレイヤーで描くので false）
    static func grid(_ p: JellyPose, shadow: Bool = true, part: Part = .all) -> Grid {
        var g = Grid()
        if part == .marks { drawMarks(&g, p); return g }
        let ws = widths(p)
        let bottom = floor - p.lift
        let top = bottom - ws.count + 1
        for (i, w) in ws.enumerated() {
            let h = (w - 1) / 2
            for c in (7 - h)...(7 + h) { g.cell(c, top + i, .body) }
        }

        // 足元の影（床の行の上半分。体のいちばん下より少し短く、跳ねると小さくなる）
        if shadow {
            let sw = shadowHalfWidth(p)
            for x in ((7 - sw) * sub)..<((8 + sw) * sub) { g.px(x, (floor + 1) * sub, .shadow) }
        }

        // 目（1 マス）。顔は下のほう。ぺたんとしたときは 2 段のまん中、いちばんふくらむと目の間が広がる
        let flat = ws.count <= 3
        let off = (ws.max() ?? 13) >= 15 ? 3 : 2
        let lc = 7 - off, rc = 7 + off
        // 2 段（つぶれた）なら 1 段目から、3 段（しぼんだ）なら 2 段目から半マス下げて、目が体からはみ出さないように
        let y = (flat ? (ws.count == 2 ? top : top + 1) : bottom - 2) * sub + (flat ? 1 : 0)
        let xs = [lc * sub, rc * sub]
        switch p.eyes {
        case .open(let dx, let dy):
            for x in xs { for i in 0..<2 { for j in 0..<2 { g.px(x + dx + i, y + dy + j, .eye) } } }
        case .closed:
            for x in xs { g.px(x, y + 1, .eye); g.px(x + 1, y + 1, .eye) }
        case .happy:
            // ^ ^（3 サブピクセル幅。左右対称になるよう外側へ半マスずらす）
            for x in [xs[0] - 1, xs[1]] { g.px(x, y + 1, .eye); g.px(x + 1, y, .eye); g.px(x + 2, y + 1, .eye) }
        case .cross:
            for x in [xs[0] - 1, xs[1]] {
                g.px(x, y, .eye); g.px(x + 2, y, .eye); g.px(x + 1, y + 1, .eye); g.px(x, y + 2, .eye); g.px(x + 2, y + 2, .eye)
            }
        }

        if part == .all { drawMarks(&g, p) }
        return g
    }

    /// 頭上の表示（キャンバス上 3 マス）
    private static func drawMarks(_ g: inout Grid, _ p: JellyPose) {
        switch p.mark {
        case .none: break
        case .dots(let n): for i in 0..<min(n, 3) { g.cell(5 + i * 2, 1, .mark) }
        case .exclaim: for y in [0, 1, 2, 4, 5] { g.px(25, y, .warn); g.px(26, y, .warn) }
        case .check: for (x, y) in [(23, 3), (24, 4), (25, 5), (26, 4), (27, 3), (28, 2), (29, 1)] { g.px(x, y, .mark) }
        }
    }

    /// 足元の影の半分の幅（マス。真ん中の 1 マスを除く）
    static func shadowHalfWidth(_ p: JellyPose) -> Int {
        let ws = widths(p)
        return max(1, (ws[ws.count - 1] + 1) / 2 - 1 - p.lift)
    }

    // MARK: - 画像

    private static var cache: [String: CGImage] = [:]

    static func image(_ pose: JellyPose, colors: SpriteColors, key: String, shadow: Bool = true, part: Part = .all) -> CGImage {
        let k = "\(key)|\(shadow)|\(part)|\(pose.hashValue)"
        if let img = cache[k] { return img }
        let img = draw(pose, colors: colors, shadow: shadow, part: part)
        if cache.count > 400 { cache.removeAll() }
        cache[k] = img
        return img
    }

    private static func draw(_ pose: JellyPose, colors: SpriteColors, shadow: Bool, part: Part) -> CGImage {
        let W = pixelWidth, H = pixelHeight
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .none
        ctx.setShouldAntialias(false)
        let g = grid(pose, shadow: shadow, part: part)
        var shades: [Role: CGColor] = [:]
        for y in 0..<H {
            for x in 0..<W {
                guard let r = g[x, y] else { continue }
                let c = shades[r] ?? {
                    let v = colors.color(r, tone: pose.tone)
                    let cg = CGColor(srgbRed: CGFloat(v.x), green: CGFloat(v.y), blue: CGFloat(v.z), alpha: r == .shadow ? SpriteColors.shadowAlpha : 1)
                    shades[r] = cg
                    return cg
                }()
                ctx.setFillColor(c)
                ctx.fill(CGRect(x: x, y: H - 1 - y, width: 1, height: 1))
            }
        }
        return ctx.makeImage()!
    }
}
