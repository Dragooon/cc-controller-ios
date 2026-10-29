#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
IOS="$ROOT/ios"
PROJECT="$IOS/CCController.xcodeproj"
DERIVED="$IOS/build"
RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-27-0"
DEFAULT_DEVICES=("iPhone 18 Pro" "iPhone 16 Plus" "iPhone SE (3rd generation)")
POOL_DEVICE_TYPES=("iPhone 18 Pro" "iPhone 16 Plus" "iPhone SE (3rd generation)" "iPhone Duo")
POOL_CACHE="${CC_IOS_POOL_CACHE:-$HOME/Library/Caches/cc-controller-ios-pool}"
EVIDENCE_ROOT="${CC_EVIDENCE_DIR:-$HOME/dev/cc-controller-evidence}"
SCRATCH_ROOT="${CC_IOS_SCRATCH:-$HOME/Library/Caches/cc-controller-scratch}"
POOL_SLOTS="${CC_IOS_POOL_SLOTS:-4}"
POOL_IDLE_SECONDS=$((20 * 60))
POOL_WAIT_SECONDS=$((60 * 60))
POOL_SLOT=""
POOL_OWNER_PID=""
STARTED_DAEMON=""
STARTED_SECOND_DAEMON=""
FIXTURE_OUT=""
FIXTURE_SECOND_OUT=""
NODE_MODULES_LINKED=0
NODE_MODULES_SOURCE=""
REAL_SMOKE_RUN=0
REAL_DEVICE_NAME=""
REAL_SECRET_DIR=""
REAL_BEARER_FILE=""
REAL_OUTPUT_DIR=""
REAL_RAW_DIR=""
PERF_SCRATCH_DIR=""
REAL_PERF_UDID=""
REAL_PERF_EVENT_PID=""
REAL_PERF_SAMPLER_PID=""
REAL_PERF_COMMAND_PID=""
REAL_SCRATCH_STARTED=0
REAL_SCRATCH_SESSION_ID=""
REAL_SCRATCH_STATE_FILE=""
FIXTURE_LOG=""
FIXTURE_SIM_UDID=""
CURRENT_XCODEBUILD_PID=""
RUN_DIR=""
DIAG_DIR=""
MOCK_RUN_DIR=""
SHARD_CONTROLLER=1
SHARD_PIDS=()
PERF_SAMPLE_PIDS=()
FLOWS_FLAKY_COUNT=0
MOTION_UDID=""
MOTION_VIDEO_PID=""
MOTION_BUILD_DIR=""

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
  node -e 'const fs=require("node:fs"); const value=JSON.parse(fs.readFileSync(process.argv[1], "utf8")); console.log(value[process.argv[2]]);' -- "$1" "$2"
}

