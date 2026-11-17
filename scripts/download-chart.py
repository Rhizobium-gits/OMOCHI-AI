#!/usr/bin/env python3
"""README の「1 日ごとのダウンロード」のグラフ（SVG）を stats.json から作る。

    python3 scripts/download-chart.py stats.json <出力フォルダ>
    → downloads-ja.svg・downloads-en.svg・downloads-zh.svg

- scripts/download-stats.sh が数え直すたびに作り、stats ブランチに stats.json と一緒に置く（README はそこを読む）
- 黒と白だけの、1 日（UTC）に 1 本の白い棒。どの棒の上にもその日の数を書く（直近 30 日）
- 1 日の数 = .dmg（新しく入れた）＋ .zip（アプリからのアップデート）＋ git clone（その日に clone した人数）
  - git clone は GitHub が日ごとに数えた人数そのまま。GitHub は数日遅れて出すので、直近の日はあとで増える
  - .dmg・.zip は GitHub が累計しか出さないので推定：
    記録（stats.json の daily。その時刻の累計）の間に増えた分を、その間の時間に比例して日に分ける。
    記録を始める前の分は、版ごとの数（releases）を、その版が最新だった間（公開から次の版の公開まで。
    README の .dmg とアプリのアップデートは、いつも最新の版を取る）の時間に比例して日に分ける
- 右上：累計と、直近 7 日の新規（.dmg）・アップデート（.zip）。アプリは利用状況を送らないのでアクティブユーザー数は出せず、
  アップデートの数が「使い続けている人」のいちばん近い目安
- 標準ライブラリだけで書く（GitHub Actions でもそのまま動く）
"""
import datetime as dt
import json
import math
import os
import sys
from xml.sax.saxutils import escape

DAYS = 30
W, H = 820, 320
PAD = 32
X0, X1 = PAD, W - PAD          # 棒を並べる横の範囲
Y0, Y1 = 124, H - 82           # いちばん高い棒の上の数の位置〜基準線
UTC = dt.timezone.utc

BG = "#000000"
EDGE = "#1f1f1f"
WHITE = "#ffffff"
BAR = "#f2f2f2"
GRAY = "#8a8a8a"
DIM = "#555555"
LINE = "#2a2a2a"
FONT = ("-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Segoe UI', 'Hiragino Sans', 'Hiragino Kaku Gothic ProN', "
        "'Noto Sans CJK JP', 'Noto Sans JP', 'PingFang SC', 'Microsoft YaHei', sans-serif")

TEXTS = {
    "ja": {
        "title": "1 日ごとのダウンロード",
        "sub": ".dmg・.zip・git clone の合計 · 毎日自動で更新",
        "new": "新規（7 日）",
        "upd": "アップデート（7 日）",
        "total": "累計",
        "note1": "更新 {date} UTC · 新規 = .dmg、アップデート = .zip（アプリから上げた数。使い続けている人の目安）",
        "note2": "※ .dmg・.zip の日ごとの数は推定（GitHub は累計しか出さないので、時間に比例して分けた）",
        "pending": "直近の git clone は GitHub の集計待ち",
        "empty": "まだ日ごとの記録がありません",
    },
    "en": {
        "title": "Downloads per day",
        "sub": ".dmg + .zip + git clone · updated daily",
        "new": "New (7 days)",
        "upd": "Updates (7 days)",
        "total": "Total",
        "note1": "Updated {date} UTC · New = .dmg · Updates = .zip, updated from the app (the closest sign of active users)",
        "note2": "* Daily .dmg/.zip are estimates (GitHub gives only totals; split in proportion to time)",
        "pending": "recent clones not counted yet",
        "empty": "No daily records yet",
    },
    "zh": {
        "title": "每日下载量",
        "sub": ".dmg・.zip・git clone 合计 · 每天自动更新",
        "new": "新安装（7 天）",
        "upd": "更新（7 天）",
        "total": "累计",
        "note1": "更新于 {date} UTC · 新安装 = .dmg，更新 = .zip（从应用内更新的次数，最接近活跃用户的指标）",
        "note2": "※ .dmg・.zip 的每日数量为估算（GitHub 只提供累计，按时间比例分配）",
        "pending": "最近的 git clone 仍在等待 GitHub 统计",
        "empty": "还没有按日的记录",
    },
}


