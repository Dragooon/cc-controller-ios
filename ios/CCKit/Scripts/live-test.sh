#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
OUT=$(mktemp "${TMPDIR:-/tmp}/cc-fixture.XXXXXX")
LOG=$(mktemp "${TMPDIR:-/tmp}/cc-fixture-log.XXXXXX")
FIXTURE_PID=""

cleanup() {
  if [ -n "$FIXTURE_PID" ]; then kill "$FIXTURE_PID" 2>/dev/null || true; wait "$FIXTURE_PID" 2>/dev/null || true; fi
  rm -f "$OUT" "$LOG"
}
trap cleanup EXIT INT TERM

node "$ROOT/scripts/fixture-daemon.mjs" --scenario default --out "$OUT" >"$LOG" 2>&1 &
FIXTURE_PID=$!

python3 - "$OUT" <<'PY'
import json
import sys
import time
from pathlib import Path

path = Path(sys.argv[1])
for _ in range(200):
    if path.exists():
        try:
            value = json.loads(path.read_text())
            if value.get("webPort") and value.get("bearer"):
                print(f"http://127.0.0.1:{value['webPort']}")
                break
        except (OSError, json.JSONDecodeError):
            pass
    time.sleep(0.05)
else:
    raise SystemExit("fixture did not become ready")
PY

FIXTURE_VALUES=$(python3 - "$OUT" <<'PY'
import json
import sys
from pathlib import Path
value = json.loads(Path(sys.argv[1]).read_text())
print(f"{value['webPort']}\n{value['bearer']}")
PY
)
CC_FIXTURE_URL="http://127.0.0.1:$(printf '%s\n' "$FIXTURE_VALUES" | awk 'NR==1 { print $1 }')"
CC_FIXTURE_BEARER=$(printf '%s\n' "$FIXTURE_VALUES" | awk 'NR==2 { print $1 }')
export CC_FIXTURE_URL CC_FIXTURE_BEARER

cd "$ROOT/ios/CCKit"
swift test --filter Live
printf '%s\n' "Live CCKit tests passed"
printf '%s\n' "Fixture request log excerpt:"
grep 'fixture_request' "$LOG" | tail -20 || true