scratch_dir_for_evidence() {
  local evidence_dir=$1 relative
  case "$evidence_dir" in
    "$EVIDENCE_ROOT") relative="";;
    "$EVIDENCE_ROOT"/*) relative=${evidence_dir#"$EVIDENCE_ROOT"/};;
    *) relative=$(basename "$evidence_dir");;
  esac
  if [[ -n "$relative" ]]; then
    printf '%s/%s\n' "$SCRATCH_ROOT" "$relative"
  else
    printf '%s\n' "$SCRATCH_ROOT"
  fi
}

prune_scratch() {
  if [[ -z "$SCRATCH_ROOT" ]]; then
    printf '%s\n' 'warning: CC_IOS_SCRATCH is empty; skipping scratch prune' >&2
    return 0
  fi
  if ! mkdir -p "$SCRATCH_ROOT"; then
    printf 'warning: could not create scratch root: %s\n' "$SCRATCH_ROOT" >&2
    return 0
  fi
  if ! find "$SCRATCH_ROOT" -mindepth 1 -depth ! -type d -mmin +1440 -delete; then
    printf 'warning: scratch file pruning failed under %s\n' "$SCRATCH_ROOT" >&2
  fi
  if ! find "$SCRATCH_ROOT" -mindepth 1 -type d -empty -mmin +1440 -delete; then
    printf 'warning: scratch directory pruning failed under %s\n' "$SCRATCH_ROOT" >&2
  fi
}

prepare_evidence_run() {
  local evidence_dir=$1 scratch_dir
  scratch_dir=$(scratch_dir_for_evidence "$evidence_dir")
  mkdir -p "$evidence_dir" "$scratch_dir"
  printf '%s\n' "$scratch_dir" > "$evidence_dir/raw.txt"
}

main_checkout() {
  local common_dir
  common_dir=$(git -C "$ROOT" rev-parse --git-common-dir)
  [[ "$common_dir" = /* ]] || common_dir="$ROOT/$common_dir"
  dirname "$common_dir"
}

ensure_node_modules() {
  [[ -e "$ROOT/node_modules" ]] && return 0
  NODE_MODULES_SOURCE="$(main_checkout)/node_modules"
  [[ -d "$NODE_MODULES_SOURCE" ]] || {
    printf 'main checkout node_modules is missing: %s\n' "$NODE_MODULES_SOURCE" >&2
    return 1
  }
  ln -s "$NODE_MODULES_SOURCE" "$ROOT/node_modules"
  NODE_MODULES_LINKED=1
}

validate_mock_screens() {
  local selection=$1
  [[ -z "$selection" ]] && return 0
  local valid=",sessions,sessions-empty,sessions-offline,sessions-reconnecting,session-idle,session-working,session-sending-states,subagent-result-sheet,session-activity,session-approvals,session-terminal-approval,activity-sheet,composer-slash,composer-attachments,composer-keyboard,tool-detail,tool-detail-edit,subagent,inspector,settings,onboarding-welcome,onboarding-connect,onboarding-pair,onboarding-faceid,lock,privacy-cover,working-bar-1-thinking,working-bar-2-tool-agents,working-bar-3-typing,working-bar-4-idle,working-bar-5-current,"
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
  xcrun simctl list devices -j | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const mode=process.argv[1],state=process.argv[2],values=new Set(process.argv.slice(3));for(const devices of Object.values(JSON.parse(d).devices)){for(const x of devices){const matchesState=state==="all"||x.state===state;const matchesName=mode==="exact"?values.has(x.name):x.name.startsWith(process.argv[3]);if(matchesState&&matchesName) console.log(x.udid)}}})' -- "$mode" "$state" "$@"
}

simulator_udid() {
  local name=$1
  local values
  values=$(simulator_udids exact all "$name")
  [[ -z "$values" ]] || printf '%s\n' "${values%%$'\n'*}"
}

simulator_state() {
  local udid=$1
  xcrun simctl list devices -j | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{for(const devices of Object.values(JSON.parse(d).devices)){for(const x of devices){if(x.udid===process.argv[1]){console.log(x.state);process.exit(0)}}}})' -- "$udid"
}

configure_keyboard() {
  local udid=$1
  xcrun simctl spawn "$udid" defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true
}

disable_pool_posterboard() {
  local udid=$1
  # PosterBoard crashes in PRPosterDescriptor _initWithPath: on this runtime, raising macOS crash dialogs.
  if ! xcrun simctl spawn "$udid" launchctl disable user/foreground/com.apple.PosterBoard >/dev/null 2>&1; then
    printf 'warning: could not disable PosterBoard for pool simulator %s\n' "$udid" >&2
  fi
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
  local pid
  for pid in "$STARTED_DAEMON" "$STARTED_SECOND_DAEMON"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      for _ in {1..50}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  STARTED_DAEMON=""
  STARTED_SECOND_DAEMON=""
  if [[ -n "$FIXTURE_OUT" ]]; then
    rm -f "$FIXTURE_OUT"
    FIXTURE_OUT=""
  fi
  if [[ -n "$FIXTURE_SECOND_OUT" ]]; then
    rm -f "$FIXTURE_SECOND_OUT"
    FIXTURE_SECOND_OUT=""
  fi
}

start_fixture_daemon() {
  FIXTURE_LOG=$1
  local scenario=${2:-default}
  local mode=${3:-C}
  local private_fixture=${4:-}
  FIXTURE_OUT=$(mktemp -t cc-controller-fixture.XXXXXX)
  if [[ "$scenario" == 'perf' && -n "$private_fixture" ]]; then
    CC_FIXTURE_SIM_UDID="$FIXTURE_SIM_UDID" CC_PERF_MODE="$mode" CC_FIXTURE_LONG_SESSION_PATH="$private_fixture" node "$ROOT/scripts/fixture-daemon.mjs" --scenario perf --mode "$mode" --out "$FIXTURE_OUT" --relay >"$FIXTURE_LOG" 2>&1 &
  elif [[ "$scenario" == 'perf' ]]; then
    CC_FIXTURE_SIM_UDID="$FIXTURE_SIM_UDID" CC_PERF_MODE="$mode" node "$ROOT/scripts/fixture-daemon.mjs" --scenario perf --mode "$mode" --out "$FIXTURE_OUT" --relay >"$FIXTURE_LOG" 2>&1 &
  else
    CC_FIXTURE_SIM_UDID="$FIXTURE_SIM_UDID" node "$ROOT/scripts/fixture-daemon.mjs" --scenario default --out "$FIXTURE_OUT" --relay >"$FIXTURE_LOG" 2>&1 &
  fi
  STARTED_DAEMON=$!
  for _ in {1..100}; do [[ -s "$FIXTURE_OUT" ]] && break; sleep 0.1; done
  if [[ ! -s "$FIXTURE_OUT" ]]; then
    printf '%s\n' 'fixture daemon did not become ready' >&2
    return 1
  fi

  FIXTURE_SECOND_OUT=$(mktemp -t cc-controller-fixture-mustafar.XXXXXX)
  CC_FIXTURE_SIM_UDID="$FIXTURE_SIM_UDID" node "$ROOT/scripts/fixture-daemon.mjs" \
    --scenario default --session-set mustafar --controller-id mustafar --controller-name Mustafar \
    --controller-kind stockade --out "$FIXTURE_SECOND_OUT" \
    >"$FIXTURE_LOG.mustafar" 2>&1 &
  STARTED_SECOND_DAEMON=$!
  for _ in {1..100}; do [[ -s "$FIXTURE_SECOND_OUT" ]] && break; sleep 0.1; done
  if [[ ! -s "$FIXTURE_SECOND_OUT" ]]; then
    printf '%s\n' 'second fixture daemon did not become ready' >&2
    return 1
  fi
  if [[ -n "${CC_FIXTURE_SECOND_BOOTSTRAP_FILE:-}" ]]; then
    curl -fsS -H "Authorization: Bearer $(json_value "$FIXTURE_SECOND_OUT" bearer)" \
      "http://127.0.0.1:$(json_value "$FIXTURE_SECOND_OUT" webPort)/api/bootstrap" \
      > "$CC_FIXTURE_SECOND_BOOTSTRAP_FILE"
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

pool_runtime_for_device() {
  local device=$1
  if [[ "$device" == 'iPhone Duo' ]]; then
    printf '%s\n' 'com.apple.CoreSimulator.SimRuntime.iOS-27-1'
  else
    printf '%s\n' "$RUNTIME"
  fi
}

ensure_pool_devices() {
  local slot=$1
  mkdir -p "$POOL_CACHE" "$(pool_slot_dir "$slot")"
  local device name udid runtime
  for device in "${POOL_DEVICE_TYPES[@]}"; do
    name=$(pool_device_name "$slot" "$device")
    udid=$(simulator_udid "$name" || true)
    if [[ -z "$udid" ]]; then
      runtime=$(pool_runtime_for_device "$device")
      udid=$(xcrun simctl create "$name" "$device" "$runtime")
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
  disable_pool_posterboard "$udid"
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
  xcrun simctl spawn "$udid" notifyutil -s com.apple.BiometricKit.enrollmentChanged 1
  xcrun simctl spawn "$udid" notifyutil -p com.apple.BiometricKit.enrollmentChanged
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
  local mocks="" set_mocks=0 real_smoke=0 real_sessions="" real_output=""
  if [[ $# -ge 8 ]]; then
    mocks=$8
    set_mocks=1
  fi
  [[ $# -lt 9 ]] || real_smoke=$9
  [[ $# -lt 10 ]] || real_sessions=${10}
  [[ $# -lt 11 ]] || real_output=${11}
  cp "$source" "$destination"
  if plutil -extract TestConfigurations xml1 -o - "$destination" >/dev/null 2>&1; then
    printf '%s\n' 'format-2 .xctestrun files with TestConfigurations are unsupported' >&2
    return 1
  fi
  if ! plutil -extract CCControllerUITests.EnvironmentVariables xml1 -o - "$destination" >/dev/null 2>&1; then
    printf 'xctestrun is missing CCControllerUITests.EnvironmentVariables: %s\n' "$destination" >&2
    return 1
  fi
  local relay_port="" relay_pin="" second_fixture_url="" second_fixture_bearer=""
  local second_tls_port="" second_tls_pin="" second_control_url=""
  if [[ -n "$FIXTURE_OUT" && -s "$FIXTURE_OUT" ]]; then
    relay_port=$(json_value "$FIXTURE_OUT" relayPort)
    relay_pin=$(json_value "$FIXTURE_OUT" relaySpkiSha256)
  fi
  if [[ -n "$FIXTURE_SECOND_OUT" && -s "$FIXTURE_SECOND_OUT" ]]; then
    second_fixture_url="http://127.0.0.1:$(json_value "$FIXTURE_SECOND_OUT" webPort)"
    second_fixture_bearer=$(json_value "$FIXTURE_SECOND_OUT" bearer)
    second_tls_port=$(json_value "$FIXTURE_SECOND_OUT" tlsPort)
    second_tls_pin=$(json_value "$FIXTURE_SECOND_OUT" tlsSpkiSha256)
    second_control_url="http://127.0.0.1:$(json_value "$FIXTURE_SECOND_OUT" controlPort)"
  fi
  local entries=(
    TEST_RUNNER_SERVER_URL "$server"
    TEST_RUNNER_BEARER "$bearer"
    TEST_RUNNER_RELAY_PORT "$relay_port"
    TEST_RUNNER_RELAY_PIN "$relay_pin"
    TEST_RUNNER_FIXTURE_CONTROL_URL "$control"
    TEST_RUNNER_SECOND_FIXTURE_URL "$second_fixture_url"
    TEST_RUNNER_SECOND_FIXTURE_BEARER "$second_fixture_bearer"
    TEST_RUNNER_SECOND_FIXTURE_TLS_PORT "$second_tls_port"
    TEST_RUNNER_SECOND_FIXTURE_TLS_PIN "$second_tls_pin"
    TEST_RUNNER_SECOND_FIXTURE_CONTROL_URL "$second_control_url"
    TEST_RUNNER_COLOR_SCHEME "$color"
    TEST_RUNNER_MOTION_TRACE "${TEST_RUNNER_MOTION_TRACE:-}"
    TEST_RUNNER_MOTION_SCENARIO "${TEST_RUNNER_MOTION_SCENARIO:-}"
    TEST_RUNNER_MOTION_ORIENTATION "${TEST_RUNNER_MOTION_ORIENTATION:-}"
    TEST_RUNNER_CC_TRANSCRIPT_ENGINE "${TEST_RUNNER_CC_TRANSCRIPT_ENGINE:-}"
    CCMotionBuildSHA "${CCMotionBuildSHA:-}"
    CCMotionDevice "${CCMotionDevice:-}"
    CC_FLOW_OUTPUT_DIR "$output_dir"
    TEST_RUNNER_REAL_SMOKE "$real_smoke"
    TEST_RUNNER_REAL_SESSIONS "$real_sessions"
    TEST_RUNNER_REAL_SMOKE_OUTPUT_DIR "$real_output"
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
  if [[ -n "$REAL_PERF_EVENT_PID" ]]; then
    kill -TERM "$REAL_PERF_EVENT_PID" 2>/dev/null || true
    wait "$REAL_PERF_EVENT_PID" 2>/dev/null || true
    REAL_PERF_EVENT_PID=""
  fi
  if [[ -n "$REAL_PERF_SAMPLER_PID" ]]; then
    kill -TERM "$REAL_PERF_SAMPLER_PID" 2>/dev/null || true
    wait "$REAL_PERF_SAMPLER_PID" 2>/dev/null || true
    REAL_PERF_SAMPLER_PID=""
  fi
  if [[ -n "$REAL_PERF_COMMAND_PID" ]]; then
    terminate_process_tree "$REAL_PERF_COMMAND_PID"
    wait "$REAL_PERF_COMMAND_PID" 2>/dev/null || true
    REAL_PERF_COMMAND_PID=""
  fi
  if [[ -n "$REAL_PERF_UDID" ]]; then
    xcrun simctl terminate "$REAL_PERF_UDID" com.example.cc-controller >/dev/null 2>&1 || true
  fi
  for sample_pid in "${PERF_SAMPLE_PIDS[@]:-}"; do
    [[ -z "$sample_pid" ]] || { kill "$sample_pid" 2>/dev/null || true; wait "$sample_pid" 2>/dev/null || true; }
  done
  PERF_SAMPLE_PIDS=()
  stop_motion_video || true
  stop_current_xcodebuild || true
  stop_fixture_daemon || true
  if [[ -n "$DIAG_DIR" ]]; then
    mkdir -p "$DIAG_DIR"
    if [[ -n "$FIXTURE_LOG" ]]; then
      cp "$FIXTURE_LOG" "$DIAG_DIR/fixture-daemon.log" 2>/dev/null || true
      cp "$FIXTURE_LOG.mustafar" "$DIAG_DIR/fixture-daemon-mustafar.log" 2>/dev/null || true
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
  if [[ -n "$MOTION_UDID" ]]; then
    xcrun simctl shutdown "$MOTION_UDID" >/dev/null 2>&1 || true
    MOTION_UDID=""
  fi
  release_pool_slot || true
  return "$status"
}

remove_node_modules_link() {
  if [[ "$NODE_MODULES_LINKED" -eq 1 && -L "$ROOT/node_modules" ]]; then
    rm "$ROOT/node_modules"
    NODE_MODULES_LINKED=0
  fi
}

revoke_real_device() {
  [[ "$REAL_SMOKE_RUN" -eq 1 ]] || return 0
  local main_root devices_file revoke_status=0 devices_status=0
  main_root=$(main_checkout)
  if ! node "$main_root/src/cli.js" revoke "$REAL_DEVICE_NAME" >"$REAL_OUTPUT_DIR/revoke.txt" 2>&1; then
    revoke_status=1
  fi
  devices_file="$REAL_OUTPUT_DIR/devices-after.txt"
  if ! node "$main_root/src/cli.js" devices >"$devices_file" 2>&1; then
    devices_status=1
  fi
  printf '%s\n' 'devices after real-smoke:'
  if [[ -f "$devices_file" ]]; then
    cat "$devices_file"
  fi
  if [[ "$devices_status" -eq 0 ]] && ! node - -- "$devices_file" <<'NODE'
const fs = require('node:fs');
const [file] = process.argv.slice(3);
const payload = JSON.parse(fs.readFileSync(file, 'utf8'));
const devices = Array.isArray(payload?.devices) ? payload.devices : [];
if (devices.some((device) => String(device?.name ?? '').startsWith('cc-real-smoke-'))) process.exit(1);
NODE
  then
    printf 'device revocation verification failed for %s\n' "$REAL_DEVICE_NAME" >&2
    revoke_status=1
  fi
  [[ "$revoke_status" -eq 0 && "$devices_status" -eq 0 ]]
}

cleanup_on_exit() {
  local status=$?
  trap - EXIT INT TERM
  # Cleanup must not replace a passing test status with an incidental cleanup failure.
  set +e
  if [[ $SHARD_CONTROLLER -eq 1 ]]; then
    stop_shards
  fi
  cleanup_run "$status" || true
  if (( REAL_SCRATCH_STARTED )); then
    if ! "$ROOT/scripts/perf-scratch-session.sh" stop; then
      printf '%s\n' 'perf-real scratch session cleanup failed' >&2
      status=1
    fi
    REAL_SCRATCH_STARTED=0
  fi
  revoke_real_device || status=1
  [[ -z "$REAL_SECRET_DIR" ]] || rm -rf "$REAL_SECRET_DIR"
  remove_node_modules_link
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
  for device in "${DEFAULT_DEVICES[@]}" "${devices[@]+"${devices[@]}"}"; do
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
  for device in "${devices[@]+"${devices[@]}"}"; do
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
      node -e 'const fs=require("node:fs");const path=require("node:path");const p=process.argv[1],dir=path.dirname(p),d=JSON.parse(fs.readFileSync(p)),attachments=Array.isArray(d)?d.flatMap((entry)=>entry.attachments??[]):d.attachments??[];for(const a of attachments){const suggested=a.suggestedHumanReadableName||a.filename||"";if(!suggested.toLowerCase().endsWith(".png"))continue;const name=suggested.replace(/_[0-9]+_[0-9a-f-]+\.png$/i,".png");const old=a.exportedFileName||a.exportedFilePath||a.filename;const src=path.join(dir,old);const dst=path.join(dir,name);if(fs.existsSync(src)&&src!==dst)fs.renameSync(src,dst);}' -- "$manifest"
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

run_flow_method() {
  local label=$1 flow_class=$2 flow_method=$3 udid=$4 output_dir=$5 raw_output_dir=$6 result=$7 exported=$8 source_xctestrun=$9 app_bundle=${10}
  local method_log="$raw_output_dir/xcodebuild.log" method_xctestrun="$exported/CCController.xctestrun"
  local method_status=0 xcode_status=0 export_status=0

  rm -rf "$output_dir" "$raw_output_dir" "$result" "$exported"
  mkdir -p "$output_dir" "$raw_output_dir" "$(dirname "$result")" "$exported"
  ln -s "$DERIVED/Build/Products/Debug-iphonesimulator" "$exported/Debug-iphonesimulator"

  stop_fixture_daemon
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
  if [[ $method_status -eq 0 ]] && start_fixture_daemon "$raw_output_dir/fixture.log"; then
    web_port=$(json_value "$FIXTURE_OUT" webPort)
    bearer=$(json_value "$FIXTURE_OUT" bearer)
    control_port=$(json_value "$FIXTURE_OUT" controlPort)
    if configure_xctestrun "$source_xctestrun" "$method_xctestrun" \
      "http://127.0.0.1:$web_port" "$bearer" "http://127.0.0.1:$control_port" \
      "${TEST_RUNNER_COLOR_SCHEME:-light}" "$output_dir"; then
      local args=(xcodebuild -xctestrun "$method_xctestrun" -destination "id=$udid" -resultBundlePath "$result" "-only-testing:CCControllerUITests/$flow_class/$flow_method" -collect-test-diagnostics never test-without-building)
      if run_flow_test "$label" "$method_log" "${args[@]}"; then
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
          node -e 'const fs=require("node:fs"),path=require("node:path"),p=process.argv[1],dir=path.dirname(p),d=JSON.parse(fs.readFileSync(p)),attachments=Array.isArray(d)?d.flatMap((entry)=>entry.attachments??[]):d.attachments??[];for(const a of attachments){const suggested=a.suggestedHumanReadableName||a.filename||"";const old=a.exportedFileName||a.exportedFilePath||a.filename;let name=suggested.replace(/_[0-9]+_[0-9a-f-]+\.(png|txt)$/i,".$1");if(!path.extname(name))name+=path.extname(old);const src=path.join(dir,old),dst=path.join(dir,name);if(fs.existsSync(src)&&src!==dst)fs.renameSync(src,dst);}' -- "$manifest"
        fi
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
  if [[ $method_status -ne 0 && -d "$exported" ]]; then
    find "$exported" -maxdepth 1 -type f -name '*.png' -exec cp {} "$output_dir" \;
    find "$exported" -maxdepth 1 -type f -name '*.txt' -exec cp {} "$output_dir" \;
  fi
  return "$method_status"
}

run_flow_shard() {
  local shard_index=$1 shard_count=$2 result_file=$3 app_bundle=$4 xctestrun=$5 flow_root=$6 flow_scratch_root=$7
  SHARD_CONTROLLER=0
  SHARD_PIDS=()
  RUN_DIR=$(mktemp -d -t cc-controller-flow-shard.XXXXXX)
  local shard_failed=0
  local shard_udids=() device device_index udid
  local index flow_class flow_method

  pool_acquire
  for device in "${devices[@]+"${devices[@]}"}"; do
    shard_udids+=("$(ensure_pool_device "$device")")
  done

  for index in "${!selected_methods[@]}"; do
    if (( index % shard_count != shard_index )); then
      continue
    fi
    flow_class=${selected_classes[$index]}
    flow_method=${selected_methods[$index]}
    device_index=0
    for device in "${devices[@]+"${devices[@]}"}"; do
      local method_started=$SECONDS
      local device_key result output_dir raw_output_dir exported udid method_status=0
      device_key=$(echo "$device" | tr ' ()' '---')
      output_dir="$flow_root/$device_key/$flow_class/$flow_method"
      raw_output_dir="$flow_scratch_root/$device_key/$flow_class/$flow_method"
      result="$raw_output_dir/result.xcresult"
      exported="$RUN_DIR/$device_key/$flow_class/$flow_method"
      udid=${shard_udids[$device_index]}
      if run_flow_method "flows $flow_class/$flow_method $device" "$flow_class" "$flow_method" "$udid" "$output_dir" "$raw_output_dir" "$result" "$exported" "$xctestrun" "$app_bundle"; then
        method_status=0
      else
        method_status=$?
      fi
      local elapsed=$((SECONDS - method_started))
      local result_label=PASS
      if [[ $method_status -ne 0 ]]; then
        result_label=FAIL
        shard_failed=$((shard_failed + 1))
      elif grep -Eq 'Test Case .* skipped' "$raw_output_dir/xcodebuild.log"; then
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
  prune_scratch
  local devices=() test_filters=() shard_count=1 no_rerun=0
  FLOWS_FLAKY_COUNT=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --device)
        [[ $# -ge 2 ]] || { printf '%s\n' 'flows --device requires a value' >&2; exit 2; }
        devices+=("$2")
        shift 2
        ;;
      --test)
        [[ $# -ge 2 ]] || { printf '%s\n' 'flows --test requires a value' >&2; exit 2; }
        test_filters+=("$2")
        shift 2
        ;;
      --shards)
        [[ $# -ge 2 ]] || { printf '%s\n' 'flows --shards requires a value' >&2; exit 2; }
        shard_count=$2
        shift 2
        ;;
      --no-rerun)
        no_rerun=1
        shift
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
    if [[ "$flow_class" == MotionFlowTests && ${#test_filters[@]} -eq 0 ]]; then
      continue
    fi
    flow_files+=("$flow_file")
    while IFS= read -r flow_method; do
      [[ -z "$flow_method" ]] && continue
      flow_method_classes+=("$flow_class")
      flow_methods+=("$flow_method")
    done < <(sed -nE 's/^[[:space:]]*func[[:space:]]+(test[A-Za-z0-9_]*).*/\1/p' "$flow_file")
  done < <(find "$IOS/UITests" -type f \( -name '*FlowTests.swift' -o -name 'SmokeFlowTests.swift' -o -name 'RealControllerSmokeTests.swift' -o -name 'RelayConnectionTests.swift' \) -print | sort)
  if [[ ${#flow_files[@]} -eq 0 ]]; then
    printf '%s\n' 'no flow tests found'
    return 0
  fi
  if [[ ${#flow_methods[@]} -eq 0 ]]; then
    printf '%s\n' 'no flow test methods found'
    return 0
  fi

  local selected_classes=() selected_methods=() selected_count=0
  local index filter selector_class selector_method filter_has_method matched
  for filter in "${test_filters[@]+"${test_filters[@]}"}"; do
    selector_class=$filter
    selector_method=""
    filter_has_method=0
    if [[ "$filter" == */* ]]; then
      filter_has_method=1
      selector_class=${filter%%/*}
      selector_method=${filter#*/}
    fi
    matched=0
    for index in "${!flow_methods[@]}"; do
      flow_class=${flow_method_classes[$index]}
      flow_method=${flow_methods[$index]}
      [[ "$selector_class" == "$flow_class" ]] || continue
      [[ $filter_has_method -eq 0 || "$selector_method" == "$flow_method" ]] || continue
      matched=1
      break
    done
    if [[ $matched -eq 0 ]]; then
      printf 'unknown flow test: %s\n' "$filter" >&2
      return 2
    fi
  done
  for index in "${!flow_methods[@]}"; do
    flow_class=${flow_method_classes[$index]}
    flow_method=${flow_methods[$index]}
    matched=0
    for filter in "${test_filters[@]+"${test_filters[@]}"}"; do
      selector_class=$filter
      selector_method=""
      filter_has_method=0
      if [[ "$filter" == */* ]]; then
        filter_has_method=1
        selector_class=${filter%%/*}
        selector_method=${filter#*/}
      fi
      if [[ "$selector_class" == "$flow_class" && ($filter_has_method -eq 0 || "$selector_method" == "$flow_method") ]]; then
        matched=1
        break
      fi
    done
    [[ ${#test_filters[@]} -eq 0 || $matched -eq 1 ]] || continue
    selected_classes+=("$flow_class")
    selected_methods+=("$flow_method")
    selected_count=$((selected_count + 1))
  done

  if [[ -n "${CC_MOCK_LANE:-}" ]]; then
    DERIVED="$IOS/build/flow-derived-$CC_MOCK_LANE"
  fi
  step generate cmd_generate
  local flow_root="$EVIDENCE_ROOT/flows/$(date -u '+%Y%m%dT%H%M%SZ')"
  if [[ -n "${CC_MOCK_LANE:-}" ]]; then
    flow_root="$flow_root/$CC_MOCK_LANE"
  fi
  [[ ! -e "$flow_root" ]] || flow_root="${flow_root}-$$"
  local flow_scratch_root
  flow_scratch_root=$(scratch_dir_for_evidence "$flow_root")
  prepare_evidence_run "$flow_root"
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
      run_flow_shard "$shard" "$shard_count" "$shard_result_dir/shard-$shard.tsv" "$app_bundle" "$xctestrun" "$flow_root" "$flow_scratch_root"
    ) &
    shard_pid=$!
    SHARD_PIDS+=("$shard_pid")
  done

  local summary_file="$flow_root/summary.txt"
  : > "$summary_file"
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
  local failed_tests=()
  local result_index result_device_index result_class result_method result_device result_label result_seconds
  printf '\nFlow summary\n' | tee -a "$summary_file"
  printf '%-70s %-8s %8s\n' 'class/method [device]' 'result' 'seconds' | tee -a "$summary_file"
  while IFS=$'\t' read -r result_index result_device_index result_class result_method result_device result_label result_seconds; do
    [[ -z "$result_index" ]] && continue
    printf '%-70s %-8s %8s\n' "$result_class/$result_method [$result_device]" "$result_label" "$result_seconds" | tee -a "$summary_file"
    summary_count=$((summary_count + 1))
    case "$result_label" in
      PASS) passed=$((passed + 1));;
      FAIL)
        failed=$((failed + 1))
        local failed_test="$result_class/$result_method" already_listed=0 listed_test
        for listed_test in "${failed_tests[@]:-}"; do
          if [[ "$listed_test" == "$failed_test" ]]; then
            already_listed=1
            break
          fi
        done
        [[ $already_listed -eq 1 ]] || failed_tests+=("$failed_test")
        ;;
      SKIP) skipped=$((skipped + 1));;
    esac
  done < <(LC_ALL=C sort -t $'\t' -k1,1n -k2,2n "${result_files[@]}")

  printf '%s passed, %s failed, %s skipped\n' "$passed" "$failed" "$skipped" | tee -a "$summary_file"
  if [[ $summary_count -ne $((selected_count * ${#devices[@]})) ]]; then
    printf 'flow summary contains %s of %s expected methods\n' "$summary_count" "$((selected_count * ${#devices[@]}))" >&2
    shard_status=1
  fi
  if [[ $no_rerun -eq 1 ]]; then
    if [[ $failed -ne 0 || $shard_status -ne 0 ]]; then
      printf '%s\n' 'one or more flow shards failed' >&2
      return 1
    fi
    printf '%s\n' "flow shots written to $flow_root"
    return 0
  fi

  local rerun_device=${devices[0]} rerun_device_key rerun_udid rerun_failed=0
  local flaky_tests=() failed_again_tests=() failed_test flow_class flow_method
  rerun_device_key=$(echo "$rerun_device" | tr ' ()' '---')
  if [[ ${#failed_tests[@]} -gt 0 ]]; then
    pool_acquire
    rerun_udid=$(ensure_pool_device "$rerun_device")
    for failed_test in "${failed_tests[@]}"; do
      flow_class=${failed_test%%/*}
      flow_method=${failed_test#*/}
      local rerun_output_dir="$flow_root/$rerun_device_key/$flow_class/$flow_method/rerun-1"
      local rerun_raw_output_dir="$flow_scratch_root/$rerun_device_key/$flow_class/$flow_method/rerun-1"
      local rerun_result="$rerun_raw_output_dir/result.xcresult"
      local rerun_exported="$RUN_DIR/rerun-$rerun_device_key/$flow_class/$flow_method"
      local rerun_status=0
      if run_flow_method "flows rerun-1 $flow_class/$flow_method $rerun_device" "$flow_class" "$flow_method" "$rerun_udid" "$rerun_output_dir" "$rerun_raw_output_dir" "$rerun_result" "$rerun_exported" "$xctestrun" "$app_bundle"; then
        rerun_status=0
      else
        rerun_status=$?
      fi
      if [[ $rerun_status -eq 0 ]]; then
        flaky_tests+=("$failed_test")
      else
        failed_again_tests+=("$failed_test")
        rerun_failed=1
      fi
    done
    release_pool_slot || true
  fi

  FLOWS_FLAKY_COUNT=${#flaky_tests[@]}
  printf 'flows flaky=%s' "$FLOWS_FLAKY_COUNT"
  [[ $FLOWS_FLAKY_COUNT -eq 0 ]] || printf ' %s' "$(IFS=,; printf '%s' "${flaky_tests[*]}")"
  printf '\n'
  printf 'flows failed=%s' "${#failed_again_tests[@]}"
  [[ ${#failed_again_tests[@]} -eq 0 ]] || printf ' %s' "$(IFS=,; printf '%s' "${failed_again_tests[*]}")"
  printf '\n'

  local idle_stall_line='App animations complete notification not received, will attempt to continue'
  local idle_original_count idle_rerun_count original_log rerun_log stall_count
  for index in "${!selected_methods[@]}"; do
    flow_class=${selected_classes[$index]}
    flow_method=${selected_methods[$index]}
    idle_original_count=0
    for device in "${devices[@]+"${devices[@]}"}"; do
      local original_device_key=$(echo "$device" | tr ' ()' '---')
      original_log="$flow_scratch_root/$original_device_key/$flow_class/$flow_method/xcodebuild.log"
      if [[ -f "$original_log" ]]; then
        stall_count=$(grep -cF "$idle_stall_line" "$original_log" 2>/dev/null || true)
        idle_original_count=$((idle_original_count + stall_count))
      fi
    done
    idle_rerun_count=0
    rerun_log="$flow_scratch_root/$rerun_device_key/$flow_class/$flow_method/rerun-1/xcodebuild.log"
    if [[ -f "$rerun_log" ]]; then
      idle_rerun_count=$(grep -cF "$idle_stall_line" "$rerun_log" 2>/dev/null || true)
    fi
    if [[ $((idle_original_count + idle_rerun_count)) -gt 0 ]]; then
      printf 'flows idle-stalls %s/%s=%s (rerun %s)\n' "$flow_class" "$flow_method" "$idle_original_count" "$idle_rerun_count"
    fi
  done

  if [[ $rerun_failed -ne 0 || $summary_count -ne $((selected_count * ${#devices[@]})) || ($shard_status -ne 0 && $failed -eq 0) ]]; then
    printf '%s\n' 'one or more flow tests failed after rerun' >&2
    return 1
  fi
  printf '%s\n' "flow shots written to $flow_root"
  return 0
}

stop_motion_video() {
  local pid=$MOTION_VIDEO_PID
  [[ -n "$pid" ]] || return 0
  kill -INT "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  MOTION_VIDEO_PID=""
}

motion_source_hash() {
  node - "$ROOT" <<'NODE'
const crypto = require('node:crypto');
const fs = require('node:fs');
const { execFileSync } = require('node:child_process');
const root = process.argv[2];
const hash = crypto.createHash('sha256');
const diff = execFileSync('git', ['-C', root, 'diff', '--binary', 'HEAD'], { maxBuffer: 1024 * 1024 * 1024 });
const files = execFileSync('git', ['-C', root, 'ls-files', '--others', '--exclude-standard', '-z', '--', 'ios'], { encoding: 'utf8' })
  .split('\0')
  .filter(Boolean)
  .sort();
hash.update(Buffer.from('diff\0'));
hash.update(diff);
for (const file of files) {
  hash.update(Buffer.from(`untracked:${file}\0`));
  hash.update(fs.readFileSync(`${root}/${file}`));
  hash.update(Buffer.from('\0'));
}
process.stdout.write(hash.digest('hex'));
NODE
}

motion_prune_build_cache() {
  local cache_root=$1
  node - "$cache_root" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const root = process.argv[2];
if (!fs.existsSync(root)) process.exit(0);
const dirs = fs.readdirSync(root, { withFileTypes: true })
  .filter((entry) => entry.isDirectory())
  .map((entry) => ({ name: entry.name, mtime: fs.statSync(path.join(root, entry.name)).mtimeMs }))
  .sort((a, b) => a.mtime - b.mtime);
while (dirs.length > 3) {
  const old = dirs.shift();
  fs.rmSync(path.join(root, old.name), { recursive: true, force: true });
  console.log(`motion build cache pruned: ${old.name}`);
}
NODE
}

motion_build_products() {
  local key=$1 rebuild=$2
  local cache_root="$HOME/Library/Caches/cc-controller-scratch/motion-builds"
  local cache_dir="$cache_root/$key"
  local motion_derived="$cache_dir/derived"
  local app_bundle="$motion_derived/Build/Products/Debug-iphonesimulator/cc-controller.app"
  local source_xctestrun=""
  mkdir -p "$cache_root" "$cache_dir"
  MOTION_BUILD_DIR="$cache_dir"
  if [[ "$rebuild" -eq 0 && -d "$app_bundle" ]]; then
    source_xctestrun=$(find "$motion_derived/Build/Products" -type f -name '*.xctestrun' -print -quit)
    if [[ -n "$source_xctestrun" ]]; then
      touch "$cache_dir"
      printf 'motion build-for-testing cache hit: %s\n' "$key"
      motion_prune_build_cache "$cache_root"
      return 0
    fi
  fi
  local build_args=(xcodebuild -project "$PROJECT" -scheme CCController -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath "$motion_derived" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build-for-testing)
  step 'motion build-for-testing' "${build_args[@]}"
  source_xctestrun=$(find "$motion_derived/Build/Products" -type f -name '*.xctestrun' -print -quit)
  if [[ ! -d "$app_bundle" || -z "$source_xctestrun" ]]; then
    printf 'motion build did not produce app and xctestrun under %s\n' "$cache_dir" >&2
    return 1
  fi
  touch "$cache_dir"
  motion_prune_build_cache "$cache_root"
}

cmd_motion() {
  prune_scratch
  local scenarios="all" engines="both" device="iphone" out_dir="" orientation="portrait" rebuild=0 video_enabled=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --scenario) [[ $# -ge 2 ]] || { printf '%s\n' 'motion --scenario requires a value' >&2; return 2; }; scenarios=$2; shift 2;;
      --engine) [[ $# -ge 2 ]] || { printf '%s\n' 'motion --engine requires a value' >&2; return 2; }; engines=$2; shift 2;;
      --device) [[ $# -ge 2 ]] || { printf '%s\n' 'motion --device requires a value' >&2; return 2; }; device=$2; shift 2;;
      --out) [[ $# -ge 2 ]] || { printf '%s\n' 'motion --out requires a value' >&2; return 2; }; out_dir=$2; shift 2;;
      --orientation) [[ $# -ge 2 ]] || { printf '%s\n' 'motion --orientation requires a value' >&2; return 2; }; orientation=$2; shift 2;;
      --rebuild) rebuild=1; shift;;
      --video) video_enabled=1; shift;;
      *) printf 'unknown motion option: %s\n' "$1" >&2; return 2;;
    esac
  done
  [[ "$device" == iphone || "$device" == duo ]] || { printf 'motion --device must be iphone or duo\n' >&2; return 2; }
  [[ "$orientation" == portrait || "$orientation" == landscape ]] || { printf 'motion --orientation must be portrait or landscape\n' >&2; return 2; }
  [[ "$engines" == legacy || "$engines" == collection || "$engines" == both ]] || { printf 'motion --engine must be legacy, collection, or both\n' >&2; return 2; }
  if [[ "$scenarios" == all ]]; then scenarios="K1,K2,S1,S2,H1,P1"; fi
  local scenario engine
  IFS=, read -r -a motion_scenarios <<< "$scenarios"
  motion_engines=()
  case "$engines" in
    legacy) motion_engines=(legacy);;
    collection) motion_engines=(collection);;
    both) motion_engines=(legacy collection);;
  esac
  for scenario in "${motion_scenarios[@]}"; do
    [[ "$scenario" == K1 || "$scenario" == K2 || "$scenario" == S1 || "$scenario" == S2 || "$scenario" == H1 || "$scenario" == P1 ]] || { printf 'unknown motion scenario: %s\n' "$scenario" >&2; return 2; }
  done
  if [[ -z "$out_dir" ]]; then out_dir="$EVIDENCE_ROOT/motion/$(date -u '+%Y%m%dT%H%M%SZ')"; fi
  local motion_scratch_dir
  motion_scratch_dir=$(scratch_dir_for_evidence "$out_dir")
  prepare_evidence_run "$out_dir"

  cmd_generate
  local source_hash build_key
  source_hash=$(motion_source_hash)
  build_key="$(git -C "$ROOT" rev-parse HEAD)-$source_hash"
  motion_build_products "$build_key" "$rebuild"
  local motion_derived="$MOTION_BUILD_DIR/derived"
  local app_bundle="$motion_derived/Build/Products/Debug-iphonesimulator/cc-controller.app"
  local source_xctestrun
  source_xctestrun=$(find "$motion_derived/Build/Products" -type f -name '*.xctestrun' -print -quit)
  [[ -d "$app_bundle" && -n "$source_xctestrun" ]] || { printf '%s\n' 'motion build did not produce app and xctestrun' >&2; return 1; }

  pool_acquire
  local motion_device_type='iPhone 16 Plus'
  [[ "$device" == duo ]] && motion_device_type='iPhone Duo'
  MOTION_UDID=$(ensure_pool_device "$motion_device_type")
  local run_dir="$out_dir"
  RUN_DIR=$(mktemp -d -t cc-controller-motion-run.XXXXXX)
  ln -s "$motion_derived/Build/Products/Debug-iphonesimulator" "$RUN_DIR/Debug-iphonesimulator"
  DIAG_DIR=""
  local app_sha
  app_sha=$(git -C "$ROOT" rev-parse --short HEAD)
  local device_name="$motion_device_type"
  for scenario in "${motion_scenarios[@]}"; do
    for engine in "${motion_engines[@]}"; do
      local run="$(printf '%s-%s' "$scenario" "$engine")"
      local trace_name="$run.jsonl" case_log="$motion_scratch_dir/$run.xcodebuild.log" video=""
      [[ "$video_enabled" -eq 0 ]] || video="$motion_scratch_dir/$run.mp4"
      local result="$motion_scratch_dir/$run.xcresult" run_xctestrun="$RUN_DIR/$run.xctestrun"
      local case_status=0 container trace_source trace_path
      local run_load_start run_load_end trace_lines frame_count video_size
      run_load_start=$(sysctl -n vm.loadavg | tr -d '{},' | awk '{print $1}')
      [[ -z "$video" ]] || rm -f "$video"
      rm -f "$run_dir/$trace_name" "$run_dir/$run.analysis.json" "$run_dir/$run.analysis.stdout" "$run_dir/$run.json"
      stop_fixture_daemon
      reset_flow_state "$MOTION_UDID"
      xcrun simctl ui "$MOTION_UDID" appearance "${TEST_RUNNER_COLOR_SCHEME:-light}"
      xcrun simctl install "$MOTION_UDID" "$app_bundle"
      FIXTURE_SIM_UDID="$MOTION_UDID"
      start_fixture_daemon "$motion_scratch_dir/$run.fixture.log"
      local web_port bearer control_port
      web_port=$(json_value "$FIXTURE_OUT" webPort)
      bearer=$(json_value "$FIXTURE_OUT" bearer)
      control_port=$(json_value "$FIXTURE_OUT" controlPort)
      export TEST_RUNNER_MOTION_TRACE="$trace_name"
      export TEST_RUNNER_MOTION_SCENARIO="$scenario"
      export TEST_RUNNER_MOTION_ORIENTATION="$orientation"
      export TEST_RUNNER_CC_TRANSCRIPT_ENGINE="$engine"
      export CCMotionBuildSHA="$app_sha"
      export CCMotionDevice="$device_name"
      if ! configure_xctestrun "$source_xctestrun" "$run_xctestrun" \
        "http://127.0.0.1:$web_port" "$bearer" "http://127.0.0.1:$control_port" \
        "${TEST_RUNNER_COLOR_SCHEME:-light}" "$run_dir"; then
        case_status=1
      fi
      if [[ "$orientation" == landscape ]]; then
        export TEST_RUNNER_MOTION_ORIENTATION=landscape
      fi
      if [[ $case_status -eq 0 ]]; then
        if [[ "$video_enabled" -eq 1 ]]; then
          xcrun simctl io "$MOTION_UDID" recordVideo --codec=h264 --force "$video" >"$motion_scratch_dir/$run.video.log" 2>&1 &
          MOTION_VIDEO_PID=$!
        fi
        local motion_method
        case "$scenario" in
          K1) motion_method=testK1KeyboardOpen;;
          K2) motion_method=testK2KeyboardDismissByTranscriptDrag;;
          S1) motion_method=testS1SendShort;;
          S2) motion_method=testS2SendMultiline;;
          H1) motion_method=testH1UnpinnedAppend;;
          P1) motion_method=testP1LoadEarlier;;
        esac
        local args=(xcodebuild -xctestrun "$run_xctestrun" -destination "id=$MOTION_UDID" -resultBundlePath "$result" \
          "-only-testing:CCControllerUITests/MotionFlowTests/$motion_method" -collect-test-diagnostics never test-without-building)
        if run_flow_test "motion $run $orientation" "$case_log" "${args[@]}"; then
          :
        else
          case_status=$?
        fi
      fi
      stop_motion_video
      sleep 1
      stop_fixture_daemon
      container=$(xcrun simctl get_app_container "$MOTION_UDID" com.example.cc-controller data)
      trace_source=$(find "$container" -type f -name "$trace_name" -print -quit)
      if [[ -n "$trace_source" && -f "$trace_source" ]]; then
        cp "$trace_source" "$run_dir/$trace_name"
      else
        printf 'motion trace missing for %s: %s\n' "$run" "$trace_name" >&2
        case_status=1
      fi
      trace_path="$run_dir/$trace_name"
      if [[ -f "$trace_path" && -f "$ROOT/scripts/motion/analyze.js" ]]; then
        if ! node "$ROOT/scripts/motion/analyze.js" "$trace_path" --json "$run_dir/$run.analysis.json" >"$run_dir/$run.analysis.stdout" 2>&1; then
          printf 'motion analyzer did not pass for %s; see %s\n' "$run" "$run_dir/$run.analysis.stdout" >&2
        fi
      fi
      run_load_end=$(sysctl -n vm.loadavg | tr -d '{},' | awk '{print $1}')
      trace_lines=0; frame_count=0
      if [[ -f "$trace_path" ]]; then
        trace_lines=$(wc -l < "$trace_path" | tr -d ' ')
        frame_count=$(grep -c '"t":"frame"' "$trace_path" || true)
      fi
      video_size=0
      [[ -f "$video" ]] && video_size=$(stat -f %z "$video")
      MOTION_JSON_FILE="$run_dir/$run.json" MOTION_SCENARIO="$scenario" MOTION_ENGINE="$engine" \
        MOTION_DEVICE="$device_name" MOTION_UDID="$MOTION_UDID" MOTION_ORIENTATION="$orientation" \
        MOTION_LOAD_START="$run_load_start" MOTION_LOAD_END="$run_load_end" MOTION_VIDEO="$video" \
        MOTION_SHA="$app_sha" MOTION_TRACE="$trace_path" MOTION_TRACE_LINES="$trace_lines" MOTION_FRAME_COUNT="$frame_count" \
        MOTION_VIDEO_SIZE="$video_size" node - <<'NODE'
const fs = require('node:fs');
const p = {
  scenario: process.env.MOTION_SCENARIO,
  engine: process.env.MOTION_ENGINE,
  device: process.env.MOTION_DEVICE,
  simulatorUDID: process.env.MOTION_UDID,
  orientation: process.env.MOTION_ORIENTATION,
  hostLoadStart: Number(process.env.MOTION_LOAD_START),
  hostLoadEnd: Number(process.env.MOTION_LOAD_END),
  videoPath: process.env.MOTION_VIDEO || null,
  videoBytes: Number(process.env.MOTION_VIDEO_SIZE),
  tracePath: process.env.MOTION_TRACE,
  traceLines: Number(process.env.MOTION_TRACE_LINES),
  frameCount: Number(process.env.MOTION_FRAME_COUNT),
  appBuildSHA: process.env.MOTION_SHA,
};
fs.writeFileSync(process.env.MOTION_JSON_FILE, JSON.stringify(p, null, 2) + '\n');
NODE
      printf 'motion %s trace_lines=%s frames=%s video_bytes=%s status=%s\n' "$run" "$trace_lines" "$frame_count" "$video_size" "$case_status"
      [[ $case_status -eq 0 ]] || return 1
    done
  done
  unset TEST_RUNNER_MOTION_TRACE TEST_RUNNER_MOTION_SCENARIO TEST_RUNNER_MOTION_ORIENTATION TEST_RUNNER_CC_TRANSCRIPT_ENGINE CCMotionBuildSHA CCMotionDevice
  xcrun simctl shutdown "$MOTION_UDID" >/dev/null 2>&1 || true
  MOTION_UDID=""
  printf 'motion evidence written to %s\n' "$out_dir"
}

real_api_request() {
  local method=$1 path=$2 body_file=$3 output_file=$4
  node - -- "$method" "$path" "$body_file" "$output_file" <<'NODE'
const fs = require('node:fs');
const http = require('node:http');
const [method, path, bodyFile, outputFile] = process.argv.slice(3);
const body = bodyFile === '-' ? '' : fs.readFileSync(bodyFile, 'utf8');
const request = http.request({
  host: '127.0.0.1',
  port: 47832,
  method,
  path,
  headers: body ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } : {},
}, (response) => {
  let text = '';
  response.setEncoding('utf8');
  response.on('data', (chunk) => { text += chunk; });
  response.on('end', () => {
    fs.writeFileSync(outputFile, text, { mode: 0o600 });
    if (response.statusCode < 200 || response.statusCode >= 300) {
      console.error(`real-smoke auth request failed at ${method} ${path} (HTTP ${response.statusCode})`);
      process.exitCode = 1;
    }
  });
});
request.on('error', (error) => {
  console.error(`real-smoke auth request failed at ${method} ${path}: ${error.message}`);
  process.exitCode = 1;
});
request.end(body);
NODE
}

real_json_value() {
  node -e 'const fs=require("node:fs"); const value=JSON.parse(fs.readFileSync(process.argv[1], "utf8")); const path=process.argv.slice(2); let current=value; for (const key of path) current=current?.[key]; if (current !== undefined && current !== null) process.stdout.write(String(current));' -- "$@"
}

real_write_json() {
  local file=$1 value=$2
  printf '%s' "$value" > "$file"
  chmod 600 "$file"
}

real_authenticate() {
  local main_root=$1 device_name=$2
  local pair_body="$REAL_SECRET_DIR/pair-start.json"
  local pair_response="$REAL_SECRET_DIR/pair-start-response.json"
  local poll_response="$REAL_SECRET_DIR/pair-poll-response.json"
  local enroll_body="$REAL_SECRET_DIR/native-enroll.json"
  local enroll_response="$REAL_SECRET_DIR/native-enroll-response.json"
  local login_body="$REAL_SECRET_DIR/native-login.json"
  local login_response="$REAL_SECRET_DIR/native-login-response.json"
  real_write_json "$pair_body" "$(node -e 'process.stdout.write(JSON.stringify({deviceName: process.argv[1]}))' -- "$device_name")"
  if ! real_api_request POST /api/pair/start "$pair_body" "$pair_response"; then
    printf '%s\n' 'real-smoke auth failed at POST /api/pair/start; app pairing path: AuthClient.startPairing -> WebApi.pairStart' >&2
    return 1
  fi
  local code
  code=$(real_json_value "$pair_response" code)
  if [[ ! "$code" =~ ^[0-9]{6}$ ]]; then
    printf '%s\n' 'real-smoke auth failed: POST /api/pair/start returned no six-digit code' >&2
    return 1
  fi
  if ! node "$main_root/src/cli.js" pair "$code" >/dev/null; then
    printf '%s\n' 'real-smoke auth failed at cc-gateway pair; app pairing path: AuthClient.pollPairing -> WebApi.pairPoll' >&2
    return 1
  fi
  local device_token="" state
  for _ in {1..60}; do
    if ! real_api_request GET "/api/pair/poll?code=$code" - "$poll_response"; then
      printf '%s\n' 'real-smoke auth failed at GET /api/pair/poll; app pairing path: AuthClient.pollPairing' >&2
      return 1
    fi
    state=$(real_json_value "$poll_response" state)
    if [[ "$state" == confirmed ]]; then
      device_token=$(real_json_value "$poll_response" deviceToken)
      break
    fi
    [[ "$state" == pending ]] || break
    sleep 1
  done
  if [[ -z "$device_token" ]]; then
    printf 'real-smoke auth failed: pairing did not confirm (state=%s)\n' "${state:-missing}" >&2
    return 1
  fi
  real_write_json "$enroll_body" "$(node -e 'process.stdout.write(JSON.stringify({deviceToken: process.argv[1],deviceName: process.argv[2]}))' -- "$device_token" "$device_name")"
  if ! real_api_request POST /api/auth/native/enroll "$enroll_body" "$enroll_response"; then
    printf '%s\n' 'real-smoke auth failed at POST /api/auth/native/enroll; app pairing path: AuthClient.enroll' >&2
    return 1
  fi
  local secret
  secret=$(real_json_value "$enroll_response" secret)
  if [[ -z "$secret" ]]; then
    printf '%s\n' 'real-smoke auth failed: native enrollment returned no secret' >&2
    return 1
  fi
  real_write_json "$login_body" "$(node -e 'process.stdout.write(JSON.stringify({secret: process.argv[1]}))' -- "$secret")"
  if ! real_api_request POST /api/auth/native/login "$login_body" "$login_response"; then
    printf '%s\n' 'real-smoke auth failed at POST /api/auth/native/login; app unlock path: AuthClient.login' >&2
    return 1
  fi
  local authenticated token
  authenticated=$(real_json_value "$login_response" authenticated)
  token=$(real_json_value "$login_response" token)
  if [[ "$authenticated" != true || -z "$token" ]]; then
    printf '%s\n' 'real-smoke auth failed: native login returned no authenticated bearer' >&2
    return 1
  fi
  printf '%s' "$token" > "$REAL_BEARER_FILE"
  chmod 600 "$REAL_BEARER_FILE"
}

real_select_sessions() {
  local status_file=$1 output_file=$2 sessions_count=$3 skip_file=${4:-}
  node "$ROOT/scripts/real-smoke-selection.mjs" "$status_file" "$output_file" "$sessions_count" "$skip_file"
}

cmd_real_smoke() {
  prune_scratch
  local sessions_count=6
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sessions)
        [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || { printf '%s\n' 'real-smoke --sessions requires a positive integer' >&2; return 2; }
        sessions_count=$2
        shift 2
        ;;
      *) printf 'unknown real-smoke option: %s\n' "$1" >&2; return 2;;
    esac
  done
  REAL_SMOKE_RUN=1
  REAL_DEVICE_NAME="cc-real-smoke-$(date '+%Y%m%dT%H%M%S')-$$"
  local timestamp output_base status_file session_file skip_file started=$SECONDS
  timestamp=$(date '+%Y%m%dT%H%M%S')
  output_base="$EVIDENCE_ROOT/real-smoke/$timestamp"
  [[ ! -e "$output_base" ]] || output_base="${output_base}-$$"
  REAL_OUTPUT_DIR="$output_base"
  REAL_RAW_DIR=$(scratch_dir_for_evidence "$REAL_OUTPUT_DIR")
  prepare_evidence_run "$REAL_OUTPUT_DIR"
  REAL_SECRET_DIR=$(mktemp -d)
  chmod 700 "$REAL_SECRET_DIR"
  REAL_BEARER_FILE="$REAL_SECRET_DIR/bearer"
  status_file="$REAL_SECRET_DIR/status.json"
  session_file="$REAL_SECRET_DIR/sessions.json"
  skip_file="$REAL_SECRET_DIR/skipped.txt"

  step 'real-smoke build-for-testing' cmd_generate
  xcodebuild -project "$PROJECT" -scheme CCController -configuration Debug -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED/real-smoke" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build-for-testing
  local app_bundle="$DERIVED/real-smoke/Build/Products/Debug-iphonesimulator/cc-controller.app"
  local xctestrun
  xctestrun=$(find "$DERIVED/real-smoke/Build/Products" -type f -name '*.xctestrun' -print -quit)
  [[ -d "$app_bundle" && -n "$xctestrun" ]] || { printf '%s\n' 'real-smoke build did not produce app and xctestrun' >&2; return 1; }

  local main_root
  main_root=$(main_checkout)
  if ! real_authenticate "$main_root" "$REAL_DEVICE_NAME"; then return 1; fi
  if ! node "$main_root/src/cli.js" status > "$status_file"; then
    printf '%s\n' 'real-smoke failed to read cc-gateway status' >&2
    return 1
  fi
  if ! real_select_sessions "$status_file" "$session_file" "$sessions_count" "$skip_file"; then
    if [[ -s "$skip_file" ]]; then cp "$skip_file" "$REAL_OUTPUT_DIR/summary.txt"; fi
    return 1
  fi

  local bearer
  bearer=$(<"$REAL_BEARER_FILE")
  local udid
  pool_acquire
  udid=$(ensure_pool_device 'iPhone 16 Plus')
  xcrun simctl install "$udid" "$app_bundle"
  # The result bundle can record the runner environment, which holds the bearer,
  # so it stays in the secret directory and only the xcodebuild log is copied after a plain-text check.
  local result="$REAL_SECRET_DIR/real-smoke.xcresult"
  local run_xctestrun="$REAL_SECRET_DIR/CCController.xctestrun"
  ln -s "$DERIVED/real-smoke/Build/Products/Debug-iphonesimulator" "$REAL_SECRET_DIR/Debug-iphonesimulator"
  configure_xctestrun "$xctestrun" "$run_xctestrun" 'http://127.0.0.1:47832' "$bearer" '' light "$REAL_OUTPUT_DIR" '' 1 "$(<"$session_file")" "$REAL_OUTPUT_DIR"
  local test_log="$REAL_SECRET_DIR/xcodebuild.log" test_status=0
  run_flow_test 'real-smoke UI test' "$test_log" xcodebuild -xctestrun "$run_xctestrun" \
    -destination "id=$udid" -resultBundlePath "$result" \
    '-only-testing:CCControllerUITests/RealControllerSmokeTests/testRealSessions' \
    -collect-test-diagnostics never test-without-building || test_status=$?
  if [[ -d "$result" ]]; then
    xcrun xcresulttool export attachments --path "$result" --output-path "$REAL_SECRET_DIR/attachments" >/dev/null 2>&1 || test_status=1
    find "$REAL_SECRET_DIR/attachments" -type f -name '*.png' -exec cp {} "$REAL_OUTPUT_DIR" \; 2>/dev/null || true
  else
    printf '%s\n' 'real-smoke produced no xcresult bundle' >&2
    test_status=1
  fi
  if grep -qF -f "$REAL_BEARER_FILE" "$test_log" 2>/dev/null; then
    printf '%s\n' 'real-smoke bearer appeared in the xcodebuild log; the log was not kept' >&2
    test_status=1
  else
    cp "$test_log" "$REAL_RAW_DIR/xcodebuild.log" 2>/dev/null || true
  fi
  if [[ -s "$skip_file" ]]; then
    if [[ -f "$REAL_OUTPUT_DIR/summary.txt" ]]; then
      cat "$skip_file" >> "$REAL_OUTPUT_DIR/summary.txt"
    else
      cp "$skip_file" "$REAL_OUTPUT_DIR/summary.txt"
    fi
  fi
  printf 'real-smoke wall-clock=%ss output=%s\n' "$((SECONDS - started))" "$REAL_OUTPUT_DIR"
  return "$test_status"
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
      node -e 'const fs=require("node:fs"),path=require("node:path"),p=process.argv[1],dir=path.dirname(p),d=JSON.parse(fs.readFileSync(p)),attachments=Array.isArray(d)?d.flatMap((entry)=>entry.attachments??[]):d.attachments??[];for(const a of attachments){const suggested=a.suggestedHumanReadableName||a.filename||"";const name=suggested.replace(/_[0-9]+_[0-9a-f-]+\.(png|txt)$/i,".$1");const old=a.exportedFileName||a.exportedFilePath||a.filename;const src=path.join(dir,old),dst=path.join(dir,name);if(fs.existsSync(src)&&src!==dst)fs.renameSync(src,dst);}' -- "$manifest"
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
  elif [[ "$target" == 'daemon' ]]; then
    pid=$(perf_host_pid 'daemon')
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
  if [[ "$target" == 'daemon' ]]; then
    launchctl list 2>/dev/null | awk '$3 == "com.example.cc-controller" && $1 ~ /^[0-9]+$/ { print $1; exit }' || true
    return 0
  fi
  ps -axo pid=,command= | awk -v target="$target" '$0 ~ target { print $1; exit }' || true
}

perf_start_samples() {
  local label=$1 host_app_pid=$2 case_dir=$3 render_pid
  [[ "$label" == C || "$label" == E-real || "$label" == E-storm || "$label" == F ]] || return 0
  local sample_prefix="sample-$label-$PERF_RUN_NUMBER"
  [[ -f "$PERF_SCRATCH_DIR/$sample_prefix.txt" ]] || {
    if [[ "$host_app_pid" =~ ^[0-9]+$ ]]; then
      sample "$host_app_pid" 10 -file "$PERF_SCRATCH_DIR/$sample_prefix.txt" >/dev/null 2>&1 &
      PERF_SAMPLE_PIDS+=("$!")
    else
      host_app_pid=$(perf_host_pid 'cc-controller.app/cc-controller' "$PERF_UDID")
      if [[ "$host_app_pid" =~ ^[0-9]+$ ]]; then
        sample "$host_app_pid" 10 -file "$PERF_SCRATCH_DIR/$sample_prefix.txt" >/dev/null 2>&1 &
        PERF_SAMPLE_PIDS+=("$!")
      fi
    fi
  }
  render_pid=$(perf_host_pid 'backboardd' "$PERF_UDID")
  if [[ "$render_pid" =~ ^[0-9]+$ ]]; then
    sample "$render_pid" 10 -file "$PERF_SCRATCH_DIR/sample-render-$label-$PERF_RUN_NUMBER.txt" >/dev/null 2>&1 &
    PERF_SAMPLE_PIDS+=("$!")
  fi
}

perf_run_case() {
  local label=$1 mode=$2 duration=$3 private_fixture=${4:-}
  local case_dir="$PERF_OUTPUT_DIR/$label/run-$PERF_RUN_NUMBER"
  local raw_case_dir="$PERF_SCRATCH_DIR/$label/run-$PERF_RUN_NUMBER"
  mkdir -p "$case_dir" "$raw_case_dir"
  local fixture_log="$raw_case_dir/fixture.log"
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
  samples="$raw_case_dir/process-samples.txt"
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

real_status_summary() {
  local status_file=$1 output_file=$2
  node - -- "$status_file" "$output_file" <<'NODE'
const fs = require('node:fs');
const [statusFile, outputFile] = process.argv.slice(3);
const payload = JSON.parse(fs.readFileSync(statusFile, 'utf8'));
const entries = payload.entries ?? {};
const sessions = (payload.sessions ?? [])
  .filter((session) => typeof session?.id === 'string' && session.id.length > 0)
  .map((session) => ({
    id: session.id,
    name: session.name ?? 'Untitled session',
    state: session.state ?? 'unknown',
    entryCount: Number(entries[session.id] ?? 0),
  }));
fs.writeFileSync(outputFile, JSON.stringify(sessions, null, 2), { mode: 0o600 });
NODE
}

real_event_query() {
  REAL_BEARER_FILE="$REAL_BEARER_FILE" node <<'NODE'
const fs = require('node:fs');
const http = require('node:http');
const bearer = fs.readFileSync(process.env.REAL_BEARER_FILE, 'utf8');
const request = http.request({
  host: '127.0.0.1',
  port: 47832,
  path: '/api/bootstrap',
  headers: { Authorization: `Bearer ${bearer}`, Accept: 'application/json' },
}, (response) => {
  let text = '';
  response.setEncoding('utf8');
  response.on('data', (chunk) => { text += chunk; });
  response.on('end', () => {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      console.error(`event query bootstrap failed (HTTP ${response.statusCode})`);
      process.exitCode = 1;
      return;
    }
    let value;
    try { value = JSON.parse(text); } catch {
      console.error('event query bootstrap returned invalid JSON');
      process.exitCode = 1;
      return;
    }
    process.stdout.write(value.capabilities?.subagentUpsert === true ? '?subagentUpsert=true' : '');
  });
});
request.on('error', (error) => {
  console.error(`event query bootstrap failed: ${error.message}`);
  process.exitCode = 1;
});
request.end();
NODE
}

real_start_event_capture() {
  local query=$1 raw_file=$2 log_file=$3
  REAL_BEARER_FILE="$REAL_BEARER_FILE" node - -- "$query" "$raw_file" <<'NODE' >"$log_file" 2>&1 &
const fs = require('node:fs');
const http = require('node:http');
const zlib = require('node:zlib');
const query = process.argv[3];
const rawFile = process.argv[4];
const bearer = fs.readFileSync(process.env.REAL_BEARER_FILE, 'utf8');
const fd = fs.openSync(rawFile, 'w', 0o600);
let response;
let request;
let stopping = false;
let finished = false;
function finish(status) {
  if (finished) return;
  finished = true;
  fs.closeSync(fd);
  process.exit(status);
}
request = http.request({
  host: '127.0.0.1',
  port: 47832,
  path: `/api/events${query}`,
  headers: {
    Authorization: `Bearer ${bearer}`,
    Accept: 'text/event-stream',
    'Accept-Encoding': 'gzip',
  },
}, (candidate) => {
  response = candidate;
  if (response.statusCode < 200 || response.statusCode >= 300) {
    console.error(`event stream failed (HTTP ${response.statusCode})`);
    response.resume();
    response.on('end', () => finish(1));
    return;
  }
  const body = response.headers['content-encoding'] === 'gzip'
    ? response.pipe(zlib.createGunzip())
    : response;
  body.on('data', (chunk) => fs.writeSync(fd, chunk));
  body.on('end', () => finish(stopping ? 0 : 1));
  body.on('error', (error) => {
    if (!stopping) console.error(`event stream failed: ${error.message}`);
    finish(stopping ? 0 : 1);
  });
});
request.on('error', (error) => {
  if (!stopping) console.error(`event stream failed: ${error.message}`);
  finish(stopping ? 0 : 1);
});
process.on('SIGTERM', () => {
  stopping = true;
  request.destroy();
  response?.destroy();
  setTimeout(() => finish(0), 100);
});
request.end();
NODE
  REAL_PERF_EVENT_PID=$!
}

real_summarize_events() {
  local raw_file=$1 summary_file=$2 wall=$3
  node - -- "$raw_file" "$summary_file" "$wall" <<'NODE'
const fs = require('node:fs');
const [rawFile, summaryFile, wallText] = process.argv.slice(3);
const buffer = fs.readFileSync(rawFile);
const text = buffer.toString('utf8');
const byType = {};
let totalEvents = 0;
let start = 0;
const separator = /\r?\n\r?\n/g;
let match;
function consume(block) {
  const lines = block.split(/\r?\n/);
  let type = 'message';
  let hasData = false;
  for (const line of lines) {
    if (line.startsWith('event:')) type = line.slice(6).trimStart();
    if (line.startsWith('data:')) hasData = true;
  }
  if (!hasData) return;
  totalEvents += 1;
  const bytes = Buffer.byteLength(block, 'utf8');
  const item = byType[type] ?? { count: 0, total_bytes: 0 };
  item.count += 1;
  item.total_bytes += bytes;
  byType[type] = item;
}
while ((match = separator.exec(text)) !== null) {
  consume(text.slice(start, match.index + match[0].length));
  start = match.index + match[0].length;
}
if (start < text.length) consume(text.slice(start));
const wall = Number(wallText);
const payload = {
  total_events: totalEvents,
  total_bytes: buffer.length,
  events_per_second: wall > 0 ? totalEvents / wall : 0,
  by_type: byType,
};
fs.writeFileSync(summaryFile, JSON.stringify(payload, null, 2), { mode: 0o600 });
NODE
}

real_write_cpu_timeline() {
  local samples=$1 timeline=$2
  python3 -I - "$samples" "$timeline" <<'PY'
import json
import statistics
import sys

samples_path, timeline_path = sys.argv[1:]
by_time = {}
for line in open(samples_path, encoding='utf-8', errors='replace'):
    fields = line.rstrip().split('|')
    if len(fields) != 5:
        continue
    try:
        timestamp = float(fields[0])
        cpu = float(fields[3])
    except ValueError:
        continue
    if fields[1] not in ('app', 'render'):
        continue
    by_time.setdefault(timestamp, {})[fields[1]] = cpu

times = sorted(by_time)
timeline = []
previous = {}
first_time = times[0] if times else 0.0
for timestamp in times:
    values = {}
    for target in ('app', 'render'):
        current = by_time[timestamp].get(target)
        prior = previous.get(target)
        if current is not None and prior is not None:
            prior_time, prior_cpu = prior
            elapsed = timestamp - prior_time
            values[target] = max(0.0, (current - prior_cpu) * 100.0 / elapsed) if elapsed > 0 else None
        else:
            values[target] = None
        if current is not None:
            previous[target] = (timestamp, current)
    if any(value is not None for value in values.values()):
        timeline.append({'t': int(round(timestamp - first_time)), **values})

with open(timeline_path, 'w', encoding='utf-8') as handle:
    json.dump(timeline, handle, indent=2)
    handle.write('\n')

def values_for(target):
    return [item[target] for item in timeline if item[target] is not None]

def summary(target):
    values = values_for(target)
    if not values:
        return 'null/null'
    return f'{max(values):.2f}/{statistics.median(values):.2f}'

print(f'PERF cpu-timeline peak/median app={summary("app")} render={summary("render")}')
PY
}

real_state_request() {
  local output_file=$1
  REAL_BEARER_FILE="$REAL_BEARER_FILE" node - -- "$output_file" <<'NODE'
const fs = require('node:fs');
const http = require('node:http');
const output = process.argv[3];
const bearer = fs.readFileSync(process.env.REAL_BEARER_FILE, 'utf8');
const request = http.request({
  host: '127.0.0.1',
  port: 47832,
  path: '/api/state',
  headers: { Authorization: `Bearer ${bearer}`, Accept: 'application/json' },
}, (response) => {
  let text = '';
  response.setEncoding('utf8');
  response.on('data', (chunk) => { text += chunk; });
  response.on('end', () => {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      console.error(`state request failed (HTTP ${response.statusCode})`);
      process.exitCode = 1;
      return;
    }
    try { JSON.parse(text); } catch {
      console.error('state request returned invalid JSON');
      process.exitCode = 1;
      return;
    }
    fs.writeFileSync(output, text, { mode: 0o600 });
  });
});
request.on('error', (error) => {
  console.error(`state request failed: ${error.message}`);
  process.exitCode = 1;
});
request.end();
NODE
}

real_state_has_session() {
  local state_file=$1 session_id=$2
  node - -- "$state_file" "$session_id" <<'NODE'
const fs = require('node:fs');
const [stateFile, target] = process.argv.slice(3);
const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
const found = Array.isArray(state.sessions) && state.sessions.some((session) => session?.id === target);
process.stdout.write(found ? 'FOUND' : 'MISSING');
NODE
}

real_state_entry_count() {
  local state_file=$1 session_id=$2
  node - -- "$state_file" "$session_id" <<'NODE'
const fs = require('node:fs');
const [stateFile, target] = process.argv.slice(3);
const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
const value = Number(state.entries?.[target] ?? 0);
if (!Number.isFinite(value)) process.exit(1);
process.stdout.write(String(value));
NODE
}

real_wait_for_scratch_state() {
  local state_file=$1
  local deadline=$((SECONDS + 60))
  while (( SECONDS <= deadline )); do
    if real_state_request "$state_file" && [[ "$(real_state_has_session "$state_file" "$REAL_SCRATCH_SESSION_ID")" == FOUND ]]; then
      return 0
    fi
    (( SECONDS < deadline )) || break
    sleep 1
  done
  printf 'real perf turn: session %s was not listed by GET /api/state within 60 seconds\n' "$REAL_SCRATCH_SESSION_ID" >&2
  return 1
}

real_start_scratch() {
  local output directory state_id existing=()
  shopt -s nullglob
  existing=("$HOME/dev"/cc-perf-scratch-*.state.json)
  shopt -u nullglob
  if (( ${#existing[@]} != 0 )); then
    printf 'real perf turn: refusing to use pre-existing scratch state: %s\n' "${existing[*]}" >&2
    return 1
  fi
  REAL_SCRATCH_STARTED=1
  if ! output=$("$ROOT/scripts/perf-scratch-session.sh" start); then
    REAL_SCRATCH_STARTED=0
    printf '%s\n' 'real perf turn: scratch session start failed' >&2
    return 1
  fi
  REAL_SCRATCH_SESSION_ID=$(printf '%s\n' "$output" | awk -F= '$1 == "session_id" { print $2; exit }')
  directory=$(printf '%s\n' "$output" | awk -F= '$1 == "directory" { print $2; exit }')
  REAL_SCRATCH_STATE_FILE="${directory}.state.json"
  [[ "$REAL_SCRATCH_SESSION_ID" =~ ^[A-Za-z0-9_-]+$ && -f "$REAL_SCRATCH_STATE_FILE" ]] || {
    printf '%s\n' 'real perf turn: scratch start returned invalid state' >&2
    return 1
  }
  state_id=$(node - -- "$REAL_SCRATCH_STATE_FILE" <<'NODE'
const fs = require('node:fs');
const state = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
process.stdout.write(String(state.session_id ?? ''));
NODE
  )
  [[ "$state_id" == "$REAL_SCRATCH_SESSION_ID" ]] || {
    printf 'real perf turn: scratch state id mismatch (%s vs %s)\n' "$state_id" "$REAL_SCRATCH_SESSION_ID" >&2
    return 1
  }
  printf 'real perf scratch session=%s\n' "$REAL_SCRATCH_SESSION_ID"
}

real_assert_cli_session_missing() {
  local output_file=$1
  if ! node "$(main_checkout)/src/cli.js" status > "$output_file"; then
    printf '%s\n' 'real perf turn: failed to read cli status after scratch stop' >&2
    return 1
  fi
  if node - -- "$output_file" "$REAL_SCRATCH_SESSION_ID" <<'NODE'
const fs = require('node:fs');
const [statusFile, target] = process.argv.slice(3);
const status = JSON.parse(fs.readFileSync(statusFile, 'utf8'));
process.exit((status.sessions ?? []).some((session) => session?.id === target) ? 1 : 0);
NODE
  then
    printf 'real perf scratch session %s absent from cli status\n' "$REAL_SCRATCH_SESSION_ID"
    return 0
  fi
  printf 'real perf turn: scratch session %s remains in cli status\n' "$REAL_SCRATCH_SESSION_ID" >&2
  return 1
}

real_cpu_or_null() {
  local before=$1 after=$2 wall=$3
  if [[ "$before" =~ ^[0-9]+([.][0-9]+)?$ && "$after" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    perf_cpu_delta "$before" "$after" "$wall"
  else
    printf '%s' 'null'
  fi
}

real_write_perf_result() {
  local json_file=$1 counter_file=$2 phase=$3 selected_id=$4 selected_count=$5 duration=$6 warmup=$7
  PERF_REAL_JSON_FILE="$json_file" PERF_REAL_COUNTER_FILE="$counter_file" \
  PERF_REAL_PHASE="$phase" PERF_REAL_SELECTED_ID="$selected_id" PERF_REAL_SELECTED_COUNT="$selected_count" \
  PERF_REAL_DURATION="$duration" PERF_REAL_WARMUP="$warmup" \
  PERF_REAL_WALL="$REAL_PERF_WALL" PERF_REAL_APP_CPU="$REAL_PERF_APP_CPU" \
  PERF_REAL_RENDER_CPU="$REAL_PERF_RENDER_CPU" PERF_REAL_DAEMON_CPU="$REAL_PERF_DAEMON_CPU" \
  PERF_REAL_PEAK_RSS="$REAL_PERF_PEAK_RSS" python3 - <<'PY'
import json, os
payload = {
  'phase': os.environ['PERF_REAL_PHASE'],
  'warmup_seconds': float(os.environ['PERF_REAL_WARMUP']),
  'duration_seconds': float(os.environ['PERF_REAL_DURATION']),
  'wall_seconds': float(os.environ['PERF_REAL_WALL']),
  'app_cpu_percent_one_core': None if os.environ['PERF_REAL_APP_CPU'] == 'null' else float(os.environ['PERF_REAL_APP_CPU']),
  'render_server_cpu_percent_one_core': None if os.environ['PERF_REAL_RENDER_CPU'] == 'null' else float(os.environ['PERF_REAL_RENDER_CPU']),
  'daemon_cpu_percent_one_core': None if os.environ['PERF_REAL_DAEMON_CPU'] == 'null' else float(os.environ['PERF_REAL_DAEMON_CPU']),
  'peak_app_rss_kb': int(os.environ['PERF_REAL_PEAK_RSS']),
  'selected_session_id': os.environ['PERF_REAL_SELECTED_ID'] or None,
  'selected_session_entry_count': int(os.environ['PERF_REAL_SELECTED_COUNT']) if os.environ['PERF_REAL_SELECTED_COUNT'] else None,
}
try:
    with open(os.environ['PERF_REAL_COUNTER_FILE']) as handle:
        payload['counters'] = json.load(handle)
except (FileNotFoundError, json.JSONDecodeError):
    payload['counters'] = None
with open(os.environ['PERF_REAL_JSON_FILE'], 'w') as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
  chmod 600 "$json_file"
}

real_perf_launch_app() {
  local phase=$1 selected_id=$2
  local app_bundle="$IOS/build/perf-release/Build/Products/Release-iphonesimulator/cc-controller.app"
  local bearer launch_output app_pid app_sample
  local launch_args=(-CCServer http://127.0.0.1:47832)
  [[ -z "$selected_id" ]] || launch_args+=( -CCSession "$selected_id" )
  launch_args+=( -CCColorScheme light )
  bearer=$(<"$REAL_BEARER_FILE")
  xcrun simctl terminate "$REAL_PERF_UDID" com.example.cc-controller >/dev/null 2>&1 || true
  xcrun simctl uninstall "$REAL_PERF_UDID" com.example.cc-controller >/dev/null 2>&1 || true
  xcrun simctl install "$REAL_PERF_UDID" "$app_bundle"
  launch_output=$(SIMCTL_CHILD_CCBearer="$bearer" SIMCTL_CHILD_CC_PERF_SCENARIO="real-$phase" \
    xcrun simctl launch "$REAL_PERF_UDID" com.example.cc-controller "${launch_args[@]}")
  PERF_HOST_APP_PID=$(printf '%s\n' "$launch_output" | awk -F': ' 'NF == 2 && $2 ~ /^[0-9]+$/ { print $2; exit }')
  [[ "$PERF_HOST_APP_PID" =~ ^[0-9]+$ ]] || { printf 'real perf %s app did not launch\n' "$phase" >&2; return 1; }
  app_pid=''
  for _ in {1..60}; do
    app_sample=$(perf_process_sample "$REAL_PERF_UDID" cc-controller)
    app_pid=${app_sample%%|*}
    [[ "$app_pid" =~ ^[0-9]+$ ]] && break
    sleep 0.25
  done
  [[ "$app_pid" =~ ^[0-9]+$ ]] || { printf 'real perf %s app process did not appear\n' "$phase" >&2; return 1; }
  sleep "$CC_PERF_REAL_WARMUP"
}

real_perf_measure_window() {
  local phase=$1 sample_duration=$2 mode=$3 value=$4 selected_id=$5 selected_count=$6
  shift 6
  local phase_dir="$REAL_OUTPUT_DIR/$phase"
  local raw_phase_dir="$REAL_RAW_DIR/$phase"
  local raw_events="$REAL_SECRET_DIR/events-$phase.raw"
  local event_log="$REAL_SECRET_DIR/events-$phase.log"
  local query render_pid daemon_pid before_app before_render before_daemon
  local before_app_cpu before_render_cpu before_daemon_cpu start end wall
  local after_app after_render after_daemon after_app_cpu after_render_cpu after_daemon_cpu
  local samples sampler app_sample_pid render_sample_pid container counter_file
  local event_status=0 phase_status=0 command_status=0 window_duration
  local bearer sample_pid
  mkdir -p "$phase_dir" "$raw_phase_dir"

  query=$(real_event_query)
  render_pid=$(perf_host_pid backboardd "$REAL_PERF_UDID")
  daemon_pid=$(perf_host_pid daemon)
  [[ "$render_pid" =~ ^[0-9]+$ ]] || { printf 'real perf %s render server process did not appear\n' "$phase" >&2; return 1; }
  [[ "$daemon_pid" =~ ^[0-9]+$ ]] || { printf 'real perf %s daemon process did not appear\n' "$phase" >&2; return 1; }
  before_app=$(perf_process_sample "$REAL_PERF_UDID" cc-controller)
  before_render=$(perf_process_sample "$REAL_PERF_UDID" backboardd)
  before_daemon=$(perf_process_sample "$REAL_PERF_UDID" daemon)
  before_app_cpu=$(printf '%s' "$before_app" | cut -d'|' -f2)
  before_render_cpu=$(printf '%s' "$before_render" | cut -d'|' -f2)
  before_daemon_cpu=$(printf '%s' "$before_daemon" | cut -d'|' -f2)
  start=$(perf_wall_seconds)
  samples="$raw_phase_dir/process-samples.txt"
  : > "$samples"
  sample "$PERF_HOST_APP_PID" "$sample_duration" -file "$raw_phase_dir/sample-app.txt" >/dev/null 2>&1 &
  app_sample_pid=$!
  PERF_SAMPLE_PIDS+=("$app_sample_pid")
  sample "$render_pid" "$sample_duration" -file "$raw_phase_dir/sample-render.txt" >/dev/null 2>&1 &
  render_sample_pid=$!
  PERF_SAMPLE_PIDS+=("$render_sample_pid")
  real_start_event_capture "$query" "$raw_events" "$event_log"
  perf_sample_loop "$REAL_PERF_UDID" "$samples" &
  sampler=$!
  REAL_PERF_SAMPLER_PID="$sampler"
  if [[ "$mode" == fixed ]]; then
    window_duration="$value"
    sleep "$value"
  else
    "$@" &
    REAL_PERF_COMMAND_PID=$!
    if wait "$REAL_PERF_COMMAND_PID"; then :; else command_status=$?; fi
    REAL_PERF_COMMAND_PID=''
    sleep "$value"
    window_duration=''
  fi
  end=$(perf_wall_seconds)
  kill "$sampler" 2>/dev/null || true
  wait "$sampler" 2>/dev/null || true
  REAL_PERF_SAMPLER_PID=''
  kill -TERM "$REAL_PERF_EVENT_PID" 2>/dev/null || true
  if wait "$REAL_PERF_EVENT_PID" 2>/dev/null; then :; else event_status=$?; fi
  REAL_PERF_EVENT_PID=''
  for sample_pid in "${PERF_SAMPLE_PIDS[@]:-}"; do
    [[ -z "$sample_pid" ]] || wait "$sample_pid" 2>/dev/null || true
  done
  PERF_SAMPLE_PIDS=()
  if [[ ! -s "$raw_phase_dir/sample-app.txt" || ! -s "$raw_phase_dir/sample-render.txt" ]]; then
    printf 'real perf %s sample command did not produce both stack files\n' "$phase" >&2
    phase_status=1
  fi
  after_app=$(perf_process_sample "$REAL_PERF_UDID" cc-controller)
  after_render=$(perf_process_sample "$REAL_PERF_UDID" backboardd)
  after_daemon=$(perf_process_sample "$REAL_PERF_UDID" daemon)
  after_app_cpu=$(printf '%s' "$after_app" | cut -d'|' -f2)
  after_render_cpu=$(printf '%s' "$after_render" | cut -d'|' -f2)
  after_daemon_cpu=$(printf '%s' "$after_daemon" | cut -d'|' -f2)
  wall=$(python3 - "$start" "$end" <<'PY'
import sys
print(float(sys.argv[2]) - float(sys.argv[1]))
PY
)
  [[ -n "$window_duration" ]] || window_duration="$wall"
  REAL_PERF_WALL="$wall"
  REAL_PERF_APP_CPU=$(real_cpu_or_null "$before_app_cpu" "$after_app_cpu" "$wall")
  REAL_PERF_RENDER_CPU=$(real_cpu_or_null "$before_render_cpu" "$after_render_cpu" "$wall")
  REAL_PERF_DAEMON_CPU=$(real_cpu_or_null "$before_daemon_cpu" "$after_daemon_cpu" "$wall")
  REAL_PERF_PEAK_RSS=$(perf_peak_rss "$samples")
  container=$(xcrun simctl get_app_container "$REAL_PERF_UDID" com.example.cc-controller data)
  counter_file="$container/Library/cc-perf.json"
  real_summarize_events "$raw_events" "$phase_dir/events-summary.json" "$wall"
  if ! real_write_cpu_timeline "$samples" "$phase_dir/cpu-timeline.json"; then
    phase_status=1
  fi
  if [[ "$event_status" -ne 0 ]]; then
    printf 'real perf %s SSE capture exited with status %s\n' "$phase" "$event_status" >&2
    phase_status=1
  fi
  bearer=$(<"$REAL_BEARER_FILE")
  if LC_ALL=C grep -a -qF -- "$bearer" "$raw_events" || LC_ALL=C grep -a -qF -- "$bearer" "$event_log" 2>/dev/null; then
    printf 'real perf %s bearer appeared in SSE capture or log; evidence was not copied\n' "$phase" >&2
    phase_status=1
  else
    cp "$raw_events" "$raw_phase_dir/events.raw"
    chmod 600 "$raw_phase_dir/events.raw"
    [[ ! -s "$event_log" ]] || cp "$event_log" "$raw_phase_dir/events.log"
    [[ ! -s "$event_log" ]] || chmod 600 "$raw_phase_dir/events.log"
  fi
  real_write_perf_result "$phase_dir/result.json" "$counter_file" "$phase" "$selected_id" "$selected_count" "$window_duration" "$CC_PERF_REAL_WARMUP"
  local counter_summary
  counter_summary=$(node - -- "$phase_dir/result.json" <<'NODE'
const fs = require('node:fs');
const value = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const rates = value.counters?.per_second ?? {};
process.stdout.write(Object.entries(rates).sort(([a], [b]) => a.localeCompare(b)).map(([key, rate]) => `${key}=${Number(rate).toFixed(2)}/s`).join(' '));
NODE
)
  printf 'PERF real-%s app_cpu=%s%% render_cpu=%s%% daemon_cpu=%s%% peak_rss=%skB wall=%.1fs events=%s selected=%s entries=%s %s\n' \
    "$phase" "$REAL_PERF_APP_CPU" "$REAL_PERF_RENDER_CPU" "$REAL_PERF_DAEMON_CPU" "$REAL_PERF_PEAK_RSS" "$wall" \
    "$(node -e 'const fs=require("node:fs");const p=JSON.parse(fs.readFileSync(process.argv[1]));process.stdout.write(String(p.total_events??0))' -- "$phase_dir/events-summary.json")" \
    "${selected_id:-none}" "${selected_count:-none}" "$counter_summary"
  if [[ "$command_status" -ne 0 ]]; then phase_status=1; fi
  [[ "$phase_status" -eq 0 ]]
}

real_perf_finish_phase() {
  local phase=$1 terminate=${2:-1}
  local phase_dir="$REAL_OUTPUT_DIR/$phase" bearer
  bearer=$(<"$REAL_BEARER_FILE")
  if [[ "$terminate" == 1 ]]; then
    xcrun simctl terminate "$REAL_PERF_UDID" com.example.cc-controller >/dev/null 2>&1 || true
  fi
  if ! node "$(main_checkout)/src/cli.js" status >"$REAL_SECRET_DIR/status-after-$phase.json"; then
    printf 'real perf %s failed to read status after phase\n' "$phase" >&2
    return 1
  fi
  real_status_summary "$REAL_SECRET_DIR/status-after-$phase.json" "$phase_dir/status-after.json"
  if find "$phase_dir" -type f \( -name '*.log' -o -name 'send.json' \) -print0 | while IFS= read -r -d '' file; do
    if LC_ALL=C grep -a -qF -- "$bearer" "$file"; then
      exit 1
    fi
  done; then :; else
    printf 'real perf %s bearer appeared in kept evidence\n' "$phase" >&2
    return 1
  fi
}

real_post_scratch_message() {
  local session_id=$1 body_file=$2 output_file=$3
  REAL_BEARER_FILE="$REAL_BEARER_FILE" node - -- "$session_id" "$body_file" "$output_file" <<'NODE'
const fs = require('node:fs');
const http = require('node:http');
const [sessionId, bodyFile, outputFile] = process.argv.slice(3);
const body = fs.readFileSync(bodyFile, 'utf8');
const bearer = fs.readFileSync(process.env.REAL_BEARER_FILE, 'utf8');
const request = http.request({
  host: '127.0.0.1',
  port: 47832,
  method: 'POST',
  path: `/api/sessions/${encodeURIComponent(sessionId)}/message`,
  headers: {
    Authorization: `Bearer ${bearer}`,
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
  },
}, (response) => {
  let text = '';
  response.setEncoding('utf8');
  response.on('data', (chunk) => { text += chunk; });
  response.on('end', () => {
    let parsed;
    try { parsed = JSON.parse(text); } catch { parsed = text; }
    fs.writeFileSync(outputFile, JSON.stringify({ status: response.statusCode, body: parsed }, null, 2) + '\n', { mode: 0o600 });
    if (response.statusCode < 200 || response.statusCode >= 300) process.exitCode = 1;
  });
});
request.on('error', (error) => {
  console.error(`message request failed: ${error.message}`);
  process.exitCode = 1;
});
request.end(body);
NODE
}

real_turn_driver() {
  local phase_dir=$1 raw_phase_dir="$REAL_RAW_DIR/turn" before_state="$REAL_SECRET_DIR/turn-state-before.json" after_state="$REAL_SECRET_DIR/turn-state-after.json"
  local state_id prompt body_file send_file before_count after_count wait_status=0
  body_file="$REAL_SECRET_DIR/turn-prompt.json"
  sleep 2
  real_state_request "$before_state" || return 1
  state_id=$(node - -- "$REAL_SCRATCH_STATE_FILE" <<'NODE'
const fs = require('node:fs');
const state = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
process.stdout.write(String(state.session_id ?? ''));
NODE
  )
  [[ "$state_id" == "$REAL_SCRATCH_SESSION_ID" ]] || {
    printf 'real perf turn: scratch state id changed before POST (%s vs %s)\n' "$state_id" "$REAL_SCRATCH_SESSION_ID" >&2
    return 1
  }
  before_count=$(real_state_entry_count "$before_state" "$REAL_SCRATCH_SESSION_ID") || return 1
  printf '%s\n' "$before_count" > "$phase_dir/entry-count-before.txt"
  prompt=$("$ROOT/scripts/perf-scratch-session.sh" prompt)
  printf '%s' "$prompt" > "$REAL_SECRET_DIR/turn-prompt.txt"
  node - -- "$REAL_SECRET_DIR/turn-prompt.txt" "$body_file" <<'NODE'
const fs = require('node:fs');
const [promptFile, bodyFile] = process.argv.slice(3);
fs.writeFileSync(bodyFile, JSON.stringify({ text: fs.readFileSync(promptFile, 'utf8') }), { mode: 0o600 });
NODE
  send_file="$REAL_SECRET_DIR/turn-send.json"
  if ! real_post_scratch_message "$REAL_SCRATCH_SESSION_ID" "$REAL_SECRET_DIR/turn-prompt.json" "$send_file"; then
    printf '%s\n' 'real perf turn: POST /message failed' >&2
    return 1
  fi
  if LC_ALL=C grep -a -qF -- "$(<"$REAL_BEARER_FILE")" "$send_file"; then
    printf '%s\n' 'real perf turn bearer appeared in POST response; send evidence was not copied' >&2
    return 1
  fi
  cp "$send_file" "$phase_dir/send.json"
  chmod 600 "$phase_dir/send.json"
  "$ROOT/scripts/perf-scratch-session.sh" wait-idle 300 > "$raw_phase_dir/wait-idle.log" 2>&1 || wait_status=$?
  real_state_request "$after_state" || return 1
  after_count=$(real_state_entry_count "$after_state" "$REAL_SCRATCH_SESSION_ID") || return 1
  printf '%s\n' "$after_count" > "$phase_dir/entry-count-after.txt"
  return "$wait_status"
}

real_patch_turn_result() {
  local result_file="$REAL_OUTPUT_DIR/turn/result.json"
  node - -- "$result_file" "$REAL_OUTPUT_DIR/turn/entry-count-before.txt" "$REAL_OUTPUT_DIR/turn/entry-count-after.txt" "$REAL_SCRATCH_SESSION_ID" <<'NODE'
const fs = require('node:fs');
const [resultFile, beforeFile, afterFile, sessionId] = process.argv.slice(3);
const result = JSON.parse(fs.readFileSync(resultFile, 'utf8'));
const readCount = (file) => {
  try { return Number(fs.readFileSync(file, 'utf8').trim()); } catch { return null; }
};
result.scratch_session_id = sessionId;
result.entry_count_before = readCount(beforeFile);
result.entry_count_after = readCount(afterFile);
result.turn_wall_seconds = result.wall_seconds;
fs.writeFileSync(resultFile, JSON.stringify(result, null, 2) + '\n', { mode: 0o600 });
NODE
}

real_perf_run_phase() {
  local phase=$1
  local phase_dir="$REAL_OUTPUT_DIR/$phase"
  local status_source="$REAL_SECRET_DIR/status-before-$phase.json"
  local selected_source="$REAL_SECRET_DIR/selected-$phase.json"
  local selected_id='' selected_count='' phase_status=0
  mkdir -p "$phase_dir"
  if ! node "$(main_checkout)/src/cli.js" status > "$status_source"; then
    printf 'real perf %s failed to read status before phase\n' "$phase" >&2
    return 1
  fi
  real_status_summary "$status_source" "$phase_dir/status-before.json"
  if [[ "$phase" == busy ]]; then
    real_select_sessions "$status_source" "$selected_source" 1 || return 1
    selected_id=$(real_json_value "$selected_source" 0 id)
    selected_count=$(real_json_value "$selected_source" 0 entryCount)
  fi
  real_perf_launch_app "$phase" "$selected_id" || return 1
  if ! real_perf_measure_window "$phase" 20 fixed "$CC_PERF_REAL_DURATION" "$selected_id" "$selected_count"; then
    phase_status=1
  fi
  real_perf_finish_phase "$phase" 1 || phase_status=1
  [[ "$phase_status" -eq 0 ]]
}

real_perf_run_turn() {
  local phase_dir="$REAL_OUTPUT_DIR/turn" status_source="$REAL_SECRET_DIR/status-before-turn.json"
  local selected_id="$REAL_SCRATCH_SESSION_ID" selected_count phase_status=0
  mkdir -p "$phase_dir"
  node "$(main_checkout)/src/cli.js" status > "$status_source" || return 1
  real_status_summary "$status_source" "$phase_dir/status-before.json"
  selected_count=$(real_json_value "$status_source" entries "$selected_id")
  real_perf_launch_app turn "$selected_id" || return 1
  if ! real_perf_measure_window turn 90 until 5 "$selected_id" "$selected_count" real_turn_driver "$phase_dir"; then
    phase_status=1
  fi
  real_patch_turn_result
  real_perf_finish_phase turn 0 || phase_status=1
  if ! real_perf_measure_window turn-after 20 fixed "$CC_PERF_REAL_AFTER" "$selected_id" "$selected_count"; then
    phase_status=1
  fi
  real_perf_finish_phase turn-after 1 || phase_status=1
  if ! "$ROOT/scripts/perf-scratch-session.sh" stop; then
    printf '%s\n' 'real perf turn: scratch session stop failed' >&2
    phase_status=1
  fi
  real_assert_cli_session_missing "$REAL_OUTPUT_DIR/turn/status-after-scratch.json" || phase_status=1
  [[ "$phase_status" -eq 0 ]]
}

cmd_perf_real() {
  prune_scratch
  local only_phase='' no_build=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --phase)
        [[ $# -ge 2 && "$2" =~ ^(list|busy|turn)$ ]] || { printf '%s\n' 'perf-real --phase requires list, busy, or turn' >&2; return 2; }
        only_phase=$2
        shift 2
        ;;
      --no-build)
        no_build=1
        shift
        ;;
      *) printf 'unknown perf-real option: %s\n' "$1" >&2; return 2;;
    esac
  done
  CC_PERF_REAL_WARMUP=${CC_PERF_REAL_WARMUP:-10}
  CC_PERF_REAL_DURATION=${CC_PERF_REAL_DURATION:-60}
  CC_PERF_REAL_AFTER=${CC_PERF_REAL_AFTER:-30}
  [[ "$CC_PERF_REAL_WARMUP" =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf '%s\n' 'CC_PERF_REAL_WARMUP must be a number of seconds' >&2; return 2; }
  [[ "$CC_PERF_REAL_DURATION" =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf '%s\n' 'CC_PERF_REAL_DURATION must be a number of seconds' >&2; return 2; }
  [[ "$CC_PERF_REAL_AFTER" =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf '%s\n' 'CC_PERF_REAL_AFTER must be a number of seconds' >&2; return 2; }
  REAL_SMOKE_RUN=1
  REAL_DEVICE_NAME="cc-real-smoke-perf-$(date '+%Y%m%dT%H%M%S')-$$"
  local timestamp main_root app_bundle
  timestamp=$(date '+%Y%m%dT%H%M%S')
  REAL_OUTPUT_DIR="$EVIDENCE_ROOT/perf-real-2026-10-13/$timestamp"
  [[ ! -e "$REAL_OUTPUT_DIR" ]] || { printf 'perf-real evidence directory already exists: %s\n' "$REAL_OUTPUT_DIR" >&2; return 1; }
  REAL_RAW_DIR=$(scratch_dir_for_evidence "$REAL_OUTPUT_DIR")
  prepare_evidence_run "$REAL_OUTPUT_DIR"
  REAL_SECRET_DIR=$(mktemp -d)
  chmod 700 "$REAL_SECRET_DIR"
  REAL_BEARER_FILE="$REAL_SECRET_DIR/bearer"
  PERF_DERIVED="$IOS/build/perf-release"
  app_bundle="$PERF_DERIVED/Build/Products/Release-iphonesimulator/cc-controller.app"
  if [[ "$no_build" -eq 0 ]]; then
    cmd_generate
    step 'perf-real Release build' xcodebuild -project "$PROJECT" -scheme CCController -configuration Release -sdk iphonesimulator \
      -destination 'generic/platform=iOS Simulator' -derivedDataPath "$PERF_DERIVED" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
      SWIFT_ACTIVE_COMPILATION_CONDITIONS=CC_PERF build
  fi
  [[ -d "$app_bundle" ]] || { printf 'perf-real requires Release+CC_PERF app at %s; omit --no-build\n' "$app_bundle" >&2; return 1; }
  main_root=$(main_checkout)
  real_authenticate "$main_root" "$REAL_DEVICE_NAME"
  pool_acquire
  REAL_PERF_UDID=$(ensure_pool_device 'iPhone 18 Pro')
  PERF_UDID="$REAL_PERF_UDID"
  local phase
  for phase in list busy turn; do
    [[ -z "$only_phase" || "$only_phase" == "$phase" ]] || continue
    if [[ "$phase" == turn ]]; then
      real_start_scratch
      real_wait_for_scratch_state "$REAL_SECRET_DIR/turn-state-listed.json"
      real_perf_run_turn
    else
      real_perf_run_phase "$phase"
    fi
  done
}

cmd_perf() {
  prune_scratch
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
  PERF_OUTPUT_DIR=${CC_PERF_OUTPUT_DIR:-$EVIDENCE_ROOT/perf-2026-10-04/harness}
  PERF_SCRATCH_DIR=$(scratch_dir_for_evidence "$PERF_OUTPUT_DIR")
  PERF_DERIVED="$IOS/build/perf-release"
  PERF_RUN_NUMBER=0
  PERF_BUDGET_FAILED=0
  prepare_evidence_run "$PERF_OUTPUT_DIR"
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
  if ! resolved=$(node - -- "$devices_json" "$selector" <<'NODE'
const fs = require('node:fs');

const jsonPath = process.argv[3];
const selector = process.argv[4] || '';
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

archive_release() {
  local build_number=$1 archive_path=$2 team=$3 derived_data=$4
  local args=(
    xcodebuild
    -project "$PROJECT"
    -scheme CCController
    -configuration Release
    archive
    -destination 'generic/platform=iOS'
    -derivedDataPath "$derived_data"
    -archivePath "$archive_path"
    -allowProvisioningUpdates
    CODE_SIGN_STYLE=Automatic
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
    [[ -n "$team" ]] || {
      printf '%s\n' 'archive requires DEVELOPMENT_TEAM (set it in the environment or ios/Config/Signing.local.xcconfig)' >&2
      return 2
    }
    args+=(DEVELOPMENT_TEAM="$team")
  fi
  mkdir -p "$(dirname "$archive_path")"
  step archive "${args[@]}"
  printf 'archive created: %s\n' "$archive_path"
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
  archive_release "$build_number" "$archive_path" "$team" "$DERIVED/archive-derived"
}

cmd_gate() {
  prune_scratch
  local gate_started=$SECONDS flows_started flows_status=0 smoke_started smoke_status=0 flows_label
  flows_started=$SECONDS
  cmd_flows --shards 2 || flows_status=$?
  if [[ $flows_status -ne 0 ]]; then
    flows_label=FAIL
  elif [[ $FLOWS_FLAKY_COUNT -gt 0 ]]; then
    flows_label=PASS-FLAKY
  else
    flows_label=PASS
  fi
  printf 'gate full-ui wall-clock=%ss status=%s\n' "$((SECONDS - flows_started))" "$flows_label"
  smoke_started=$SECONDS
  cmd_real_smoke "$@" || smoke_status=$?
  printf 'gate real-smoke wall-clock=%ss status=%s\n' "$((SECONDS - smoke_started))" "$([[ $smoke_status -eq 0 ]] && printf PASS || printf FAIL)"
  printf 'gate total wall-clock=%ss status=%s\n' "$((SECONDS - gate_started))" "$([[ $flows_status -eq 0 && $smoke_status -eq 0 ]] && printf PASS || printf FAIL)"
  [[ $flows_status -eq 0 && $smoke_status -eq 0 ]]
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

ota_validate_revision() {
  local requested_sha=$1 head expected main_sha
  head=$(git -C "$ROOT" rev-parse HEAD)
  if [[ -n "$requested_sha" ]]; then
    expected=$(git -C "$ROOT" rev-parse --verify "$requested_sha^{commit}") || {
      printf 'ota could not resolve --sha %s\n' "$requested_sha" >&2
      return 2
    }
  else
    main_sha=$(git -C "$ROOT" rev-parse --verify main^{commit} 2>/dev/null || true)
    expected=$main_sha
  fi
  if [[ -z "$expected" || "$head" != "$expected" ]]; then
    printf 'ota requires HEAD %s to equal main%s\n' "$head" "${requested_sha:+ or --sha $requested_sha}" >&2
    return 2
  fi
  local dirty
  dirty=$(git -C "$ROOT" status --porcelain --untracked-files=all)
  if [[ -L "$ROOT/node_modules" && "$(readlink "$ROOT/node_modules")" == "$(main_checkout)/node_modules" ]]; then
    dirty=$(printf '%s\n' "$dirty" | while IFS= read -r line; do
      [[ "$line" == '?? node_modules' ]] || printf '%s\n' "$line"
    done)
  fi
  if [[ -n "$dirty" ]]; then
    printf '%s\n' 'ota requires a clean worktree' >&2
    return 2
  fi
  printf '%s\n' "$head"
}

ota_next_build_number() {
  local build_number path name existing
  build_number=$(date +%Y%m%d%H%M)
  for path in "$IOS/build/ota"/*; do
    [[ -d "$path" ]] || continue
    name=${path##*/}
    [[ "$name" =~ ^[0-9]+$ ]] || continue
    existing=$name
    if (( existing >= build_number )); then
      build_number=$((existing + 1))
    fi
  done
  printf '%s\n' "$build_number"
}

ota_write_export_options() {
  local output=$1 team=$2 base_url=$3
  cat > "$output" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>compileBitcode</key>
  <false/>
  <key>manifest</key>
  <dict>
    <key>appURL</key>
    <string>${base_url}/CCController.ipa</string>
    <key>displayImageURL</key>
    <string>${base_url}/AppIcon57.png</string>
    <key>fullSizeImageURL</key>
    <string>${base_url}/AppIcon512.png</string>
  </dict>
  <key>method</key>
  <string>debugging</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>${team}</string>
  <key>thinning</key>
  <string>&lt;none&gt;</string>
</dict>
</plist>
EOF
}

ota_render_icons() {
  local output_dir=$1 source="$IOS/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
  [[ -f "$source" ]] || {
    printf 'ota icon source is missing: %s\n' "$source" >&2
    return 1
  }
  sips -z 57 57 "$source" --out "$output_dir/AppIcon57.png" >/dev/null
  sips -z 512 512 "$source" --out "$output_dir/AppIcon512.png" >/dev/null
}

ota_write_index() {
  local output_dir=$1 build_number=$2 short_sha=$3 build_date=$4 base_url=$5
  cat > "$output_dir/index.html" <<EOF
<!doctype html>
<meta charset="utf-8">
<title>cc-controller build ${build_number}</title>
<p><a style="font: bold 2em system-ui" href="itms-services://?action=download-manifest&url=${base_url}/manifest.plist">Install cc-controller build ${build_number} (${short_sha})</a></p>
<p>Build date: ${build_date}</p>
EOF
}

ota_verify_remote() {
  local base_url=$1 build_number=$2 response code content path url
  local paths=("manifest.plist" "CCController.ipa" "AppIcon57.png" "AppIcon512.png" "index.html")
  for path in "${paths[@]}"; do
    url="${base_url}/${path}"
    response=$(ssh mustafar "curl -sf -o /dev/null -w '%{http_code} %{content_type}\\n' '$url'") || {
      printf 'ota verification failed: %s\n' "$url" >&2
      return 1
    }
    code=${response%% *}
    content=${response#* }
    [[ "$code" =~ ^2[0-9][0-9]$ ]] || {
      printf 'ota verification failed: %s returned %s\n' "$url" "$response" >&2
      return 1
    }
    if [[ "$path" == manifest.plist && "$content" == text/html* ]]; then
      printf 'ota verification failed: manifest served as %s\n' "$content" >&2
      return 1
    fi
    printf 'ota verify %s: %s\n' "$url" "$response"
  done
  url="https://mustafar.example.ts.net/latest.html"
  response=$(ssh mustafar "curl -sf -o /dev/null -w '%{http_code} %{content_type}\\n' '$url'") || {
    printf 'ota verification failed: %s\n' "$url" >&2
    return 1
  }
  code=${response%% *}
  [[ "$code" =~ ^2[0-9][0-9]$ ]] || {
    printf 'ota verification failed: %s returned %s\n' "$url" "$response" >&2
    return 1
  }
  printf 'ota verify %s: %s\n' "$url" "$response"
}

ota_retain_builds() {
  ssh mustafar 'set -eu
for build in $(find /var/lib/cc-ota/cc -mindepth 1 -maxdepth 1 -type d -printf "%f\\n" | sort -rn | tail -n +4); do
  case "$build" in
    ""|*[!0-9]*) ;;
    *) rm -rf -- "/var/lib/cc-ota/cc/$build"; printf "ota deleted old build %s\\n" "$build" ;;
  esac
done'
  # Keep only the newest three local builds and archives; each archive is several hundred MB.
  local ota_root="$IOS/build/ota" old
  for old in $(find "$ota_root" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' -exec basename {} \; | sort -rn | tail -n +4); do
    [[ "$old" =~ ^[0-9]+$ ]] || continue
    rm -rf -- "$ota_root/$old" "$ota_root/archive/CCController-$old.xcarchive" "$ota_root/ExportOptions-$old.plist"
  done
}

cmd_ota() {
  local requested_sha='' dry_run=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sha)
        [[ $# -ge 2 ]] || { printf '%s\n' 'ota --sha requires a value' >&2; return 2; }
        requested_sha=$2
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      *)
        printf 'unknown ota option: %s\n' "$1" >&2
        return 2
        ;;
    esac
  done

  local source_sha
  source_sha=$(ota_validate_revision "$requested_sha") || return $?
  printf 'ota source SHA: %s\n' "$source_sha"
  cmd_generate

  local team
  team=$(signing_team)
  if [[ -z "$team" ]]; then
    printf '%s\n' 'ota requires DEVELOPMENT_TEAM (set it in the environment or ios/Config/Signing.local.xcconfig)' >&2
    return 2
  fi

  local build_number short_sha base_url build_date ota_root artifact_dir export_options archive_path export_dir
  build_number=$(ota_next_build_number)
  short_sha=$(git -C "$ROOT" rev-parse --short HEAD)
  base_url="https://mustafar.example.ts.net/cc/${build_number}"
  build_date=$(date -u '+%Y-%m-%d %H:%M UTC')
  ota_root="$IOS/build/ota"
  if (( dry_run )); then
    artifact_dir="$ota_root/dry-run/$build_number"
    export_options="$artifact_dir/ExportOptions.plist"
    mkdir -p "$artifact_dir"
    ota_write_export_options "$export_options" "$team" "$base_url"
    plutil -lint "$export_options"
    ota_render_icons "$artifact_dir"
    ota_write_index "$artifact_dir" "$build_number" "$short_sha" "$build_date" "$base_url"
    cp "$artifact_dir/index.html" "$ota_root/latest.html"
    printf 'ota plan: dry-run\n'
    printf 'ota build number: %s\n' "$build_number"
    printf 'ota artifacts: %s\n' "$artifact_dir"
    printf 'ota export options: %s\n' "$export_options"
    cat "$export_options"
    printf 'ota manifest URLs:\n'
    printf '  appURL: %s/CCController.ipa\n' "$base_url"
    printf '  displayImageURL: %s/AppIcon57.png\n' "$base_url"
    printf '  fullSizeImageURL: %s/AppIcon512.png\n' "$base_url"
    printf 'ota dry-run: no archive, export, or publish performed\n'
    printf '%s/index.html\n' "$base_url"
    return 0
  fi

  artifact_dir="$ota_root/$build_number"
  export_options="$ota_root/ExportOptions-$build_number.plist"
  archive_path="$ota_root/archive/CCController-$build_number.xcarchive"
  if [[ -e "$artifact_dir" || -e "$archive_path" || -e "$export_options" ]]; then
    printf 'ota build artifacts already exist for %s; refusing to overwrite\n' "$build_number" >&2
    return 2
  fi
  mkdir -p "$artifact_dir"
  ota_write_export_options "$export_options" "$team" "$base_url"
  archive_release "$build_number" "$archive_path" "$team" "$ota_root/derived"

  export_dir="$artifact_dir"
  local export_args=(
    xcodebuild
    -exportArchive
    -allowProvisioningUpdates
    -archivePath "$archive_path"
    -exportPath "$export_dir"
    -exportOptionsPlist "$export_options"
  )
  step 'ota export' "${export_args[@]}"
  local ipa_path
  ipa_path="$export_dir/CCController.ipa"
  if [[ ! -f "$ipa_path" ]]; then
    local exported_ipa
    exported_ipa=$(find "$export_dir" -maxdepth 1 -type f -name '*.ipa' -print -quit)
    [[ -n "$exported_ipa" ]] || {
      printf 'ota export did not produce an IPA in %s\n' "$export_dir" >&2
      return 1
    }
    mv "$exported_ipa" "$ipa_path"
  fi
  [[ -f "$export_dir/manifest.plist" ]] || {
    printf 'ota export did not produce a manifest in %s\n' "$export_dir" >&2
    return 1
  }
  ota_render_icons "$artifact_dir"
  ota_write_index "$artifact_dir" "$build_number" "$short_sha" "$build_date" "$base_url"
  cp "$artifact_dir/index.html" "$ota_root/latest.html"

  ssh mustafar "mkdir -p /var/lib/cc-ota/cc/$build_number"
  rsync -a "$artifact_dir/" "mustafar:/var/lib/cc-ota/cc/$build_number/"
  scp "$ota_root/latest.html" "mustafar:/var/lib/cc-ota/latest.html"
  ota_retain_builds
  ota_verify_remote "$base_url" "$build_number"
  printf '%s/index.html\n' "$base_url"
}

ensure_node_modules

case "${1:-}" in
  generate) shift; step generate cmd_generate "$@";;
  build) shift; step build cmd_build "$@";;
  test) shift; step test cmd_test "$@";;
  release-check) shift; cmd_release_check "$@";;
  perf) shift; cmd_perf "$@";;
  perf-real) shift; cmd_perf_real "$@";;
  archive) shift; cmd_archive "$@";;
  upload) shift; cmd_upload "$@";;
  ota) shift; cmd_ota "$@";;
  gate) shift; cmd_gate "$@";;
  real-smoke) shift; cmd_real_smoke "$@";;
  shots) shift; cmd_shots "$@";;
  flows) shift; cmd_flows "$@";;
  motion) shift; cmd_motion "$@";;
  mocks) shift; cmd_mocks "$@";;
  pool) shift; cmd_pool "$@";;
  clean) shift; cmd_clean "$@";;
  install) shift; cmd_install "$@";;
  *) printf 'Usage: %s {generate|build|test|release-check|perf|perf-real|archive|upload|ota [--sha <commit>] [--dry-run]|gate|real-smoke|shots|flows [--test <Class[/method]>]... [--device <name>] [--shards <N>] [--no-rerun]|motion [--scenario K1,K2,S1,S2,H1,P1|all] [--engine legacy|collection|both] [--device iphone|duo] [--orientation portrait|landscape] [--out DIR] [--rebuild] [--video]|mocks|pool|clean|install [--device <udid-or-name>] [--launch]}\n' "$0" >&2; exit 2;;
esac
