import AppKit
import Foundation
import Testing
@testable import OmochiAI

// 近づけて離すと、つながる（2.0.3）。
// 2.0.0〜2.0.2 は、重なり・相手の頭の上に入った瞬間に「くっつく」「鏡餅」に切り替わっていたので、
// 縦に並んだおもちを少し寄せただけで鏡餅になり、つながらない・糸が体に隠れて見えない、になっていた。
// いまは、重なり・頭の上に少しとどめてから（armDelay）くっつく・載るになり、それまでに離せばその相手とつながる

@Suite struct DropDwellTests {
    let a = UUID(), b = UUID()

    /// 初期の並び（縦一列・互い違い）のとなりどうしは、つながる範囲の外（重なるくらいまで寄せたらつながる）
    @Test func defaultNeighborsAreOutOfReach() {
        #expect(MochiPlay.dropKind(dx: -39, dy: 80, width: 102) == nil)
        #expect(MochiPlay.dropKind(dx: -29, dy: 70, width: 102) == nil)
    }

    @Test func quickDropOnTheHeadLinks() {
        var p: MochiPlay.DropPending?
        let r = MochiPlay.decideDrop(special: (a, .stack), link: a, linkSpecial: true, pending: &p, now: 10, delay: 0.4)
        #expect(r.target == a && r.kind == .link && r.waiting == .stack && r.started)
        #expect(p == MochiPlay.DropPending(target: a, kind: .stack, since: 10))
    }

    @Test func stayingArmsTheSpecialDrop() {
        var p: MochiPlay.DropPending? = .init(target: a, kind: .merge, since: 10)
        let early = MochiPlay.decideDrop(special: (a, .merge), link: a, linkSpecial: true, pending: &p, now: 10.2, delay: 0.4)
        #expect(early.target == a && early.kind == .link && early.waiting == .merge && !early.started)
        let late = MochiPlay.decideDrop(special: (a, .merge), link: a, linkSpecial: true, pending: &p, now: 10.45, delay: 0.4)
        #expect(late.target == a && late.kind == .merge && late.waiting == nil)
    }

    @Test func changingTargetOrKindStartsOver() {
        var p: MochiPlay.DropPending? = .init(target: a, kind: .merge, since: 10)
        let other = MochiPlay.decideDrop(special: (b, .merge), link: b, linkSpecial: true, pending: &p, now: 11, delay: 0.4)
        #expect(other.kind == .link && other.started && p?.target == b && p?.since == 11)
        let kind = MochiPlay.decideDrop(special: (b, .stack), link: b, linkSpecial: true, pending: &p, now: 12, delay: 0.4)
        #expect(kind.kind == .link && kind.waiting == .stack && kind.started && p?.kind == .stack)
    }

    /// もうつながっている相手に重ねてすぐ離しても、近くの別のおもちとはつながらない
    @Test func alreadyLinkedWaitsWithoutLinkingSomeoneElse() {
        var p: MochiPlay.DropPending?
        let r = MochiPlay.decideDrop(special: (a, .merge), link: b, linkSpecial: false, pending: &p, now: 1, delay: 0.4)
        #expect(r.target == nil && r.kind == nil && r.waiting == .merge)
    }

    @Test func leavingTheZoneLinksTheNearest() {
        var p: MochiPlay.DropPending? = .init(target: a, kind: .stack, since: 1)
        let r = MochiPlay.decideDrop(special: nil, link: b, linkSpecial: false, pending: &p, now: 2, delay: 0.4)
        #expect(r.target == b && r.kind == .link && r.waiting == nil && p == nil)
        let none = MochiPlay.decideDrop(special: nil, link: nil, linkSpecial: false, pending: &p, now: 3, delay: 0.4)
        #expect(none.target == nil && none.kind == nil)
    }
}

// おもちと糸は、スペース（ほかのアプリのフル画面）を切り替えても・アプリを隠しても、いつも出ている（2.0.3）
@Suite(.serialized) struct AlwaysShownTests {
    @Test @MainActor func mochiStayWhenTheAppIsHidden() {
        #expect(JellyPanel(size: CGSize(width: 10, height: 10)).canHide == false)
    }

    @Test @MainActor func overlayReshowsLostWindowsWithTheirStrings() {
        guard let screen = NSScreen.screens.first else { return }
        let o = LinkOverlay()
        let f = screen.frame
        let l = JellyLink(UUID(), UUID())
        func windows() -> [String] { o.debugLines(onScreen: { _ in true }).filter { $0.hasPrefix("overlay window") } }
        o.update(segments: [(l, CGPoint(x: f.midX - 80, y: f.midY), CGPoint(x: f.midX + 80, y: f.midY))], labels: [], preview: nil)
        #expect(windows().count == NSScreen.screens.count)
        #expect(windows().allSatisfy { $0.contains("strings=1") && $0.contains("visible=true") })
        // 出ていれば何もしない
        #expect(o.reassert(onScreen: { _ in true }) == 0)
        // 画面から下りた（別のスペースに取り残された）窓は前に出し直し、糸もそのまま
        o.debugLose()
        #expect(o.reassert(onScreen: { _ in false }) == NSScreen.screens.count)
        #expect(windows().allSatisfy { $0.contains("strings=1") && $0.contains("visible=true") })
        // 出し直しても出ないまま（消灯中のディスプレイなど）の窓は、2 回目からは数えない（ログを出し続けない）
        #expect(o.reassert(onScreen: { _ in false }) == 0)
        // 描くものが無くなったら下ろし、出し直さない
        o.update(segments: [], labels: [], preview: nil)
        #expect(o.reassert(onScreen: { _ in false }) == 0)
        #expect(windows().allSatisfy { $0.contains("strings=0") && $0.contains("visible=false") })
    }
}
