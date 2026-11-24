#!/usr/bin/env python3
"""開発用の「使い方の記録」（dev-journal/*.jsonl）をまとめて、改善の手がかりを Markdown で出す。

  python3 scripts/dev/journal-report.py [記録のフォルダ] [> report.md]

記録のフォルダの既定は ~/Library/Application Support/OmochiAI/dev-journal。
記録はこの Mac の開発用ビルド（scripts/build.sh --dev-journal・.dev-journal）だけが書き、指示の本文は入っていない。
"""
import collections
import json
import os
import statistics
import sys
from datetime import datetime

DIR = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Library/Application Support/OmochiAI/dev-journal")


def load():
    rows = []
    for name in sorted(os.listdir(DIR)):
        if not name.endswith(".jsonl"):
            continue
        with open(os.path.join(DIR, name), encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    r = json.loads(line)
                    r["_t"] = datetime.fromisoformat(r["t"].replace("Z", "+00:00"))
                    rows.append(r)
                except (ValueError, KeyError):
                    pass
    rows.sort(key=lambda r: r["_t"])
    return rows


def med(xs):
    xs = [x for x in xs if isinstance(x, (int, float))]
    return statistics.median(xs) if xs else 0


def table(head, rows):
    out = ["| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
    for r in rows:
        out.append("| " + " | ".join(str(x) for x in r) + " |")
    return "\n".join(out)


def top(counter, n=15):
    return counter.most_common(n)


def main():
    if not os.path.isdir(DIR):
        sys.exit(f"記録のフォルダがありません: {DIR}")
    rows = load()
    if not rows:
        sys.exit("記録がまだありません")
    ev = collections.defaultdict(list)
    for r in rows:
        ev[r["ev"]].append(r)
    c = lambda name: len(ev.get(name, []))
    days = sorted({r["_t"].astimezone().date() for r in rows})
    runs = {r.get("run") for r in rows}
    out = []
    P = out.append

    P(f"# OMOCHI AI 使い方の記録のまとめ\n")
    P(f"- 期間: {days[0]} 〜 {days[-1]}（記録のあった日 {len(days)} 日）")
    P(f"- 記録 {len(rows)} 件・起動 {len(runs)} 回（launch {c('launch')} 回・quit {c('quit')} 回）")
    per_day = collections.Counter(r["_t"].astimezone().date() for r in rows)
    hours = collections.Counter(r["_t"].astimezone().hour for r in ev.get("submit", []))
    P("- 日ごとの記録: " + "、".join(f"{d.strftime('%m/%d')} {per_day[d]}" for d in days))
    if hours:
        P("- 指示を送った時間帯（多い順）: " + "、".join(f"{h} 時 {n}" for h, n in top(hours, 6)))
    P("")

    # おもち
    P("## おもち\n")
    via = collections.Counter(r.get("via") for r in ev.get("spawn-source", []))
    P(table(["項目", "回数"], [
        ["新しいおもち（spawn）", c("spawn")],
        ["  ⌘L から", via.get("hotkey", 0)],
        ["  アプリを開き直して", via.get("reopen", 0)],
        ["仲間として作られた（spawn-teammate）", c("spawn-teammate")],
        ["消した（remove）", c("remove")],
        ["  作業中に消した", sum(1 for r in ev.get("remove", []) if r.get("running"))],
        ["  一度も指示しないまま消した", sum(1 for r in ev.get("remove", []) if r.get("turns") == 0)],
        ["タップ", c("tap")],
        ["チャットを開いた", c("chat-open")],
    ]))
    totals = [r.get("total", 0) for r in ev.get("spawn", [])] + [r.get("mochi", 0) for r in ev.get("launch", [])]
    if totals:
        P(f"\n- 同時にいたおもちの数: 最大 {max(totals)}・中央値 {med(totals)}")
    secs = [r.get("secs", 0) for r in ev.get("chat-close", [])]
    if secs:
        P(f"- チャットを開いていた時間: 中央値 {med(secs):.0f} 秒・最長 {max(secs)} 秒（{len(secs)} 回）")
    P("")

    # 指示
    sub = ev.get("submit", [])
    P("## 指示\n")
    if sub:
        kinds = collections.Counter(r.get("kind") for r in sub)
        engines = collections.Counter(r.get("engine") for r in sub)
        models = collections.Counter(r.get("model") for r in sub)
        tags = collections.Counter(t for r in sub if r.get("kind") == "user" for t in r.get("tags", []))
        P(f"- 送った指示 {len(sub)} 件（" + "、".join(f"{k} {n}" for k, n in kinds.most_common()) + "）")
        P("- AI: " + "、".join(f"{k} {n}" for k, n in engines.most_common()) + " ／ モデル: " + "、".join(f"{k} {n}" for k, n in models.most_common(6)))
        user = [r for r in sub if r.get("kind") == "user"]
        if user:
            P(f"- 本人の指示の長さ: 中央値 {med([r.get('chars', 0) for r in user]):.0f} 字・複数行 {sum(1 for r in user if r.get('lines', 1) > 1)} 件")
            P(f"- 添付つき {sum(1 for r in user if r.get('attach'))}・画面つき {sum(1 for r in user if r.get('screen'))}・前の結果を渡した {sum(1 for r in sub if r.get('passed'))}・続き（resume）{sum(1 for r in user if r.get('resume'))}・モデル自動 {sum(1 for r in user if r.get('auto'))}")
        if tags:
            P("- 依頼の種類（タグ）: " + "、".join(f"{k} {n}" for k, n in top(tags, 10)))
        cs = ev.get("chat-submit", [])
        if cs:
            P(f"- チャットから: {len(cs)} 件（作業中に予約 {sum(1 for r in cs if r.get('queued'))}・串に流す {sum(1 for r in cs if r.get('skewer'))}・最初の指示 {sum(1 for r in cs if r.get('firstTurn'))}）・↑↓ の履歴 {c('history')} 回")
    else:
        P("- 指示はまだありません")
    P("")

    # ターン
    turns = ev.get("turn", [])
    P("## 作業の結果\n")
    if turns:
        st = collections.Counter(r.get("state") for r in turns)
        P("- " + "、".join(f"{k} {n}" for k, n in st.most_common()) + f"（キャンセル操作 {c('cancel')}・動かせなかった {c('refused')}）")
        by = collections.defaultdict(list)
        for r in turns:
            by[(r.get("engine"), r.get("model"))].append(r)
        rows_ = []
        for (e, m), rs in sorted(by.items(), key=lambda kv: -len(kv[1])):
            ok = sum(1 for r in rs if r.get("state") == "completed")
            rows_.append([e, m, len(rs), f"{ok / len(rs) * 100:.0f}%", f"{med([r.get('secs', 0) for r in rs]):.0f}s",
                          f"${sum(r.get('cost', 0) or 0 for r in rs):.2f}", f"{med([r.get('tools', 0) for r in rs]):.0f}"])
        P(table(["AI", "モデル", "回数", "完了", "時間（中央値）", "費用", "ツール（中央値）"], rows_))
        errs = collections.Counter(r.get("error") for r in turns if r.get("state") == "error")
        refused = collections.Counter(r.get("why") for r in ev.get("refused", []))
        if errs:
            P("\n- エラーの種類: " + "、".join(f"{k} {n}" for k, n in errs.most_common()))
        if refused:
            P("- 動かせなかった理由: " + "、".join(f"{k} {n}" for k, n in refused.most_common()))
        tools = collections.Counter(t for r in turns for t in r.get("toolKinds", []))
        if tools:
            P("- よく使われたツール: " + "、".join(f"{k} {n}" for k, n in top(tools, 12)))
        ctx = [r.get("context", 0) for r in turns if r.get("context")]
        if ctx:
            P(f"- 会話の大きさ: 中央値 {med(ctx) / 1000:.0f}k・最大 {max(ctx) / 1000:.0f}k トークン")
    else:
        P("- まだありません")
    P("")

    # お餅の性質
    P("## お餅の性質（2.0）\n")
    tear_b = collections.Counter(r.get("via") for r in ev.get("tear-begin", []))
    tear_e = ev.get("tear-end", [])
    clones_used = sum(1 for r in sub if r.get("forked") or r.get("fork"))
    merge_ch = collections.Counter("まとめる" if r.get("combine") else "片方を残す" for r in ev.get("merge", []))
    drops = collections.Counter(r.get("kind") for r in ev.get("drop", []))
    maki = ev.get("maki", [])
    picks = ev.get("maki-pick", [])
    P(table(["機能", "使った回数", "内訳"], [
        ["✂️ ちぎる", sum(tear_b.values()), f"ドラッグ {tear_b.get('drag', 0)}・メニュー {tear_b.get('menu', 0)}・ちぎれた {sum(1 for r in tear_e if r.get('torn'))}/{len(tear_e)}（ドラッグ）・分身への最初の指示 {clones_used}・作業中で断った {c('tear-refused')}"],
        ["🍡 くっつく", c("merge"), f"選択肢を出した {c('merge-offer')}・" + "・".join(f"{k} {n}" for k, n in merge_ch.items()) + f"・やめた {c('merge-cancel')}"],
        ["🍊 鏡餅", c("stack"), f"くずした {c('unstack')}"],
        ["🍡 串だんご", c("skewer"), f"流した {c('skewer-run')}・レシピで流した {c('recipe-run')}・レシピ保存 {c('recipe-save')}・画面を開いた {c('dango-window')}"],
        ["🎊 餅まき", len(maki), f"画面を開いた {c('maki-window')}・拾った {len(picks)}" + (f"・拾ったのは最初に終わった答え {sum(1 for r in picks if r.get('finishRank') == 1)}/{len(picks)}" if picks else "")],
        ["🫘 大福", c("anko-add"), f"外した {c('anko-remove')}"],
        ["♨️ 温め直す", c("warm"), ""],
        ["🧽 焦げを落とす", c("compact"), ""],
        ["🔗 つなぐ", c("link"), f"切った {c('unlink')}"],
    ]))
    if drops:
        P("\n- ドラッグして置いた結果: " + "、".join(f"{k} {n}" for k, n in drops.most_common()))
        far = [r.get("distance", 0) for r in ev.get("drop", []) if r.get("kind") == "none"]
        if far:
            P(f"  - 何も起きなかったドロップの移動距離（体の幅で）: 中央値 {med(far):.1f}")
    if maki:
        me = collections.Counter(e for r in maki for e in r.get("engines", []))
        pe = collections.Counter(r.get("engine") for r in picks)
        P("- 餅まきでまいた AI: " + "、".join(f"{k} {n}" for k, n in me.most_common()) + (" ／ 拾われた AI: " + "、".join(f"{k} {n}" for k, n in pe.most_common()) if pe else ""))
    hints = collections.Counter(r.get("text") for r in ev.get("hint", []))
    if hints:
        P("- 断った・止めた案内（つまずき）: " + "、".join(f"「{k}」{n}" for k, n in hints.most_common(8)))
    P("")

    # 予約・チーム
    P("## 予約・チーム\n")
    P(table(["項目", "回数"], [
        ["予約に足した", c("queue-add")], ["  ほかのおもちへ", sum(1 for r in ev.get("queue-add", []) if r.get("other"))],
        ["予約を書き換えた・送り先を変えた", c("queue-edit")], ["並べ替え", c("queue-move")], ["消した", c("queue-remove")],
        ["一時停止 / 再開 / 止めて次へ", f"{c('queue-pause')} / {c('queue-resume')} / {c('queue-skip')}"],
        ["予約が送れなかった", c("queue-refused")],
        ["仲間への依頼（team-task）", c("team-task")], ["自律組織の form_team", c("form-team")], ["👍👎", c("org-react")],
    ]))
    ft = collections.Counter(r.get("formation") for r in ev.get("form-team", []))
    if ft:
        P("\n- 組んだ組織: " + "、".join(f"{k} {n}" for k, n in ft.most_common()))
    P("")

    # 画面の操作
    P("## 画面の操作\n")
    menu = collections.Counter(r.get("item") for r in ev.get("menu", []))
    buttons = collections.Counter(r.get("button") for r in ev.get("chat-button", []))
    P(f"- メニューバーのメニューを開いた {c('menubar-open')} 回")
    if menu:
        P("- よく選んだメニュー項目:\n")
        P(table(["項目", "回数"], [[k.replace("|", "／"), n] for k, n in top(menu, 20)]))
    if buttons:
        P("\n- チャットのボタン: " + "、".join(f"{k} {n}" for k, n in buttons.most_common()))
    P("")

    # 気づき
    P("## 気づき（自動の目安）\n")
    notes = []
    for name, n in [("ちぎる", sum(tear_b.values())), ("くっつく", c("merge")), ("鏡餅", c("stack")), ("串だんご", c("skewer")),
                    ("餅まき", len(maki)), ("大福", c("anko-add")), ("温め直す", c("warm")), ("焦げを落とす", c("compact"))]:
        if n == 0:
            notes.append(f"「{name}」は一度も使われていない（見つけにくい・要らない・使う場面が無い のどれかを確かめる）")
    if tear_e and sum(1 for r in tear_e if not r.get("torn")) / len(tear_e) > 0.4:
        notes.append("⌘ ドラッグでちぎれなかった割合が高い（ちぎれる距離が遠すぎるかも）")
    if c("merge-offer") and c("merge-cancel") / max(1, c("merge-offer")) > 0.4:
        notes.append("くっつくの選択肢を出してやめた割合が高い（重ねたつもりがない・選択肢が分かりにくい）")
    if turns:
        err = sum(1 for r in turns if r.get("state") == "error") / len(turns)
        if err > 0.15:
            notes.append(f"エラーで終わる作業が {err * 100:.0f}% ある（上の種類を確かめる）")
    rm0 = sum(1 for r in ev.get("remove", []) if r.get("turns") == 0)
    if c("remove") and rm0 / c("remove") > 0.3:
        notes.append("一度も指示しないまま消したおもちが多い（⌘L の押しまちがい・出しすぎ）")
    if hints:
        notes.append("つまずきの案内が出ている（上の「断った・止めた案内」）")
    P("\n".join(f"- {n}" for n in notes) if notes else "- 目立つものはありません")
    print("\n".join(out))


if __name__ == "__main__":
    main()
