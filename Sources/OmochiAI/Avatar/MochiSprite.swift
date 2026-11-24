import CoreGraphics
import Foundation

/// ドット絵のお餅「まるもち」の表情とポーズ。
/// キャンバスは 15×12 マス（上 3 マスは「…」「!」「✓」などの表示用、いちばん下の行は足元の影）で、1 マスを 2×2 のサブピクセルで描く。
/// 体はマス単位の四角だけ。目だけは半マス単位で動かせる。
struct JellyPose: Hashable {
    enum Eyes: Hashable { case open(dx: Int, dy: Int), closed, happy, cross }
    enum Arms: Hashable { case normal, up, down, leftUp, rightUp, raised }
    enum Legs: Hashable { case stand, walkA, walkB, crouch, dangle }
    enum Mark: Hashable { case none, dots(Int), exclaim, check, steam(Int) }
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
    /// 焦げ目：0 なし、1 少し、2 しっかり（会話が文脈の上限に近い）
    var char: Int = 0
    /// 硬さ：0 やわらかい、1 少し硬い、2 硬い（ひびが入る。しばらく使っていない）
    var hard: Int = 0
    /// 大福：あんこ（いつも参照する資料）を包んでいる
    var anko: Bool = false
    /// 鏡餅の上（リーダー）：頭にだいだい
    var crown: Bool = false
}

/// おもちの見た目にかかわる状態（会話の大きさ・硬さ・あんこ・鏡餅・温め直し中）
struct MochiLook: Equatable {
    /// ふくらみ（0〜1。会話の大きさ）
    var fullness: Double = 0
    var char: Int = 0
    var hard: Int = 0
    var anko: Bool = false
    var crown: Bool = false
    /// 温め直している（湯気が立つ）
    var warming: Bool = false
}

/// ドット絵の色（体の色はエージェントの色。エラーは赤、中止は濃い灰色）
struct SpriteColors {
    let flat: SIMD3<Double>

    static func from(_ c: JellyColor) -> SpriteColors {
        SpriteColors(flat: SIMD3(Double(c.flat.x), Double(c.flat.y), Double(c.flat.z)))
    }

    static let errorBody = SIMD3<Double>(0.90, 0.33, 0.30)
    /// 焦げ目（こんがり・しっかり）・あんこ・打ち粉・だいだい・葉・湯気
    static let char = SIMD3<Double>(0.66, 0.43, 0.20)
    static let charDeep = SIMD3<Double>(0.44, 0.26, 0.11)
    static let ankoColor = SIMD3<Double>(0.36, 0.20, 0.24)
    static let powder = SIMD3<Double>(0.99, 0.98, 0.96)
    static let daidai = SIMD3<Double>(0.98, 0.56, 0.12)
    static let leaf = SIMD3<Double>(0.30, 0.60, 0.24)
    static let steam = SIMD3<Double>(0.80, 0.82, 0.86)
    /// 硬くなった体の色（乾いて白っぽくなる）
    static let dry = SIMD3<Double>(0.93, 0.92, 0.88)
    /// 中止：既定の灰色のお餅と見分けられるよう、濃い灰色
    static let cancelledBody = SIMD3<Double>(0.40, 0.39, 0.38)
    static let warn = SIMD3<Double>(1.00, 0.78, 0.27)
    static let eye = SIMD3<Double>(0.09, 0.07, 0.06)

