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
FIXTURE_LOG=""
RUN_DIR=""
DIAG_DIR=""
MOCK_PREFIX=""
MOCK_RUN_DIR=""
MOCK_DEVICE_NAMES=()
SHOT_PREFIX="cc-"
SHOT_DEVICE_NAMES=("cc-iPhone 18 Pro" "cc-iPhone 16 Plus" "cc-iPhone SE (3rd generation)")

step() {
  local name=$1; shift
  local started=$SECONDS
  local status=0
  printf '%s\n' "[$name]"
  "$@" || status=$?
  printf '%s\n' "[$name] $((SECONDS - started))s"
  return "$status"
}

json_value() {
  node -e 'const fs=require("node:fs"); const value=JSON.parse(fs.readFileSync(process.argv[1], "utf8")); console.log(value[process.argv[2]]);' "$1" "$2"
}

validate_mock_screens() {
  local selection=$1
  [[ -z "$selection" ]] && return 0
  local valid=",sessions,sessions-empty,sessions-offline,sessions-reconnecting,session-idle,session-working,session-approvals,session-terminal-approval,composer-slash,composer-attachments,composer-keyboard,tool-detail,tool-detail-edit,subagent,inspector,settings,onboarding-welcome,onboarding-connect,onboarding-pair,onboarding-faceid,lock,privacy-cover,"
  local item
  local items=()
  IFS=, read -r -a items <<< "$selection"
  for item in "${items[@]}"; do
    if [[ "$valid" != *",$item,"* ]]; then
      printf 'unknown mock screen id: %s\n' "$item" >&2
      return 2
    fi
  done
}

simulator_udids() {
  local mode=$1
  local state=$2
  shift 2
  xcrun simctl list devices -j | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const mode=process.argv[1],state=process.argv[2],values=new Set(process.argv.slice(3));for(const devices of Object.values(JSON.parse(d).devices)){for(const x of devices){const matchesState=state==="all"||x.state===state;const matchesName=mode==="exact"?values.has(x.name):x.name.startsWith(process.argv[3]);if(matchesState&&matchesName) console.log(x.udid)}}})' "$mode" "$state" "$@"
}

configure_keyboard() {
  local udid=$1
  xcrun simctl spawn "$udid" defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true
}

