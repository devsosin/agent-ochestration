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

check "hub may manage plugin sources" yes "$(jq -e '.permissions.allow | index("Bash(proj plugin source*)")' "$s" >/dev/null && echo yes || echo no)"
check "hub has no allow rule for per-project plugin add/rm" 0 "$(jq '[.permissions.allow[] | select(test("proj plugin \\*|proj plugin [^sl]"))] | length' "$s")"

# Plugins: marketplace clones on the host, per-project managed settings.
src="$(mktemp -d)"; mkdir -p "$src/.claude-plugin"
printf '{"name":"pony-mkt","plugins":[{"name":"ponytail","source":"./"}]}\n' > "$src/.claude-plugin/marketplace.json"
git -C "$src" init -q -b main && git -C "$src" add -A && git -C "$src" -c user.name=t -c user.email=t@t commit -q -m init
plugin_source add "file://$src" >/dev/null
check "source add names the folder after marketplace.json" yes "$([ -f "$PLUGINS_DIR/pony-mkt/.claude-plugin/marketplace.json" ] && echo yes || echo no)"
check "source add leaves no temp folder" "" "$(ls -A "$PLUGINS_DIR" | grep '^\.add' || true)"
check "source add refuses an existing marketplace" "already exists" "$( (plugin_source add "file://$src") 2>&1 | grep -o 'already exists' || true)"
check "source ls lists plugins" 1 "$(plugin_source ls | grep -c 'pony-mkt.*plugins: ponytail')"
rm -rf "$src"
mkdir -p "$AGENT_HUB_HOME/harness/.claude-plugin"
printf '{"name":"devsosin-harness","plugins":[{"name":"harness"}]}\n' > "$AGENT_HUB_HOME/harness/.claude-plugin/marketplace.json"
printf 'PROJECT_NAME=p1\nHARNESS_DIR=%s\n' "$AGENT_HUB_HOME/harness" > "$(env_file p1)"
printf 'PROJECT_NAME=p2\nHARNESS_DIR=%s\n' "$AGENT_HUB_HOME/harness" > "$(env_file p2)"
sf="$(settings_file p1)"
ensure_settings p1
check "default settings: harness on" true "$(jq '.enabledPlugins["harness@devsosin-harness"]' "$sf")"
check "default settings: harness marketplace at /opt/harness" /opt/harness "$(jq -r '.extraKnownMarketplaces["devsosin-harness"].source.path' "$sf")"
ino="$(stat -f %i "$sf")"
plugin_add p1 ponytail@pony-mkt --env PONYTAIL_DEFAULT_MODE=full --env X=a=b >/dev/null
check "add enables the plugin" true "$(jq '.enabledPlugins["ponytail@pony-mkt"]' "$sf")"
check "add registers its directory marketplace" /opt/plugins/pony-mkt "$(jq -r '.extraKnownMarketplaces["pony-mkt"].source.path' "$sf")"
check "add sets env options" full "$(jq -r '.env.PONYTAIL_DEFAULT_MODE' "$sf")"
check "env value keeps '='" a=b "$(jq -r '.env.X' "$sf")"
check "settings rewritten in place (bind mount keeps the inode)" "$ino" "$(stat -f %i "$sf")"
check "other project unaffected" null "$(ensure_settings p2; jq '.enabledPlugins["ponytail@pony-mkt"]' "$(settings_file p2)")"
check "ls shows plugins and env" 1 "$(plugin_ls p1 | grep -c 'ponytail@pony-mkt.*PONYTAIL_DEFAULT_MODE=full')"
plugin_add p1 ponytail@pony-mkt --env X= >/dev/null
check "KEY= removes an env option" null "$(jq '.env.X' "$sf")"
check "unknown plugin refused" "no plugin" "$( (plugin_add p1 nope@pony-mkt) 2>&1 | grep -o 'no plugin' || true)"
check "unknown marketplace refused" "no plugin" "$( (plugin_add p1 x@missing) 2>&1 | grep -o 'no plugin' || true)"
check "bad --env refused" "KEY=VALUE" "$( (plugin_add p1 ponytail@pony-mkt --env 1X=y) 2>&1 | grep -o 'KEY=VALUE' || true)"
plugin_rm p1 ponytail@pony-mkt >/dev/null
check "rm disables the plugin" null "$(jq '.enabledPlugins["ponytail@pony-mkt"]' "$sf")"
check "rm drops the unused marketplace" null "$(jq '.extraKnownMarketplaces["pony-mkt"]' "$sf")"
plugin_rm p1 harness@devsosin-harness >/dev/null
check "harness can be turned off, marketplace stays" "null /opt/harness" "$(jq -r '"\(.enabledPlugins["harness@devsosin-harness"]) \(.extraKnownMarketplaces["devsosin-harness"].source.path)"' "$sf")"
check "rm of a plugin that is off refused" "is not on" "$( (plugin_rm p1 harness@devsosin-harness) 2>&1 | grep -o 'is not on' || true)"
rm -f "$(env_file p1)" "$(env_file p2)" "$sf" "$(settings_file p2)"

