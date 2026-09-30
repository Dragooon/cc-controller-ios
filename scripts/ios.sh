#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
IOS="$ROOT/ios"
PROJECT="$IOS/CCController.xcodeproj"
DERIVED="$IOS/build"
RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-27-0"
DEFAULT_DEVICES=("iPhone 18 Pro" "iPhone 16 Plus" "iPhone SE (3rd generation)")
STARTED_DAEMON=""
FIXTURE_OUT=""

step() {
  local name=$1; shift
  local started=$SECONDS
  printf '%s\n' "[$name]"
  "$@"
  printf '%s\n' "[$name] $((SECONDS - started))s"
}

json_value() {
  node -e 'const fs=require("node:fs"); const value=JSON.parse(fs.readFileSync(process.argv[1], "utf8")); console.log(value[process.argv[2]]);' "$1" "$2"
}

cleanup_shots() {
  if [[ -n "$STARTED_DAEMON" ]] && kill -0 "$STARTED_DAEMON" 2>/dev/null; then
    kill -TERM "$STARTED_DAEMON" 2>/dev/null || true
    for _ in {1..50}; do kill -0 "$STARTED_DAEMON" 2>/dev/null || break; sleep 0.1; done
    kill -KILL "$STARTED_DAEMON" 2>/dev/null || true
    wait "$STARTED_DAEMON" 2>/dev/null || true
  fi
  if [[ -n "$FIXTURE_OUT" ]]; then rm -f "$FIXTURE_OUT"; fi
  while read -r udid; do
    [[ -z "$udid" ]] || xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  done < <(xcrun simctl list devices -j | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{for(const devices of Object.values(JSON.parse(d).devices)){for(const x of devices){if(x.name.startsWith("cc-")&&x.state==="Booted") console.log(x.udid)}}})')
}

ensure_device() {
  local device=$1
  local name="cc-$device"
  local udid
  udid=$(xcrun simctl list devices -j | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{for(const devices of Object.values(JSON.parse(d).devices)){for(const x of devices){if(x.name===process.argv[1]){console.log(x.udid);process.exit(0)}}}})' "$name")
  if [[ -z "$udid" ]]; then
    udid=$(xcrun simctl create "$name" "$device" "$RUNTIME")
    printf '%s\n' "created $name"
  else
    printf '%s\n' "reusing $name"
  fi
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
  printf '%s\n' "$udid"
}

cmd_generate() {
  mkdir -p "$IOS/Config"
  touch "$IOS/Config/Signing.local.xcconfig"
  swift "$IOS/Scripts/render-icon.swift"
  xcodegen generate --spec "$IOS/project.yml" --project "$IOS"
}

cmd_build() {
  [[ -d "$PROJECT" ]] || cmd_generate
  xcodebuild -project "$PROJECT" -scheme CCController -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO build
}

cmd_test() {
  if [[ -d "$IOS/CCKit" ]]; then
    (cd "$IOS/CCKit" && swift test)
  else
    printf '%s\n' 'No ios/CCKit yet; skipping package tests.'
  fi
}

