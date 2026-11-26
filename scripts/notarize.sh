#!/bin/bash
# 配る .app を Developer ID で署名し、Apple の公証（notarization）を通して、ホチキス留め（staple）する。
# scripts/release.sh が使う（GitHub Releases で配る版。Mac App Store には出さない：サンドボックスでは
# ~/.claude や各 AI の CLI を動かせないため）。
#
#   scripts/notarize.sh [<.app>]   既定は dist/OMOCHI AI.app（scripts/build.sh --universal の出来上がり）。その場で置き換える
#   scripts/notarize.sh --sign-only [<.app>]   Developer ID の署名と確認まで（Apple の公証には出さない）
#
# 署名：Swift Package で作った .app を Xcode のアーカイブの形に入れ、xcodebuild -exportArchive（method developer-id）で
#   「Developer ID Application」に署名し直す。エンタイトルメント（Resources/OmochiAI.entitlements）と Hardened Runtime は
#   ビルドのときの署名のものがそのまま残る。証明書は、キーチェーンにあればそれ、無ければ Xcode にサインインしている
#   アカウント（Apple Developer Program の Account Holder）の権限で Apple が管理する Developer ID の証明書を使う。
# 公証：xcrun notarytool。認証は次のどちらか（リポジトリには書かない）：
#   OMOCHI_NOTARY_PROFILE   xcrun notarytool store-credentials で作ったキーチェーンのプロファイルの名前
#   OMOCHI_ASC_KEY_ID・OMOCHI_ASC_ISSUER_ID・OMOCHI_ASC_KEY_PATH   App Store Connect の API キー（.p8）
# チーム：OMOCHI_TEAM（既定は配布版のチーム。署名を見れば誰でも読める公開の値）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SIGN_ONLY=0
if [[ "${1:-}" == "--sign-only" ]]; then SIGN_ONLY=1; shift; fi
APP="${1:-$ROOT/dist/OMOCHI AI.app}"
TEAM="${OMOCHI_TEAM:-793HF34NYX}"
BUNDLE_ID="ai.omochi.desktop"
fail() { echo "止めます: $*" >&2; exit 1; }

[[ -d "$APP" && ! -L "$APP" ]] || fail "$APP がありません（先に scripts/build.sh --universal）"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcrun --find xcodebuild >/dev/null 2>&1 || fail "Xcode が要ります（xcodebuild -exportArchive で Developer ID の署名をするため）"

NOTARY=()
if (( ! SIGN_ONLY )); then
  if [[ -n "${OMOCHI_NOTARY_PROFILE:-}" ]]; then
    NOTARY=(--keychain-profile "$OMOCHI_NOTARY_PROFILE")
  elif [[ -n "${OMOCHI_ASC_KEY_ID:-}" && -n "${OMOCHI_ASC_ISSUER_ID:-}" && -r "${OMOCHI_ASC_KEY_PATH:-}" ]]; then
    NOTARY=(--key "$OMOCHI_ASC_KEY_PATH" --key-id "$OMOCHI_ASC_KEY_ID" --issuer "$OMOCHI_ASC_ISSUER_ID")
  else
    fail "公証の認証がありません（OMOCHI_NOTARY_PROFILE か、OMOCHI_ASC_KEY_ID・OMOCHI_ASC_ISSUER_ID・OMOCHI_ASC_KEY_PATH）"
  fi
fi

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null || true; }
VERSION="$(plist CFBundleShortVersionString "$APP/Contents/Info.plist")"
BUILD="$(plist CFBundleVersion "$APP/Contents/Info.plist")"
[[ "$(plist CFBundleIdentifier "$APP/Contents/Info.plist")" == "$BUNDLE_ID" ]] || fail "バンドル ID が $BUNDLE_ID ではありません"
NAME="$(basename "$APP")"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/omochi-notarize.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# 1. Xcode のアーカイブの形にする（Products/Applications/<アプリ> と Info.plist）
ARCHIVE="$WORK/OMOCHI.xcarchive"
mkdir -p "$ARCHIVE/Products/Applications"
ditto "$APP" "$ARCHIVE/Products/Applications/$NAME"
cat > "$ARCHIVE/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>ApplicationProperties</key>
	<dict>
		<key>ApplicationPath</key><string>Applications/${NAME}</string>
		<key>Architectures</key><array><string>arm64</string><string>x86_64</string></array>
		<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
		<key>CFBundleShortVersionString</key><string>${VERSION}</string>
		<key>CFBundleVersion</key><string>${BUILD}</string>
		<key>SigningIdentity</key><string>-</string>
		<key>Team</key><string>${TEAM}</string>
	</dict>
	<key>ArchiveVersion</key><integer>2</integer>
	<key>CreationDate</key><date>$(date -u +%Y-%m-%dT%H:%M:%SZ)</date>
	<key>Name</key><string>OMOCHI AI</string>
	<key>SchemeName</key><string>OmochiAI</string>