cleanup_shots() {
  if [[ -n "$STARTED_DAEMON" ]] && kill -0 "$STARTED_DAEMON" 2>/dev/null; then
    kill -TERM "$STARTED_DAEMON" 2>/dev/null || true
    for _ in {1..50}; do kill -0 "$STARTED_DAEMON" 2>/dev/null || break; sleep 0.1; done
    kill -KILL "$STARTED_DAEMON" 2>/dev/null || true
    wait "$STARTED_DAEMON" 2>/dev/null || true
  fi
  if [[ -n "$FIXTURE_OUT" ]]; then rm -f "$FIXTURE_OUT"; fi
  if [[ -n "$DIAG_DIR" ]]; then
    mkdir -p "$DIAG_DIR"
    if [[ -n "$FIXTURE_LOG" ]]; then
      cp "$FIXTURE_LOG" "$DIAG_DIR/fixture-daemon.log" 2>/dev/null || true
    fi
    while read -r udid; do
      [[ -z "$udid" ]] || xcrun simctl spawn "$udid" log show --last 10m --style compact --predicate 'subsystem == "com.example.cc-controller"' > "$DIAG_DIR/app-$udid.log" 2>&1 || true
    done < <(
      if [[ ${#SHOT_DEVICE_NAMES[@]} -eq 0 ]]; then
        simulator_udids prefix Booted "$SHOT_PREFIX"
      else
        simulator_udids exact Booted "${SHOT_DEVICE_NAMES[@]}"
      fi
    )
    mkdir -p "$DIAG_DIR/attachments"
    for result in "$IOS"/build/*.xcresult; do
      [[ -d "$result" ]] || continue
      xcrun xcresulttool export attachments --path "$result" --output-path "$DIAG_DIR/attachments" >/dev/null 2>&1 || true
    done
  fi
  if [[ -n "$RUN_DIR" ]]; then rm -rf "$RUN_DIR"; fi
  while read -r udid; do
    [[ -z "$udid" ]] || xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  done < <(
    if [[ ${#SHOT_DEVICE_NAMES[@]} -eq 0 ]]; then
      simulator_udids prefix Booted "$SHOT_PREFIX"
    else
      simulator_udids exact Booted "${SHOT_DEVICE_NAMES[@]}"
    fi
  )
  return 0
}

ensure_device() {
  local device=$1
  local name="$SHOT_PREFIX$device"
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
  configure_keyboard "$udid"
  xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
  xcrun simctl uninstall "$udid" com.example.cc-controller >/dev/null 2>&1 || true
  printf '%s\n' "$udid"
}

cmd_generate() {
  mkdir -p "$IOS/Config"
  touch "$IOS/Config/Signing.local.xcconfig"
  swift "$IOS/Scripts/render-icon.swift"
  xcodegen generate --spec "$IOS/project.yml" --project "$IOS"
}

cmd_build() {
  cmd_generate
  xcodebuild -project "$PROJECT" -scheme CCController -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
}

cmd_test() {
  cmd_generate
  if [[ -d "$IOS/CCKit" ]]; then
    (cd "$IOS/CCKit" && swift test)
  else
    printf '%s\n' 'No ios/CCKit yet; skipping package tests.'
  fi
}

cmd_shots() {
  cmd_generate
  local devices=() only=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --device) devices+=("$2"); shift 2;;
      --only) only=$2; shift 2;;
      *) printf 'unknown shots option: %s\n' "$1" >&2; exit 2;;
    esac
  done
  [[ ${#devices[@]} -gt 0 ]] || devices=("${DEFAULT_DEVICES[@]}")
  local lane="${CC_MOCK_LANE:-}"
  if [[ -n "$lane" ]]; then
    SHOT_PREFIX="ccshot-$lane-"
    SHOT_DEVICE_NAMES=()
  else
    SHOT_PREFIX="cc-"
    SHOT_DEVICE_NAMES=("cc-iPhone 18 Pro" "cc-iPhone 16 Plus" "cc-iPhone SE (3rd generation)")
  fi
  mkdir -p "$IOS/shots"
  rm -f "$IOS/shots/index.html" "$IOS/shots/fixture-daemon.log"
  for device in "${DEFAULT_DEVICES[@]}" "${devices[@]}"; do
    rm -rf "$IOS/shots/$(echo "$device" | tr ' ()' '---')"
  done
  RUN_DIR=$(mktemp -d -t cc-controller-shot-run.XXXXXX)
  DIAG_DIR="$IOS/build/diag"
  mkdir -p "$DIAG_DIR"
  FIXTURE_OUT=$(mktemp -t cc-controller-fixture.XXXXXX)
  FIXTURE_LOG="$IOS/shots/fixture-daemon.log"
  local fixture_started=$SECONDS
  node "$ROOT/scripts/fixture-daemon.mjs" --scenario default --out "$FIXTURE_OUT" >"$FIXTURE_LOG" 2>&1 &
  STARTED_DAEMON=$!
  printf '%s\n' "[fixture] $((SECONDS - fixture_started))s (pid $STARTED_DAEMON)"
  for _ in {1..100}; do [[ -s "$FIXTURE_OUT" ]] && break; sleep 0.1; done
  [[ -s "$FIXTURE_OUT" ]] || { printf '%s\n' 'fixture daemon did not become ready' >&2; exit 1; }
  local web_port bearer
  web_port=$(json_value "$FIXTURE_OUT" webPort)
  bearer=$(json_value "$FIXTURE_OUT" bearer)
  local index_file="$IOS/shots/index.html"
  printf '%s\n' '<!doctype html><meta charset="utf-8"><title>cc-controller iOS shots</title><style>body{font:15px system-ui;background:#121110;color:#eee;margin:24px}main{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:20px}figure{margin:0}img{display:block;max-width:100%;border-radius:16px}figcaption{padding-top:8px;color:#bbb}</style><main>' > "$index_file"
  trap 'status=$?; cleanup_shots; exit "$status"' EXIT
  for device in "${devices[@]}"; do
    local udid result exported output_dir
    udid=$(ensure_device "$device" | tail -1)
    xcrun simctl ui "$udid" appearance light
    result="$IOS/build/CCController-$(echo "$device" | tr ' ()' '---').xcresult"
    exported="$RUN_DIR/$(echo "$device" | tr ' ()' '---')"
    output_dir="$IOS/shots/$(echo "$device" | tr ' ()' '---')"
    rm -rf "$result" "$exported" "$output_dir"
    mkdir -p "$exported" "$output_dir"
    local args=(xcodebuild -project "$PROJECT" -scheme CCController -destination "id=$udid" -derivedDataPath "$DERIVED" -resultBundlePath "$result" -only-testing:CCControllerUITests/ScreenshotTests test)
    [[ -z "$only" ]] || args+=("-only-testing:CCControllerUITests/ScreenshotTests/testSessionsAndSelectedSessionScreens")
    TEST_RUNNER_SERVER_URL="http://127.0.0.1:$web_port" TEST_RUNNER_BEARER="$bearer" TEST_RUNNER_ONLY="$only" step "shots $device" "${args[@]}"
    xcrun xcresulttool export attachments --path "$result" --output-path "$exported" --filter '*.png'
    local manifest="$exported/manifest.json"
    if [[ -f "$manifest" ]]; then
      node -e 'const fs=require("node:fs");const path=require("node:path");const p=process.argv[1],dir=path.dirname(p),d=JSON.parse(fs.readFileSync(p)),attachments=Array.isArray(d)?d.flatMap((entry)=>entry.attachments??[]):d.attachments??[];for(const a of attachments){const suggested=a.suggestedHumanReadableName||a.filename||"";if(!suggested.toLowerCase().endsWith(".png"))continue;const name=suggested.replace(/_[0-9]+_[0-9a-f-]+\.png$/i,".png");const old=a.exportedFileName||a.exportedFilePath||a.filename;const src=path.join(dir,old);const dst=path.join(dir,name);if(fs.existsSync(src)&&src!==dst)fs.renameSync(src,dst);}' "$manifest"
    fi
    find "$exported" -maxdepth 1 -type f -name '*.png' -exec cp {} "$output_dir" \;
    find "$output_dir" -maxdepth 1 -type f -name '*.png' -print | while read -r png; do
      local base="$(basename "$png")"
      printf '<figure><img src="%s/%s"><figcaption>%s · %s</figcaption></figure>\n' "$(basename "$output_dir")" "$base" "$device" "$base" >> "$index_file"
    done
  done
  printf '%s\n' '</main>' >> "$index_file"
  printf '%s\n' "shots written to $IOS/shots"
}

cmd_flows() {
  cmd_generate
  local devices=() test_filter=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --device)
        [[ $# -ge 2 ]] || { printf '%s\n' 'flows --device requires a value' >&2; exit 2; }
        devices+=("$2")
        shift 2
        ;;
      --test)
        [[ $# -ge 2 ]] || { printf '%s\n' 'flows --test requires a value' >&2; exit 2; }
        test_filter=$2
        shift 2
        ;;
      *) printf 'unknown flows option: %s\n' "$1" >&2; exit 2;;
    esac
  done
  [[ ${#devices[@]} -gt 0 ]] || devices=("iPhone 16 Plus")

  local flow_file
  local flow_files=()
  local flow_classes=()
  while IFS= read -r flow_file; do
    [[ -z "$flow_file" ]] || {
      flow_files+=("$flow_file")
      flow_classes+=("$(basename "$flow_file" .swift)")
    }
  done < <(find "$IOS/UITests" -type f -name '*FlowTests.swift' -print | sort)
  if [[ ${#flow_files[@]} -eq 0 ]]; then
    printf '%s\n' 'no flow tests found'
    return 0
  fi

  local selector_class=${test_filter%%/*}
  if [[ -n "$test_filter" ]]; then
    local found=0
    for flow_class in "${flow_classes[@]}"; do
      [[ "$flow_class" == "$selector_class" ]] || continue
      found=1
      break
    done
    if [[ $found -eq 0 ]]; then
      printf 'unknown flow test class: %s\n' "$selector_class" >&2
      return 2
    fi
  fi

  local lane="${CC_MOCK_LANE:-}"
  if [[ -n "$lane" ]]; then
    SHOT_PREFIX="ccshot-$lane-"
    SHOT_DEVICE_NAMES=()
  else
    SHOT_PREFIX="cc-"
    SHOT_DEVICE_NAMES=("cc-iPhone 18 Pro" "cc-iPhone 16 Plus" "cc-iPhone SE (3rd generation)")
  fi

  mkdir -p "$IOS/shots/flows"
  rm -rf "$IOS/shots/flows"
  mkdir -p "$IOS/shots/flows"
  RUN_DIR=$(mktemp -d -t cc-controller-flow-run.XXXXXX)
  DIAG_DIR="$IOS/build/diag"
  mkdir -p "$DIAG_DIR"
  FIXTURE_OUT=$(mktemp -t cc-controller-fixture.XXXXXX)
  FIXTURE_LOG="$RUN_DIR/fixture-daemon.log"
  trap 'status=$?; cleanup_shots; exit "$status"' EXIT
  local fixture_started=$SECONDS
  node "$ROOT/scripts/fixture-daemon.mjs" --scenario default --out "$FIXTURE_OUT" >"$FIXTURE_LOG" 2>&1 &
  STARTED_DAEMON=$!
  printf '%s\n' "[fixture] $((SECONDS - fixture_started))s (pid $STARTED_DAEMON)"
  for _ in {1..100}; do [[ -s "$FIXTURE_OUT" ]] && break; sleep 0.1; done
  [[ -s "$FIXTURE_OUT" ]] || { printf '%s\n' 'fixture daemon did not become ready' >&2; exit 1; }
  local web_port bearer
  web_port=$(json_value "$FIXTURE_OUT" webPort)
  bearer=$(json_value "$FIXTURE_OUT" bearer)

  for flow_file in "${flow_files[@]}"; do
    local flow_class
    flow_class=$(basename "$flow_file" .swift)
    [[ -z "$test_filter" || "$selector_class" == "$flow_class" ]] || continue
    for device in "${devices[@]}"; do
      local udid result exported output_dir device_key
      udid=$(ensure_device "$device" | tail -1)
      xcrun simctl ui "$udid" appearance light
      device_key=$(echo "$device" | tr ' ()' '---')
      result="$IOS/build/Flow-$flow_class-$device_key.xcresult"
      exported="$RUN_DIR/$flow_class-$device_key"
      output_dir="$IOS/shots/flows/$device_key"
      rm -rf "$result" "$exported"
      mkdir -p "$exported" "$output_dir"
      local selector="${flow_class}"
      [[ -z "$test_filter" ]] || selector=$test_filter
      local args=(xcodebuild -project "$PROJECT" -scheme CCController -destination "id=$udid" -derivedDataPath "$DERIVED" -resultBundlePath "$result" "-only-testing:CCControllerUITests/$selector" test)
      TEST_RUNNER_SERVER_URL="http://127.0.0.1:$web_port" TEST_RUNNER_BEARER="$bearer" step "flows $flow_class $device" "${args[@]}"
      xcrun xcresulttool export attachments --path "$result" --output-path "$exported" >/dev/null
      local manifest="$exported/manifest.json"
      if [[ -f "$manifest" ]]; then
        node -e 'const fs=require("node:fs"),path=require("node:path"),p=process.argv[1],dir=path.dirname(p),d=JSON.parse(fs.readFileSync(p)),attachments=Array.isArray(d)?d.flatMap((entry)=>entry.attachments??[]):d.attachments??[];for(const a of attachments){const suggested=a.suggestedHumanReadableName||a.filename||"";const old=a.exportedFileName||a.exportedFilePath||a.filename;let name=suggested.replace(/_[0-9]+_[0-9a-f-]+\.(png|txt)$/i,".$1");if(!path.extname(name))name+=path.extname(old);const src=path.join(dir,old),dst=path.join(dir,name);if(fs.existsSync(src)&&src!==dst)fs.renameSync(src,dst);}' "$manifest"
      fi
      find "$exported" -maxdepth 1 -type f -name '*.png' -exec cp {} "$output_dir" \;
      find "$exported" -maxdepth 1 -type f -name '*.txt' -exec cp {} "$output_dir" \;
    done
  done
  printf '%s\n' "flow shots written to $IOS/shots/flows"
}

cmd_mocks() {
  local only=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --only) only=$2; shift 2;;
      *) printf 'unknown mocks option: %s\n' "$1" >&2; exit 2;;
    esac
  done
  validate_mock_screens "$only"

  cmd_generate
  local lane="${CC_MOCK_LANE:-}"
  MOCK_PREFIX="ccmock-"
  if [[ -n "$lane" ]]; then
    MOCK_PREFIX="ccmock-$lane-"
    MOCK_DEVICE_NAMES=()
  else
    MOCK_DEVICE_NAMES=("ccmock-iPhone 16 Plus" "ccmock-iPhone 18 Pro")
  fi
  local mock_root="$IOS/shots/mocks"
  if [[ -n "$lane" ]]; then mock_root="$mock_root/$lane"; fi
  if [[ -n "$lane" ]]; then DERIVED="$IOS/build/mock-derived-$lane"; else DERIVED="$IOS/build"; fi
  MOCK_RUN_DIR=$(mktemp -d -t cc-controller-mock-run.XXXXXX)
  rm -rf "$mock_root"
  mkdir -p "$mock_root"

  cleanup_mocks() {
    rm -rf "$MOCK_RUN_DIR"
    if [[ ${#MOCK_DEVICE_NAMES[@]} -eq 0 ]]; then
      while read -r udid; do
        [[ -z "$udid" ]] || xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
      done < <(simulator_udids prefix Booted "$MOCK_PREFIX")
    else
      while read -r udid; do
        [[ -z "$udid" ]] || xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
      done < <(simulator_udids exact Booted "${MOCK_DEVICE_NAMES[@]}")
    fi
  }
  trap 'status=$?; cleanup_mocks; exit "$status"' EXIT

  ensure_mock_device() {
    local device=$1
    local name="$MOCK_PREFIX$device"
    local udid
    udid=$(xcrun simctl list devices -j | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{for(const devices of Object.values(JSON.parse(d).devices)){for(const x of devices){if(x.name===process.argv[1]){process.stdout.write(x.udid);process.exit(0)}}}})' "$name")
    if [[ -z "$udid" ]]; then
      udid=$(xcrun simctl create "$name" "$device" "$RUNTIME")
      printf '%s\n' "created $name" >&2
    else
      printf '%s\n' "reusing $name" >&2
    fi
    xcrun simctl boot "$udid" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$udid" -b >/dev/null
    xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
    xcrun simctl uninstall "$udid" com.example.cc-controller >/dev/null 2>&1 || true
    printf '%s\n' "$udid"
  }

  rm -rf "$DERIVED"
  step build cmd_build

  local audit="$mock_root/audit.txt"
  : > "$audit"
  local device
  for device in "iPhone 16 Plus" "iPhone 18 Pro"; do
    local udid result exported output_dir device_derived
    udid=$(ensure_mock_device "$device")
    result="$IOS/build/MockScreenshot-$(echo "$device" | tr ' ()' '---').xcresult"
    exported="$MOCK_RUN_DIR/$(echo "$device" | tr ' ()' '---')"
    output_dir="$mock_root/$(echo "$device" | tr ' ()' '---')"
    device_derived="$DERIVED/mock-derived-$(echo "$device" | tr ' ()' '---')"
    rm -rf "$result" "$exported" "$output_dir" "$device_derived"
    mkdir -p "$exported" "$output_dir"
    local args=(xcodebuild -project "$PROJECT" -scheme CCController -destination "id=$udid" -derivedDataPath "$device_derived" -resultBundlePath "$result" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -only-testing:CCControllerUITests/MockScreenshotTests test)
    TEST_RUNNER_MOCKS="$only" step "mocks $device" "${args[@]}"
    xcrun xcresulttool export attachments --path "$result" --output-path "$exported" >/dev/null
    local manifest="$exported/manifest.json"
    node -e 'const fs=require("node:fs"),path=require("node:path"),p=process.argv[1],dir=path.dirname(p),d=JSON.parse(fs.readFileSync(p)),attachments=Array.isArray(d)?d.flatMap((entry)=>entry.attachments??[]):d.attachments??[];for(const a of attachments){const suggested=a.suggestedHumanReadableName||a.filename||"";const name=suggested.replace(/_[0-9]+_[0-9a-f-]+\.(png|txt)$/i,".$1");const old=a.exportedFileName||a.exportedFilePath||a.filename;const src=path.join(dir,old),dst=path.join(dir,name);if(fs.existsSync(src)&&src!==dst)fs.renameSync(src,dst);}' "$manifest"
    find "$exported" -maxdepth 1 -type f -name '*.png' -exec cp {} "$output_dir" \;
    if [[ -f "$exported/audit.txt" ]]; then
      printf '## %s\n' "$device" >> "$audit"
      cat "$exported/audit.txt" >> "$audit"
      printf '\n' >> "$audit"
    fi
    for scheme in light dark; do
      local images=()
      while IFS= read -r image; do images+=("$image"); done < <(find "$output_dir" -maxdepth 1 -type f -name "*-$scheme-*.png" | sort)
      if [[ ${#images[@]} -gt 0 ]]; then
        swift "$IOS/Scripts/contact-sheet.swift" "$mock_root/contact-$(echo "$device" | tr ' ()' '---')-$scheme.png" "${images[@]}"
      fi
    done
  done
  printf '%s\n' "mock shots written to $mock_root"
}

cmd_clean() {
  step clean rm -rf "$DERIVED"
  while read -r udid; do
    [[ -z "$udid" ]] || xcrun simctl delete "$udid"
  done < <(simulator_udids exact all "cc-${DEFAULT_DEVICES[0]}" "cc-${DEFAULT_DEVICES[1]}" "cc-${DEFAULT_DEVICES[2]}")
}

cmd_install() {
  cmd_generate
  printf '%s\n' 'install requires a DEVELOPMENT_TEAM and a paired physical device; no install was attempted.' >&2
  return 2
}

case "${1:-}" in
  generate) shift; step generate cmd_generate "$@";;
  build) shift; step build cmd_build "$@";;
  test) shift; step test cmd_test "$@";;
  shots) shift; cmd_shots "$@";;
  flows) shift; cmd_flows "$@";;
  mocks) shift; cmd_mocks "$@";;
  clean) shift; cmd_clean "$@";;
  install) shift; cmd_install "$@";;
  *) printf 'Usage: %s {generate|build|test|shots|flows|mocks|clean|install}\n' "$0" >&2; exit 2;;
esac
