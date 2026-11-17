#!/bin/zsh
# README の GIF を撮り直す。
#   scripts/demo/record.sh [basic parallel states team link crossai]
#
# - 普段の Jellyfish AI を一度終了し、JELLYFISH_DATA_DIR で空のデモ用データから起動して録画する
#   （JELLYFISH_AUTOMATION=1 で、指示の送信などデモ用の jellyfish:// 操作を受け付ける）
#   （普段のクラゲ・会話・設定には触れない。録画後に普段のアプリを起動し直す）
#   （jellyfish:// は録画用に起動した dist/JellyfishAI.app へ明示して渡す。アプリケーションフォルダの方には届かない）
# - basic / parallel / team は実際に Claude Code へ、crossai は Claude Code と Codex CLI へ指示を送る（作業フォルダは ~/jellyfish-demo）
#   （crossai には ChatGPT でログインした Codex CLI が要る）
# - 背景は scripts/demo/*.json の background（いまは黒）
# - 録画範囲は 1920x1080 pt のメインディスプレイ右上を前提にしている（scripts/demo/*.json の region）
# - 録画中はキーボード・マウスに触らない（チャットウィンドウがフォーカスを持つ）
# - 撮影するプロセス（ターミナル / VS Code）に「画面収録」の許可が必要
set -e
cd "$(dirname "$0")/../.."
# zsh では ${@:-a b} が 1 語になるので、引数が無いときの一覧は別に書く
if (( $# )); then takes=("$@"); else takes=(basic parallel states team link crossai); fi
[[ -d dist/JellyfishAI.app ]] || scripts/build.sh
mkdir -p .build ~/jellyfish-demo
swiftc -O scripts/demo/recorder.swift -o .build/recorder
# 終わったら（途中で失敗しても）普段のアプリを起動し直す（scripts/install.sh で入れたものがあればそちら）
stopped=0
relaunch() {
  (( stopped )) || return 0
  pkill -x JellyfishAI 2>/dev/null || true
  /bin/sleep 0.5
  local installed=""
  for d in /Applications ~/Applications; do [[ -d "$d/JellyfishAI.app" ]] && { installed="$d/JellyfishAI.app"; break; }; done
  open "${installed:-dist/JellyfishAI.app}"
}
trap relaunch EXIT
for name in $takes; do
  stopped=1
  pkill -x JellyfishAI || true
  while pgrep -x JellyfishAI >/dev/null; do /bin/sleep 0.1; done
  data="$PWD/.build/demo-data/$name"
  rm -rf "$data" ".build/demo-frames/$name"; mkdir -p "$data"
  cp scripts/demo/seed/$name/*.json "$data/"
  # 前の録画で覚えたチャットウィンドウの位置・大きさを消す（シードのクラゲは毎回同じ ID）
  for id in $(grep -oE '[0-9A-F]{8}-[0-9A-F-]{27}' scripts/demo/seed/$name/jellies.json); do
    defaults delete ai.jellyfish.desktop "NSWindow Frame JellyfishChat-$id" 2>/dev/null || true
  done
  open --env JELLYFISH_DATA_DIR="$data" --env JELLYFISH_AUTOMATION=1 dist/JellyfishAI.app
  .build/recorder "scripts/demo/$name.json" ".build/demo-frames/$name"
  pkill -x JellyfishAI || true
  /bin/sleep 0.5
done
relaunch
stopped=0
# 写ったホームのパスをぼかす位置を探してから GIF にする
scripts/demo/redact.sh $takes
"${PYTHON:-python3}" scripts/demo/make_gif.py .build/demo-frames docs/media $takes
