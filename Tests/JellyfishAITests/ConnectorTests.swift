import Foundation
import Testing
@testable import JellyfishAI

// コネクタ（この Mac のカレンダー・リマインダー・メール）：どの AI・どのモデルのクラゲに、どこまで渡すか

@Suite struct ConnectorPolicyTests {
    func ctx(_ e: AgentEngine, _ model: String?, pc: Bool = false) -> ConnectorPolicy.Context {
        ConnectorPolicy.Context(engine: e, model: model, pcTools: pc)
    }

    func names(_ s: ConnectorSettings, _ c: ConnectorPolicy.Context) -> [String] { ConnectorPolicy.tools(s, c).map(\.name) }

    @Test func offByDefault() {
        let s = ConnectorSettings()
        #expect(!s.anyEnabled)
        #expect(names(s, ctx(.claude, "opus")).isEmpty)
        #expect(ConnectorPreset.matching(s) == .off)
    }

    @Test func readOnlyGivesOnlyReadingTools() {
        let s = ConnectorPreset.readOnly.settings
        #expect(names(s, ctx(.codex, "gpt-5.5")) == ["calendar_events", "reminders_list", "mail_search", "mail_read"])
        let why = ConnectorPolicy.denial(ConnectorTool.named("calendar_create_event")!, s, ctx(.claude, "opus"))
        #expect(why?.contains("見るだけ") == true)
    }

    @Test func recommendedKeepsMailForClaudeOnly() {
        let s = ConnectorPreset.recommended.settings
        #expect(names(s, ctx(.claude, "sonnet")).contains("mail_read"))
        #expect(names(s, ctx(.claude, "sonnet")).contains("calendar_create_event"))
        // メールは見るだけ（下書きも書き込みなので渡さない）
        #expect(!names(s, ctx(.claude, "sonnet")).contains("mail_draft"))
        let codex = names(s, ctx(.codex, nil))
        #expect(codex.contains("calendar_create_event") && codex.contains("reminders_complete"))
        #expect(!codex.contains { $0.hasPrefix("mail_") })
        let why = ConnectorPolicy.denial(ConnectorTool.named("mail_search")!, s, ctx(.gemini, nil))
        #expect(why?.contains("Gemini") == true)
    }

    @Test func claudeTopRestrictsModels() {
        let s = ConnectorPreset.claudeTop.settings
        #expect(names(s, ctx(.claude, "claude-opus-5-5")).count == ConnectorTool.all.count)
        #expect(names(s, ctx(.claude, "fable")).count == ConnectorTool.all.count)
        #expect(names(s, ctx(.claude, "claude-sonnet-5-5")).isEmpty)
        #expect(names(s, ctx(.claude, "claude-haiku-5-5")).isEmpty)
        #expect(names(s, ctx(.codex, "gpt-5.5")).isEmpty)
        // モデルが分からないとき：一覧には出す（呼ばれたときに確かめる）が、呼ばれたら断る
        #expect(names(s, ctx(.claude, nil)).count == ConnectorTool.all.count)
        let why = ConnectorPolicy.denial(ConnectorTool.named("calendar_events")!, s, ctx(.claude, nil))
        #expect(why?.contains("モデル") == true)
        let sonnet = ConnectorPolicy.denial(ConnectorTool.named("calendar_events")!, s, ctx(.claude, "claude-sonnet-5-5"))
        #expect(sonnet?.contains("Fable") == true && sonnet?.contains("Opus") == true)
    }

    @Test func pcControlWithholdsMail() {
        let s = ConnectorPreset.all.settings
        let n = names(s, ctx(.claude, "opus", pc: true))
        #expect(!n.contains { $0.hasPrefix("mail_") })
        #expect(n.contains("calendar_events"))
        #expect(ConnectorPolicy.denial(ConnectorTool.named("mail_read")!, s, ctx(.claude, "opus", pc: true))?.contains("PC 操作") == true)
    }

