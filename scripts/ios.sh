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
POOL_SLOTS="${CC_IOS_POOL_SLOTS:-4}"
POOL_IDLE_SECONDS=$((20 * 60))
POOL_WAIT_SECONDS=$((60 * 60))
POOL_SLOT=""
POOL_OWNER_PID=""
STARTED_DAEMON=""
FIXTURE_OUT=""
FIXTURE_LOG=""
FIXTURE_SIM_UDID=""
CURRENT_XCODEBUILD_PID=""
RUN_DIR=""
DIAG_DIR=""
MOCK_RUN_DIR=""
SHARD_CONTROLLER=1
SHARD_PIDS=()
PERF_SAMPLE_PIDS=()

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
  local valid=",sessions,sessions-empty,sessions-offline,sessions-reconnecting,session-idle,session-working,subagent-result-sheet,session-activity,session-approvals,session-terminal-approval,activity-sheet,composer-slash,composer-attachments,composer-keyboard,tool-detail,tool-detail-edit,subagent,inspector,settings,onboarding-welcome,onboarding-connect,onboarding-pair,onboarding-faceid,lock,privacy-cover,working-bar-1-thinking,working-bar-2-tool-agents,working-bar-3-typing,working-bar-4-idle,working-bar-5-current,"
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

terminate_process_tree() {
  local pid=$1 child
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    terminate_process_tree "$child"
  done
  kill -TERM "$pid" 2>/dev/null || true
}

