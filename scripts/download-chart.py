#!/usr/bin/env python3
"""README の「1 日ごとのダウンロード」のグラフ（SVG）を stats.json から作る。

    python3 scripts/download-chart.py stats.json <出力フォルダ>
    → downloads-ja.svg・downloads-en.svg・downloads-zh.svg

- scripts/download-stats.sh が数え直すたびに作り、stats ブランチに stats.json と一緒に置く（README はそこを読む）
- 1 日（UTC）ごとに積み上げた棒：.dmg（新しく入れた）・.zip（アップデート）・git clone（その日に clone した人数）
  .dmg・.zip は GitHub が累計しか出さないので、毎日の累計（stats.json の daily）の差を、その日の数にする。
  記録を始める前の .dmg・.zip は日ごとに分けられないので棒に入れず、下に件数を書く（右上の累計には入る）
- 標準ライブラリだけで書く（GitHub Actions でもそのまま動く）。黒い背景・直近 60 日
"""
import datetime as dt
import json
import math
import os
import sys
from xml.sax.saxutils import escape

DAYS = 60
W, H = 820, 344
PAD = 24
X0, X1 = 58, W - PAD           # 棒を描く横の範囲
Y0, Y1 = 118, H - 80           # 棒を描く縦の範囲（上・下＝基準線）

SURFACE = "#0d0d10"
GRID = "#24242a"
PENDING = "#17171d"            # clone の数がまだ出ていない日の帯
TEXT = "#f0efec"
TEXT2 = "#c3c2b7"
MUTED = "#8b8b94"
# 種類ごとの色（積み上げの下から。暗い背景で色覚の違いも含めて見分けられる 3 色）
SERIES = [("dmg", "#3987e5"), ("zip", "#d95926"), ("clone", "#199e70")]
FONT = ("-apple-system, BlinkMacSystemFont, 'Segoe UI', 'Hiragino Sans', 'Hiragino Kaku Gothic ProN', "
        "'Noto Sans CJK JP', 'Noto Sans JP', 'PingFang SC', 'Microsoft YaHei', sans-serif")

TEXTS = {
    "ja": {
        "title": "1 日ごとのダウンロード",
        "sub": "UTC の日ごと · 毎日自動で更新",
        "total": "累計",
        "dmg": ".dmg（新しく入れた）",
        "zip": ".zip（アップデート）",
        "clone": "git clone（人数）",
        "updated": "更新 {date} UTC · 数は stats ブランチの stats.json",
        "before": "※ {day} までの .dmg・.zip（{n} 件）は日ごとの内訳がないため棒に入れていません（累計には入っています）",
        "empty": "まだ日ごとの記録がありません",
        "pending": "git clone は集計待ち（GitHub が数日遅れて出す）",
    },
    "en": {
        "title": "Downloads per day",
        "sub": "By UTC day · updated automatically every day",
        "total": "Total",
        "dmg": ".dmg (new installs)",
        "zip": ".zip (updates)",
        "clone": "git clone (people)",
        "updated": "Updated {date} UTC · numbers in stats.json on the stats branch",
        "before": "* The {n} .dmg/.zip downloads up to {day} have no daily breakdown, so they are left out of the bars (they are in the total)",
        "empty": "No daily records yet",
        "pending": "git clone: not counted yet (GitHub is days behind)",
    },
    "zh": {
        "title": "每日下载量",
        "sub": "按 UTC 日期 · 每天自动更新",
        "total": "累计",
        "dmg": ".dmg（新安装）",
        "zip": ".zip（更新）",
        "clone": "git clone（人数）",
        "updated": "更新于 {date} UTC · 数据见 stats 分支的 stats.json",
        "before": "※ {day} 之前的 .dmg・.zip（{n} 次）没有按日的明细，未计入柱形（已计入累计）",
        "empty": "还没有按日的记录",
        "pending": "git clone 等待统计（GitHub 会晚几天给出）",
    },
}