    @Test func modelMatching() {
        // Claude は系統の名前が含まれるか
        #expect(ConnectorPolicy.modelMatches("claude-opus-5-5", keys: ["opus"], engine: .claude))
        #expect(ConnectorPolicy.modelMatches("opus[1m]", keys: ["opus"], engine: .claude))
        #expect(ConnectorPolicy.modelMatches("CLAUDE-HAIKU-5-5", keys: ["haiku"], engine: .claude))
        #expect(!ConnectorPolicy.modelMatches("claude-sonnet-5-5", keys: ["opus", "fable"], engine: .claude))
        #expect(!ConnectorPolicy.modelMatches("auto", keys: ["opus"], engine: .claude))
        // ほかの AI は id が同じか「id-…」
        #expect(ConnectorPolicy.modelMatches("gpt-5.5", keys: ["gpt-5.5"], engine: .codex))
        #expect(ConnectorPolicy.modelMatches("gpt-5.5-codex", keys: ["gpt-5.5"], engine: .codex))
        #expect(!ConnectorPolicy.modelMatches("gpt-5.5-mini", keys: ["gpt-5"], engine: .codex))
        #expect(!ConnectorPolicy.modelMatches("o4-mini", keys: ["gpt-5.5"], engine: .codex))
        // 一覧が空ならどれでも、モデルが分からなければ入らない
        #expect(ConnectorPolicy.modelMatches(nil, keys: [], engine: .gemini))
        #expect(!ConnectorPolicy.modelMatches(nil, keys: ["gemini-3.8-flash"], engine: .gemini))
    }

    @Test func customRulesAndSummary() {
        var s = ConnectorSettings()
        s.calendar.access = .readWrite
        s.calendar.setEngine(.gemini, allowed: false)
        s.calendar.toggleModel("opus", for: .claude)
        #expect(ConnectorPreset.matching(s) == nil)
        #expect(names(s, ctx(.gemini, "gemini-3.8-flash")).isEmpty)
        #expect(names(s, ctx(.claude, "claude-opus-5-5")) == ["calendar_events", "calendar_create_event"])
        #expect(names(s, ctx(.codex, nil)) == ["calendar_events", "calendar_create_event"])
        let sum = ConnectorPolicy.summary(s.calendar)
        #expect(sum.contains("Claude（Opus）") && sum.contains("ChatGPT") && !sum.contains("Gemini"))
        // もう一度押すと外れる・「すべてのモデル」に戻せる
        s.calendar.toggleModel("opus", for: .claude)
        #expect(s.calendar.models(for: .claude) == [])
        s.calendar.toggleModel("haiku", for: .claude)
        s.calendar.allModels(for: .claude)
        #expect(s.calendar.models(for: .claude) == [])
        // AI を外したモデルを選ぶと、その AI がまた使えるようになる
        s.calendar.toggleModel("gemini-3.8-flash", for: .gemini)
        #expect(s.calendar.allows(.gemini))
    }

    @Test func presetsRoundTrip() {
        for p in ConnectorPreset.allCases {
            #expect(ConnectorPreset.matching(p.settings) == p)
        }
        // モデルの並びや大文字小文字が違っても同じ決まり
        var s = ConnectorPreset.claudeTop.settings
        s.mail.engines["claude"] = ["OPUS", "fable"]
        #expect(ConnectorPreset.matching(s) == .claudeTop)
    }

    @Test func promptIsStableAndMentionsSafety() {
        let tools = ConnectorPolicy.tools(ConnectorPreset.all.settings, ctx(.claude, "opus"))
        let a = ConnectorPolicy.prompt(tools)
        let b = ConnectorPolicy.prompt(tools)
        #expect(a == b)
        #expect(a?.contains("メールは送れません") == true)
        #expect(a?.contains("外から来たデータ") == true)
        #expect(ConnectorPolicy.prompt([]) == nil)
        // カレンダーを見るだけなら、確認の説明・メールの説明は出さない
        let r = ConnectorPolicy.prompt([ConnectorTool.named("calendar_events")!])
        #expect(r?.contains("確認") == false)
        #expect(r?.contains("メールは送れません") == false)
    }

