import CoreGraphics
import Foundation

/// ドット絵のクラゲ「もち」の表情・手足のポーズ。
/// キャンバスは 15×12 マス（上 3 マスは「…」「!」「✓」などの表示用）で、1 マスを 2×2 のサブピクセルで描く。
/// 触手・腕・目は半マス（サブピクセル）単位で描くので、細い線や目の動きが出せる。
struct JellyPose: Hashable {
    enum Eyes: Hashable { case open(dx: Int, dy: Int), closed, happy, cross }
    enum Arms: Hashable { case normal, up, down, leftUp, rightUp, raised }
    enum Legs: Hashable { case stand, walkA, walkB, crouch, dangle }
    enum Mark: Hashable { case none, dots(Int), exclaim, check }
    enum Tone: Hashable { case normal, error, cancelled }

    var eyes: Eyes = .open(dx: 0, dy: 0)
    var arms: Arms = .normal
    /// 触手の揺れ（walkA / walkB）・縮む（crouch）・つままれて垂れる（dangle）
    var legs: Legs = .stand
    var mark: Mark = .none
    var tone: Tone = .normal
    /// 体を何マス持ち上げるか（ぴょんと跳ねるコマ）
    var lift: Int = 0
}

/// ドット絵の色（エージェントの色から、つや・ほっぺ・触手の色を作る）
struct SpriteColors {
    let flat: SIMD3<Double>

    static func from(_ c: JellyColor) -> SpriteColors {
        SpriteColors(flat: SIMD3(Double(c.flat.x), Double(c.flat.y), Double(c.flat.z)))
    }

    static let errorBody = SIMD3<Double>(0.90, 0.33, 0.30)
    static let cancelledBody = SIMD3<Double>(0.56, 0.55, 0.54)
    static let warn = SIMD3<Double>(1.00, 0.78, 0.27)
    static let eye = SIMD3<Double>(0.08, 0.07, 0.12)

    static func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> { a + (b - a) * t }

    /// 役割ごとの色（体の色は状態で変わる。頭上の記号はいつもエージェントの色）
    func color(_ role: MochiSprite.Role, tone: JellyPose.Tone) -> SIMD3<Double> {
        let body: SIMD3<Double>
        switch tone {
        case .normal: body = flat
        case .error: body = SpriteColors.errorBody
        case .cancelled: body = SpriteColors.cancelledBody
        }
        let white = SIMD3<Double>(1, 1, 1)
        switch role {
        case .body: return body
        case .shine: return SpriteColors.mix(body, white, 0.55)
        case .cheek: return SpriteColors.mix(body, SIMD3(1.0, 0.42, 0.55), 0.62)
        case .eye: return SpriteColors.eye
        case .tentacle: return SpriteColors.mix(body, white, 0.22)
        case .mark: return flat
        case .warn: return SpriteColors.warn
        }
    }
}

/// クラゲのドット絵「もち」：背の高いおもちのようなかさ、細い 2 本の腕、2 本の触手、点の目とほっぺ。
/// 作業中は腕を交互に上げ、つままれるとバンザイ、長押しで腕を下ろして縮こまる。
enum MochiSprite {
    static let cols = 15
    static let rows = 12
    static let sub = 2                       // 1 マス = 2×2 サブピクセル
    static var pixelWidth: Int { cols * sub }
    static var pixelHeight: Int { rows * sub }

