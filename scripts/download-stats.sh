#!/bin/bash
# README のバッジの「ダウンロード数」と「1 日ごとのダウンロード」のグラフを数え直して、stats ブランチに書く
# （stats.json と、scripts/download-chart.py が作る downloads-ja.svg・downloads-en.svg・downloads-zh.svg を 1 つのコミットで）。
#   scripts/download-stats.sh            数え直して、変わっていれば stats ブランチに書く（無ければ作る）
#   scripts/download-stats.sh --dry-run  書かずに、数え直した stats.json を出すだけ
# 数えるもの（合計が total、バッジに出る数）：
#   dmg    リリースの .dmg のダウンロード（README・リリースのページ・curl などで取って入れた）
#   zip    リリースの JellyfishAI-<版>.zip のダウンロード（アプリの「アップデートする」・ターミナルの update.sh・手での .zip）
#   clone  git clone（GitHub が数えた、日ごとの clone した人数の合計。ボット・ミラー・CI の clone も入る）
#   SHA256SUMS.txt はアップデートのたびに取るので数えない
# clone 数は GitHub が直近 14 日の分しか残さないので、日ごとに stats.json に貯める（同じ日は大きいほうを取る）。
# .dmg・.zip は GitHub が累計しか出さないので、その日（UTC）の累計を daily に貯め、前の日との差を 1 日の数にする（グラフ）。
# daily が無い stats.json からは、stats ブランチの過去のコミットの累計で埋める
# clone 数を読むには、このリポジトリの Administration（読み取り）の権限が要る：
#   ・この Mac から：gh にログインしているアカウント（push できる人）で読める
#   ・GitHub Actions（.github/workflows/stats.yml）から：シークレット TRAFFIC_TOKEN があれば読む。
#     無ければ clone は貯めてある分のまま、リリースのダウンロード数だけ数え直す
# 自分の clone を数に入れないよう、リポジトリは clone しない（GitHub の API で読み書きする）
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="${JELLYFISH_REPO:-Rhizobium-gits/jellyfish-ai}"
BRANCH="${JELLYFISH_STATS_BRANCH:-stats}"
DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done
command -v gh >/dev/null || { echo "gh（GitHub CLI）が要ります" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq が要ります" >&2; exit 1; }

# 貯めてある分（stats ブランチが無い・stats.json が無いときは空から）
OLD='{}'
SHA=""
BRANCH_EXISTS=0
if gh api "repos/$REPO/branches/$BRANCH" --silent 2>/dev/null; then
  BRANCH_EXISTS=1
  if SHA="$(gh api "repos/$REPO/contents/stats.json?ref=$BRANCH" --jq .sha 2>/dev/null)"; then
    OLD="$(gh api -H "Accept: application/vnd.github.raw" "repos/$REPO/contents/stats.json?ref=$BRANCH")"
    printf '%s' "$OLD" | jq -e 'type == "object"' >/dev/null || { echo "stats.json を読めません" >&2; exit 1; }
  else
    SHA=""
  fi
fi

# 日ごとの累計（.dmg・.zip）。まだ無ければ stats ブランチの過去の stats.json から（その日の最後の数＝大きいほう）
TODAY="$(date -u +%Y-%m-%d)"
DAILY="$(printf '%s' "$OLD" | jq -c '.daily // empty')"
if [[ -z "$DAILY" ]]; then
  DAILY='{}'
  if [[ $BRANCH_EXISTS == 1 ]]; then
    while IFS=$'\t' read -r sha day; do
      S="$(gh api -H "Accept: application/vnd.github.raw" "repos/$REPO/contents/stats.json?ref=$sha" 2>/dev/null)" || continue
      printf '%s' "$S" | jq -e 'type == "object" and has("dmg")' >/dev/null 2>&1 || continue
      DAILY="$(jq -cn --argjson d "$DAILY" --argjson s "$S" --arg day "$day" '
        $d + {($day): {dmg: ([$d[$day].dmg // 0, $s.dmg] | max), zip: ([$d[$day].zip // 0, $s.zip] | max)}}')"
    done < <(gh api "repos/$REPO/commits?sha=$BRANCH&path=stats.json&per_page=100" --paginate \
               --jq '.[] | [.sha, .commit.committer.date[0:10]] | @tsv')
  fi
fi

# clone 数（直近 14 日、日ごと）。読めなければ null（貯めてある分のまま）
# 読めないとき gh api はエラーの JSON を出してから失敗するので、出たものは使わない
if [[ -n "${TRAFFIC_TOKEN:-}" ]]; then
  CLONES="$(GH_TOKEN="$TRAFFIC_TOKEN" gh api "repos/$REPO/traffic/clones" 2>/dev/null)" || CLONES=null
else
  CLONES="$(gh api "repos/$REPO/traffic/clones" 2>/dev/null)" || CLONES=null
fi
printf '%s' "$CLONES" | jq -e 'type == "object" and (.clones | type == "array")' >/dev/null 2>&1 || CLONES=null
[[ "$CLONES" == null ]] && echo "clone 数を読めませんでした（Administration の読み取りの権限が要ります）。clone は貯めてある分のままにします" >&2

# リリースのファイルごとのダウンロード数（下書きは除く）
ASSETS="$(gh api "repos/$REPO/releases" --paginate --jq '.[] | select(.draft | not) | .assets[] | {name, download_count}' | jq -s .)"

NEW="$(jq -n --argjson old "$OLD" --argjson t "$CLONES" --argjson assets "$ASSETS" --argjson daily "$DAILY" --arg today "$TODAY" '
  ($old.clones // {}) as $kept
  | (reduce ((if $t == null then [] else ($t.clones // []) end)[] | select(.count > 0)) as $d ($kept;
      ($d.timestamp[0:10]) as $day
      | .[$day] = {count: ([.[$day].count // 0, $d.count] | max), uniques: ([.[$day].uniques // 0, $d.uniques] | max)}))
  | to_entries | sort_by(.key) | from_entries
  | . as $clones
  | ([$assets[] | select(.name | endswith(".dmg")) | .download_count] | add // 0) as $dmg
  | ([$assets[] | select(.name | endswith(".zip")) | .download_count] | add // 0) as $zip
  | ([$clones[] | .uniques] | add // 0) as $clone
  | ($daily + {($today): {dmg: ([$daily[$today].dmg // 0, $dmg] | max), zip: ([$daily[$today].zip // 0, $zip] | max)}}
     | to_entries | sort_by(.key) | from_entries) as $days
  | {total: ($dmg + $zip + $clone), dmg: $dmg, zip: $zip, clone: $clone, clones: $clones, daily: $days}')"

if [[ $DRY == 1 ]]; then
  printf '%s\n' "$NEW" | jq .
  exit 0
fi

# 数が変わっていなければ書かない（書くたびに stats ブランチにコミットが 1 つ増えるので）
if [[ "$(printf '%s' "$OLD" | jq -S 'del(.updated)')" == "$(printf '%s' "$NEW" | jq -S .)" ]]; then
  echo "変わっていません: $(printf '%s' "$NEW" | jq -c '{total, dmg, zip, clone}')"
  exit 0
fi

if [[ $BRANCH_EXISTS == 0 ]]; then
  # 履歴を持たない、データだけのブランチを作る（main の履歴とは別）
  TREE="$(jq -n '{tree: [{path: "README.md", mode: "100644", type: "blob",
    content: "README のダウンロード数のバッジが読むデータです（scripts/download-stats.sh と .github/workflows/stats.yml が書きます）。\n"}]}' |
    gh api -X POST "repos/$REPO/git/trees" --input - --jq .sha)"
  COMMIT="$(jq -n --arg tree "$TREE" '{message: "Start the download stats branch", tree: $tree, parents: []}' |
    gh api -X POST "repos/$REPO/git/commits" --input - --jq .sha)"
  jq -n --arg ref "refs/heads/$BRANCH" --arg sha "$COMMIT" '{ref: $ref, sha: $sha}' |
    gh api -X POST "repos/$REPO/git/refs" --input - --silent
fi

BODY="$(printf '%s' "$NEW" | jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{updated: $now} + .')"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
printf '%s\n' "$BODY" > "$WORK/stats.json"
python3 "$HERE/download-chart.py" "$WORK/stats.json" "$WORK"

HEAD_SHA="$(gh api "repos/$REPO/git/ref/heads/$BRANCH" --jq .object.sha)"
BASE_TREE="$(gh api "repos/$REPO/git/commits/$HEAD_SHA" --jq .tree.sha)"
TREE="$(jq -n --arg base "$BASE_TREE" \
  --rawfile stats "$WORK/stats.json" --rawfile ja "$WORK/downloads-ja.svg" \
  --rawfile en "$WORK/downloads-en.svg" --rawfile zh "$WORK/downloads-zh.svg" '
  {base_tree: $base, tree: [
    {path: "stats.json", mode: "100644", type: "blob", content: $stats},
    {path: "downloads-ja.svg", mode: "100644", type: "blob", content: $ja},
    {path: "downloads-en.svg", mode: "100644", type: "blob", content: $en},
    {path: "downloads-zh.svg", mode: "100644", type: "blob", content: $zh}]}' |
  gh api -X POST "repos/$REPO/git/trees" --input - --jq .sha)"
MSG="Download stats: $(printf '%s' "$NEW" | jq -r '"\(.total) (dmg \(.dmg), zip \(.zip), clone \(.clone))"')"
COMMIT="$(jq -n --arg msg "$MSG" --arg tree "$TREE" --arg parent "$HEAD_SHA" '{message: $msg, tree: $tree, parents: [$parent]}' |
  gh api -X POST "repos/$REPO/git/commits" --input - --jq .sha)"
jq -n --arg sha "$COMMIT" '{sha: $sha}' | gh api -X PATCH "repos/$REPO/git/refs/heads/$BRANCH" --input - --silent
echo "書きました: $(printf '%s' "$NEW" | jq -c '{total, dmg, zip, clone}')"
