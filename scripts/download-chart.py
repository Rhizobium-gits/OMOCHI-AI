#!/usr/bin/env python3
"""README の「1 日ごとのダウンロード」のグラフ（SVG）を stats.json から作る。

    python3 scripts/download-chart.py stats.json <出力フォルダ>
    → downloads-ja.svg・downloads-en.svg・downloads-zh.svg

- scripts/download-stats.sh が数え直すたびに作り、stats ブランチに stats.json と一緒に置く（README はそこを読む）
- 黒と白だけの、1 日（UTC）に 1 本の白い棒。どの棒の上にもその日の数を書く（直近 30 日）
- 1 日の数 = .dmg（新しく入れた）＋ .zip（アップデート）＋ git clone（その日に clone した人数）。
  .dmg・.zip は GitHub が累計しか出さないので、毎日の累計（stats.json の daily）の差を、その日の数にする。
  記録を始める前の .dmg・.zip は日ごとに分けられないので棒に入れず、下に一言書く（右上の累計には入る）。
  GitHub は clone 数を数日遅れて出すので、直近の日はあとで増えることも下に書く
- 標準ライブラリだけで書く（GitHub Actions でもそのまま動く）
"""
import datetime as dt
import json
import math
import os
import sys
from xml.sax.saxutils import escape

DAYS = 30
W, H = 820, 300
PAD = 32
X0, X1 = PAD, W - PAD          # 棒を並べる横の範囲
Y0, Y1 = 120, H - 64           # いちばん高い棒の上の数の位置〜基準線

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
        "total": "累計",
        "updated": "更新 {date} UTC",
        "before": "{day} までの .dmg・.zip（{n} 件）は棒に含めていません",
        "pending": "直近の git clone は GitHub の集計待ち",
        "empty": "まだ日ごとの記録がありません",
    },
    "en": {
        "title": "Downloads per day",
        "sub": ".dmg + .zip + git clone · updated daily",
        "total": "Total",
        "updated": "Updated {date} UTC",
        "before": "{n} .dmg/.zip downloads up to {day} aren't in the bars",
        "pending": "recent git clones are still being counted by GitHub",
        "empty": "No daily records yet",
    },
    "zh": {
        "title": "每日下载量",
        "sub": ".dmg・.zip・git clone 合计 · 每天自动更新",
        "total": "累计",
        "updated": "更新于 {date} UTC",
        "before": "{day} 之前的 .dmg・.zip（{n} 次）未计入柱形",
        "pending": "最近的 git clone 仍在等待 GitHub 统计",
        "empty": "还没有按日的记录",
    },
}


def series(stats, today):
    """日ごとの合計：[(日付, 数)]、記録を始めた日、その日までの .dmg・.zip の数、clone がまだ出ていない日があるか"""
    clones = stats.get("clones") or {}
    daily = stats.get("daily") or {}
    snap = sorted(daily.items())
    inc = {}
    for (_, a), (d1, b) in zip(snap, snap[1:]):
        inc[d1] = sum(max(0, int(b.get(k, 0)) - int(a.get(k, 0))) for k in ("dmg", "zip"))
    known = sorted(set(clones) | set(daily))
    if not known:
        return [], None, 0, False
    first = max(dt.date.fromisoformat(known[0]), today - dt.timedelta(days=DAYS - 1))
    last_clone = max(clones) if clones else ""
    days, pending = [], False
    d = first
    while d <= today:
        k = d.isoformat()
        days.append((d, inc.get(k, 0) + int((clones.get(k) or {}).get("uniques", 0))))
        if k > last_clone:
            pending = True
        d += dt.timedelta(days=1)
    before_day, before_n = None, 0
    if snap:
        before_day = dt.date.fromisoformat(snap[0][0])
        before_n = int(snap[0][1].get("dmg", 0)) + int(snap[0][1].get("zip", 0))
    return days, before_day, before_n, pending


def bar_path(x, y_top, w, h, r):
    """上の角だけ丸い棒（下＝基準線側は四角）"""
    r = max(0.0, min(r, w / 2, h))
    return (f'M{x:.1f},{y_top + h:.1f}V{y_top + r:.1f}Q{x:.1f},{y_top:.1f} {x + r:.1f},{y_top:.1f}'
            f'H{x + w - r:.1f}Q{x + w:.1f},{y_top:.1f} {x + w:.1f},{y_top + r:.1f}V{y_top + h:.1f}Z')


def md(d):
    return f"{d.month}/{d.day}"


def render(stats, lang, today):
    t = TEXTS[lang]
    days, before_day, before_n, pending = series(stats, today)
    out = []
    a = out.append
    a(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" '
      f'aria-label="{escape(t["title"])}">')
    a(f'<title>{escape(t["title"])}</title>')
    a(f'<rect x="0.5" y="0.5" width="{W - 1}" height="{H - 1}" rx="18" fill="{BG}" stroke="{EDGE}"/>')
    a(f'<g font-family="{FONT}" style="font-variant-numeric: tabular-nums">')
    # 見出しと累計
    a(f'<text x="{PAD}" y="48" font-size="19" font-weight="600" fill="{WHITE}" letter-spacing="-0.2">{escape(t["title"])}</text>')
    a(f'<text x="{PAD}" y="72" font-size="12" fill="{GRAY}">{escape(t["sub"])}</text>')
    a(f'<text x="{W - PAD}" y="30" font-size="11" fill="{GRAY}" text-anchor="end" letter-spacing="0.6">{escape(t["total"])}</text>')
    a(f'<text x="{W - PAD}" y="70" font-size="38" font-weight="700" fill="{WHITE}" text-anchor="end" letter-spacing="-1">'
      f'{int(stats.get("total", 0)):,}</text>')

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

    # 下の注記（薄く 1〜2 行）
    updated = (stats.get("updated") or today.isoformat())[:10]
    notes = []
    if before_day and before_n:
        notes.append(t["before"].format(day=md(before_day), n=before_n))
    if pending:
        notes.append(t["pending"])
    a(f'<text x="{PAD}" y="{H - 22}" font-size="10.5" fill="{DIM}">'
      f'{escape(" · ".join([t["updated"].format(date=updated)] + notes))}</text>')
    a('</g></svg>')
    return "\n".join(out) + "\n"


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    stats = json.load(open(sys.argv[1]))
    today = dt.date.fromisoformat((stats.get("updated") or dt.datetime.now(dt.timezone.utc).isoformat())[:10])
    os.makedirs(sys.argv[2], exist_ok=True)
    for lang in TEXTS:
        with open(os.path.join(sys.argv[2], f"downloads-{lang}.svg"), "w") as f:
            f.write(render(stats, lang, today))


if __name__ == "__main__":
    main()
