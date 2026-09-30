#!/usr/bin/env python3
"""Extract JSON contract examples into fixtures and a reviewable type manifest."""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path


def slug(value: str) -> str:
    value = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return value or "section"


def fixture_type(title: str, value: object) -> str:
    lowered = title.lower()
    if isinstance(value, list):
        if value and isinstance(value[0], dict) and "kind" in value[0]:
            return "TranscriptArray"
        return "JSONValue"
    if not isinstance(value, dict):
        return "JSONValue"
    kind = value.get("kind")
    if kind:
        return "TranscriptEntry"
    if "apiVersion" in value:
        return "Bootstrap"
    if "authenticated" in value and "token" in value:
        return "NativeLoginResponse"
    if "authenticated" in value:
        return "WhoAmI"
    if "secret" in value:
        return "NativeEnrollResponse"
    if "deviceToken" in value and "state" not in value:
        return "PairPollResponse"
    if value.get("state") in {"pending", "expired", "confirmed"}:
        return "PairPollResponse"
    if "code" in value and len(value) == 1:
        return "PairStartResponse"
    if "loggedOut" in value:
        return "LogoutResponse"
    if "delivered" in value or ("queued" in value and "route" in value):
        return "MessageResult"
    if "sent" in value:
        return "KeyResult"
    if "mode" in value and len(value) == 1:
        return "ModeResult"
    if "decided" in value:
        return "Decision"
    if "files" in value:
        if isinstance(value["files"], list) and all(isinstance(item, str) for item in value["files"]):
            return "JSONValue"
        return "UploadResponse"
    if "devices" in value:
        return "DeviceList"
    if "usage" in value and "sessionId" in value:
        return "UsageEvent"
    if "subagents" in value and "sessionId" in value:
        return "SubagentsEvent"
    if "requestId" in value and ("behavior" in value or "tool_name" in value):
        return "DecisionEvent" if "behavior" in value else "ApprovalEvent"
    if "name" in value and "url" in value and "size" in value:
        return "UploadedFile"
    if "sessionId" in value and "entry" in value:
        return "TranscriptEvent"
    if "sessionId" in value and "name" in value and "url" in value:
        return "FileEvent"
    if "sessions" in value and "entries" in value:
        if "transcriptPath" in json.dumps(value):
            return "RegistryEvent"
        return "StateSnapshot"
    if title.lower().endswith("state") or ("sessionId" in value and any(key in value for key in ("lastTool", "toolRunning", "pending"))):
        return "StateDelta"
    return "JSONValue"


def has_placeholder(value: object) -> bool:
    if isinstance(value, str):
        return bool(re.fullmatch(r"<[^>]+>", value))
    if isinstance(value, list):
        return any(has_placeholder(item) for item in value)
    if isinstance(value, dict):
        return any(has_placeholder(item) for item in value.values())
    return False


def main() -> int:
    root = Path(__file__).resolve().parents[3]
    contract = root / "tasks" / "api-contract.md"
    fixture_dir = Path(__file__).resolve().parents[1] / "Tests" / "CCKitTests" / "Fixtures"
    fixture_dir.mkdir(parents=True, exist_ok=True)
    text = contract.read_text(encoding="utf-8")
    heading = "contract"
    counters: dict[str, int] = {}
    manifest: dict[str, dict[str, object]] = {}
    in_fence = False
    language = ""
    block: list[str] = []
    for line in text.splitlines():
        heading_match = re.match(r"^#{2,3}\s+(.+?)\s*$", line)
        if heading_match and not in_fence:
            heading = heading_match.group(1)
        fence_match = re.match(r"^```(\w*)\s*$", line)
        if fence_match:
            if not in_fence:
                in_fence = True
                language = fence_match.group(1).lower()
                block = []
            else:
                if language == "json":
                    raw = "\n".join(block).strip()
                    try:
                        value = json.loads(raw)
                    except json.JSONDecodeError:
                        value = None
                    if value is not None:
                        base = slug(heading)
                        counters[base] = counters.get(base, 0) + 1
                        filename = f"{base}-{counters[base]}.json"
                        (fixture_dir / filename).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
                        decoded_type = fixture_type(heading, value)
                        spec: dict[str, object] = {"type": decoded_type}
                        if decoded_type in {"Bootstrap", "NativeLoginResponse"} and has_placeholder(value):
                            spec = {"type": decoded_type, "skip": True, "reason": "Contract example uses a placeholder date (<iso>)."}
                        manifest[filename] = spec
                    else:
                        print(f"Skipping non-JSON fenced example under {heading}", file=sys.stderr)
                in_fence = False
                language = ""
            continue
        if in_fence:
            block.append(line)
    (fixture_dir / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Extracted {len(manifest)} JSON fixtures into {fixture_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
