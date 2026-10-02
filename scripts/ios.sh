#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
IOS="$ROOT/ios"
PROJECT="$IOS/CCController.xcodeproj"
DERIVED="$IOS/build"
RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-27-0"
DEFAULT_DEVICES=("iPhone 18 Pro" "iPhone 16 Plus" "iPhone SE (3rd generation)")
POOL_DEVICE_TYPES=("iPhone 18 Pro" "iPhone 16 Plus" "iPhone SE (3rd generation)")
POOL_CACHE="${CC_IOS_POOL_CACHE:-$HOME/Library/Caches/cc-controller-ios-pool}"
POOL_IDLE_SECONDS=$((20 * 60))
POOL_WAIT_SECONDS=$((60 * 60))
POOL_SLOT=""
STARTED_DAEMON=""
FIXTURE_OUT=""
FIXTURE_LOG=""
FIXTURE_SIM_UDID=""
RUN_DIR=""
DIAG_DIR=""
MOCK_RUN_DIR=""

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

simulator_udid() {
  local name=$1
  local values
  values=$(simulator_udids exact all "$name")
  [[ -z "$values" ]] || printf '%s\n' "${values%%$'\n'*}"
}

simulator_state() {
  local udid=$1
  xcrun simctl list devices -j | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{for(const devices of Object.values(JSON.parse(d).devices)){for(const x of devices){if(x.udid===process.argv[1]){console.log(x.state);process.exit(0)}}}})' "$udid"
}

configure_keyboard() {
  local udid=$1
  xcrun simctl spawn "$udid" defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true
}

stop_fixture_daemon() {
  if [[ -n "$STARTED_DAEMON" ]] && kill -0 "$STARTED_DAEMON" 2>/dev/null; then
    kill -TERM "$STARTED_DAEMON" 2>/dev/null || true
    for _ in {1..50}; do kill -0 "$STARTED_DAEMON" 2>/dev/null || break; sleep 0.1; done
    kill -KILL "$STARTED_DAEMON" 2>/dev/null || true
    wait "$STARTED_DAEMON" 2>/dev/null || true
  fi
  STARTED_DAEMON=""
  if [[ -n "$FIXTURE_OUT" ]]; then
    rm -f "$FIXTURE_OUT"
    FIXTURE_OUT=""
  fi
}

start_fixture_daemon() {
  FIXTURE_LOG=$1
  FIXTURE_OUT=$(mktemp -t cc-controller-fixture.XXXXXX)
  CC_FIXTURE_SIM_UDID="$FIXTURE_SIM_UDID" node "$ROOT/scripts/fixture-daemon.mjs" --scenario default --out "$FIXTURE_OUT" >"$FIXTURE_LOG" 2>&1 &
  STARTED_DAEMON=$!
  for _ in {1..100}; do [[ -s "$FIXTURE_OUT" ]] && break; sleep 0.1; done
  if [[ ! -s "$FIXTURE_OUT" ]]; then
    printf '%s\n' 'fixture daemon did not become ready' >&2
    return 1
  fi
  return 0
}

pool_slot_dir() {
  printf '%s/slot-%s\n' "$POOL_CACHE" "$1"
}

pool_lock_dir() {
  printf '%s/lock\n' "$(pool_slot_dir "$1")"
}

pool_device_name() {
  printf 'ccpool-%s-%s\n' "$1" "$2"
}

pool_last_use_file() {
  local slot=$1
  local device=$2
  local key
  key=$(printf '%s' "$device" | tr ' ()' '---')
  printf '%s/last-use-%s\n' "$(pool_slot_dir "$slot")" "$key"
}

pool_marker_file() {
  local udid=$1
  printf '%s/media-%s-attachment.marker\n' "$POOL_CACHE" "$udid"
}

pool_lock_pid() {
  local slot=$1
  local file="$(pool_lock_dir "$slot")/pid"
  [[ -f "$file" ]] || return 1
  printf '%s' "$(<"$file")"
}

pool_lock_lane() {
  local slot=$1
  local file="$(pool_lock_dir "$slot")/lane"
  [[ -f "$file" ]] || printf '%s' 'unknown'
  [[ -f "$file" ]] && printf '%s' "$(<"$file")"
}