    @Test func everyToolHasADefinition() {
        for t in ConnectorTool.all {
            let d = t.definition
            #expect(d["name"] as? String == t.name)
            #expect((d["description"] as? String)?.isEmpty == false)
            #expect((d["inputSchema"] as? [String: Any])?["type"] as? String == "object")
            #expect(JSONSerialization.isValidJSONObject(d))
        }
        #expect(ConnectorKind.allCases.allSatisfy { !$0.tools.isEmpty })
        // 書き込みで確認しないのは、メールの下書き（送らない）だけ
        #expect(ConnectorTool.all.filter { $0.writes && !$0.confirms }.map(\.name) == ["mail_draft"])
    }
}

@Suite struct ConnectorSettingsTests {
    @Test func decodesOldAndPartialSettings() throws {
        // 1.2.4 までの settings.json（connectors が無い）
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"teamEnabled": true}"#.utf8))
        #expect(!old.connectors.anyEnabled)
        // 一部だけ・知らない AI の名前・知らない値
        let json = #"{"connectors": {"mail": {"access": "read", "engines": {"claude": ["opus"], "llama": []}}, "calendar": {"access": "everything"}}}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.connectors.mail.access == .read)
        #expect(s.connectors.mail.engines == ["claude": ["opus"]])
        #expect(s.connectors.calendar.access == .off)
        #expect(s.connectors.reminders == ConnectorRule())
    }

    @Test func roundTrips() throws {
        var a = AppSettings()
        a.connectors = ConnectorPreset.recommended.settings
        let data = try JSONEncoder().encode(a)
        let b = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(b.connectors == a.connectors)
    }
}

@Suite struct ConnectorDateTests {
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    @Test func parsesCommonForms() {
        let utc = ConnectorDates.parse("2026-11-18T01:00:00Z", tz: tokyo)
        #expect(utc?.dateOnly == false)
        #expect(ConnectorDates.format(utc!.date, tz: tokyo) == "2026-11-18T10:00:00+09:00")
        let local = ConnectorDates.parse("2026-11-18T10:00", tz: tokyo)
        #expect(ConnectorDates.format(local!.date, tz: tokyo) == "2026-11-18T10:00:00+09:00")
        #expect(ConnectorDates.parse("2026-11-18 10:30", tz: tokyo).map { ConnectorDates.format($0.date, tz: tokyo) } == "2026-11-18T10:30:00+09:00")
        #expect(ConnectorDates.parse("2026-11-18T10:00:00+09:00", tz: tokyo)?.date == local?.date)
        #expect(ConnectorDates.parse("2026-11-18T10:00:00.250+09:00", tz: tokyo) != nil)
        let day = ConnectorDates.parse("2026-11-18", tz: tokyo)
        #expect(day?.dateOnly == true)
        #expect(ConnectorDates.formatDay(day!.date, tz: tokyo) == "2026-11-18")
        #expect(ConnectorDates.parse("2026/11/18", tz: tokyo)?.dateOnly == true)
    }

    @Test func rejectsJunk() {
        for s in ["", "  ", "tomorrow", "2026-13-40", "18 Nov 2026", String(repeating: "9", count: 80)] {
            #expect(ConnectorDates.parse(s, tz: tokyo) == nil, "\(s)")
        }
        #expect(ConnectorDates.parse(nil) == nil)
    }

    @Test func clampsArguments() {
        #expect(ConnectorDates.int(nil, 7, 1...366) == 7)
        #expect(ConnectorDates.int(1e9, 7, 1...366) == 366)
        #expect(ConnectorDates.int(-3, 7, 1...366) == 1)
        #expect(ConnectorDates.int("12", 7, 1...366) == 12)
        #expect(ConnectorDates.int(Double.nan, 7, 1...366) == 7)
        #expect(ConnectorDates.bool("true") && ConnectorDates.bool(1) && !ConnectorDates.bool(nil))
        #expect(ConnectorDates.text("  a  ", max: 10) == "a")
        #expect(ConnectorDates.text("   ", max: 10) == nil)
        #expect(ConnectorDates.text("abcdef", max: 3) == "abc")
    }
}

