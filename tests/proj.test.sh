#!/bin/bash
# Unit checks for bin/proj helpers. Runs under macOS /bin/bash 3.2 on purpose.
set -euo pipefail
AGENT_HUB_HOME="$(mktemp -d)"; export AGENT_HUB_HOME
trap 'rm -rf "$AGENT_HUB_HOME"' EXIT
. "$(dirname "$0")/../bin/proj"

fails=0
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi
}

check "compose name lowercases and maps dots" "proj-sosincommerce-be" "$(compose_name SosinCommerce-BE)"
check "compose name keeps underscores"        "proj-my_app-v2" "$(compose_name my_app.v2)"
check "container name"                         "proj-coffee-agent-1" "$(container coffee)"

for n in coffee SosinCommerce-BE a.b_c 9lives; do
  check "valid name $n" yes "$(valid_name "$n" && echo yes || echo no)"
done
for n in "" -lead .hidden "has space" "a/b" '$(x)'; do
  check "invalid name '$n'" no "$(valid_name "$n" && echo yes || echo no)"
done

# Task state from files only (no container needed for finished tasks).
d="$AGENT_HUB_HOME/tasks/demo/t1"; mkdir -p "$d"
printf 'PROJECT=demo\nBRANCH=agent/t1\n' > "$d/meta"
printf '%s\n' '{"type":"system","subtype":"init","session_id":"s-123"}' \
  '{"type":"result","is_error":false,"result":"all good","total_cost_usd":0.1}' > "$d/log.jsonl"
echo 0 > "$d/exit"
check "session id from init event" "s-123" "$(session_id "$d")"
check "result text"                "all good" "$(result_field "$d" result)"
check "finished task is done"      "done" "$(task_state "$d")"
echo 1 > "$d/exit"
check "non-zero exit is failed"    "failed" "$(task_state "$d")"
check "meta reads last value"      "agent/t1" "$(meta "$d" BRANCH)"
check "finished tasks are not running" "" "$(running_tasks)"

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
