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
printf 'PROJECT=demo\nBRANCH=agent/t1\n' > "$d/meta"; echo "demo prompt" > "$d/prompt.txt"
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
check "wait returns at once for a finished task" 0 "$(wait_task "$d" 5 >/dev/null; echo $?)"

# Removed projects' tasks are hidden from the list.
mkdir -p "$AGENT_HUB_HOME/projects"
check "task of unregistered project hidden" 0 "$(status_list '*' | grep -c t1 || true)"
printf 'PROJECT_NAME=demo\n' > "$(env_file demo)"
check "task of registered project listed" 1 "$(status_list '*' | grep -c t1 || true)"

# Aliases replace their line in the env file.
cmd_alias demo 스모크 >/dev/null; cmd_alias demo 데모 >/dev/null
check "alias is replaced, not duplicated" "데모" "$(project_var demo ALIAS)"
check "one alias line" 1 "$(grep -c '^ALIAS=' "$(env_file demo)")"

# --purge refuses while work exists only locally.
r="$(mktemp -d)"; git -C "$r" init -q -b main
git -C "$r" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
check "local-only commit is unsaved work" 1 "$(unsaved_work "$r" | grep -c 'on no remote')"
touch "$r/new.txt"
check "uncommitted file is unsaved work" 1 "$(unsaved_work "$r" | grep -c uncommitted)"
rm -rf "$r"

# Workspaces: repos inside are checked one by one; loose top-level files count as unsaved.
w="$(mktemp -d)"; o="$(mktemp -d)"
git init -q --bare "$o/origin.git"
git -C "$w" clone -q "$o/origin.git" api 2>/dev/null
git -C "$w/api" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init && git -C "$w/api" push -q origin HEAD 2>/dev/null
check "is_repo: workspace root is not a repo" no "$(is_repo "$w" && echo yes || echo no)"
check "is_repo: repo inside workspace" yes "$(is_repo "$w/api" && echo yes || echo no)"
check "is_repo: folder inside a repo is not a repo" no "$(mkdir -p "$w/api/src"; is_repo "$w/api/src" && echo yes || echo no)"
check "clean pushed workspace has nothing unsaved" "" "$(unsaved_work "$w")"
echo notes > "$w/NOTES.md"
check "loose file in workspace is unsaved" 1 "$(unsaved_work "$w" | grep -c 'not in any repo')"
check "uses_rust finds a nested Cargo.toml" yes "$(touch "$w/api/Cargo.toml"; uses_rust "$w" && echo yes || echo no)"
check "uses_rust is false without Cargo.toml" no "$(uses_rust "$o" && echo yes || echo no)"
rm -rf "$w" "$o"

# rm refuses piped consent.
check "rm refuses piped y" "confirmation needed" "$(echo y | (cmd_rm demo 2>&1) | grep -o 'confirmation needed' || true)"

# Task ids stay unique across projects within the same second.
mkdir -p "$AGENT_HUB_HOME/tasks/other/$(date +%y%m%d-%H%M%S)"
check "id taken in another project gets a suffix" yes "$(new_task_id | grep -qE -- '-[23]$' && echo yes || echo no)"

# Usage comes from the newest rate_limit_event of the account's tasks; past windows count as 0.
u="$AGENT_HUB_HOME/tasks/demo/u1"; mkdir -p "$u"; printf 'PROJECT=demo\nACCOUNT=acct\n' > "$u/meta"
future=$(( $(date +%s) + 3600 )); past=$(( $(date +%s) - 60 ))
printf '{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.97,"resetsAt":%s,"status":"allowed"},"seven_day":{"utilization":0.4,"resetsAt":%s,"status":"allowed"}}}}\n' "$future" "$past" > "$u/log.jsonl"
check "5h usage shown as percent" yes "$(usage_line acct | grep -q '5h 97%' && echo yes || echo no)"
check "expired 7d window counts as 0" yes "$(usage_line acct | grep -q '7d 0%' && echo yes || echo no)"
check "over USAGE_MAX blocks" blocked "$( (USAGE_MAX=0.95; usage_ok acct) >/dev/null 2>&1 && echo ok || echo blocked)"
check "under a higher USAGE_MAX passes" ok "$( (USAGE_MAX=0.99; usage_ok acct) >/dev/null 2>&1 && echo ok || echo blocked)"
check "account without tasks has no data" "usage: no data yet" "$(usage_line nobody)"
mkdir -p "$AGENT_HUB_HOME/usage"; sleep 1
printf '{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.02,"resetsAt":%s,"status":"allowed"}}}}\n' "$future" > "$AGENT_HUB_HOME/usage/acct.jsonl"
check "newer probe result wins over task log" yes "$(usage_line acct | grep -q '5h 2%' && echo yes || echo no)"

check "tilde shortens home paths" "~/Storage/agents/x" "$(tilde "$HOME/Storage/agents/x")"
check "tilde keeps other paths" "/Volumes/other/x" "$(tilde /Volumes/other/x)"

# Hub settings follow WORKSPACE_ROOT / AGENT_HUB_HOME.
s="$(WORKSPACE_ROOT="$HOME/Storage" hub_settings)"
check "hub settings: workspace read rule" yes "$(jq -e '.permissions.allow | index("Read(~/Storage/**)")' "$s" >/dev/null && echo yes || echo no)"
check "hub settings: accounts deny follows hub home" "Read(/$AGENT_HUB_HOME/accounts/**)" "$(jq -r '.permissions.deny[0]' "$s")"
check "hub settings: plain additionalDirectories" "$HOME/Storage" "$(jq -r '.permissions.additionalDirectories[0]' "$s")"

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
