#!/usr/bin/env bash
# Mock curl for the duet NES transport test. Validates that the request body
# (curl's `-d @file`) is a real JSON object (regression guard against
# double-encoding), then prints a non-streaming chat-completions response with a
# single apply_patch tool call turning `return 1` into `return 42`.
set -uo pipefail

# Find the `-d @<file>` argument and read the request body.
data=""
prev=""
for a in "$@"; do
    [ "$prev" = "-d" ] && data="$a"
    prev="$a"
done
file="${data#@}"
body=""
[ -n "$file" ] && [ -f "$file" ] && body="$(cat "$file")"

if [ "${body:0:1}" != "{" ]; then
    # Not a JSON object (e.g. double-encoded into a quoted string): fail loudly.
    python3 - "$body" <<'PY'
import json, sys
print(json.dumps({"error": {"message": "mock: request body is not a JSON object: " + sys.argv[1][:60]}}))
PY
    exit 0
fi

python3 - <<'PY'
import json
patch = "*** Begin Patch\n*** Update File: buf\n@@\n-return 1\n+return 42\n*** End Patch"
print(json.dumps({
    "choices": [{
        "message": {
            "role": "assistant",
            "content": None,
            "tool_calls": [{
                "id": "call_1",
                "type": "function",
                "function": {"name": "apply_patch", "arguments": json.dumps({"input": patch})},
            }],
        }
    }]
}))
PY