</dict>
</plist>
PLIST
cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>destination</key><string>export</string>
	<key>teamID</key><string>${TEAM}</string>
	<key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST

# 2. Developer ID で書き出す
echo "Developer ID で署名しています…"
if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$WORK/out" -exportOptionsPlist "$WORK/ExportOptions.plist" \
     -allowProvisioningUpdates > "$WORK/export.log" 2>&1; then
  grep -hiE "error|certificate|Developer ID|permission" "$WORK/export.log" | sort -u | head -20 >&2
  fail "Developer ID で書き出せませんでした。Xcode › Settings › Accounts に Account Holder の Apple ID でサインインしているか、Manage Certificates… に Developer ID Application があるかを確かめてください"
fi
SIGNED="$WORK/out/$NAME"
[[ -d "$SIGNED" ]] || fail "書き出した $NAME がありません"

# 3. 確かめる：Developer ID・チーム・タイムスタンプ・Hardened Runtime・エンタイトルメント・universal
SIG="$(codesign -dvv "$SIGNED" 2>&1)"
grep -q "^Authority=Developer ID Application:" <<<"$SIG" || fail "Developer ID Application の署名ではありません（$(grep -m1 '^Authority=' <<<"$SIG" || echo 証明書なし)）"
[[ "$(sed -n 's/^TeamIdentifier=//p' <<<"$SIG")" == "$TEAM" ]] || fail "署名のチームが $TEAM ではありません"
grep -q "^Timestamp=" <<<"$SIG" || fail "署名にタイムスタンプがありません"
[[ "$SIG" =~ flags=[^[:space:]]*runtime ]] || fail "Hardened Runtime が付いていません"
codesign --verify --deep --strict "$SIGNED" 2>/dev/null || fail "署名が正しくありません（codesign --verify --deep --strict）"
WANT="$(plutil -convert json -o - Resources/OmochiAI.entitlements | python3 -I -c 'import json,sys; print(sorted(json.load(sys.stdin)))')"
GOT="$(codesign -d --entitlements - --xml "$SIGNED" 2>/dev/null | plutil -convert json -o - - | python3 -I -c 'import json,sys; print(sorted(json.load(sys.stdin)))')"
[[ "$WANT" == "$GOT" ]] || fail "エンタイトルメントが Resources/OmochiAI.entitlements と違います（${GOT}）"
ARCHS="$(lipo -archs "$SIGNED/Contents/MacOS/OmochiAI")"
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || fail "universal ではありません: $ARCHS"
echo "署名: $(grep -m1 '^Authority=' <<<"$SIG" | sed 's/^Authority=//')・${ARCHS}・版 ${VERSION}（${BUILD}）"

if (( SIGN_ONLY )); then
  rm -rf "$APP" && ditto "$SIGNED" "$APP"
  echo "（--sign-only：公証には出していません）: $APP"
  exit 0
fi

# 4. 公証（終わるまで待つ。数分）
ZIP="$WORK/OmochiAI-notarize.zip"
ditto -c -k --sequesterRsrc --keepParent "$SIGNED" "$ZIP"
echo "Apple の公証に出しています（数分かかります）…"
RESULT="$(xcrun notarytool submit "$ZIP" "${NOTARY[@]}" --wait --output-format json 2>"$WORK/notary.err" || true)"
ID="$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1] or "{}").get("id",""))' "$RESULT" 2>/dev/null || true)"
STATUS="$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1] or "{}").get("status",""))' "$RESULT" 2>/dev/null || true)"
if [[ "$STATUS" != "Accepted" ]]; then
  cat "$WORK/notary.err" >&2 || true
  if [[ -n "$ID" ]]; then
    LOGFILE="$ROOT/dist/notary-log-$ID.json"
    mkdir -p "$ROOT/dist"
    xcrun notarytool log "$ID" "${NOTARY[@]}" "$LOGFILE" >/dev/null 2>&1 && echo "公証のログ: $LOGFILE" >&2
  fi
  fail "公証が通りませんでした（${STATUS:-不明}）"
fi
echo "公証: Accepted（${ID}）"

# 5. staple と Gatekeeper の確認
xcrun stapler staple "$SIGNED" >/dev/null || fail "staple できませんでした"
xcrun stapler validate "$SIGNED" >/dev/null || fail "staple を確かめられませんでした"
SPCTL="$(spctl -a -vv -t exec "$SIGNED" 2>&1 || true)"
grep -q "accepted" <<<"$SPCTL" && grep -q "Notarized Developer ID" <<<"$SPCTL" || { echo "$SPCTL" >&2; fail "Gatekeeper が受け付けません（spctl）"; }

rm -rf "$APP"
ditto "$SIGNED" "$APP"
echo "出来上がり: ${APP}（Developer ID・公証済み・staple 済み）"
