#!/usr/bin/env bash
# Mock curl for Mercury Edit 2. Validates that duet sends the tagged
# /edit/completions request shape, then returns a fenced replacement for the
# editable region.
set -uo pipefail

data=""
prev=""
for a in "$@"; do
    [ "$prev" = "-d" ] && data="$a"
    prev="$a"
done
file="${data#@}"
body=""
[ -n "$file" ] && [ -f "$file" ] && body="$(cat "$file")"

python3 - "$body" <<'PY'
import json
import os
import sys

try:
    body = json.loads(sys.argv[1])
except Exception as exc:
    print(json.dumps({"error": {"message": f"mock: invalid json: {exc}"}}))
    raise SystemExit(0)

content = body.get("messages", [{}])[0].get("content", "")
required = [
    "<|recently_viewed_code_snippets|>",
    "<|current_file_content|>",
    "<|code_to_edit|>",
    "<|cursor|>",
    "<|edit_diff_history|>",
]
missing = [tag for tag in required if tag not in content]
if body.get("model") != "mercury-edit-2" or missing:
    print(json.dumps({"error": {"message": f"mock: bad Mercury Edit request, missing={missing}"}}))
    raise SystemExit(0)

replacement = os.environ.get("MINUET_MOCK_INCEPTION_CONTENT", "return 42")
print(json.dumps({
    "id": "editcmpl_mock",
    "object": "edit.completion",
    "model": "mercury-edit-2",
    "choices": [{
        "index": 0,
        "message": {
            "role": "assistant",
            "content": f"```\n{replacement}\n```",
        },
        "finish_reason": "stop",
    }],
}))
PY