def text_width(s, size):
    """だいたいの文字幅（全角は 1em、半角は 0.58em）"""
    return sum(size * (1.0 if ord(ch) > 0x2E7F else 0.58) for ch in s)


def nice_step(top):
    """目盛りの間隔（1・2・5 × 10^n で、4 本前後になるように）"""
    if top <= 4:
        return 1
    raw = top / 4
    mag = 10 ** math.floor(math.log10(raw))
    for m in (1, 2, 5, 10):
        if raw <= m * mag:
            return int(m * mag)
    return int(10 * mag)


def series(stats, today):
    """日ごとの数：{日付: {"dmg": n|None, "zip": n|None, "clone": n|None}}"""
    clones = stats.get("clones") or {}
    daily = stats.get("daily") or {}
    snap = sorted(daily.items())
    inc = {}
    for (d0, a), (d1, b) in zip(snap, snap[1:]):
        inc[d1] = {k: max(0, int(b.get(k, 0)) - int(a.get(k, 0))) for k in ("dmg", "zip")}
    known = sorted(set(clones) | set(daily))
    if not known:
        return [], None, 0
    first = max(dt.date.fromisoformat(known[0]), today - dt.timedelta(days=DAYS - 1))
    days = []
    d = first
    while d <= today:
        k = d.isoformat()
        v = {"dmg": None, "zip": None, "clone": None}
        if k in inc:
            v.update(inc[k])
        if k in clones:
            v["clone"] = int(clones[k].get("uniques", 0))
        days.append((d, v))
        d += dt.timedelta(days=1)
    # 記録を始めた日（最初の累計）までの .dmg・.zip：日ごとに分けられない分
    before_day, before_n = None, 0
    if snap:
        before_day = dt.date.fromisoformat(snap[0][0])
        before_n = int(snap[0][1].get("dmg", 0)) + int(snap[0][1].get("zip", 0))
    return days, before_day, before_n


def bar_path(x, y_top, w, h, r):
    """上の角だけ丸い棒（下＝基準線側は四角）"""
    r = max(0.0, min(r, w / 2, h))
    if r == 0:
        return f'M{x:.1f},{y_top + h:.1f}V{y_top:.1f}H{x + w:.1f}V{y_top + h:.1f}Z'
    return (f'M{x:.1f},{y_top + h:.1f}V{y_top + r:.1f}Q{x:.1f},{y_top:.1f} {x + r:.1f},{y_top:.1f}'
            f'H{x + w - r:.1f}Q{x + w:.1f},{y_top:.1f} {x + w:.1f},{y_top + r:.1f}V{y_top + h:.1f}Z')


def fmt_day(d, lang):
    return f"{d.month}/{d.day}"