stop_current_xcodebuild() {
  local pid=$CURRENT_XCODEBUILD_PID
  [[ -n "$pid" ]] || return 0
  terminate_process_tree "$pid"
  for _ in {1..50}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  CURRENT_XCODEBUILD_PID=""
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
  local scenario=${2:-default}
  local mode=${3:-C}
  local private_fixture=${4:-}
  FIXTURE_OUT=$(mktemp -t cc-controller-fixture.XXXXXX)
  if [[ "$scenario" == 'perf' && -n "$private_fixture" ]]; then
    CC_FIXTURE_SIM_UDID="$FIXTURE_SIM_UDID" CC_PERF_MODE="$mode" CC_FIXTURE_LONG_SESSION_PATH="$private_fixture" node "$ROOT/scripts/fixture-daemon.mjs" --scenario perf --mode "$mode" --out "$FIXTURE_OUT" >"$FIXTURE_LOG" 2>&1 &
  elif [[ "$scenario" == 'perf' ]]; then
    CC_FIXTURE_SIM_UDID="$FIXTURE_SIM_UDID" CC_PERF_MODE="$mode" node "$ROOT/scripts/fixture-daemon.mjs" --scenario perf --mode "$mode" --out "$FIXTURE_OUT" >"$FIXTURE_LOG" 2>&1 &
  else
    CC_FIXTURE_SIM_UDID="$FIXTURE_SIM_UDID" node "$ROOT/scripts/fixture-daemon.mjs" --scenario default --out "$FIXTURE_OUT" >"$FIXTURE_LOG" 2>&1 &
  fi
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
  for ((slot = 1; slot <= POOL_SLOTS; slot++)); do
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
  local owner_pid
  owner_pid=$(perl -e 'print getppid')
  POOL_OWNER_PID=$owner_pid
  local lane="${CC_MOCK_LANE:-${USER:-user}-$owner_pid}"
  local waited=0 slot lock holders message
  while (( waited <= POOL_WAIT_SECONDS )); do
    for ((slot = 1; slot <= POOL_SLOTS; slot++)); do
      mkdir -p "$(pool_slot_dir "$slot")"
      pool_clear_stale_lock "$slot"
      lock=$(pool_lock_dir "$slot")
      if mkdir "$lock" 2>/dev/null; then
        printf '%s\n' "$owner_pid" > "$lock/pid"
        printf '%s\n' "$lane" > "$lock/lane"
        POOL_SLOT=$slot
        ensure_pool_devices "$slot"
        pool_idle_cleanup "$slot"
        printf '%s\n' "acquired simulator slot $slot for $lane"
        return 0
      fi
    done
    holders=()
    for ((slot = 1; slot <= POOL_SLOTS; slot++)); do
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

pool_shutdown_slot_devices() {
  local slot=$1
  local device name udid state
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
}

release_pool_slot() {
  [[ -z "$POOL_SLOT" ]] && return 0
  local slot=$POOL_SLOT
  local lock pid
  if (( slot >= 3 )); then
    pool_shutdown_slot_devices "$slot" || true
  fi
  lock=$(pool_lock_dir "$slot")
  pid=$(pool_lock_pid "$slot" || true)
  if [[ "$pid" == "$POOL_OWNER_PID" ]]; then
    rm -rf "$lock"
  fi
  POOL_SLOT=""
  POOL_OWNER_PID=""
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

configure_xctestrun() {
  local source=$1 destination=$2 server=$3 bearer=$4 control=$5 color=$6 output_dir=$7
  local mocks="" set_mocks=0
  if [[ $# -ge 8 ]]; then
    mocks=$8
    set_mocks=1
  fi
  cp "$source" "$destination"
  if plutil -extract TestConfigurations xml1 -o - "$destination" >/dev/null 2>&1; then
    printf '%s\n' 'format-2 .xctestrun files with TestConfigurations are unsupported' >&2
    return 1
  fi
  if ! plutil -extract CCControllerUITests.EnvironmentVariables xml1 -o - "$destination" >/dev/null 2>&1; then
    printf 'xctestrun is missing CCControllerUITests.EnvironmentVariables: %s\n' "$destination" >&2
    return 1
  fi
  local entries=(
    TEST_RUNNER_SERVER_URL "$server"
    TEST_RUNNER_BEARER "$bearer"
    TEST_RUNNER_FIXTURE_CONTROL_URL "$control"
    TEST_RUNNER_COLOR_SCHEME "$color"
    CC_FLOW_OUTPUT_DIR "$output_dir"
  )
  if [[ $set_mocks -eq 1 ]]; then
    entries+=(TEST_RUNNER_MOCKS "$mocks")
  fi
  local index key value
  for ((index = 0; index < ${#entries[@]}; index += 2)); do
    key=${entries[$index]}
    value=${entries[$((index + 1))]}
    plutil -replace "CCControllerUITests.EnvironmentVariables.$key" -string "$value" "$destination" 2>/dev/null || \
      plutil -insert "CCControllerUITests.EnvironmentVariables.$key" -string "$value" "$destination"
  done
}

stop_shards() {
  [[ ${#SHARD_PIDS[@]} -gt 0 ]] || return 0
  local pid
  for pid in "${SHARD_PIDS[@]}"; do
    [[ -z "$pid" ]] || kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${SHARD_PIDS[@]}"; do
    [[ -z "$pid" ]] || wait "$pid" 2>/dev/null || true
  done
  SHARD_PIDS=()
}

cleanup_run() {
  local status=$1 sample_pid
  for sample_pid in "${PERF_SAMPLE_PIDS[@]:-}"; do
    [[ -z "$sample_pid" ]] || { kill "$sample_pid" 2>/dev/null || true; wait "$sample_pid" 2>/dev/null || true; }
  done
  PERF_SAMPLE_PIDS=()
  stop_current_xcodebuild || true
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
  if [[ $SHARD_CONTROLLER -eq 1 ]]; then
    stop_shards
  fi
  cleanup_run "$status" || true
  exit "$status"
}

trap cleanup_on_exit EXIT
trap 'exit 130' INT TERM

cmd_generate() {
  mkdir -p "$IOS/Config"
  touch "$IOS/Config/Signing.local.xcconfig"
  (cd "$ROOT" && swift "$IOS/Scripts/render-icon.swift")
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

run_flow_test() {
  local label=$1 method_log=$2
  shift 2
  local started=$SECONDS status=0
  printf '%s\n' "[$label]"
  "$@" > >(tee -a "$method_log") 2>&1 &
  CURRENT_XCODEBUILD_PID=$!
  if wait "$CURRENT_XCODEBUILD_PID"; then
    status=0
  else
    status=$?
  fi
  CURRENT_XCODEBUILD_PID=""
  printf '%s\n' "[$label] $((SECONDS - started))s"
  return "$status"
}

run_flow_shard() {
  local shard_index=$1 shard_count=$2 result_file=$3 app_bundle=$4 xctestrun=$5 flow_root=$6 flow_build_root=$7
  SHARD_CONTROLLER=0
  SHARD_PIDS=()
  RUN_DIR=$(mktemp -d -t cc-controller-flow-shard.XXXXXX)
  local shard_failed=0
  local shard_udids=() device device_index udid
  local index flow_class flow_method

  pool_acquire
  for device in "${devices[@]}"; do
    shard_udids+=("$(ensure_pool_device "$device")")
  done

  for index in "${!selected_methods[@]}"; do
    if (( index % shard_count != shard_index )); then
      continue
    fi
    flow_class=${selected_classes[$index]}
    flow_method=${selected_methods[$index]}
    device_index=0
    for device in "${devices[@]}"; do
      local method_started=$SECONDS
      local result exported output_dir device_key method_log method_xctestrun
      local method_status=0 xcode_status=0 export_status=0
      device_key=$(echo "$device" | tr ' ()' '---')
      output_dir="$flow_root/$device_key/$flow_class/$flow_method"
      result="$flow_build_root/$device_key/$flow_class/$flow_method.xcresult"
      exported="$RUN_DIR/$device_key/$flow_class/$flow_method"
      method_log="$output_dir/xcodebuild.log"
      method_xctestrun="$exported/CCController.xctestrun"
      rm -rf "$output_dir" "$result" "$exported"
      mkdir -p "$output_dir" "$(dirname "$result")" "$exported"
      ln -s "$DERIVED/Build/Products/Debug-iphonesimulator" "$exported/Debug-iphonesimulator"

      stop_fixture_daemon
      udid=${shard_udids[$device_index]}
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
        if configure_xctestrun "$xctestrun" "$method_xctestrun" \
          "http://127.0.0.1:$web_port" "$bearer" "http://127.0.0.1:$control_port" \
          "${TEST_RUNNER_COLOR_SCHEME:-light}" "$output_dir"; then
          local args=(xcodebuild -xctestrun "$method_xctestrun" -destination "id=$udid" -resultBundlePath "$result" "-only-testing:CCControllerUITests/$flow_class/$flow_method" -collect-test-diagnostics never test-without-building)
          if run_flow_test "flows $flow_class/$flow_method $device" "$method_log" "${args[@]}"; then
            xcode_status=0
          else
            xcode_status=$?
          fi
        else
          printf '%s\n' 'failed to configure per-method xctestrun' | tee -a "$method_log"
          method_status=1
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
      rm -f "$method_xctestrun"
      [[ $xcode_status -eq 0 ]] || method_status=1
      [[ $export_status -eq 0 ]] || method_status=1
      local elapsed=$((SECONDS - method_started))
      local result_label=PASS
      if [[ $method_status -ne 0 ]]; then
        result_label=FAIL
        shard_failed=$((shard_failed + 1))
      elif grep -Eq 'Test Case .* skipped' "$method_log"; then
        result_label=SKIP
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$index" "$device_index" "$flow_class" "$flow_method" "$device" "$result_label" "$elapsed" >> "$result_file"
      device_index=$((device_index + 1))
    done
  done
  if [[ $shard_failed -eq 0 ]]; then
    return 0
  fi
  return 1
}

cmd_flows() {
  local devices=() test_filter="" shard_count=1
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
      --shards)
        [[ $# -ge 2 ]] || { printf '%s\n' 'flows --shards requires a value' >&2; exit 2; }
        shard_count=$2
        shift 2
        ;;
      *) printf 'unknown flows option: %s\n' "$1" >&2; exit 2;;
    esac
  done
  [[ "$shard_count" =~ ^[1-9][0-9]*$ ]] || { printf 'flows --shards must be a positive integer\n' >&2; exit 2; }
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
  step generate cmd_generate
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
  local xctestrun
  xctestrun=$(find "$DERIVED/Build/Products" -type f -name '*.xctestrun' -print -quit)
  if [[ -z "$xctestrun" ]]; then
    printf 'build-for-testing did not produce an .xctestrun file under %s\n' "$DERIVED/Build/Products" >&2
    return 1
  fi

  local shard_result_dir="$RUN_DIR/results"
  mkdir -p "$shard_result_dir"
  local shard shard_pid
  for (( shard = 0; shard < shard_count; shard++ )); do
    : > "$shard_result_dir/shard-$shard.tsv"
    (
      trap 'cleanup_run $?' EXIT
      trap 'exit 130' INT TERM
      run_flow_shard "$shard" "$shard_count" "$shard_result_dir/shard-$shard.tsv" "$app_bundle" "$xctestrun" "$flow_root" "$flow_build_root"
    ) &
    shard_pid=$!
    SHARD_PIDS+=("$shard_pid")
  done

  local shard_status=0
  for shard_pid in "${SHARD_PIDS[@]}"; do
    if wait "$shard_pid"; then
      :
    else
      shard_status=1
    fi
  done
  SHARD_PIDS=()

  local result_files=()
  for (( shard = 0; shard < shard_count; shard++ )); do
    result_files+=("$shard_result_dir/shard-$shard.tsv")
  done
  local summary_count=0 passed=0 failed=0 skipped=0
  local result_index result_device_index result_class result_method result_device result_label result_seconds
  printf '\nFlow summary\n'
  printf '%-70s %-8s %8s\n' 'class/method [device]' 'result' 'seconds'
  while IFS=$'\t' read -r result_index result_device_index result_class result_method result_device result_label result_seconds; do
    [[ -z "$result_index" ]] && continue
    printf '%-70s %-8s %8s\n' "$result_class/$result_method [$result_device]" "$result_label" "$result_seconds"
    summary_count=$((summary_count + 1))
    case "$result_label" in
      PASS) passed=$((passed + 1));;
      FAIL) failed=$((failed + 1));;
      SKIP) skipped=$((skipped + 1));;
    esac
  done < <(LC_ALL=C sort -t $'\t' -k1,1n -k2,2n "${result_files[@]}")

  printf '%s passed, %s failed, %s skipped\n' "$passed" "$failed" "$skipped"
  if [[ $summary_count -ne $((selected_count * ${#devices[@]})) ]]; then
    printf 'flow summary contains %s of %s expected methods\n' "$summary_count" "$((selected_count * ${#devices[@]}))" >&2
    shard_status=1
  fi
  if [[ $failed -ne 0 || $shard_status -ne 0 ]]; then
    printf '%s\n' 'one or more flow shards failed' >&2
    return 1
  fi
  printf '%s\n' "flow shots written to $flow_root"
}

run_mock_lane() {
  local lane_index=$1 device=$2 only=$3 xctestrun=$4 mock_root=$5 result_root=$6 result_file=$7
  SHARD_CONTROLLER=0
  MOCK_RUN_DIR=""
  DIAG_DIR=""
  RUN_DIR=$(mktemp -d -t cc-controller-mock-lane.XXXXXX)
  local device_key=$(echo "$device" | tr ' ()' '---')
  local result="$result_root/MockScreenshot-$device_key.xcresult"
  local output_dir="$mock_root/$device_key"
  local lane_xctestrun="$RUN_DIR/CCController.xctestrun"
  local lane_log="$RUN_DIR/xcodebuild.log"
  local lane_status=0
  local started=$SECONDS
  local udid

  if ! pool_acquire; then
    lane_status=1
  elif ! udid=$(ensure_pool_device "$device"); then
    lane_status=1
  else
    rm -rf "$result"
    mkdir -p "$output_dir"
    ln -s "$DERIVED/Build/Products/Debug-iphonesimulator" "$RUN_DIR/Debug-iphonesimulator"
    if ! configure_xctestrun "$xctestrun" "$lane_xctestrun" "" "" "" "" "$output_dir" "$only"; then
      printf '%s\n' 'failed to configure per-lane xctestrun' | tee "$lane_log"
      lane_status=1
    else
      local args=(xcodebuild -xctestrun "$lane_xctestrun" -destination "id=$udid" -resultBundlePath "$result" "-only-testing:CCControllerUITests/MockScreenshotTests/testDesignMocks" -collect-test-diagnostics never test-without-building)
      if ! run_flow_test "mocks $device" "$lane_log" "${args[@]}"; then
        lane_status=1
      fi
    fi
  fi

  local label=PASS
  [[ $lane_status -eq 0 ]] || label=FAIL
  printf '%s\t%s\t%s\t%s\n' "$lane_index" "$device" "$label" "$((SECONDS - started))" > "$result_file"
  return "$lane_status"
}

cmd_mocks() {
  local only=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --only)
        [[ $# -ge 2 ]] || { printf '%s\n' 'mocks --only requires a value' >&2; exit 2; }
        only=$2
        shift 2
        ;;
      *) printf 'unknown mocks option: %s\n' "$1" >&2; exit 2;;
    esac
  done
  validate_mock_screens "$only"
  cmd_generate
  local mock_root="$IOS/shots/mocks"
  if [[ -n "${CC_MOCK_LANE:-}" ]]; then mock_root="$mock_root/$CC_MOCK_LANE"; fi
  if [[ -n "${CC_MOCK_LANE:-}" ]]; then DERIVED="$IOS/build/mock-derived-$CC_MOCK_LANE"; else DERIVED="$IOS/build"; fi
  MOCK_RUN_DIR=$(mktemp -d -t cc-controller-mock-run.XXXXXX)
  local result_root="$MOCK_RUN_DIR/results"
  mkdir -p "$result_root"
  rm -rf "$mock_root"
  mkdir -p "$mock_root"

  local build_args=(xcodebuild -project "$PROJECT" -scheme CCController -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build-for-testing)
  step 'mocks build-for-testing' "${build_args[@]}"
  local app_bundle="$DERIVED/Build/Products/Debug-iphonesimulator/cc-controller.app"
  if [[ ! -d "$app_bundle" ]]; then
    printf 'build-for-testing did not produce %s\n' "$app_bundle" >&2
    return 1
  fi
  local xctestrun
  xctestrun=$(find "$DERIVED/Build/Products" -type f -name '*.xctestrun' -print -quit)
  if [[ -z "$xctestrun" ]]; then
    printf 'build-for-testing did not produce an .xctestrun file under %s\n' "$DERIVED/Build/Products" >&2
    return 1
  fi

  rm -rf "$DERIVED"/MockScreenshot-*.xcresult
  local devices=("iPhone 16 Plus" "iPhone 18 Pro")
  local device_index device shard_pid
  for device_index in "${!devices[@]}"; do
    device=${devices[$device_index]}
    : > "$result_root/lane-$device_index.tsv"
    (
      trap 'cleanup_run $?' EXIT
      trap 'exit 130' INT TERM
      run_mock_lane "$device_index" "$device" "$only" "$xctestrun" "$mock_root" "$DERIVED" "$result_root/lane-$device_index.tsv"
    ) &
    shard_pid=$!
    SHARD_PIDS+=("$shard_pid")
  done

  local lane_status=0
  for shard_pid in "${SHARD_PIDS[@]}"; do
    if wait "$shard_pid"; then
      :
    else
      lane_status=1
    fi
  done
  SHARD_PIDS=()

  local audit="$mock_root/audit.txt"
  : > "$audit"
  local collection_status=0 result exported output_dir manifest scheme image
  local images=()
  for device_index in "${!devices[@]}"; do
    device=${devices[$device_index]}
    local device_key=$(echo "$device" | tr ' ()' '---')
    result="$DERIVED/MockScreenshot-$device_key.xcresult"
    exported="$MOCK_RUN_DIR/$device_key"
    output_dir="$mock_root/$device_key"
    mkdir -p "$exported" "$output_dir"
    if [[ ! -d "$result" ]]; then
      printf 'missing mock result bundle for %s\n' "$device" >&2
      collection_status=1
      continue
    fi
    if ! xcrun xcresulttool export attachments --path "$result" --output-path "$exported" >/dev/null; then
      printf 'failed to export mock attachments for %s\n' "$device" >&2
      collection_status=1
      continue
    fi
    manifest="$exported/manifest.json"
    if [[ -f "$manifest" ]]; then
      node -e 'const fs=require("node:fs"),path=require("node:path"),p=process.argv[1],dir=path.dirname(p),d=JSON.parse(fs.readFileSync(p)),attachments=Array.isArray(d)?d.flatMap((entry)=>entry.attachments??[]):d.attachments??[];for(const a of attachments){const suggested=a.suggestedHumanReadableName||a.filename||"";const name=suggested.replace(/_[0-9]+_[0-9a-f-]+\.(png|txt)$/i,".$1");const old=a.exportedFileName||a.exportedFilePath||a.filename;const src=path.join(dir,old),dst=path.join(dir,name);if(fs.existsSync(src)&&src!==dst)fs.renameSync(src,dst);}' "$manifest"
    fi
    find "$exported" -maxdepth 1 -type f -name '*.png' -exec cp {} "$output_dir" \;
    if [[ -f "$exported/audit.txt" ]]; then
      printf '## %s\n' "$device" >> "$audit"
      cat "$exported/audit.txt" >> "$audit"
      printf '\n' >> "$audit"
    fi
  done

  for device_index in "${!devices[@]}"; do
    device=${devices[$device_index]}
    local device_key=$(echo "$device" | tr ' ()' '---')
    output_dir="$mock_root/$device_key"
    for scheme in light dark; do
      images=()
      while IFS= read -r image; do images+=("$image"); done < <(find "$output_dir" -maxdepth 1 -type f -name "*-$scheme-*.png" | sort)
      if [[ ${#images[@]} -gt 0 ]]; then
        swift "$IOS/Scripts/contact-sheet.swift" "$mock_root/contact-$device_key-$scheme.png" "${images[@]}"
      fi
    done
  done

  if [[ $lane_status -ne 0 || $collection_status -ne 0 ]]; then
    printf '%s\n' 'one or more mock lanes failed' >&2
    return 1
  fi
  printf '%s\n' "mock shots written to $mock_root"
}

perf_time_seconds() {
  python3 - "$1" <<'PY'
import sys
value = sys.argv[1].strip()
parts = value.split(':')
try:
    if len(parts) == 3:
        result = int(parts[0]) * 3600 + int(parts[1]) * 60 + float(parts[2])
    elif len(parts) == 2:
        result = int(parts[0]) * 60 + float(parts[1])
    else:
        result = float(value)
    print(result)
except ValueError:
    print('0')
PY
}

perf_wall_seconds() {
  python3 - <<'PY'
import time
print(time.monotonic())
PY
}

perf_process_sample() {
  local udid=$1 target=$2 pid row cpu rss
  if [[ "$target" == 'cc-controller' ]]; then
    pid=${PERF_HOST_APP_PID:-}
  else
    pid=$(perf_host_pid 'backboardd' "$udid")
  fi
  [[ "$pid" =~ ^[0-9]+$ ]] || { printf '|||\n'; return 0; }
  row=$(ps -p "$pid" -o pid=,time=,rss= 2>/dev/null || true)
  [[ -n "$row" ]] || { printf '|||\n'; return 0; }
  read -r pid cpu rss <<< "$row"
  printf '%s|%s|%s\n' "$pid" "$(perf_time_seconds "$cpu")" "$rss"
}

perf_sample_loop() {
  local udid=$1 file=$2
  while :; do
    local now app render
    now=$(perf_wall_seconds)
    app=$(perf_process_sample "$udid" cc-controller)
    render=$(perf_process_sample "$udid" backboardd)
    printf '%s|app|%s\n' "$now" "$app" >> "$file"
    printf '%s|render|%s\n' "$now" "$render" >> "$file"
    sleep 1
  done
}

perf_peak_rss() {
  python3 - "$1" <<'PY'
import sys
values = []
for line in open(sys.argv[1]):
    fields = line.rstrip().split('|')
    if len(fields) != 5 or not fields[4].isdigit():
        continue
    values.append(int(fields[4]))
print(max(values) if values else 0)
PY
}

perf_cpu_delta() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
before, after, wall = map(float, sys.argv[1:])
print(max(0.0, (after - before) * 100.0 / wall))
PY
}

perf_host_pid() {
  local target=$1 udid=${2:-} parent_pid
  if [[ "$target" == 'backboardd' && -n "$udid" ]]; then
    parent_pid=$(ps -axo pid=,command= | awk -v udid="$udid" '$0 ~ udid && $0 ~ /launchd_sim/ { print $1; exit }' || true)
    [[ "$parent_pid" =~ ^[0-9]+$ ]] || return 0
    ps -axo pid=,ppid=,command= | awk -v parent="$parent_pid" '$2 == parent && $0 ~ /backboardd$/ { print $1; exit }' || true
    return 0
  fi
  ps -axo pid=,command= | awk -v target="$target" '$0 ~ target { print $1; exit }' || true
}

perf_start_samples() {
  local label=$1 host_app_pid=$2 case_dir=$3 render_pid
  [[ "$label" == C || "$label" == E-real || "$label" == E-storm || "$label" == F ]] || return 0
  local sample_prefix="sample-$label-$PERF_RUN_NUMBER"
  [[ -f "$PERF_OUTPUT_DIR/$sample_prefix.txt" ]] || {
    if [[ "$host_app_pid" =~ ^[0-9]+$ ]]; then
      sample "$host_app_pid" 10 -file "$PERF_OUTPUT_DIR/$sample_prefix.txt" >/dev/null 2>&1 &
      PERF_SAMPLE_PIDS+=("$!")
    else
      host_app_pid=$(perf_host_pid 'cc-controller.app/cc-controller' "$PERF_UDID")
      if [[ "$host_app_pid" =~ ^[0-9]+$ ]]; then
        sample "$host_app_pid" 10 -file "$PERF_OUTPUT_DIR/$sample_prefix.txt" >/dev/null 2>&1 &
        PERF_SAMPLE_PIDS+=("$!")
      fi
    fi
  }
  render_pid=$(perf_host_pid 'backboardd' "$PERF_UDID")
  if [[ "$render_pid" =~ ^[0-9]+$ ]]; then
    sample "$render_pid" 10 -file "$PERF_OUTPUT_DIR/sample-render-$label-$PERF_RUN_NUMBER.txt" >/dev/null 2>&1 &
    PERF_SAMPLE_PIDS+=("$!")
  fi
}

perf_run_case() {
  local label=$1 mode=$2 duration=$3 private_fixture=${4:-}
  local case_dir="$PERF_OUTPUT_DIR/$label/run-$PERF_RUN_NUMBER"
  mkdir -p "$case_dir"
  local fixture_log="$case_dir/fixture.log"
  local app_bundle="$PERF_DERIVED/Build/Products/Release-iphonesimulator/cc-controller.app"
  start_fixture_daemon "$fixture_log" perf "$mode" "$private_fixture"
  local web_port bearer
  web_port=$(json_value "$FIXTURE_OUT" webPort)
  bearer=$(json_value "$FIXTURE_OUT" bearer)

  xcrun simctl terminate "$PERF_UDID" com.example.cc-controller >/dev/null 2>&1 || true
  xcrun simctl uninstall "$PERF_UDID" com.example.cc-controller >/dev/null 2>&1 || true
  xcrun simctl install "$PERF_UDID" "$app_bundle"
  local launch_output host_app_pid
  launch_output=$(SIMCTL_CHILD_CCBearer="$bearer" SIMCTL_CHILD_CC_PERF_SCENARIO="$label" xcrun simctl launch "$PERF_UDID" com.example.cc-controller \
    -CCServer "http://127.0.0.1:$web_port" \
    -CCSession long-session \
    -CCColorScheme light)
  host_app_pid=$(printf '%s\n' "$launch_output" | awk -F': ' 'NF == 2 && $2 ~ /^[0-9]+$/ { print $2; exit }')

  local app_sample="" render_sample="" app_pid=""
  PERF_HOST_APP_PID="$host_app_pid"
  for _ in {1..60}; do
    app_sample=$(perf_process_sample "$PERF_UDID" cc-controller)
    app_pid=${app_sample%%|*}
    [[ "$app_pid" =~ ^[0-9]+$ ]] && break
    sleep 0.25
  done
  [[ "$app_pid" =~ ^[0-9]+$ ]] || { printf 'perf %s: app did not launch (simctl=%s)\n' "$label" "$launch_output" >&2; return 1; }
  sleep "${CC_PERF_WARMUP_SECONDS:-5}"
  perf_start_samples "$label" "$host_app_pid" "$case_dir"

  local before_app before_render before_rss start end after_app after_render after_rss sampler samples
  before_app=$(perf_process_sample "$PERF_UDID" cc-controller)
  before_render=$(perf_process_sample "$PERF_UDID" backboardd)
  before_rss=${before_app##*|}
  start=$(perf_wall_seconds)
  samples="$case_dir/process-samples.txt"
  : > "$samples"
  perf_sample_loop "$PERF_UDID" "$samples" &
  sampler=$!
  sleep "$duration"
  end=$(perf_wall_seconds)
  kill "$sampler" 2>/dev/null || true
  wait "$sampler" 2>/dev/null || true
  local sample_pid
  for sample_pid in "${PERF_SAMPLE_PIDS[@]:-}"; do
    [[ -z "$sample_pid" ]] || wait "$sample_pid" 2>/dev/null || true
  done
  PERF_SAMPLE_PIDS=()
  after_app=$(perf_process_sample "$PERF_UDID" cc-controller)
  after_render=$(perf_process_sample "$PERF_UDID" backboardd)
  after_rss=${after_app##*|}
  local wall app_before_cpu app_after_cpu render_before_cpu render_after_cpu app_cpu render_cpu peak_rss
  wall=$(python3 - "$start" "$end" <<'PY'
import sys
print(float(sys.argv[2]) - float(sys.argv[1]))
PY
)
  app_before_cpu=$(printf '%s' "$before_app" | cut -d'|' -f2)
  app_after_cpu=$(printf '%s' "$after_app" | cut -d'|' -f2)
  render_before_cpu=$(printf '%s' "$before_render" | cut -d'|' -f2)
  render_after_cpu=$(printf '%s' "$after_render" | cut -d'|' -f2)
  app_cpu=$(perf_cpu_delta "$app_before_cpu" "$app_after_cpu" "$wall")
  render_cpu=null
  if [[ -n "$render_before_cpu" && -n "$render_after_cpu" ]]; then
    render_cpu=$(perf_cpu_delta "$render_before_cpu" "$render_after_cpu" "$wall")
  fi
  peak_rss=$(perf_peak_rss "$samples")

  local before_shot after_shot rendering
  before_shot="$case_dir/before.png"
  after_shot="$case_dir/after.png"
  xcrun simctl io "$PERF_UDID" screenshot "$before_shot" >/dev/null 2>&1 || true
  sleep 1
  xcrun simctl io "$PERF_UDID" screenshot "$after_shot" >/dev/null 2>&1 || true
  rendering=false
  if [[ -s "$before_shot" && -s "$after_shot" ]] && ! cmp -s "$before_shot" "$after_shot"; then rendering=true; fi
  if [[ "$render_cpu" != null ]] && python3 - "$render_cpu" <<'PY'
import sys
raise SystemExit(0 if float(sys.argv[1]) > 0 else 1)
PY
  then rendering=true; fi

  xcrun simctl terminate "$PERF_UDID" com.example.cc-controller >/dev/null 2>&1 || true
  local container counter_file
  container=$(xcrun simctl get_app_container "$PERF_UDID" com.example.cc-controller data)
  counter_file="$container/Library/cc-perf.json"
  local json_file="$case_dir/result.json"
  PERF_LABEL="$label" PERF_RUN_NUMBER="$PERF_RUN_NUMBER" PERF_MODE="$mode" PERF_DURATION="$duration" PERF_WALL="$wall" PERF_APP_CPU="$app_cpu" PERF_RENDER_CPU="$render_cpu" PERF_PEAK_RSS="$peak_rss" PERF_RENDERING="$rendering" PERF_COUNTER_FILE="$counter_file" PERF_JSON_FILE="$json_file" python3 - <<'PY'
import json, os
payload = {
  'scenario': os.environ['PERF_LABEL'], 'run': int(os.environ['PERF_RUN_NUMBER']), 'mode': os.environ['PERF_MODE'],
  'duration_seconds': float(os.environ['PERF_DURATION']), 'wall_seconds': float(os.environ['PERF_WALL']),
  'app_cpu_percent_one_core': float(os.environ['PERF_APP_CPU']),
  'render_server_cpu_percent_one_core': None if os.environ['PERF_RENDER_CPU'] == 'null' else float(os.environ['PERF_RENDER_CPU']),
  'peak_memory_kb': int(os.environ['PERF_PEAK_RSS']), 'headless_rendering_changed': os.environ['PERF_RENDERING'] == 'true',
}
try:
    with open(os.environ['PERF_COUNTER_FILE']) as f: payload['counters'] = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    payload['counters'] = None
with open(os.environ['PERF_JSON_FILE'], 'w') as f: json.dump(payload, f, indent=2, sort_keys=True)
PY
  local counter_summary
  counter_summary=$(python3 - "$json_file" <<'PY'
import json, sys
p=json.load(open(sys.argv[1])); c=p.get('counters') or {}; r=c.get('per_second') or {}; print(' '.join(f'{k}={v:.2f}/s' for k,v in sorted(r.items())))
PY
)
  printf 'PERF %s run=%s app_cpu=%.2f%% render_cpu=%s%% peak_rss=%skB rendering=%s %s\n' "$label" "$PERF_RUN_NUMBER" "$app_cpu" "$render_cpu" "$peak_rss" "$rendering" "$counter_summary"
  stop_fixture_daemon
  local budget
  case "$label" in A) budget=${CC_PERF_BUDGET_A:-1};; B) budget=${CC_PERF_BUDGET_B:-3};; C|D|E-real|E-storm|F) budget=${CC_PERF_BUDGET_C:-15};; esac
  if python3 - "$app_cpu" "$budget" <<'PY'
import sys
raise SystemExit(0 if float(sys.argv[1]) <= float(sys.argv[2]) else 1)
PY
  then :; else PERF_BUDGET_FAILED=1; fi
}

cmd_perf() {
  local only_scenario='' no_build=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --scenario)
        [[ $# -ge 2 && "$2" =~ ^(A|B|C|D|E|E-real|E-storm|F)$ ]] || { printf '%s\n' 'perf --scenario requires A, B, C, D, E-real, E-storm, or F' >&2; return 2; }
        only_scenario=$2
        [[ "$only_scenario" == E ]] && only_scenario=E-storm
        shift 2
        ;;
      --no-build)
        no_build=1
        shift
        ;;
      *) printf 'unknown perf option: %s\n' "$1" >&2; return 2;;
    esac
  done
  local default_repeats=3
  [[ -z "$only_scenario" ]] || default_repeats=1
  local repeats=${CC_PERF_REPEATS:-$default_repeats}
  [[ "$repeats" =~ ^[1-9][0-9]*$ ]] || { printf 'CC_PERF_REPEATS must be a positive integer\n' >&2; return 2; }
  PERF_OUTPUT_DIR=${CC_PERF_OUTPUT_DIR:-$HOME/Documents/dev/cc-controller-evidence/perf-2026-10-04/harness}
  PERF_DERIVED="$IOS/build/perf-release"
  PERF_RUN_NUMBER=0
  PERF_BUDGET_FAILED=0
  mkdir -p "$PERF_OUTPUT_DIR"
  local iteration_start
  iteration_start=$(perf_wall_seconds)
  pool_acquire
  PERF_UDID=$(ensure_pool_device "${CC_PERF_DEVICE:-iPhone 18 Pro}")
  local app_bundle="$PERF_DERIVED/Build/Products/Release-iphonesimulator/cc-controller.app"
  if [[ "$no_build" -eq 0 ]]; then
    cmd_generate
    step 'perf Release build' xcodebuild -project "$PROJECT" -scheme CCController -configuration Release -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath "$PERF_DERIVED" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES SWIFT_ACTIVE_COMPILATION_CONDITIONS=CC_PERF build
  fi
  [[ -d "$app_bundle" ]] || { printf 'perf requires Release+CC_PERF app at %s; omit --no-build\n' "$app_bundle" >&2; return 1; }

  local label private_fixture
  for label in A B C D E-real E-storm F; do
    [[ -z "$only_scenario" || "$only_scenario" == "$label" ]] || continue
    if [[ "$label" == D ]]; then
      private_fixture=${CC_FIXTURE_LONG_SESSION_PATH:-}
      if [[ -z "$private_fixture" ]]; then
        printf '%s\n' 'perf D requires CC_FIXTURE_LONG_SESSION_PATH to point to the private long-session fixture' >&2
        PERF_BUDGET_FAILED=1
        continue
      fi
      if [[ ! -f "$private_fixture" ]]; then
        printf 'perf D private fixture is missing at %s\n' "$private_fixture" >&2
        PERF_BUDGET_FAILED=1
        continue
      fi
      PERF_RUN_NUMBER=1
      perf_run_case D C 60 "$private_fixture"
      continue
    fi
    for ((PERF_RUN_NUMBER = 1; PERF_RUN_NUMBER <= repeats; PERF_RUN_NUMBER++)); do
      case "$label" in A|B) perf_run_case "$label" "$label" 30;; C) perf_run_case C C 60;; E-real) perf_run_case E-real E-real 120;; E-storm) perf_run_case E-storm E-storm 60;; F) perf_run_case F F 60;; esac
    done
  done
  local iteration_end
  iteration_end=$(perf_wall_seconds)
  if [[ "$only_scenario" == C ]]; then
    python3 - "$iteration_start" "$iteration_end" <<'PY'
import sys
print(f'PERF iteration rebuild_plus_C_seconds={float(sys.argv[2]) - float(sys.argv[1]):.1f}')
PY
  fi
  python3 - "$PERF_OUTPUT_DIR" "$ROOT" <<'PY'
import pathlib, subprocess, sys
out, root = map(pathlib.Path, sys.argv[1:])
diff = subprocess.check_output(['git', '-C', str(root), 'diff', 'main', '--'])
(out / 'perf-harness.diff').write_bytes(diff)
PY
  [[ "$PERF_BUDGET_FAILED" -eq 0 ]]
}

pool_status() {
  mkdir -p "$POOL_CACHE"
  local slot device name udid state marker last display lane
  for ((slot = 1; slot <= POOL_SLOTS; slot++)); do
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
  for ((slot = 1; slot <= POOL_SLOTS; slot++)); do
    pool_clear_stale_lock "$slot"
    if [[ -d "$(pool_lock_dir "$slot")" ]]; then
      printf 'cannot pool down: slot %s is held by %s\n' "$slot" "$(pool_lock_lane "$slot")" >&2
      return 1
    fi
  done
  for ((slot = 1; slot <= POOL_SLOTS; slot++)); do
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
  for ((slot = 1; slot <= POOL_SLOTS; slot++)); do
    pool_clear_stale_lock "$slot"
    if [[ -d "$(pool_lock_dir "$slot")" ]]; then
      printf 'cannot pool reset: slot %s is held by %s\n' "$slot" "$(pool_lock_lane "$slot")" >&2
      return 1
    fi
  done
  for ((slot = 1; slot <= POOL_SLOTS; slot++)); do
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

resolve_install_device() {
  local selector=${1:-}
  local devices_json
  devices_json=$(mktemp -t cc-controller-devices.XXXXXX)
  if ! xcrun devicectl list devices --json-output "$devices_json" >/dev/null; then
    rm -f "$devices_json"
    printf '%s\n' 'install could not list devices with devicectl' >&2
    return 1
  fi

  local resolved
  if ! resolved=$(node - "$devices_json" "$selector" <<'NODE'
const fs = require('node:fs');

const jsonPath = process.argv[2];
const selector = process.argv[3] || '';
const data = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
const allDevices = data.result?.devices ?? [];
const physicalDevices = allDevices.map((device) => {
  const hardware = device.hardwareProperties ?? device.properties?.hardware ?? {};
  const details = device.deviceProperties ?? {};
  const connection = device.connectionProperties ?? device.properties?.connection ?? {};
  return {
    coreDeviceId: device.identifier,
    hardwareUdid: hardware.udid,
    name: details.name ?? device.properties?.state?.name ?? '',
    model: hardware.marketingName ?? '',
    osVersion: details.osVersionNumber ?? device.properties?.software?.osVersionNumber?.stringValue ?? '',
    platform: hardware.platform,
    reality: hardware.reality,
    paired: connection.pairingState === 'paired',
    connected: connection.tunnelState === 'connected' || connection.state === 'connected',
  };
}).filter((device) => device.platform === 'iOS' && device.reality === 'physical');
const availableDevices = physicalDevices.filter((device) => device.paired && device.connected);
const describe = (device) => `${device.name} (${device.model}, iOS ${device.osVersion})`;
let matches;

if (selector) {
  matches = physicalDevices.filter((device) => device.hardwareUdid === selector || device.name === selector);
  if (matches.length === 0) {
    console.error(`install device not found: ${selector}`);
    process.exit(2);
  }
  if (matches.length > 1) {
    console.error(`install device selector matched several physical devices: ${matches.map(describe).join('; ')}`);
    process.exit(2);
  }
  if (!availableDevices.includes(matches[0])) {
    console.error(`install device is not paired and available: ${describe(matches[0])}`);
    process.exit(2);
  }
} else {
  matches = availableDevices;
  if (matches.length === 0) {
    console.error('install requires one paired and available physical iOS device; found none');
    process.exit(2);
  }
  if (matches.length > 1) {
    console.error(`install requires exactly one paired and available physical iOS device; found: ${matches.map(describe).join('; ')}`);
    process.exit(2);
  }
}

const device = matches[0];
process.stdout.write([device.coreDeviceId, device.hardwareUdid, device.name, device.model, device.osVersion].join('\t') + '\n');
NODE
  ); then
    rm -f "$devices_json"
    return 2
  fi
  rm -f "$devices_json"
  printf '%s\n' "$resolved"
}

cmd_install() {
  local selector='' launch=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --device)
        [[ $# -ge 2 ]] || { printf '%s\n' 'install --device requires a value' >&2; return 2; }
        selector=$2
        shift 2
        ;;
      --launch)
        launch=1
        shift
        ;;
      *)
        printf 'unknown install option: %s\n' "$1" >&2
        return 2
        ;;
    esac
  done

  cmd_generate
  local team
  team=$(signing_team)
  if [[ -z "$team" ]]; then
    printf '%s\n' 'install requires DEVELOPMENT_TEAM (set it in the environment or ios/Config/Signing.local.xcconfig)' >&2
    return 2
  fi

  local device_info core_device_id hardware_udid device_name device_model device_os
  device_info=$(resolve_install_device "$selector") || return $?
  IFS=$'\t' read -r core_device_id hardware_udid device_name device_model device_os <<< "$device_info"
  printf 'install device: %s (%s, iOS %s)\n' "$device_name" "$device_model" "$device_os"
  printf 'install device identifiers: xcodebuild=%s devicectl=%s\n' "$hardware_udid" "$core_device_id"

  local build_number
  build_number=$(git -C "$ROOT" rev-list --count HEAD)
  local device_derived="$DERIVED/device-derived"
  local app_bundle="$device_derived/Build/Products/Release-iphoneos/cc-controller.app"
  local build_args=(
    xcodebuild
    -project "$PROJECT"
    -scheme CCController
    -configuration Release
    -destination "id=$hardware_udid"
    -derivedDataPath "$device_derived"
    -allowProvisioningUpdates
    -allowProvisioningDeviceRegistration
    DEVELOPMENT_TEAM="$team"
    CURRENT_PROJECT_VERSION="$build_number"
    build
  )
  step 'install build' "${build_args[@]}"
  if [[ ! -d "$app_bundle" ]]; then
    printf 'install build did not produce %s\n' "$app_bundle" >&2
    return 1
  fi

  local bundle_id
  if ! bundle_id=$(plutil -extract CFBundleIdentifier raw -o - "$app_bundle/Info.plist"); then
    printf 'install build produced an app without CFBundleIdentifier: %s\n' "$app_bundle" >&2
    return 1
  fi
  step 'install app' xcrun devicectl device install app --device "$core_device_id" "$app_bundle"
  printf 'installed bundle ID: %s\n' "$bundle_id"
  if [[ $launch -eq 1 ]]; then
    step 'launch app' xcrun devicectl device process launch --device "$core_device_id" "$bundle_id"
  fi
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
  local build_number
  build_number=$(git -C "$ROOT" rev-list --count HEAD)
  local archive_path="$IOS/build/archive/CCController-$build_number.xcarchive"
  if [[ -e "$archive_path" ]]; then
    printf 'commit first or delete %s\n' "$archive_path" >&2
    return 2
  fi
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
  local archive_dir="$IOS/build/archive"
  local selected_archive="" selected_build=-1 archive_path archive_name build
  for archive_path in "$archive_dir"/CCController-*.xcarchive; do
    [[ -d "$archive_path" ]] || continue
    archive_name=${archive_path##*/}
    build=${archive_name#CCController-}
    build=${build%.xcarchive}
    [[ "$build" =~ ^[0-9]+$ ]] || continue
    if (( build > selected_build )); then
      selected_build=$build
      selected_archive=$archive_path
    fi
  done
  if [[ -z "$selected_archive" ]]; then
    printf 'upload requires an archive under %s; run archive first\n' "$archive_dir" >&2
    return 2
  fi
  printf 'uploading build %s from %s\n' "$selected_build" "$selected_archive"
  local export_dir="$IOS/build/export/$selected_build"
  local auth_configured=0
  if [[ -n "${ASC_KEY_PATH:-}${ASC_KEY_ID:-}${ASC_ISSUER_ID:-}" ]]; then
    auth_configured=1
    local input
    for input in ASC_KEY_PATH ASC_KEY_ID ASC_ISSUER_ID; do
      if [[ -z "${!input:-}" ]]; then
        printf 'upload requires %s when App Store Connect API key authentication is used\n' "$input" >&2
        return 2
      fi
    done
  fi
  RUN_DIR=$(mktemp -d -t cc-controller-upload.XXXXXX)
  local export_options="$RUN_DIR/ExportOptions.plist"
  cp "$IOS/Config/ExportOptions.plist" "$export_options"
  plutil -replace teamID -string "$team" "$export_options"
  mkdir -p "$export_dir"
  local args=(
    xcodebuild
    -exportArchive
    -allowProvisioningUpdates
    -archivePath "$selected_archive"
    -exportPath "$export_dir"
    -exportOptionsPlist "$export_options"
  )
  if [[ $auth_configured -eq 1 ]]; then
    args+=(
      -authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID"
    )
  fi
  step upload "${args[@]}"
  printf 'upload export completed: %s\n' "$export_dir"
}

case "${1:-}" in
  generate) shift; step generate cmd_generate "$@";;
  build) shift; step build cmd_build "$@";;
  test) shift; step test cmd_test "$@";;
  release-check) shift; cmd_release_check "$@";;
  perf) shift; cmd_perf "$@";;
  archive) shift; cmd_archive "$@";;
  upload) shift; cmd_upload "$@";;
  shots) shift; cmd_shots "$@";;
  flows) shift; cmd_flows "$@";;
  mocks) shift; cmd_mocks "$@";;
  pool) shift; cmd_pool "$@";;
  clean) shift; cmd_clean "$@";;
  install) shift; cmd_install "$@";;
  *) printf 'Usage: %s {generate|build|test|release-check|perf|archive|upload|shots|flows|mocks|pool|clean|install [--device <udid-or-name>] [--launch]}\n' "$0" >&2; exit 2;;
esac