    /// 役割ごとの色（頭上の記号はいつもエージェントの色）。影は shadowAlpha の黒
    func color(_ role: MochiSprite.Role, tone: JellyPose.Tone, hard: Int = 0) -> SIMD3<Double> {
        func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> { a + (b - a) * t }
        let body: SIMD3<Double>
        switch tone {
        case .normal: body = mix(flat, SpriteColors.dry, 0.2 * Double(max(0, min(2, hard))))
        case .error: body = SpriteColors.errorBody
        case .cancelled: body = SpriteColors.cancelledBody
        }
        switch role {
        case .body: return body
        case .eye: return SpriteColors.eye
        case .shadow: return SIMD3(0, 0, 0)
        case .mark: return flat
        case .warn: return SpriteColors.warn
        case .char: return mix(body, SpriteColors.char, 0.75)
        case .charDeep: return SpriteColors.charDeep
        case .crack: return mix(body, SpriteColors.eye, 0.45)
        case .anko: return mix(body, SpriteColors.ankoColor, 0.3)
        case .powder: return SpriteColors.powder
        case .daidai: return SpriteColors.daidai
        case .leaf: return SpriteColors.leaf
        case .steam: return SpriteColors.steam
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
    enum Role: UInt8 { case body, eye, shadow, mark, warn, char, charDeep, crack, anko, powder, daidai, leaf, steam }

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

        drawSurface(&g, p, widths: ws, top: top)

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

    /// 体の表面：あんこ（大福）・打ち粉・焦げ目・ひび（硬い）・頭のだいだい（鏡餅のリーダー）。サブピクセル単位
    private static func drawSurface(_ g: inout Grid, _ p: JellyPose, widths ws: [Int], top: Int) {
        let n = ws.count
        guard n >= 2 else { return }
        let s = sub
        let cx = 7 * s + 1            // 中心（サブピクセル。列 7 の右半分）
        let y0 = top * s              // 体のいちばん上の行（サブピクセル）
        let yb = (top + n) * s - 1    // いちばん下の行
        func half(_ row: Int) -> Int { (ws[max(0, min(n - 1, row))] - 1) / 2 }
        /// 体の中にあるときだけ置く（体の外にははみ出さない）
        func put(_ x: Int, _ y: Int, _ r: Role) {
            let row = y / s - top
            guard row >= 0, row < n else { return }
            let h = half(row)
            guard x >= (7 - h) * s, x <= (7 + h) * s + 1 else { return }
            g.px(x, y, r)
        }
        let flat = n <= 3
        // あんこ：体の上のほうに透けて見える、角の丸い濃いところ（目より上）
        if p.anko && !flat {
            let ay = y0 + s           // 2 行目から
            let rows = n >= 7 ? 4 : 3
            for dy in 0..<rows {
                let w = (dy == 0 || dy == rows - 1) ? 3 : 4
                for x in (cx - w)...(cx + w - 1) { put(x, ay + dy, .anko) }
            }
            // 打ち粉（上の面の白い粉）
            for (dx, dy) in [(-6, 0), (-2, 1), (3, 0), (7, 1), (-9, 2), (10, 3)] { put(cx + dx, y0 + dy, .powder) }
        }
        // 焦げ目：上の面のこんがりした斑点（しっかり焦げると濃く・多く、下のほうにも）
        if p.char > 0 {
            var spots: [(Int, Int, Role)] = [(-5, 0, .char), (-4, 0, .char), (-4, 1, .char), (4, 0, .char), (5, 1, .char), (5, 0, .char)]
            if p.char >= 2 {
                spots += [(-1, 0, .charDeep), (0, 0, .charDeep), (0, 1, .char), (-8, 2, .char), (-7, 2, .charDeep), (8, 2, .char),
                          (9, 3, .charDeep), (-4, 0, .charDeep), (5, 0, .charDeep)]
                // 床に近いところも少し
                spots += [(-9, yb - y0, .char), (-8, yb - y0, .char), (8, yb - y0, .char), (9, yb - y0 - 1, .char)]
            }
            for (dx, dy, r) in spots { put(cx + dx, y0 + dy, r) }
        }
        // ひび：硬くなると、左上から入る細いひび（とても硬いと右にも）
        if p.hard > 0 {
            let leftEdge = (7 - half(1)) * s
            var crack: [(Int, Int)] = [(0, 0), (1, 1), (2, 1), (3, 2)]
            if p.hard >= 2 { crack += [(4, 3), (4, 4), (5, 5)] }
            for (dx, dy) in crack { put(leftEdge + 1 + dx, y0 + s + dy, .crack) }
            if p.hard >= 2 {
                let rightEdge = (7 + half(2)) * s + 1
                for (dx, dy) in [(0, 0), (-1, 1), (-2, 1), (-2, 2)] { put(rightEdge - 1 + dx, y0 + 2 * s + dy, .crack) }
            }
        }
        // だいだい：鏡餅のいちばん上に載る。体の上にのせた丸いみかんと葉
        if p.crown {
            let base = y0 - 1
            let rows: [(Int, Int)] = [(0, 3), (1, 4), (2, 4), (3, 3)]   // (上からの行, 半分の幅)
            for (i, w) in rows {
                for x in (cx - w)...(cx + w - 1) { g.px(x, base - 3 + i, .daidai) }
            }
            g.px(cx - 1, base - 4, .leaf); g.px(cx, base - 4, .leaf); g.px(cx + 1, base - 5, .leaf); g.px(cx + 2, base - 5, .leaf)
        }
    }

    /// 頭上の表示（キャンバス上 3 マス）
    private static func drawMarks(_ g: inout Grid, _ p: JellyPose) {
        switch p.mark {
        case .none: break
        case .steam(let phase):
            // 湯気：3 本のゆらゆらした白い線（phase でゆらぎがずれる）
            for (k, x0) in [9, 15, 21].enumerated() {
                for y in 0..<6 {
                    let wob = ((y + phase + k) / 2) % 2 == 0 ? 0 : 1
                    g.px(x0 + wob, y, .steam)
                }
            }
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
                    let v = colors.color(r, tone: pose.tone, hard: pose.hard)
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
