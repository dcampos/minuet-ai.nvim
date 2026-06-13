#!/usr/bin/env bash
# Live end-to-end test of duet NES against gpt-oss-120b on OpenRouter, driving a
# real Neovim under tmux: rename a variable (captured as edit history), trigger a
# prediction, and accept it. Requires OPENROUTER_API_KEY in the environment.
set -uo pipefail

REPO="$HOME/code/lua/minuet-ai.nvim"
INIT="$REPO/tests/harness/e2e_init.lua"
SESS="duet_e2e_$$"
WORK="$(mktemp -d)"
FILE="$WORK/nes.lua"

cat >"$FILE" <<'EOF'
local timeout = 30
local function connect(host)
  return open(host, timeout)
end
EOF

cleanup() { tmux kill-session -t "$SESS" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

if [ -z "${OPENROUTER_API_KEY:-}" ]; then echo "OPENROUTER_API_KEY not set"; exit 1; fi

tmux new-session -d -s "$SESS" -x 110 -y 24 "nvim -u '$INIT' '$FILE'"
sleep 2.5
echo "===== 1. initial buffer ====="
tmux capture-pane -t "$SESS" -p | sed -n '1,4p'

# 2. Rename `timeout` -> `timeout_secs` on line 1 (captured as an edit).
tmux send-keys -t "$SESS" 'gg0w' 'ciwtimeout_secs' Escape
sleep 0.8
echo "===== 2. after rename on line 1 ====="
tmux capture-pane -t "$SESS" -p | sed -n '1,4p'

# 3. Move cursor to the usage site and trigger a prediction.
tmux send-keys -t "$SESS" '/timeout)' Enter
sleep 0.3
tmux send-keys -t "$SESS" ':Minuet duet predict' Enter
echo "===== 3. waiting for live gpt-oss-120b prediction ====="

# Poll is_visible (preview rendered) up to ~20s.
vis=""
for _ in $(seq 1 20); do
  sleep 1
  tmux send-keys -t "$SESS" ':lua duet_vis()' Enter
  sleep 0.2
  if tmux capture-pane -t "$SESS" -p | grep -q 'DUET_VIS=true'; then vis=yes; break; fi
done
if [ "$vis" = yes ]; then echo "PASS preview became visible (model predicted an edit)"; else
  echo "FAIL no preview within timeout"; tmux capture-pane -t "$SESS" -p | sed -n '1,8p'; exit 1; fi

# 4. Accept and verify the usage site was renamed.
tmux send-keys -t "$SESS" ':Minuet duet apply' Enter
sleep 1.0
echo "===== 4. after apply ====="
RESULT="$(tmux capture-pane -t "$SESS" -p)"
sed -n '1,4p' <<<"$RESULT"

echo "===== 5. assertions ====="
fail=0
grep -q 'local timeout_secs = 30'        <<<"$RESULT" && echo "PASS line 1 renamed"                || { echo "FAIL line1"; fail=1; }
grep -q 'open(host, timeout_secs)'        <<<"$RESULT" && echo "PASS usage propagated by model"     || { echo "FAIL usage not propagated"; fail=1; }
[ "$fail" -eq 0 ] && echo "LIVE E2E PASSED" || { echo "LIVE E2E FAILED"; exit 1; }