pool_clear_stale_lock() {
  local slot=$1
  local lock
  lock=$(pool_lock_dir "$slot")
  [[ -d "$lock" ]] || return 0
  local pid
  pid=$(pool_lock_pid "$slot" || true)
  if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
    rm -rf "$lock"
  fi
}

pool_holders() {
  local slot
  for slot in 1 2; do
    pool_clear_stale_lock "$slot"
    if [[ -d "$(pool_lock_dir "$slot")" ]]; then
      pool_lock_lane "$slot"
    fi
  done
}

pool_shutdown_other_devices() {
  local slot=$1
  local keep_udid=$2
  local device name udid state
  for device in "${POOL_DEVICE_TYPES[@]}"; do
    name=$(pool_device_name "$slot" "$device")
    udid=$(simulator_udid "$name" || true)
    [[ -z "$udid" || "$udid" == "$keep_udid" ]] && continue
    state=$(simulator_state "$udid" || true)
    if [[ "$state" == 'Booted' ]]; then
      printf '%s\n' "shutting down $name to keep slot $slot sequential" >&2
      xcrun simctl shutdown "$udid" >/dev/null
    fi
  done
}

pool_idle_cleanup() {
  local slot=$1
  local now=$SECONDS
  now=$(date +%s)
  local device name udid state marker last
  for device in "${POOL_DEVICE_TYPES[@]}"; do
    name=$(pool_device_name "$slot" "$device")
    udid=$(simulator_udid "$name" || true)
    [[ -z "$udid" ]] && continue
    marker=$(pool_last_use_file "$slot" "$device")
    [[ -f "$marker" ]] || continue
    last=$(<"$marker")
    [[ "$last" =~ ^[0-9]+$ ]] || continue
    (( now - last > POOL_IDLE_SECONDS )) || continue
    state=$(simulator_state "$udid" || true)
    if [[ "$state" == 'Booted' ]]; then
      printf '%s\n' "shutting down idle pool device $name"
      xcrun simctl shutdown "$udid" >/dev/null
    fi
  done
}

ensure_pool_devices() {
  local slot=$1
  mkdir -p "$POOL_CACHE" "$(pool_slot_dir "$slot")"
  local device name udid
  for device in "${POOL_DEVICE_TYPES[@]}"; do
    name=$(pool_device_name "$slot" "$device")
    udid=$(simulator_udid "$name" || true)
    if [[ -z "$udid" ]]; then
      udid=$(xcrun simctl create "$name" "$device" "$RUNTIME")
      printf '%s\n' "created $name ($udid)"
    fi
  done
}