def render(stats, lang, today):
    t = TEXTS[lang]
    days, before_day, before_n = series(stats, today)
    out = []
    a = out.append
    a(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" '
      f'aria-label="{escape(t["title"])}">')
    a(f'<title>{escape(t["title"])}</title>')
    a(f'<rect x="0.5" y="0.5" width="{W - 1}" height="{H - 1}" rx="16" fill="{SURFACE}" stroke="#2a2a31"/>')
    a(f'<g font-family="{FONT}">')
    # 見出しと累計
    a(f'<text x="{PAD}" y="42" font-size="18" font-weight="600" fill="{TEXT}">{escape(t["title"])}</text>')
    a(f'<text x="{PAD}" y="64" font-size="12" fill="{MUTED}">{escape(t["sub"])}</text>')
    a(f'<text x="{W - PAD}" y="30" font-size="12" fill="{MUTED}" text-anchor="end">{escape(t["total"])}</text>')
    a(f'<text x="{W - PAD}" y="64" font-size="32" font-weight="700" fill="{TEXT}" text-anchor="end">{int(stats.get("total", 0)):,}</text>')
    # 凡例
    lx = PAD
    for key, color in SERIES:
        a(f'<rect x="{lx}" y="84" width="10" height="10" rx="2" fill="{color}"/>')
        a(f'<text x="{lx + 16}" y="93.5" font-size="12" fill="{TEXT2}">{escape(t[key])}</text>')
        lx += 16 + text_width(t[key], 12) + 22
    # clone の数がまだ出ていない最近の日（GitHub は数日遅れて出す）：帯で示し、凡例に書く
    last_clone = max(stats.get("clones") or {"": 0})
    pending = [i for i, (d, v) in enumerate(days) if v["clone"] is None and d.isoformat() > last_clone]
    if pending:
        a(f'<rect x="{lx}" y="84" width="10" height="10" rx="2" fill="{PENDING}" stroke="#34343c"/>')
        a(f'<text x="{lx + 16}" y="93.5" font-size="12" fill="{MUTED}">{escape(t["pending"])}</text>')

    if not days:
        a(f'<text x="{W / 2}" y="{(Y0 + Y1) / 2}" font-size="13" fill="{MUTED}" text-anchor="middle">{escape(t["empty"])}</text>')
    else:
        totals = [sum(v[k] or 0 for k, _ in SERIES) for _, v in days]
        top = max(max(totals), 1)
        step = nice_step(top)
        ymax = step * math.ceil(top / step)
        sy = (Y1 - Y0) / ymax
        n = len(days)
        slot = (X1 - X0) / n
        if pending:
            px = X0 + slot * pending[0]
            a(f'<rect x="{px:.1f}" y="{Y0 - 8}" width="{X1 - px:.1f}" height="{Y1 - Y0 + 8}" fill="{PENDING}"/>')
        bw = min(24.0, slot * 0.64)
        # 目盛り（細い実線）
        for i in range(0, ymax + 1, step):
            y = Y1 - i * sy
            a(f'<line x1="{X0}" y1="{y:.1f}" x2="{X1}" y2="{y:.1f}" stroke="{GRID}" stroke-width="1"/>')
            a(f'<text x="{X0 - 10}" y="{y + 4:.1f}" font-size="11" fill="{MUTED}" text-anchor="end">{i}</text>')
        every = max(1, math.ceil(44 / slot))
        imax = max(range(n), key=lambda i: (totals[i], i))
        for i, (d, v) in enumerate(days):
            x = X0 + slot * i + (slot - bw) / 2
            parts = [(v[k] or 0, color) for k, color in SERIES if (v[k] or 0) > 0]
            y = Y1
            for j, (val, color) in enumerate(parts):
                h = val * sy
                # 積み上げのあいだに 2px のすき間（上に重なる段の下側を削る）
                gap = 2 if j > 0 else 0
                last = j == len(parts) - 1
                hh = max(h - gap, 0.8)
                ytop = y - h
                a(f'<path d="{bar_path(x, ytop, bw, hh, 4 if last else 0)}" fill="{color}"/>')
                y = ytop
            # 横軸の日付（重ならない間隔で。最後の日は必ず）
            if (n - 1 - i) % every == 0:
                a(f'<text x="{x + bw / 2:.1f}" y="{Y1 + 18}" font-size="11" fill="{MUTED}" text-anchor="middle">{fmt_day(d, lang)}</text>')
            # 数を書くのは、いちばん多い日と最後の日だけ
            if totals[i] > 0 and i in (imax, n - 1):
                a(f'<text x="{x + bw / 2:.1f}" y="{Y1 - totals[i] * sy - 6:.1f}" font-size="11" font-weight="600" '
                  f'fill="{TEXT2}" text-anchor="middle">{totals[i]}</text>')
        a(f'<line x1="{X0}" y1="{Y1}" x2="{X1}" y2="{Y1}" stroke="#3a3a42" stroke-width="1"/>')

    updated = (stats.get("updated") or today.isoformat())[:10]
    a(f'<text x="{PAD}" y="{H - 38}" font-size="11" fill="{MUTED}">{escape(t["updated"].format(date=updated))}</text>')
    if before_day and before_n:
        a(f'<text x="{PAD}" y="{H - 16}" font-size="11" fill="{MUTED}">'
          f'{escape(t["before"].format(day=fmt_day(before_day, lang), n=before_n))}</text>')
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