cmd_shots() {
  local devices=() only=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --device) devices+=("$2"); shift 2;;
      --only) only=$2; shift 2;;
      *) printf 'unknown shots option: %s\n' "$1" >&2; exit 2;;
    esac
  done
  [[ ${#devices[@]} -gt 0 ]] || devices=("${DEFAULT_DEVICES[@]}")
  rm -rf "$IOS/shots"
  mkdir -p "$IOS/shots"
  FIXTURE_OUT=$(mktemp -t cc-controller-fixture.XXXXXX)
  local fixture_started=$SECONDS
  node "$ROOT/scripts/fixture-daemon.mjs" --scenario default --out "$FIXTURE_OUT" >"$IOS/shots/fixture-daemon.log" 2>&1 &
  STARTED_DAEMON=$!
  printf '%s\n' "[fixture] $((SECONDS - fixture_started))s (pid $STARTED_DAEMON)"
  for _ in {1..100}; do [[ -s "$FIXTURE_OUT" ]] && break; sleep 0.1; done
  [[ -s "$FIXTURE_OUT" ]] || { printf '%s\n' 'fixture daemon did not become ready' >&2; exit 1; }
  local web_port bearer host_ip
  web_port=$(json_value "$FIXTURE_OUT" webPort)
  bearer=$(json_value "$FIXTURE_OUT" bearer)
  host_ip=$(ipconfig getifaddr en0 2>/dev/null || printf '127.0.0.1')
  local index_file="$IOS/shots/index.html"
  printf '%s\n' '<!doctype html><meta charset="utf-8"><title>cc-controller iOS shots</title><style>body{font:15px system-ui;background:#121110;color:#eee;margin:24px}main{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:20px}figure{margin:0}img{display:block;max-width:100%;border-radius:16px}figcaption{padding-top:8px;color:#bbb}</style><main>' > "$index_file"
  trap cleanup_shots EXIT
  for device in "${devices[@]}"; do
    local udid result exported
    udid=$(ensure_device "$device" | tail -1)
    xcrun simctl ui "$udid" appearance light
    result="$IOS/build/CCController-$(echo "$device" | tr ' ()' '---').xcresult"
    exported="$IOS/shots/$(echo "$device" | tr ' ()' '---')"
    rm -rf "$result" "$exported"
    mkdir -p "$exported"
    local args=(xcodebuild -project "$PROJECT" -scheme CCController -destination "id=$udid" -derivedDataPath "$DERIVED" -resultBundlePath "$result" -only-testing:CCControllerUITests/ScreenshotTests test)
    [[ -z "$only" ]] || args+=("-only-testing:CCControllerUITests/ScreenshotTests/testSessionsAndSelectedSessionScreens")
    TEST_RUNNER_SERVER_URL="http://$host_ip:$web_port" TEST_RUNNER_BEARER="$bearer" TEST_RUNNER_ONLY="$only" step "shots $device" "${args[@]}"
    xcrun xcresulttool export attachments --path "$result" --output-path "$exported" --filter '*.png'
    local manifest="$exported/manifest.json"
    if [[ -f "$manifest" ]]; then
      node -e 'const fs=require("node:fs");const p=process.argv[1],d=JSON.parse(fs.readFileSync(p));for(const a of d.attachments??[]){const n=a.suggestedHumanReadableName||a.filename;if(!n.endsWith(".png"))continue;const old=a.exportedFilePath||a.filename;const src=require("node:path").join(require("node:path").dirname(p),old);const dst=require("node:path").join(require("node:path").dirname(p),n.endsWith(".png")?n:`${n}.png`);if(fs.existsSync(src)&&src!==dst)fs.renameSync(src,dst);}' "$manifest"
    fi
    find "$exported" -maxdepth 1 -type f -name '*.png' -print | while read -r png; do
      local base="$(basename "$png")"
      printf '<figure><img src="%s/%s"><figcaption>%s · %s</figcaption></figure>\n' "$(basename "$exported")" "$base" "$device" "$base" >> "$index_file"
    done
  done
  printf '%s\n' '</main>' >> "$index_file"
  printf '%s\n' "shots written to $IOS/shots"
}

case "${1:-}" in
  generate) shift; step generate cmd_generate "$@";;
  build) shift; step build cmd_build "$@";;
  test) shift; step test cmd_test "$@";;
  shots) shift; cmd_shots "$@";;
  clean) shift; step clean rm -rf "$DERIVED"; xcrun simctl list devices -j | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{for(const devices of Object.values(JSON.parse(d).devices)){for(const x of devices){if(x.name.startsWith("cc-"))process.stdout.write(x.udid+"\n")}}})' | while read -r udid; do xcrun simctl delete "$udid"; done;;
  install) printf '%s\n' 'install requires a DEVELOPMENT_TEAM and a paired physical device; no install was attempted.' >&2; exit 2;;
  *) printf 'Usage: %s {generate|build|test|shots|clean|install}\n' "$0" >&2; exit 2;;
esac