pool_acquire() {
  [[ -n "$POOL_SLOT" ]] && return 0
  mkdir -p "$POOL_CACHE"
  local lane="${CC_MOCK_LANE:-${USER:-user}-$$}"
  local waited=0 slot lock holders message
  while (( waited <= POOL_WAIT_SECONDS )); do
    for slot in 1 2; do
      mkdir -p "$(pool_slot_dir "$slot")"
      pool_clear_stale_lock "$slot"
      lock=$(pool_lock_dir "$slot")
      if mkdir "$lock" 2>/dev/null; then
        printf '%s\n' "$$" > "$lock/pid"
        printf '%s\n' "$lane" > "$lock/lane"
        POOL_SLOT=$slot
        ensure_pool_devices "$slot"
        pool_idle_cleanup "$slot"
        printf '%s\n' "acquired simulator slot $slot for $lane"
        return 0
      fi
    done
    holders=()
    for slot in 1 2; do
      [[ -d "$(pool_lock_dir "$slot")" ]] && holders+=("$(pool_lock_lane "$slot")")
    done
    message=$(IFS=', '; printf '%s' "${holders[*]:-unknown}")
    if (( waited == 0 || waited % 60 == 0 )); then
      printf 'waiting for a simulator slot (held by %s)\n' "$message" >&2
    fi
    if (( waited == POOL_WAIT_SECONDS )); then
      printf 'timed out after 60 minutes waiting for a simulator slot (held by %s)\n' "$message" >&2
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

release_pool_slot() {
  [[ -z "$POOL_SLOT" ]] && return 0
  local slot=$POOL_SLOT
  local lock pid
  lock=$(pool_lock_dir "$slot")
  pid=$(pool_lock_pid "$slot" || true)
  if [[ "$pid" == "$$" ]]; then
    rm -rf "$lock"
  fi
  POOL_SLOT=""
}

pool_booted_udids() {
  [[ -n "$POOL_SLOT" ]] || return 0
  local device name udid state
  for device in "${POOL_DEVICE_TYPES[@]}"; do
    name=$(pool_device_name "$POOL_SLOT" "$device")
    udid=$(simulator_udid "$name" || true)
    [[ -z "$udid" ]] && continue
    state=$(simulator_state "$udid" || true)
    [[ "$state" == 'Booted' ]] && printf '%s\n' "$udid"
  done
}

ensure_pool_device() {
  local device=$1
  local name udid state
  name=$(pool_device_name "$POOL_SLOT" "$device")
  udid=$(simulator_udid "$name" || true)
  [[ -n "$udid" ]] || { printf 'pool device is missing: %s\n' "$name" >&2; return 1; }
  pool_shutdown_other_devices "$POOL_SLOT" "$udid"
  state=$(simulator_state "$udid" || true)
  if [[ "$state" != 'Booted' ]]; then
    printf '%s\n' "booting $name" >&2
    xcrun simctl boot "$udid" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$udid" -b >/dev/null
  else
    printf '%s\n' "reusing booted $name" >&2
  fi
  configure_keyboard "$udid"
  xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
  printf '%s\n' "$(date +%s)" > "$(pool_last_use_file "$POOL_SLOT" "$device")"
  printf '%s\n' "$udid"
}

reset_flow_state() {
  local udid=$1
  xcrun simctl keychain "$udid" reset
  xcrun simctl privacy "$udid" reset all com.example.cc-controller
  xcrun simctl uninstall "$udid" com.example.cc-controller >/dev/null 2>&1 || true
}

ensure_attachment_media() {
  local udid=$1
  local marker
  marker=$(pool_marker_file "$udid")
  [[ -f "$marker" ]] && return 0
  xcrun simctl addmedia "$udid" "$IOS/UITests/Fixtures/attachment.jpg"
  : > "$marker"
}

cleanup_run() {
  local status=$1
  stop_fixture_daemon || true
  if [[ -n "$DIAG_DIR" ]]; then
    mkdir -p "$DIAG_DIR"
    if [[ -n "$FIXTURE_LOG" ]]; then
      cp "$FIXTURE_LOG" "$DIAG_DIR/fixture-daemon.log" 2>/dev/null || true
    fi
    while read -r udid; do
      [[ -z "$udid" ]] || xcrun simctl spawn "$udid" log show --last 10m --style compact --predicate 'subsystem == "com.example.cc-controller"' > "$DIAG_DIR/app-$udid.log" 2>&1 || true
    done < <(pool_booted_udids)
    mkdir -p "$DIAG_DIR/attachments"
    for result in "$IOS"/build/*.xcresult; do
      [[ -d "$result" ]] || continue
      xcrun xcresulttool export attachments --path "$result" --output-path "$DIAG_DIR/attachments" >/dev/null 2>&1 || true
    done
  fi
  [[ -z "$RUN_DIR" ]] || rm -rf "$RUN_DIR"
  [[ -z "$MOCK_RUN_DIR" ]] || rm -rf "$MOCK_RUN_DIR"
  release_pool_slot || true
  return "$status"
}

cleanup_on_exit() {
  local status=$?
  trap - EXIT INT TERM
  cleanup_run "$status" || true
  exit "$status"
}

trap cleanup_on_exit EXIT
trap 'exit 130' INT TERM

cmd_generate() {
  mkdir -p "$IOS/Config"
  touch "$IOS/Config/Signing.local.xcconfig"
  swift "$IOS/Scripts/render-icon.swift"
  xcodegen generate --spec "$IOS/project.yml" --project "$IOS"
}

cmd_build() {
  cmd_generate
  xcodebuild -project "$PROJECT" -scheme CCController -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
}

cmd_test() {
  pool_acquire
  cmd_generate
  if [[ -d "$IOS/CCKit" ]]; then
    (cd "$IOS/CCKit" && swift test)
  else
    printf '%s\n' 'No ios/CCKit yet; skipping package tests.'
  fi
}

cmd_release_check() {
  cmd_generate
  local release_derived="$IOS/build/release"
  local app_bundle="$release_derived/Build/Products/Release-iphoneos/cc-controller.app"
  local binary="$app_bundle/cc-controller"
  step 'release-check build' xcodebuild -project "$PROJECT" -scheme CCController -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$release_derived" CODE_SIGNING_ALLOWED=NO build
  if [[ ! -d "$app_bundle" || ! -f "$binary" ]]; then
    printf 'release-check failed: missing app bundle at %s\n' "$app_bundle" >&2
    return 1
  fi

  local mock_resources=""
  mock_resources=$(find "$app_bundle" -type f \( -name 'sessions.json' -o -name 'judge-alignment.png' -o -name 'rollout.png' \) -print)
  if [[ -n "$mock_resources" ]]; then
    printf '%s\n' 'release-check failed: mock resources found in Release app:' >&2
    printf '%s\n' "$mock_resources" >&2
    return 1
  fi
  printf '%s\n' 'release-check resource listing: no mock resources'

  local mock_symbols=""
  mock_symbols=$(nm "$binary" 2>/dev/null | grep -E 'Mocks' || true)
  if [[ -z "$mock_symbols" ]]; then
    mock_symbols=$(strings "$binary" 2>/dev/null | grep -E 'Mocks' || true)
  fi
  if [[ -n "$mock_symbols" ]]; then
    printf '%s\n' 'release-check failed: compiled symbols containing Mocks:' >&2
    printf '%s\n' "$mock_symbols" >&2
    return 1
  fi
  printf '%s\n' 'release-check symbol listing: no Mocks symbols'
  printf 'release-check app size: %s\n' "$(du -sh "$app_bundle" | awk '{print $1}')"
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
  if [[ -n "${CC_MOCK_LANE:-}" ]]; then
    DERIVED="$IOS/build/shot-derived-$CC_MOCK_LANE"
  fi
  pool_acquire
  local shot_root="$IOS/shots"
  if [[ -n "${CC_MOCK_LANE:-}" ]]; then shot_root="$shot_root/$CC_MOCK_LANE"; fi
  mkdir -p "$shot_root"
  rm -f "$shot_root/index.html" "$shot_root/fixture-daemon.log"
  for device in "${DEFAULT_DEVICES[@]}" "${devices[@]}"; do
    rm -rf "$shot_root/$(echo "$device" | tr ' ()' '---')"
  done
  RUN_DIR=$(mktemp -d -t cc-controller-shot-run.XXXXXX)
  DIAG_DIR="$IOS/build/diag"
  mkdir -p "$DIAG_DIR"
  FIXTURE_LOG="$shot_root/fixture-daemon.log"
  local fixture_started=$SECONDS
  start_fixture_daemon "$FIXTURE_LOG"
  printf '%s\n' "[fixture] $((SECONDS - fixture_started))s (pid $STARTED_DAEMON)"
  local web_port bearer
  web_port=$(json_value "$FIXTURE_OUT" webPort)
  bearer=$(json_value "$FIXTURE_OUT" bearer)
  local index_file="$shot_root/index.html"
  printf '%s\n' '<!doctype html><meta charset="utf-8"><title>cc-controller iOS shots</title><style>body{font:15px system-ui;background:#121110;color:#eee;margin:24px}main{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:20px}figure{margin:0}img{display:block;max-width:100%;border-radius:16px}figcaption{padding-top:8px;color:#bbb}</style><main>' > "$index_file"
  for device in "${devices[@]}"; do
    local udid result exported output_dir
    udid=$(ensure_pool_device "$device")
    xcrun simctl ui "$udid" appearance light
    result="$DERIVED/CCController-$(echo "$device" | tr ' ()' '---').xcresult"
    exported="$RUN_DIR/$(echo "$device" | tr ' ()' '---')"
    output_dir="$shot_root/$(echo "$device" | tr ' ()' '---')"
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
  printf '%s\n' "shots written to $shot_root"
}

cmd_flows() {
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

  local flow_file flow_class flow_method
  local flow_files=() flow_methods=() flow_method_classes=()
  while IFS= read -r flow_file; do
    [[ -z "$flow_file" ]] && continue
    flow_class=$(basename "$flow_file" .swift)
    flow_files+=("$flow_file")
    while IFS= read -r flow_method; do
      [[ -z "$flow_method" ]] && continue
      flow_method_classes+=("$flow_class")
      flow_methods+=("$flow_method")
    done < <(sed -nE 's/^[[:space:]]*func[[:space:]]+(test[A-Za-z0-9_]*).*/\1/p' "$flow_file")
  done < <(find "$IOS/UITests" -type f \( -name '*FlowTests.swift' -o -name 'SmokeFlowTests.swift' \) -print | sort)
  if [[ ${#flow_files[@]} -eq 0 ]]; then
    printf '%s\n' 'no flow tests found'
    return 0
  fi
  if [[ ${#flow_methods[@]} -eq 0 ]]; then
    printf '%s\n' 'no flow test methods found'
    return 0
  fi
  pool_acquire

  local selector_class="$test_filter" selector_method="" filter_has_method=0
  if [[ "$test_filter" == */* ]]; then
    filter_has_method=1
    selector_class=${test_filter%%/*}
    selector_method=${test_filter#*/}
  fi
  local selected_classes=() selected_methods=() selected_count=0
  local index
  for index in "${!flow_methods[@]}"; do
    flow_class=${flow_method_classes[$index]}
    flow_method=${flow_methods[$index]}
    [[ -z "$test_filter" || "$selector_class" == "$flow_class" ]] || continue
    [[ $filter_has_method -eq 0 || "$selector_method" == "$flow_method" ]] || continue
    selected_classes+=("$flow_class")
    selected_methods+=("$flow_method")
    selected_count=$((selected_count + 1))
  done
  if [[ -n "$test_filter" && $selected_count -eq 0 ]]; then
    printf 'unknown flow test: %s\n' "$test_filter" >&2
    return 2
  fi

  if [[ -n "${CC_MOCK_LANE:-}" ]]; then
    DERIVED="$IOS/build/flow-derived-$CC_MOCK_LANE"
  fi
  cmd_generate
  local flow_root="$IOS/shots/flows"
  local flow_build_root="$IOS/build/flows"
  if [[ -n "${CC_MOCK_LANE:-}" ]]; then
    flow_root="$flow_root/$CC_MOCK_LANE"
    flow_build_root="$flow_build_root-$CC_MOCK_LANE"
  fi
  mkdir -p "$flow_root"
  RUN_DIR=$(mktemp -d -t cc-controller-flow-run.XXXXXX)
  DIAG_DIR=""

  local build_args=(xcodebuild -project "$PROJECT" -scheme CCController -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build-for-testing)
  step 'flows build-for-testing' "${build_args[@]}"
  local app_bundle="$DERIVED/Build/Products/Debug-iphonesimulator/cc-controller.app"
  if [[ ! -d "$app_bundle" ]]; then
    printf 'build-for-testing did not produce %s\n' "$app_bundle" >&2
    return 1
  fi

  local summary_labels=() summary_results=() summary_seconds=() failed=0
  for index in "${!selected_methods[@]}"; do
    flow_class=${selected_classes[$index]}
    flow_method=${selected_methods[$index]}
    for device in "${devices[@]}"; do
      local method_started=$SECONDS
      local udid result exported output_dir device_key method_log
      local method_status=0 xcode_status=0 export_status=0
      device_key=$(echo "$device" | tr ' ()' '---')
      output_dir="$flow_root/$device_key/$flow_class/$flow_method"
      result="$flow_build_root/$device_key/$flow_class/$flow_method.xcresult"
      exported="$RUN_DIR/$device_key/$flow_class/$flow_method"
      method_log="$output_dir/xcodebuild.log"
      rm -rf "$output_dir" "$result" "$exported"
      mkdir -p "$output_dir" "$(dirname "$result")" "$exported"

      stop_fixture_daemon
      udid=$(ensure_pool_device "$device")
      FIXTURE_SIM_UDID="$udid"
      if [[ "$flow_class" == "AttachmentFlowTests" ]]; then
        ensure_attachment_media "$udid"
      fi
      xcrun simctl ui "$udid" appearance "${TEST_RUNNER_COLOR_SCHEME:-light}"
      reset_flow_state "$udid"
      if ! xcrun simctl install "$udid" "$app_bundle"; then
        printf '%s\n' 'failed to install the freshly built app' | tee "$method_log"
        method_status=1
      else
        printf 'installed %s\n' "$app_bundle" > "$method_log"
      fi

      local web_port bearer control_port
      if [[ $method_status -eq 0 ]] && start_fixture_daemon "$output_dir/fixture-daemon.log"; then
        web_port=$(json_value "$FIXTURE_OUT" webPort)
        bearer=$(json_value "$FIXTURE_OUT" bearer)
        control_port=$(json_value "$FIXTURE_OUT" controlPort)
        local args=(xcodebuild -project "$PROJECT" -scheme CCController -destination "id=$udid" -derivedDataPath "$DERIVED" -resultBundlePath "$result" "-only-testing:CCControllerUITests/$flow_class/$flow_method" -collect-test-diagnostics never test-without-building)
        if step "flows $flow_class/$flow_method $device" env \
          "CC_FLOW_OUTPUT_DIR=$output_dir" \
          "TEST_RUNNER_SERVER_URL=http://127.0.0.1:$web_port" \
          "TEST_RUNNER_BEARER=$bearer" \
          "TEST_RUNNER_FIXTURE_CONTROL_URL=http://127.0.0.1:$control_port" \
          "TEST_RUNNER_COLOR_SCHEME=${TEST_RUNNER_COLOR_SCHEME:-light}" \
          "${args[@]}" 2>&1 | tee -a "$method_log"; then
          xcode_status=0
        else
          xcode_status=$?
        fi
        stop_fixture_daemon
        if [[ -d "$result" ]]; then
          if xcrun xcresulttool export attachments --path "$result" --output-path "$exported" >/dev/null 2>&1; then
            local manifest="$exported/manifest.json"
            if [[ -f "$manifest" ]]; then
              node -e 'const fs=require("node:fs"),path=require("node:path"),p=process.argv[1],dir=path.dirname(p),d=JSON.parse(fs.readFileSync(p)),attachments=Array.isArray(d)?d.flatMap((entry)=>entry.attachments??[]):d.attachments??[];for(const a of attachments){const suggested=a.suggestedHumanReadableName||a.filename||"";const old=a.exportedFileName||a.exportedFilePath||a.filename;let name=suggested.replace(/_[0-9]+_[0-9a-f-]+\.(png|txt)$/i,".$1");if(!path.extname(name))name+=path.extname(old);const src=path.join(dir,old),dst=path.join(dir,name);if(fs.existsSync(src)&&src!==dst)fs.renameSync(src,dst);}' "$manifest"
            fi
            find "$exported" -maxdepth 1 -type f -name '*.png' -exec cp {} "$output_dir" \;
            find "$exported" -maxdepth 1 -type f -name '*.txt' -exec cp {} "$output_dir" \;
          else
            printf '%s\n' 'failed to export result attachments' | tee -a "$method_log"
            export_status=1
          fi
        else
          printf '%s\n' 'xcodebuild produced no result bundle' | tee -a "$method_log"
          export_status=1
        fi
      else
        printf '%s\n' 'fixture daemon failed to become ready' | tee -a "$method_log"
        method_status=1
        stop_fixture_daemon
      fi
      [[ $xcode_status -eq 0 ]] || method_status=1
      [[ $export_status -eq 0 ]] || method_status=1
      local elapsed=$((SECONDS - method_started))
      local result_label=PASS
      if [[ $method_status -ne 0 ]]; then
        result_label=FAIL
        failed=$((failed + 1))
      fi
      summary_labels+=("$flow_class/$flow_method [$device]")
      summary_results+=("$result_label")
      summary_seconds+=("$elapsed")
    done
  done

  printf '\nFlow summary\n'
  printf '%-70s %-8s %8s\n' 'class/method [device]' 'result' 'seconds'
  for index in "${!summary_labels[@]}"; do
    printf '%-70s %-8s %8s\n' "${summary_labels[$index]}" "${summary_results[$index]}" "${summary_seconds[$index]}"
  done
  if [[ $failed -ne 0 ]]; then
    printf '%s\n' "$failed flow method(s) failed" >&2
    return 1
  fi
  printf '%s\n' "flow shots written to $flow_root"
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
  pool_acquire
  local mock_root="$IOS/shots/mocks"
  if [[ -n "${CC_MOCK_LANE:-}" ]]; then mock_root="$mock_root/$CC_MOCK_LANE"; fi
  if [[ -n "${CC_MOCK_LANE:-}" ]]; then DERIVED="$IOS/build/mock-derived-$CC_MOCK_LANE"; else DERIVED="$IOS/build"; fi
  MOCK_RUN_DIR=$(mktemp -d -t cc-controller-mock-run.XXXXXX)
  rm -rf "$mock_root"
  mkdir -p "$mock_root"

  rm -rf "$DERIVED"
  step build cmd_build

  local audit="$mock_root/audit.txt"
  : > "$audit"
  local device
  for device in "iPhone 16 Plus" "iPhone 18 Pro"; do
    local udid result exported output_dir device_derived
    udid=$(ensure_pool_device "$device")
    result="$DERIVED/MockScreenshot-$(echo "$device" | tr ' ()' '---').xcresult"
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

pool_status() {
  mkdir -p "$POOL_CACHE"
  local slot device name udid state marker last display lane
  for slot in 1 2; do
    pool_clear_stale_lock "$slot"
    if [[ -d "$(pool_lock_dir "$slot")" ]]; then
      lane=$(pool_lock_lane "$slot")
      printf 'slot %s holder=%s pid=%s\n' "$slot" "$lane" "$(pool_lock_pid "$slot")"
    else
      printf 'slot %s holder=free\n' "$slot"
    fi
    for device in "${POOL_DEVICE_TYPES[@]}"; do
      name=$(pool_device_name "$slot" "$device")
      udid=$(simulator_udid "$name" || true)
      state=missing
      [[ -z "$udid" ]] || state=$(simulator_state "$udid" || printf 'unknown')
      marker=$(pool_last_use_file "$slot" "$device")
      if [[ -f "$marker" ]]; then
        last=$(<"$marker")
        display=$(date -r "$last" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$last")
      else
        display=never
      fi
      printf '  %s udid=%s state=%s last-use=%s\n' "$name" "${udid:-missing}" "$state" "$display"
    done
  done
}

pool_down() {
  local slot device name udid state
  for slot in 1 2; do
    pool_clear_stale_lock "$slot"
    if [[ -d "$(pool_lock_dir "$slot")" ]]; then
      printf 'cannot pool down: slot %s is held by %s\n' "$slot" "$(pool_lock_lane "$slot")" >&2
      return 1
    fi
  done
  for slot in 1 2; do
    for device in "${POOL_DEVICE_TYPES[@]}"; do
      name=$(pool_device_name "$slot" "$device")
      udid=$(simulator_udid "$name" || true)
      [[ -z "$udid" ]] && continue
      state=$(simulator_state "$udid" || true)
      if [[ "$state" == 'Booted' ]]; then
        xcrun simctl shutdown "$udid" >/dev/null
        printf '%s\n' "shut down $name"
      fi
    done
  done
}

pool_reset() {
  local slot device name udid
  for slot in 1 2; do
    pool_clear_stale_lock "$slot"
    if [[ -d "$(pool_lock_dir "$slot")" ]]; then
      printf 'cannot pool reset: slot %s is held by %s\n' "$slot" "$(pool_lock_lane "$slot")" >&2
      return 1
    fi
  done
  for slot in 1 2; do
    for device in "${POOL_DEVICE_TYPES[@]}"; do
      name=$(pool_device_name "$slot" "$device")
      udid=$(simulator_udid "$name" || true)
      [[ -z "$udid" ]] && continue
      xcrun simctl delete "$udid"
      rm -f "$(pool_last_use_file "$slot" "$device")" "$(pool_marker_file "$udid")"
      printf '%s\n' "deleted $name ($udid)"
    done
    rmdir "$(pool_slot_dir "$slot")" 2>/dev/null || true
  done
}

cmd_pool() {
  case "${1:-}" in
    status) shift; pool_status "$@";;
    down) shift; pool_down "$@";;
    reset) shift; pool_reset "$@";;
    *) printf 'Usage: %s pool {status|down|reset}\n' "$0" >&2; return 2;;
  esac
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

signing_team() {
  if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    printf '%s\n' "$DEVELOPMENT_TEAM"
    return 0
  fi
  local config="$IOS/Config/Signing.local.xcconfig"
  [[ -f "$config" ]] || return 0
  awk -F= '
    /^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=/ {
      value = $2
      sub(/[[:space:]]*(\/\/|#).*$/, "", value)
      gsub(/[[:space:]\"]/, "", value)
      print value
      exit
    }
  ' "$config"
}

cmd_archive() {
  cmd_generate
  local archive_path="$IOS/build/archive/CCController.xcarchive"
  if [[ -e "$archive_path" ]]; then
    printf 'archive output already exists: %s\n' "$archive_path" >&2
    return 2
  fi
  local build_number
  build_number=$(git -C "$ROOT" rev-list --count HEAD)
  local team
  team=$(signing_team)
  local args=(
    xcodebuild
    -project "$PROJECT"
    -scheme CCController
    -configuration Release
    archive
    -destination 'generic/platform=iOS'
    -derivedDataPath "$DERIVED/archive-derived"
    -archivePath "$archive_path"
    -allowProvisioningUpdates
    CURRENT_PROJECT_VERSION="$build_number"
  )
  if [[ "${CC_ARCHIVE_UNSIGNED:-0}" == '1' ]]; then
    args+=(
      CODE_SIGNING_ALLOWED=NO
      CODE_SIGNING_REQUIRED=NO
      CODE_SIGN_IDENTITY=''
      DEVELOPMENT_TEAM=''
    )
  else
    if [[ -z "$team" ]]; then
      printf '%s\n' 'archive requires DEVELOPMENT_TEAM (set it in the environment or ios/Config/Signing.local.xcconfig)' >&2
      return 2
    fi
    args+=(DEVELOPMENT_TEAM="$team")
  fi
  mkdir -p "$(dirname "$archive_path")"
  step archive "${args[@]}"
  printf 'archive created: %s\n' "$archive_path"
}

cmd_upload() {
  local team
  team=$(signing_team)
  if [[ -z "$team" ]]; then
    printf '%s\n' 'upload requires DEVELOPMENT_TEAM (set it in the environment or ios/Config/Signing.local.xcconfig)' >&2
    return 2
  fi
  local archive_path="$IOS/build/archive/CCController.xcarchive"
  if [[ ! -d "$archive_path" ]]; then
    printf 'upload requires an archive at %s; run archive first\n' "$archive_path" >&2
    return 2
  fi
  local export_dir="$IOS/build/export"
  if [[ -e "$export_dir" ]]; then
    printf 'upload output already exists: %s\n' "$export_dir" >&2
    return 2
  fi
  local key_args=()
  if [[ -n "${ASC_KEY_PATH:-}${ASC_KEY_ID:-}${ASC_ISSUER_ID:-}" ]]; then
    local input
    for input in ASC_KEY_PATH ASC_KEY_ID ASC_ISSUER_ID; do
      if [[ -z "${!input:-}" ]]; then
        printf 'upload requires %s when App Store Connect API key authentication is used\n' "$input" >&2
        return 2
      fi
    done
    key_args=(
      -authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID"
    )
  fi
  RUN_DIR=$(mktemp -d -t cc-controller-upload.XXXXXX)
  local export_options="$RUN_DIR/ExportOptions.plist"
  cp "$IOS/Config/ExportOptions.plist" "$export_options"
  plutil -replace teamID -string "$team" "$export_options"
  mkdir -p "$export_dir"
  local args=(
    xcodebuild
    -exportArchive
    -archivePath "$archive_path"
    -exportPath "$export_dir"
    -exportOptionsPlist "$export_options"
  )
  args+=("${key_args[@]}")
  step upload "${args[@]}"
  printf 'upload export completed: %s\n' "$export_dir"
}

case "${1:-}" in
  generate) shift; step generate cmd_generate "$@";;
  build) shift; step build cmd_build "$@";;
  test) shift; step test cmd_test "$@";;
  release-check) shift; cmd_release_check "$@";;
  archive) shift; cmd_archive "$@";;
  upload) shift; cmd_upload "$@";;
  shots) shift; cmd_shots "$@";;
  flows) shift; cmd_flows "$@";;
  mocks) shift; cmd_mocks "$@";;
  pool) shift; cmd_pool "$@";;
  clean) shift; cmd_clean "$@";;
  install) shift; cmd_install "$@";;
  *) printf 'Usage: %s {generate|build|test|release-check|archive|upload|shots|flows|mocks|pool|clean|install}\n' "$0" >&2; exit 2;;
esac
