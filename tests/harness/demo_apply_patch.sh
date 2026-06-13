#!/usr/bin/env bash
# Drive the dev minuet plugin in a real Neovim under tmux: apply an apply_patch
# edit and verify buffer state via screen capture, then prove keystroke driving.
# Proof harness for duet NES — no API needed (uses the reusable applier directly).
set -euo pipefail

REPO="$HOME/code/lua/minuet-ai.nvim"
INIT="$REPO/tests/harness/minimal_init.lua"
SESS="duet_demo_$$"
WORK="$(mktemp -d)"
FILE="$WORK/demo.lua"
PATCH="$WORK/patch.txt"

cat >"$FILE" <<'EOF'
local function greet(name)
  return "hello " .. name
end
EOF

# Patch read from a file (robust: no newline/quoting issues through tmux).
cat >"$PATCH" <<'EOF'
*** Begin Patch
*** Update File: demo.lua
@@
-local function greet(name)
+local function greet(person)
*** End Patch
EOF

cleanup() { tmux kill-session -t "$SESS" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

# 1. Launch nvim in a detached tmux pane.
tmux new-session -d -s "$SESS" -x 100 -y 24 "nvim -u '$INIT' '$FILE'"
sleep 2.5
echo "===== 1. initial buffer ====="
tmux capture-pane -t "$SESS" -p | sed -n '1,3p'

# 2. Apply the patch (model-style edit) and capture.
tmux send-keys -t "$SESS" ":lua duet_demo_apply_file('$PATCH')" Enter
sleep 0.8
STEP2="$(tmux capture-pane -t "$SESS" -p)"   # DUET_APPLY_OK message is on screen here
echo "===== 2. after apply_patch (greet(name) -> greet(person)) ====="
sed -n '1,3p' <<<"$STEP2"

# 3. Keystroke edit to prove tmux keystroke driving end-to-end.
tmux send-keys -t "$SESS" 'ggA  -- typed by tmux' Escape
sleep 0.5
echo "===== 3. after keystroke edit (insert mode typing) ====="
tmux capture-pane -t "$SESS" -p | sed -n '1,3p'

# 4. Assertions over the final screen.
RESULT="$(tmux capture-pane -t "$SESS" -p)"
echo "===== 4. assertions ====="
fail=0
grep -q 'DUET_APPLY_OK'  <<<"$STEP2"  && echo "PASS apply reported OK"            || { echo "FAIL no OK";        fail=1; }
grep -q 'greet(person)'  <<<"$RESULT" && echo "PASS buffer shows greet(person)"   || { echo "FAIL rename missing"; fail=1; }
grep -q 'greet(name)'    <<<"$RESULT" && { echo "FAIL old greet(name) present"; fail=1; } || echo "PASS old greet(name) gone"
grep -q 'typed by tmux'  <<<"$RESULT" && echo "PASS keystroke edit landed"        || { echo "FAIL keystroke missing"; fail=1; }
[ "$fail" -eq 0 ] && echo "ALL HARNESS ASSERTIONS PASSED" || { echo "HARNESS FAILED"; exit 1; }
