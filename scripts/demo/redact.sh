#!/bin/zsh
# 録画のフレームに写ったホームのパス（/Users/<名前>）を macOS の文字認識で探し、
# .build/demo-frames/<take>/redact.json に位置を書く（make_gif.py がそこをぼかす）。端末内だけで処理する。
#   scripts/demo/redact.sh [basic parallel states team link crossai]
set -e
cd "$(dirname "$0")/../.."
if (( $# )); then takes=("$@"); else takes=(basic parallel states team link crossai); fi
mkdir -p .build
swiftc -O scripts/demo/ocr.swift -o .build/ocr 2>/dev/null
# 「/Users/…」と、ユーザー名の 5 文字以上の切れ端（窓の端で切れたものも）
pattern=$(python3 -c '
import os, re
u = os.path.basename(os.path.expanduser("~"))
frags = sorted({u[i:j] for i in range(len(u)) for j in range(i + 5, len(u) + 1)}, key=len, reverse=True)
print("/?Users/[^/\\s]*|sers/[^/\\s]*" + "".join("|" + re.escape(f) for f in frags))')
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
for name in $takes; do
  [[ -f .build/demo-frames/$name/timeline.json ]] || continue
  mkdir -p "$work/$name"
  ls .build/demo-frames/$name/frame-*.png | split -l 40 - "$work/$name/chunk-"
  ls "$work/$name"/chunk-* | xargs -P 8 -I{} sh -c '.build/ocr --pattern "$1" $(cat "$2") > "$2.json"' _ "$pattern" {}
  python3 - "$work/$name" ".build/demo-frames/$name/redact.json" <<'PY'
import glob, json, sys
merged = {}
for f in glob.glob(sys.argv[1] + "/chunk-*.json"):
    merged.update(json.load(open(f)))
json.dump(merged, open(sys.argv[2], "w"), sort_keys=True)
print(sys.argv[2].split("/")[-2], len(merged), "frames,", sum(1 for v in merged.values() if v), "with the home path")
PY
done