# Tasks run in the checkout on a new branch from the default branch; --worktree opts into .worktrees/<id>.
r="$(mktemp -d)"; g() { git -C "$r" -c user.name=t -c user.email=t@t "$@"; }
git -C "$r" init -q -b main; g commit -q --allow-empty -m init
g switch -q -c agent/old; g commit -q --allow-empty -m old   # an earlier task's branch is still checked out
task_workdir "$r" c1 0
check "checkout task: workdir is the checkout" "$r" "$WORKDIR"
check "checkout task: new branch checked out" "agent/c1" "$(git -C "$r" rev-parse --abbrev-ref HEAD)"
check "checkout task: branches from the default branch" "main" "$BASE"
check "checkout task: starts at main, not the old task branch" "$(git -C "$r" rev-parse main)" "$(git -C "$r" rev-parse HEAD)"
check "checkout task: no .worktrees" no "$([ -e "$r/.worktrees" ] && echo yes || echo no)"
echo x > "$r/f.txt"
check "dirty checkout is refused" "uncommitted changes" "$( (task_workdir "$r" c2 0) 2>&1 | grep -o 'uncommitted changes' || true)"
check "refused task leaves the branch alone" "agent/c1" "$(git -C "$r" rev-parse --abbrev-ref HEAD)"
check "dirty checkout still allows --worktree" "$r/.worktrees/c3" "$(task_workdir "$r" c3 1 && echo "$WORKDIR")"
check "worktree task: own branch in the worktree" "agent/c3" "$(git -C "$r/.worktrees/c3" rev-parse --abbrev-ref HEAD)"
check ".worktrees is not a change in the checkout" "?? f.txt" "$(git -C "$r" status --porcelain)"
rm "$r/f.txt"
td="$AGENT_HUB_HOME/tasks/demo/c1"; mkdir -p "$td"; printf 'PROJECT=demo\nWORKDIR=%s\n' "$r" > "$td/meta"
check "second task in the same checkout is refused" "already working" "$( (running_tasks() { echo "$td"; }; task_workdir "$r" c4 0) 2>&1 | grep -o 'already working' || true)"
check "task in a subfolder of a running task's folder is refused" "already working" "$( (running_tasks() { echo "$td"; }; mkdir -p "$r/sub"; task_workdir "$r/sub" c5 0) 2>&1 | grep -o 'already working' || true)"
rmdir "$r/sub"
printf 'PROJECT=demo\nWORKDIR=%s\n' "$r/.worktrees/c3" > "$td/meta"
check "running --worktree task does not block the checkout" "agent/c6" "$( (running_tasks() { echo "$td"; }; task_workdir "$r" c6 0 && git -C "$r" rev-parse --abbrev-ref HEAD) 2>&1)"
git -C "$r" switch -q agent/c1

# diff shows the task branch even after the checkout moved on; close only switches back when clean.
printf 'PROJECT=demo\nWORKDIR=%s\nBRANCH=agent/c1\nBASE=main\n' "$r" > "$td/meta"; echo 0 > "$td/exit"
g commit -q --allow-empty -m "task work"
check "diff lists the task branch commits" 1 "$(cmd_diff c1 | grep -c 'task work')"
echo x > "$r/f.txt"
check "close keeps a dirty checkout on the branch" "agent/c1" "$(cmd_close c1 >/dev/null; git -C "$r" rev-parse --abbrev-ref HEAD)"
rm "$r/f.txt"; cmd_close c1 >/dev/null
check "close switches a clean checkout back to main" "main" "$(git -C "$r" rev-parse --abbrev-ref HEAD)"
check "close keeps the task branch" yes "$(git -C "$r" rev-parse -q --verify agent/c1 >/dev/null && echo yes || echo no)"
check "diff still shows the branch after close" 1 "$(cmd_diff c1 | grep -c 'task work')"
printf '%s\n' '{"type":"system","subtype":"init","session_id":"s-c1"}' > "$td/log.jsonl"
check "reply switches the checkout back to the task branch" "agent/c1" "$( (launch() { :; }; cmd_reply c1 more) >/dev/null; git -C "$r" rev-parse --abbrev-ref HEAD)"
rm -rf "$r" "$td"

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
