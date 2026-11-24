#!/bin/zsh
# README のダウンロード数（バッジとグラフ）を、この Mac で毎日数え直す（launchd）。
#   scripts/download-stats-daily.sh install    毎日 10:00 とログインしたときに scripts/download-stats.sh を動かすようにする
#   scripts/download-stats-daily.sh uninstall  やめる
#   scripts/download-stats-daily.sh status     入っているか・前に動いたときのログ
#   scripts/download-stats-daily.sh run        いま 1 回動かす（ログに書く）
#
# なぜ：git clone の数は、リポジトリの Administration（読み取り）の権限が無いと読めず、GitHub は直近 14 日しか残さない。
# GitHub Actions（.github/workflows/stats.yml）はシークレット TRAFFIC_TOKEN が無いと clone を読めないので、
# gh にログインしているこの Mac で毎日読んで stats ブランチに貯める（Actions と両方動いても、数えた分が消えることはない）。
# - 動くのは、この Mac が起きていてログインしているときだけ（10:00 に眠っていたら、起きたときに動く）
# - 数が変わっていなければ stats ブランチには書かない
# - ログは ~/Library/Logs/omochi-download-stats.log
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="ai.omochi.download-stats"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/omochi-download-stats.log"
DOMAIN="gui/$(id -u)"
# 前の名前（Jellyfish AI）のときのジョブ。入れ直す・やめるときに一緒に外す
LEGACY_LABEL="ai.jellyfish.download-stats"
remove_legacy() {
  launchctl bootout "$DOMAIN/$LEGACY_LABEL" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
}
# launchd の PATH は短いので、gh・jq・python3 のある場所を足す
JOB_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

job() {
  # launchd から動くときの中身（日時を付けてログに書く）
  echo "=== $(date '+%Y-%m-%d %H:%M:%S %z')"
  "$ROOT/scripts/download-stats.sh"
}

case "${1:-}" in
  install)
    command -v gh >/dev/null || { echo "gh（GitHub CLI）が要ります" >&2; exit 1; }
    gh auth status >/dev/null 2>&1 || { echo "gh にログインしてください（gh auth login）" >&2; exit 1; }
    if ! gh api "repos/${OMOCHI_REPO:-Rhizobium-gits/jellyfish-ai}/traffic/clones" --silent 2>/dev/null; then
      echo "注意：この gh のアカウントでは clone 数を読めません（リポジトリの Administration の読み取りの権限が要ります）。.dmg・.zip だけ数え直します" >&2
    fi
    mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$LOG")"
    cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>$ROOT/scripts/download-stats-daily.sh</string>
    <string>job</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>$JOB_PATH</string></dict>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>10</integer><key>Minute</key><integer>0</integer></dict>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PL
    plutil -lint "$PLIST" >/dev/null
    remove_legacy
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    launchctl bootstrap "$DOMAIN" "$PLIST"
    echo "入れました：毎日 10:00 とログインしたときに数え直します（ログ：${LOG}）"
    ;;
  uninstall)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    remove_legacy
    rm -f "$PLIST"
    echo "やめました（ログは $LOG に残っています）"
    ;;
  status)
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
      echo "入っています（${PLIST}）"
      launchctl print "$DOMAIN/$LABEL" | grep -E '^\s*(state|last exit code|runs) ' || true
    else
      echo "入っていません"
    fi
    [[ -f "$LOG" ]] && { echo "--- ログの最後"; tail -n 6 "$LOG"; }
    ;;
  run)
    mkdir -p "$(dirname "$LOG")"
    job 2>&1 | tee -a "$LOG"
    ;;
  job)
    job
    ;;
  *)
    sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
