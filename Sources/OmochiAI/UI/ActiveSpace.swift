import AppKit

/// 窓を、いま見ているスペース（デスクトップでも、ほかのアプリのフル画面でも）に出すための手順。
///
/// macOS 26 で確かめたこと（private な API は使っていない。下の 2 つはどちらも公開の API）：
/// - 窓がほかのアプリのフル画面のスペースに入れるかは、**窓を作ったときの**アプリの種類で決まる。
///   普通のアプリ（Dock に出る）のときに作った窓は、あとから何をしても普通のデスクトップに回される。
///   Dock に出ないアプリ（accessory）のときに作った窓は、あとで普通のアプリになっても入れる。
///   （collectionBehavior の fullScreenAuxiliary・canJoinAllApplications では入れなかった）
/// - アプリを先に前面にすると、窓が残っている別のスペースへ画面ごと切り替わる（「アプリケーションの切り替えで、
///   アプリケーションのウインドウが開いているスペースに移動」）。窓（moveToActiveSpace）を先に前に出して
///   今のスペースへ移してから前面にすれば、切り替わらない。
enum ActiveSpace {
    /// 窓を作る。普通のアプリのときは、作る一瞬だけ Dock に出ないアプリにする（ほかのアプリのフル画面にも出せる窓になる）
    static func make<W: NSWindow>(_ create: () -> W) -> W {
        guard NSApp.activationPolicy() == .regular else { return create() }
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(.regular) }
        return create()
    }

    /// 前面にする（activate）前に呼ぶ：窓を今のスペースへ出す（collectionBehavior に moveToActiveSpace のある窓）。
    /// アプリごと隠しているとき（⌘H）は何もしない（前面にすれば元の場所に戻る）
    static func bringHere(_ w: NSWindow) {
        guard !NSApp.isHidden else { return }
        w.orderFrontRegardless()
    }

    /// 確認の窓（NSAlert）を今のスペースに出してから前面にして、答えを待つ（a.runModal() の代わり）。
    /// 確認の窓は最初に前に出したときに作られるので、そのときだけ Dock に出ないアプリにする（make と同じ理由）。
    /// 見えないスペース（普通のデスクトップ）に出たまま答えを待つと、答えるまでおもちを押しても何も起きず、
    /// アプリの終了もできなくなっていた
    @discardableResult
    static func runModal(_ a: NSAlert) -> NSApplication.ModalResponse {
        a.layout()
        if !NSApp.isHidden && !a.window.isVisible {
            a.window.center()
            let regular = NSApp.activationPolicy() == .regular
            if regular { NSApp.setActivationPolicy(.accessory) }
            a.window.orderFrontRegardless()
            if regular { NSApp.setActivationPolicy(.regular) }
        }
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal()
    }
}