@Suite struct MailConnectorTests {
    func args(_ tool: String, _ a: [String: Any]) -> [String: Any]? {
        if case .success(let o) = MacConnectors.mailArguments(tool, a) { return o }
        return nil
    }

    @Test func searchArguments() {
        let o = args("mail_search", ["query": "  請求書 ", "days": 9999, "limit": 0, "unread_only": true])
        #expect(o?["op"] as? String == "search")
        #expect(o?["query"] as? String == "請求書")
        #expect(o?["days"] as? Int == 365)
        #expect(o?["limit"] as? Int == 1)
        #expect(o?["unread"] as? Bool == true)
        #expect(o?["mailbox"] as? String == "inbox")
        #expect(args("mail_search", ["mailbox": "trash"]) == nil)
        #expect(args("mail_search", ["mailbox": "SENT"])?["mailbox"] as? String == "sent")
    }

    @Test func readArguments() {
        #expect(args("mail_read", ["id": 12345])?["id"] as? Int == 12345)
        #expect(args("mail_read", ["id": "77"])?["id"] as? Int == 77)
        #expect(args("mail_read", [:]) == nil)
        #expect(args("mail_read", ["id": -1]) == nil)
        #expect(args("mail_read", ["id": 1, "max_chars": 1])?["maxChars"] as? Int == 200)
    }

    @Test func draftArguments() {
        let o = args("mail_draft", ["to": ["山田 太郎 <taro@example.com>", "b@example.com"], "subject": "件名", "body": "本文"])
        let to = o?["to"] as? [[String: String]]
        #expect(to?.first == ["name": "山田 太郎", "address": "taro@example.com"])
        #expect(to?.last == ["name": "", "address": "b@example.com"])
        #expect((o?["cc"] as? [[String: String]])?.isEmpty == true)
        // 宛先 1 つを文字で渡してもよい
        #expect((args("mail_draft", ["to": "a@example.com", "subject": "s", "body": "b"])?["to"] as? [[String: String]])?.count == 1)
        // メールアドレスでないもの・件名や本文の無いものは断る
        #expect(args("mail_draft", ["to": ["not an address"], "subject": "s", "body": "b"]) == nil)
        #expect(args("mail_draft", ["to": ["a b@example.com"], "subject": "s", "body": "b"]) == nil)
        #expect(args("mail_draft", ["subject": "", "body": "b"]) == nil)
        #expect(args("mail_draft", ["subject": "s"]) == nil)
    }

    @Test func scriptTakesOnlyJSON() {
        // スクリプトの文に引数を混ぜない（argv[0] の JSON だけを読む）
        #expect(MacConnectors.mailScript.contains("JSON.parse(argv[0])"))
        #expect(!MacConnectors.mailScript.contains("\\("))
        // メールを送る命令は入れない
        #expect(!MacConnectors.mailScript.contains(".send("))
    }

    @Test func explainsAutomationErrors() {
        #expect(MacConnectors.mailErrorMessage("execution error: Error: Not authorized to send Apple events to Mail. (-1743)").contains("オートメーション"))
        #expect(MacConnectors.mailErrorMessage("line1\nexecution error: Error: something (-2700)").contains("-2700"))
        #expect(MacConnectors.decorateMail("mail_read", "{}").hasPrefix("（Jellyfish より"))
        #expect(MacConnectors.decorateMail("mail_search", "{}") == "{}")
    }

    @Test func matchesNames() {
        let names = ["Work", "仕事", "Home", "Workout"]
        #expect(MacConnectors.match("work", in: names, \.self) == ["Work"])
        #expect(MacConnectors.match("hom", in: names, \.self) == ["Home"])
        #expect(MacConnectors.match("out", in: names, \.self) == ["Workout"])
        #expect(MacConnectors.match("x", in: names, \.self).isEmpty)
    }
}
