import Foundation
import Testing
@testable import OmochiAI

// 開発用の「使い方の記録」：書き方（本文を残さない）と、普段のビルドには入らないこと

@Suite struct DevJournalTests {
    @Test func normalBuildsDoNotRecord() {
        // テスト・CI・配る版は -DOMOCHI_DEV_JOURNAL なしでビルドする（記録の部分が入らない）
        #expect(DevJournal.compiledIn == false)
        DevJournal.log("test", ["x": 1])   // 何もしない（落ちない）
    }

    @Test func lineIsSortedJSONWithOnlySimpleValues() throws {
        let d = Date(timeIntervalSince1970: 1_800_000_000)
        let l = try #require(DevJournal.line("submit", ["chars": 12, "ok": true, "ratio": 0.12345, "tags": ["code", "research"],
                                                         "long": String(repeating: "あ", count: 300), "obj": Date(), "ev": "x"], at: d, session: "abcd"))
        let o = try #require(try JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any])
        #expect(o["ev"] as? String == "submit")
        #expect(o["run"] as? String == "abcd")
        #expect(o["chars"] as? Int == 12 && o["ok"] as? Bool == true)
        #expect(o["ratio"] as? Double == 0.123)
        #expect((o["long"] as? String)?.count == 121)
        #expect(o["obj"] == nil)                       // 文字列・数・真偽・文字列の配列だけ
        #expect((o["t"] as? String)?.hasPrefix("2027-01-15T") == true)
        #expect(!l.contains("\n"))
    }

    @Test func promptSummaryKeepsNoText() {
        let p = "秘密のプロジェクト X のバグを直して\n詳しく" + AgentChatController.attachMarker + "\n- /Users/me/secret.png"
        let s = DevJournal.promptSummary(p)
        #expect(s["kind"] as? String == "user")
        #expect(s["chars"] as? Int == "秘密のプロジェクト X のバグを直して\n詳しく".count)
        #expect(s["lines"] as? Int == 2)
        #expect(s["attach"] as? Bool == true)
        let all = s.values.map { "\($0)" }.joined(separator: " ")
        #expect(!all.contains("秘密") && !all.contains("secret"))
        #expect(DevJournal.promptSummary(MochiPlay.warmPrompt(minutesSince: 70))["kind"] as? String == "warm")
        #expect(DevJournal.promptSummary("/compact")["kind"] as? String == "compact")
        #expect(DevJournal.promptSummary(TeamCoordinator.requestMarker + "A]\nx")["kind"] as? String == "team")
    }

    @Test func errorKinds() {
        #expect(DevJournal.errorKind(nil) == "none")
        #expect(DevJournal.errorKind("Claude にログインしていません") == "login")
        #expect(DevJournal.errorKind("Error: rate limit exceeded") == "limit")
        #expect(DevJournal.errorKind("アプリの終了により中断されました") == "interrupted")
        #expect(DevJournal.errorKind("something odd") == "other")
    }

    @Test func periodStopsAfterItsDays() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var p = DevJournal.Period(started: start)
        #expect(p.days == 7)
        #expect(p.recording(at: start.addingTimeInterval(6.9 * 86400)))
        #expect(!p.recording(at: start.addingTimeInterval(7.1 * 86400)))
        #expect(p.day(at: start.addingTimeInterval(2.5 * 86400)) == 3)
        p.paused = true
        #expect(!p.recording(at: start.addingTimeInterval(3600)))
        #expect(DevJournal.fileName(for: start).hasSuffix(".jsonl"))
    }
}