    /// ドットの役割（色は SpriteColors が決める）
    enum Role: UInt8 { case body, shine, cheek, eye, tentacle, mark, warn }

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
        mutating func clear(_ x: Int, _ y: Int) {
            guard x >= 0, y >= 0, x < Grid.W, y < Grid.H else { return }
            cells[y * Grid.W + x] = nil
        }
        mutating func cell(_ c: Int, _ r: Int, _ role: Role) {
            for i in 0..<MochiSprite.sub { for j in 0..<MochiSprite.sub { px(c * MochiSprite.sub + i, r * MochiSprite.sub + j, role) } }
        }
        mutating func row(_ r: Int, _ c0: Int, _ c1: Int, _ role: Role) {
            for c in c0...c1 { cell(c, r, role) }
        }
    }

    // MARK: - 形

    /// 触手の 1 段（サブピクセル）ごとの横ずれ（左の 1 本ぶん）。sym なら右は左右反転、そうでなければ同じ向きに揺れる
    private struct Sway { let sym: Bool; let offsets: [Int] }
    private static func sway(_ p: JellyPose) -> Sway {
        if p.legs == .dangle { return Sway(sym: true, offsets: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]) }
        if p.legs == .crouch { return Sway(sym: true, offsets: [0, 0, -1, -1, -1]) }
        if p.arms == .down { return Sway(sym: true, offsets: [0, 0, 0, 0]) }
        switch p.legs {
        case .walkA: return Sway(sym: false, offsets: [0, 0, -1, -1, -2, -2, -2, -1])
        case .walkB: return Sway(sym: false, offsets: [0, 0, 1, 1, 2, 2, 2, 1])
        default: return Sway(sym: true, offsets: [0, 0, 0, -1, -1, -1, 0, 0])
        }
    }

    /// 腕の通り道（左腕。根元からの [dx, dy]、サブピクセル）。右腕は左右反転
    private static func armPath(_ a: String) -> [(Int, Int)] {
        switch a {
        case "up": return [(-1, 0), (-2, -1), (-3, -2), (-3, -3), (-3, -4), (-2, -5)]
        case "raised": return [(-1, 0), (-2, -1), (-3, -2), (-3, -3), (-3, -4), (-3, -5), (-3, -6), (-3, -7), (-2, -8)]
        case "down": return [(0, 0), (0, 1), (0, 2)]
        default: return [(0, 0), (0, 1), (-1, 2), (-1, 3), (-2, 4), (-2, 5), (-1, 6)]
        }
    }

    /// そのポーズのドットの配置
    static func grid(_ p: JellyPose) -> Grid {
        var g = Grid()
        let W = Grid.W
        let crouch = p.legs == .crouch
        let T = 3 - p.lift + (crouch ? 1 : 0)

        // かさ（行ごとの左端・右端のマス）。いちばん下の段の下半分は 1 マスおきの波形
        let rows: [(Int, Int)] = crouch ? [(4, 10), (3, 11), (2, 12), (2, 12)] : [(5, 9), (4, 10), (3, 11), (3, 11), (3, 11)]
        for (r, (c0, c1)) in rows.enumerated() { g.row(T + r, c0, c1, .body) }
        let last = T + rows.count - 1
        let (l0, l1) = rows[rows.count - 1]
        for c in l0...l1 {
            let y = last * 2 + 1
            if (c - l0) % 2 == 0 { g.px(c * 2, y, .body); g.px(c * 2 + 1, y, .body) } else { g.clear(c * 2, y); g.clear(c * 2 + 1, y) }
        }
        let y0 = last * 2 + 2            // 触手・腕の付け根の y（サブピクセル）

        // つや
        g.cell(5, T + 1, .shine)

        // 腕（かさの下の角から出る細い線）
        var la = "normal", ra = "normal"
        switch p.arms {
        case .up: la = "up"; ra = "up"
        case .leftUp: la = "up"
        case .rightUp: ra = "up"
        case .raised: la = "raised"; ra = "raised"
        case .down: la = "down"; ra = "down"
        case .normal: break
        }
        let ax = l0 * 2 + 1
        for (dx, dy) in armPath(la) { g.px(ax + dx, y0 - 1 + dy, .body) }
        for (dx, dy) in armPath(ra) { g.px((W - 1) - (ax + dx), y0 - 1 + dy, .body) }

        // 触手（2 本。体より少し明るい色）
        let s = sway(p)
        let n = max(1, min(s.offsets.count, 6))
        for x in [12, 17] {
            let right = Double(x) > Double(W - 1) / 2
            for j in 0..<n { g.px(x + (right && s.sym ? -s.offsets[j] : s.offsets[j]), y0 + j, .tentacle) }
        }

        // 目（2×2 の点）とほっぺ
        let ey = (T + 2) * 2 + (crouch ? 0 : 1)
        let lx = 10, w = 2, h = 2
        let rx = (W - 1) - lx - (w - 1)
        switch p.eyes {
        case .open(let dx, let dy):
            for x in [lx, rx] { for i in 0..<w { for j in 0..<h { g.px(x + dx + i, ey + dy + j, .eye) } } }
        case .closed:
            for x in [lx, rx] { for i in 0..<w { g.px(x + i, ey + h - 1, .eye) } }
        case .happy:
            // ^ ^（3 サブピクセル幅。左右対称になるよう外側へ半マスずらす）
            for x in [lx - 1, rx] { g.px(x, ey + 1, .eye); g.px(x + 1, ey, .eye); g.px(x + 2, ey + 1, .eye) }
        case .cross:
            for x in [lx - 1, rx] {
                g.px(x, ey, .eye); g.px(x + 2, ey, .eye); g.px(x + 1, ey + 1, .eye); g.px(x, ey + 2, .eye); g.px(x + 2, ey + 2, .eye)
            }
        }
        if p.eyes != .cross { for x in [7, 8, 21, 22] { g.px(x, ey + 2, .cheek) } }

        // 頭上の表示（キャンバス上 3 マス）
        switch p.mark {
        case .none: break
        case .dots(let n): for i in 0..<min(n, 3) { g.cell(5 + i * 2, 1, .mark) }
        case .exclaim: for y in [0, 1, 2, 4, 5] { g.px(25, y, .warn); g.px(26, y, .warn) }
        case .check: for (x, y) in [(23, 3), (24, 4), (25, 5), (26, 4), (27, 3), (28, 2), (29, 1)] { g.px(x, y, .mark) }
        }
        return g
    }

    // MARK: - 画像

    private static var cache: [String: CGImage] = [:]

    static func image(_ pose: JellyPose, colors: SpriteColors, key: String) -> CGImage {
        let k = "\(key)|\(pose.hashValue)"
        if let img = cache[k] { return img }
        let img = draw(pose, colors: colors)
        if cache.count > 400 { cache.removeAll() }
        cache[k] = img
        return img
    }

    private static func draw(_ pose: JellyPose, colors: SpriteColors) -> CGImage {
        let W = pixelWidth, H = pixelHeight
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .none
        ctx.setShouldAntialias(false)
        let g = grid(pose)
        var shades: [Role: CGColor] = [:]
        for y in 0..<H {
            for x in 0..<W {
                guard let r = g[x, y] else { continue }
                let c = shades[r] ?? {
                    let v = colors.color(r, tone: pose.tone)
                    let cg = CGColor(srgbRed: CGFloat(v.x), green: CGFloat(v.y), blue: CGFloat(v.z), alpha: 1)
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
