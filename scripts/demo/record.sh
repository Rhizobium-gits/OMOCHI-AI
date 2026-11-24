#!/bin/zsh
# README の GIF を撮り直す。
#   scripts/demo/record.sh [basic parallel states team link crossai connectors queue]
#
# - 普段の Jellyfish AI を一度終了し、JELLYFISH_DATA_DIR で空のデモ用データから起動して録画する
#   （JELLYFISH_AUTOMATION=1 で、指示の送信などデモ用の jellyfish:// 操作を受け付ける）
#   （普段のクラゲ・会話・設定には触れない。録画後に普段のアプリを起動し直す）
#   （jellyfish:// は録画用に起動した dist/JellyfishAI.app へ明示して渡す。アプリケーションフォルダの方には届かない）
# - basic / parallel / team は実際に Claude Code へ、crossai は Claude Code と Codex CLI へ指示を送る（作業フォルダは ~/jellyfish-demo）
#   （crossai には ChatGPT でログインした Codex CLI が要る）
# - 背景は scripts/demo/*.json の background（いまは黒）
# - 録画範囲は 1920x1080 pt のメインディスプレイ右上を前提にしている（scripts/demo/*.json の region）
#   （メインディスプレイの大きさが違えば、右上からの位置を保つように録画範囲・シードのクラゲ・
#    connectors の窓の位置をずらした写しを .build/demo-takes に作って撮る）
# - 録画中はキーボード・マウスに触らない（チャットウィンドウがフォーカスを持つ）
# - 撮影するプロセス（ターミナル / VS Code）に「画面収録」の許可が必要
# - DEMO_KEEP_APP=1：普段の Jellyfish AI を止めずに撮る。dist/ の写しの ID を ai.jellyfish.desktop.demo に変えて動かす
#   （同じ ID のアプリが動いていると 2 つ目はすぐ終わるため。写しは録画のあと LaunchServices から外す）
set -e
cd "$(dirname "$0")/../.."
# zsh では ${@:-a b} が 1 語になるので、引数が無いときの一覧は別に書く
if (( $# )); then takes=("$@"); else takes=(basic parallel states team link crossai connectors queue); fi
[[ -d dist/JellyfishAI.app ]] || scripts/build.sh
mkdir -p .build ~/jellyfish-demo
swiftc -O scripts/demo/recorder.swift -o .build/recorder
app="dist/JellyfishAI.app"
bid="ai.jellyfish.desktop"
lsr=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
if [[ "${DEMO_KEEP_APP:-}" == 1 ]]; then
  bid="ai.jellyfish.desktop.demo"
  app="$PWD/.build/demo-app/JellyfishAI.app"
  rm -rf "$app"; mkdir -p "${app:h}"
  ditto dist/JellyfishAI.app "$app"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bid" "$app/Contents/Info.plist"
  codesign --force --sign - --options runtime --entitlements Resources/JellyfishAI.entitlements --timestamp=none "$app" 2>/dev/null
  export DEMO_APP="$app" DEMO_BUNDLE_ID="$bid"
fi
# 録画用に動かした Jellyfish だけを止める（DEMO_KEEP_APP=1 なら写しだけ。普段のアプリには触れない）
stop_demo() {
  if [[ "${DEMO_KEEP_APP:-}" == 1 ]]; then
    pkill -f "$app/Contents/MacOS/JellyfishAI" 2>/dev/null || true
    while pgrep -f "$app/Contents/MacOS/JellyfishAI" >/dev/null; do /bin/sleep 0.1; done
  else
    pkill -x JellyfishAI || true
    while pgrep -x JellyfishAI >/dev/null; do /bin/sleep 0.1; done
  fi
}
# 終わったら（途中で失敗しても）普段のアプリを起動し直す（scripts/install.sh で入れたものがあればそちら）
stopped=0
relaunch() {
  if [[ "${DEMO_KEEP_APP:-}" == 1 ]]; then stop_demo; "$lsr" -u "$app" 2>/dev/null || true; return 0; fi
  (( stopped )) || return 0
  pkill -x JellyfishAI 2>/dev/null || true
  /bin/sleep 0.5
  local installed=""
  for d in /Applications ~/Applications; do [[ -d "$d/JellyfishAI.app" ]] && { installed="$d/JellyfishAI.app"; break; }; done
  open "${installed:-dist/JellyfishAI.app}"
}
trap relaunch EXIT
# メインディスプレイの大きさ（ポイント）。1920x1080 からの差だけ右上基準でずらす
read -r scr_w scr_h <<<"$(osascript -l JavaScript -e 'ObjC.import("AppKit"); const f = $.NSScreen.screens.objectAtIndex(0).frame; `${f.size.width} ${f.size.height}`')"
dx=$(( ${scr_w%.*} - 1920 )); dy=$(( ${scr_h%.*} - 1080 ))
(( dx || dy )) && echo "メインディスプレイ ${scr_w%.*}x${scr_h%.*}：録画範囲とシードを x ${dx} / y ${dy} ずらして撮る"
rm -rf .build/demo-takes; mkdir -p .build/demo-takes
for name in $takes; do
  stopped=1
  stop_demo
  data="$PWD/.build/demo-data/$name"
  rm -rf "$data" ".build/demo-frames/$name"; mkdir -p "$data"
  cp scripts/demo/seed/$name/*.json "$data/"
  take="scripts/demo/$name.json"
  if (( dx || dy )); then
    take=".build/demo-takes/$name.json"
    # region と connectors?x= は左上原点、jellies.json の origin は左下原点（Cocoa）
    "${PYTHON:-python3}" - "scripts/demo/$name.json" "$take" "$data/jellies.json" "$dx" "$dy" <<'PY'
import json, re, sys
src, out, jellies, dx, dy = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
t = json.load(open(src))
t["region"][0] += dx
for s in t["steps"]:
    if s.get("url"):
        s["url"] = re.sub(r"(connectors\?(?:.*&)?x=)(-?\d+(?:\.\d+)?)", lambda m: m.group(1) + str(round(float(m.group(2)) + dx)), s["url"])
json.dump(t, open(out, "w"), ensure_ascii=False, indent=1)
js = json.load(open(jellies))
for j in js:
    j["origin"] = [j["origin"][0] + dx, j["origin"][1] + dy]
json.dump(js, open(jellies, "w"), ensure_ascii=False, indent=1)
PY
  fi
  # 前の録画で覚えたチャットウィンドウの位置・大きさを消す（シードのクラゲは毎回同じ ID）
  for id in $(grep -oE '[0-9A-F]{8}-[0-9A-F-]{27}' scripts/demo/seed/$name/jellies.json); do
    defaults delete "$bid" "NSWindow Frame JellyfishChat-$id" 2>/dev/null || true
  done
  open -n --env JELLYFISH_DATA_DIR="$data" --env JELLYFISH_AUTOMATION=1 "$app"
  .build/recorder "$take" ".build/demo-frames/$name"
  stop_demo
  /bin/sleep 0.5
done
relaunch
stopped=0
# 写ったホームのパスをぼかす位置を探してから GIF にする
scripts/demo/redact.sh $takes
"${PYTHON:-python3}" scripts/demo/make_gif.py .build/demo-frames docs/media $takes
