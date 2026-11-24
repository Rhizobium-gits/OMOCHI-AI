import AppKit

/// おもち（エージェント）の見た目。ウィンドウや操作は JellyController が持ち、
/// 描画とアニメーションだけをこのプロトコルの実装が受け持つ。
protocol Avatar: AnyObject {
    /// ウィンドウいっぱいに置かれる描画ビュー（マウスイベントは受けない）
    var view: NSView { get }
    var size: CGSize { get }
    var state: AgentState { get }
    /// アニメーション中か（静止していれば false）
    var isAnimating: Bool { get }

    func setState(_ s: AgentState)
    /// クリック・ドラッグを受け付ける領域か（ウィンドウローカル pt）
    func hitTest(_ p: CGPoint) -> Bool
    func pointerMoved(inside: Bool, local: CGPoint)
    func poke()
    func spawn()
    func despawn(_ done: @escaping () -> Void)
    func dragBegan()
    func dragEnded()
    /// 表示・非表示。非表示中はタイマーも止める（エージェント本体の処理には影響しない）
    func setActive(_ active: Bool)
    func setFrameRates(max: Int, calm: Int)
    /// 長押し中の手応え（縮んで震える）。duration で消える
    func pressBegan(duration: Double)
    func pressCancelled()
    func teardown()
    /// 体の中心（ウィンドウローカル pt、左下原点）。つながりの線はここから引く
    var anchor: CGPoint { get }
    /// 名前ラベルを置く高さ（ウィンドウローカル pt）
    var labelY: CGFloat { get }
}

extension Avatar {
    func pressBegan(duration: Double) {}
    func pressCancelled() {}
    var anchor: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }
    var labelY: CGFloat { size.height * 0.12 }
}

enum AvatarStyle: String, Codable, CaseIterable {
    case pixel
    /// リアルなおもち（1.3 までは Metal で描いたリアルなクラゲだった。設定に残る値はそのまま）
    case realistic

    var label: String {
        switch self {
        case .pixel: return L("ドット絵（おもち）")
        case .realistic: return L("リアルなおもち")
        }
    }
}

/// 見た目ごとのサイズ・並べ方
struct AvatarLayout {
    var size: CGSize
    /// 縦・横の間隔、互い違いのずらし量、画面右端へのはみ出し量（pt）
    var stepY: CGFloat
    var stepX: CGFloat
    var stagger: CGFloat
    var edgeOverhang: CGFloat
}

enum AvatarFactory {
    /// どちらの見た目も同じ大きさ・並べ方（リアルなおもちはドット絵と同じキャンバスに描く）
    static func layout(_ style: AvatarStyle, scale: Double) -> AvatarLayout {
        let s = MochiAvatar.windowSize(scale: scale)
        let P = CGFloat(MochiAvatar.cell(scale: scale))
        return AvatarLayout(size: s, stepY: s.height * 0.92, stepX: s.width * 0.95,
                            stagger: -s.width * 0.38, edgeOverhang: P * 0.4)
    }

    static func make(_ style: AvatarStyle, record: JellyRecord, scale: Double, maxFPS: Int, calmFPS: Int) -> Avatar {
        MochiAvatar(record: record, scale: scale, art: style == .realistic ? .real : .pixel)
    }
}