def ts(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


def spread(acc, amount, t0, t1):
    """amount を t0〜t1 の時間に比例して、UTC の日ごとに足す"""
    if amount <= 0:
        return
    if t1 <= t0:
        acc[t1.date()] = acc.get(t1.date(), 0.0) + amount
        return
    total = (t1 - t0).total_seconds()
    t = t0
    while t < t1:
        end = min(dt.datetime.combine(t.date() + dt.timedelta(days=1), dt.time(0), UTC), t1)
        acc[t.date()] = acc.get(t.date(), 0.0) + amount * (end - t).total_seconds() / total
        t = end


def rounded(acc):
    """日ごとの小数を整数に（合計は変えない。端数の大きい日から 1 ずつ足す）"""
    if not acc:
        return {}
    base = {d: math.floor(v + 1e-9) for d, v in acc.items()}
    rest = round(sum(acc.values())) - sum(base.values())
    for d in sorted(acc, key=lambda d: acc[d] - base[d], reverse=True)[:max(0, rest)]:
        base[d] += 1
    return base


def estimate(stats, kind):
    """kind（dmg / zip）の日ごとの推定：{日付: 数}"""
    acc = {}
    snaps = sorted((ts(v["at"]), v) for v in (stats.get("daily") or {}).values() if v.get("at"))
    rels = sorted((ts(r["published"]), r) for r in (stats.get("releases") or []) if r.get("published"))
    if not snaps:
        return {}
    t0, s0 = snaps[0]
    target = int(s0.get(kind, 0))
    before = [(p, r) for p, r in rels if p < t0]
    weight = sum(int(r.get(kind, 0)) for _, r in before)
    if target and weight:
        # 記録を始める前：版ごとの数を、その版が最新だった間に（記録を始めた時刻で切る）
        for i, (p, r) in enumerate(before):
            end = before[i + 1][0] if i + 1 < len(before) else t0
            spread(acc, target * int(r.get(kind, 0)) / weight, p, end)
    elif target:
        spread(acc, target, rels[0][0] if rels else t0, t0)
    # 記録の間に増えた分
    for (ta, a), (tb, b) in zip(snaps, snaps[1:]):
        spread(acc, max(0, int(b.get(kind, 0)) - int(a.get(kind, 0))), ta, tb)
    return rounded(acc)


def series(stats, today):
    """[(日付, その日の数)]、直近 7 日の新規・アップデート、clone がまだ出ていない日があるか"""
    clones = stats.get("clones") or {}
    dmg, zp = estimate(stats, "dmg"), estimate(stats, "zip")
    starts = [dt.date.fromisoformat(k) for k in clones] + list(dmg) + list(zp)
    if not starts:
        return [], 0, 0, False
    first = max(min(starts), today - dt.timedelta(days=DAYS - 1))
    last_clone = max(clones) if clones else ""
    days, pending = [], False
    d = first
    while d <= today:
        k = d.isoformat()
        days.append((d, dmg.get(d, 0) + zp.get(d, 0) + int((clones.get(k) or {}).get("uniques", 0))))
        if k > last_clone:
            pending = True
        d += dt.timedelta(days=1)
    week = [today - dt.timedelta(days=i) for i in range(7)]
    return days, sum(dmg.get(x, 0) for x in week), sum(zp.get(x, 0) for x in week), pending


def bar_path(x, y_top, w, h, r):
    """上の角だけ丸い棒（下＝基準線側は四角）"""
    r = max(0.0, min(r, w / 2, h))
    return (f'M{x:.1f},{y_top + h:.1f}V{y_top + r:.1f}Q{x:.1f},{y_top:.1f} {x + r:.1f},{y_top:.1f}'
            f'H{x + w - r:.1f}Q{x + w:.1f},{y_top:.1f} {x + w:.1f},{y_top + r:.1f}V{y_top + h:.1f}Z')


def md(d):
    return f"{d.month}/{d.day}"


def stat(a, x_end, label, value):
    a(f'<text x="{x_end}" y="34" font-size="11" fill="{GRAY}" text-anchor="end">{escape(label)}</text>')
    a(f'<text x="{x_end}" y="70" font-size="32" font-weight="700" fill="{WHITE}" text-anchor="end" letter-spacing="-1">{value:,}</text>')


def render(stats, lang, today):
    t = TEXTS[lang]
    days, new7, upd7, pending = series(stats, today)
    out = []
    a = out.append
    a(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" '
      f'aria-label="{escape(t["title"])}">')
    a(f'<title>{escape(t["title"])}</title>')
    a(f'<rect x="0.5" y="0.5" width="{W - 1}" height="{H - 1}" rx="18" fill="{BG}" stroke="{EDGE}"/>')
    a(f'<g font-family="{FONT}" style="font-variant-numeric: tabular-nums">')
    # 見出し（左）と数（右：新規・アップデート・累計）
    a(f'<text x="{PAD}" y="50" font-size="19" font-weight="600" fill="{WHITE}" letter-spacing="-0.2">{escape(t["title"])}</text>')
    a(f'<text x="{PAD}" y="74" font-size="12" fill="{GRAY}">{escape(t["sub"])}</text>')
    stat(a, W - PAD, t["total"], int(stats.get("total", 0)))
    stat(a, W - PAD - 150, t["upd"], upd7)
    stat(a, W - PAD - 300, t["new"], new7)

    if not days:
        a(f'<text x="{W / 2}" y="{(Y0 + Y1) / 2}" font-size="13" fill="{GRAY}" text-anchor="middle">{escape(t["empty"])}</text>')
    else:
        n = len(days)
        slot = (X1 - X0) / n
        bw = min(20.0, slot * 0.5)
        top = max(max(v for _, v in days), 1)
        sy = (Y1 - Y0 - 16) / top          # いちばん高い棒の上に数を書く余白を残す
        every = max(1, math.ceil(46 / slot))
        size = 11 if slot >= 22 else 9.5
        for i, (d, v) in enumerate(days):
            cx = X0 + slot * (i + 0.5)
            h = v * sy
            if v > 0:
                a(f'<path d="{bar_path(cx - bw / 2, Y1 - h, bw, h, 3)}" fill="{BAR}"/>')
            # どの日にも数を書く（0 の日は薄く）
            a(f'<text x="{cx:.1f}" y="{Y1 - h - 7:.1f}" font-size="{size}" font-weight="600" '
              f'fill="{WHITE if v else DIM}" text-anchor="middle">{v}</text>')
            if (n - 1 - i) % every == 0:
                a(f'<text x="{cx:.1f}" y="{Y1 + 20}" font-size="11" fill="{GRAY}" text-anchor="middle">{md(d)}</text>')
        a(f'<line x1="{X0}" y1="{Y1 + 0.5}" x2="{X1}" y2="{Y1 + 0.5}" stroke="{LINE}" stroke-width="1"/>')

    # 下の注記（薄く 2 行）
    updated = (stats.get("updated") or today.isoformat())[:10]
    line2 = t["note2"] + (" · " + t["pending"] if pending else "")
    a(f'<text x="{PAD}" y="{H - 40}" font-size="10.5" fill="{DIM}">{escape(t["note1"].format(date=updated))}</text>')
    a(f'<text x="{PAD}" y="{H - 22}" font-size="10.5" fill="{DIM}">{escape(line2)}</text>')
    a('</g></svg>')
    return "\n".join(out) + "\n"


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    stats = json.load(open(sys.argv[1]))
    today = dt.date.fromisoformat((stats.get("updated") or dt.datetime.now(UTC).isoformat())[:10])
    os.makedirs(sys.argv[2], exist_ok=True)
    for lang in TEXTS:
        with open(os.path.join(sys.argv[2], f"downloads-{lang}.svg"), "w") as f:
            f.write(render(stats, lang, today))


if __name__ == "__main__":
    main()
