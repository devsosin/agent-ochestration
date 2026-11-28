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
w="$AGENT_HUB_HOME/tasks/demo/w1"; mkdir -p "$w"; printf 'PROJECT=demo\nACCOUNT=warn\n' > "$w/meta"
printf '{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"seven_day":{"utilization":0.79,"resetsAt":%s,"status":"allowed_warning"}}}}\n' "$future" > "$w/log.jsonl"
check "allowed_warning under USAGE_MAX passes" ok "$( (USAGE_MAX=0.95; usage_ok warn) >/dev/null 2>&1 && echo ok || echo blocked)"
sed -i '' 's/allowed_warning/rejected/' "$w/log.jsonl"
check "rejected blocks under USAGE_MAX" blocked "$( (USAGE_MAX=0.95; usage_ok warn) >/dev/null 2>&1 && echo ok || echo blocked)"
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
check "hub may list and update reference repos" yes "$(jq -e '.permissions.allow | index("Bash(proj ref ls*)") and index("Bash(proj ref update*)")' "$s" >/dev/null && echo yes || echo no)"
check "hub may not mount reference repos unasked" no "$(jq -e '.permissions.allow | index("Bash(proj ref add*)")' "$s" >/dev/null && echo yes || echo no)"
check "hub may check and update knowledge" yes "$(jq -e '.permissions.allow | index("Bash(proj knowledge status*)") and index("Bash(proj knowledge update*)")' "$s" >/dev/null && echo yes || echo no)"
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
check "reply without the session file is refused with --from hint" "--from c1" "$( (launch() { :; }; cmd_reply c1 more) 2>&1 | grep -o -- '--from c1' || true)"
mkdir -p "$AGENT_HUB_HOME/sessions/demo/-x"; : > "$AGENT_HUB_HOME/sessions/demo/-x/s-c1.jsonl"
check "reply switches the checkout back to the task branch" "agent/c1" "$( (launch() { :; }; cmd_reply c1 more) >/dev/null; git -C "$r" rev-parse --abbrev-ref HEAD)"
git -C "$r" switch -q main
check "--from a task: new branch cut from its branch" "$(git -C "$r" rev-parse agent/c1)" "$(task_workdir "$r" c7 0 agent/c1 && echo "$BASE" >/dev/null && git -C "$r" rev-parse HEAD)"
check "--from a task: own new branch" "agent/c7" "$(git -C "$r" rev-parse --abbrev-ref HEAD)"
check "--from a task: old branch untouched" "$(git -C "$r" rev-parse main)" "$(git -C "$r" rev-parse agent/c1~1)"
check "--from an unknown branch is refused" "no branch" "$( (task_workdir "$r" c8 0 agent/nope) 2>&1 | grep -o 'no branch' || true)"
rm -rf "$r" "$td" "$AGENT_HUB_HOME/sessions/demo/-x"

# transcript.md is built from Claude Code's session files ($HUB/sessions/<project>/, bind-mounted .claude/projects).
td="$AGENT_HUB_HOME/tasks/demo/tr1"; mkdir -p "$td"; printf 'PROJECT=demo\n' > "$td/meta"
printf '%s\n' '{"type":"system","subtype":"init","session_id":"S1"}' '{"type":"system","subtype":"init","session_id":"S1"}' > "$td/log.jsonl"
sd="$AGENT_HUB_HOME/sessions/demo/-Users-x-demo"; mkdir -p "$sd/S1/subagents"
cat > "$sd/S1.jsonl" <<'EOF'
{"type":"api-request","sessionId":"S1","timestamp":"2026-11-19T01:00:00.000Z","params":"SECRET-REQUEST"}
{"type":"user","sessionId":"S1","uuid":"u1","timestamp":"2026-11-19T01:00:01.123Z","isSidechain":false,"message":{"role":"user","content":"fix the bug"}}
{"type":"assistant","sessionId":"S1","uuid":"a1","timestamp":"2026-11-19T01:00:05.000Z","isSidechain":false,"message":{"content":[{"type":"thinking","thinking":"hidden thoughts"},{"type":"text","text":"Looking. key sk-ant-oat01-AbC_123-xyz"},{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"env\nls"}}]}}
{"type":"user","sessionId":"S1","uuid":"u2","timestamp":"2026-11-19T01:00:06.000Z","isSidechain":false,"message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":"PATH=/bin\nGH_TOKEN=ghp_abcdef123456\nHOME=/home/node\nFOO=1"}]}}
{"type":"assistant","sessionId":"S1","uuid":"a2","timestamp":"2026-11-19T01:00:07.000Z","isSidechain":false,"message":{"content":[{"type":"tool_use","id":"tu2","name":"Agent","input":{"subagent_type":"Explore","description":"find callers","prompt":"find callers of foo"}}]}}
{"type":"user","sessionId":"S1","uuid":"u3","timestamp":"2026-11-19T01:00:20.000Z","isSidechain":false,"toolUseResult":{"agentId":"ag1","status":"completed"},"message":{"content":[{"type":"tool_result","tool_use_id":"tu2","content":[{"type":"text","text":"foo is called in bar.rs"}]}]}}
{"type":"user","sessionId":"S1","uuid":"u4","timestamp":"2026-11-19T02:00:00.000Z","isSidechain":false,"message":{"role":"user","content":"now add a test, token github_pat_11AAbb_cc"}}
EOF
cat > "$sd/S1/subagents/agent-ag1.jsonl" <<'EOF'
{"type":"user","sessionId":"S1","agentId":"ag1","uuid":"s1","timestamp":"2026-11-19T01:00:08.000Z","isSidechain":true,"message":{"role":"user","content":"find callers of foo"}}
{"type":"assistant","sessionId":"S1","agentId":"ag1","uuid":"s2","timestamp":"2026-11-19T01:00:09.000Z","isSidechain":true,"message":{"content":[{"type":"tool_use","id":"tu3","name":"Grep","input":{"pattern":"foo("}}]}}
{"type":"assistant","sessionId":"S1","agentId":"ag1","uuid":"s3","timestamp":"2026-11-19T01:00:10.000Z","isSidechain":true,"message":{"content":[{"type":"text","text":"foo is called in bar.rs"}]}}
EOF
printf '%s\n' '{"type":"user","sessionId":"OTHER","uuid":"o1","timestamp":"2026-11-19T01:00:02.000Z","message":{"content":"another task"}}' > "$sd/OTHER.jsonl"
t="$(TZ=Asia/Seoul transcript_md "$td")"
check "transcript: prompt with local date and time" 1 "$(printf '%s\n' "$t" | grep -c '2026-11-19 10:00:01 · user')"
check "transcript: main agent text" 1 "$(printf '%s\n' "$t" | grep -c '^Looking')"
check "transcript: tool call on one line" 1 "$(printf '%s\n' "$t" | grep -c '→ Bash: env ls')"
check "transcript: subagent named by type and description" 3 "$(printf '%s\n' "$t" | grep -c '· subagent Explore (find callers)')"
check "transcript: subagent tool call" 1 "$(printf '%s\n' "$t" | grep -c '→ Grep: foo(')"
check "transcript: ordered by time" "fix the bug|Looking|find callers of foo|now add a test" \
  "$(printf '%s\n' "$t" | grep -oE '^(fix the bug|Looking|find callers of foo|now add a test)' | paste -sd '|' -)"
check "transcript: tool result marked as tool" 1 "$(printf '%s\n' "$t" | grep -c "10:00:20 · tool")"
check "transcript: short tool result kept" 1 "$(printf '%s\n' "$t" | grep -c "← foo is called in bar.rs")"
check "transcript: long tool result (env dump) dropped" 0 "$(printf '%s\n' "$t" | grep -c 'HOME=/home/node')"
check "transcript: tokens redacted" 0 "$(printf '%s\n' "$t" | grep -cE 'sk-ant-oat|ghp_abc|github_pat_11')"
check "transcript: redaction marker" 2 "$(printf '%s\n' "$t" | grep -c '\[REDACTED\]')"
check "transcript: no thinking, api requests, or other sessions" 0 "$(printf '%s\n' "$t" | grep -cE 'hidden thoughts|SECRET-REQUEST|another task')"
check "transcript: proj transcript writes the file" yes "$(cmd_transcript tr1 >/dev/null && [ -s "$td/transcript.md" ] && echo yes || echo no)"
echo 0 > "$td/exit"; touch -t 202001010000 "$td/transcript.md"
transcript_fresh "$td"
check "transcript: regenerated when the task finished after it" yes "$([ "$td/exit" -nt "$td/transcript.md" ] && echo no || echo yes)"
check "transcript: missing sessions is an error" "no session records" "$( (rm -rf "$AGENT_HUB_HOME/sessions"; cmd_transcript tr1) 2>&1 | grep -o 'no session records' || true)"
rm -f "$td/transcript.md"; transcript_fresh "$td"
check "transcript: stub when there is nothing to read" 1 "$(grep -c 'No session records found' "$td/transcript.md")"
rm -rf "$td"

# proj hub use: only to an account whose host Claude config is logged in; writes HUB_ACCOUNT.
hh="$(mktemp -d)"; mkdir -p "$hh/.claude-ready"; echo '{"oauthAccount":{}}' > "$hh/.claude-ready/.claude.json"
check "hub use refuses an account that is not logged in" "not set up" "$( (HOME="$hh"; launchctl() { return 1; }; cmd_hub use nope) 2>&1 | grep -o 'not set up' || true)"
( HOME="$hh"; launchctl() { return 1; }; cmd_hub use ready ) >/dev/null
check "hub use writes HUB_ACCOUNT" "HUB_ACCOUNT=ready" "$(grep '^HUB_ACCOUNT=' "$AGENT_HUB_HOME/config")"
( HOME="$hh"; launchctl() { return 1; }; cmd_hub use ready ) >/dev/null
check "hub use keeps one HUB_ACCOUNT line" 1 "$(grep -c '^HUB_ACCOUNT=' "$AGENT_HUB_HOME/config")"
rm -rf "$hh"

# Settings profiles: common + team rules go into the project's managed settings; plugins and env stay.
printf 'PROJECT_NAME=prof\nPROJECT_DIR=/w/prof\n' > "$(env_file prof)"
ensure_settings prof
s="$(settings_file prof)"
check "profile: dev by default" dev "$(project_profile prof)"
check "profile: common env deny" yes "$(jq -e '.permissions.deny | index("Read(//**/.env)")' "$s" >/dev/null && echo yes || echo no)"
check "profile: guard hook" yes "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$s" | grep -q hooks/guard && echo yes || echo no)"
check "profile: work log hook" yes "$(jq -r '.hooks.Stop[0].hooks[0].command' "$s" | grep -q hooks/worklog && echo yes || echo no)"
check "profile: dev does not deny push" no "$(jq -e '.permissions.deny | index("Bash(git push*)")' "$s" >/dev/null && echo yes || echo no)"
check "profile: dev has the Rust stop check" yes "$(jq -r '.hooks.Stop[].hooks[].command' "$s" | grep -q 'rust-check stop' && echo yes || echo no)"
check "profile: dev has the Rust edit check" yes "$(jq -r '.hooks.PostToolUse[].hooks[].command' "$s" | grep -q 'rust-check edit' && echo yes || echo no)"
check "profile: harness plugin kept" true "$(jq -r '.enabledPlugins["harness@devsosin-harness"]' "$s")"
write_settings prof '.env.FOO = "1"'
cmd_profile prof marketing >/dev/null
check "profile: switched" marketing "$(project_var prof PROFILE)"
check "profile: marketing denies push" yes "$(jq -e '.permissions.deny | index("Bash(git push*)")' "$s" >/dev/null && echo yes || echo no)"
check "profile: marketing has no Rust checks" no "$(jq -r '[.hooks[][].hooks[].command] | join(" ")' "$s" | grep -q rust-check && echo yes || echo no)"
check "profile: common deny kept" yes "$(jq -e '.permissions.deny | index("Read(//**/.env)")' "$s" >/dev/null && echo yes || echo no)"
check "profile: env kept on switch" 1 "$(jq -r .env.FOO "$s")"
check "profile: hooks not doubled" 1 "$(jq '.hooks.PreToolUse | length' "$s")"
check "profile: unknown profile refused" "unknown profile" "$( (cmd_profile prof sales) 2>&1 | grep -o 'unknown profile' || true)"
check "profile: show" "prof: marketing" "$(cmd_profile prof)"
check "profile: name in env for the work log" marketing "$(jq -r .env.AGENT_HUB_PROFILE "$s")"
check "profile: project dir in env for the guard" /w/prof "$(jq -r .env.AGENT_HUB_PROJECT_DIR "$s")"
check "profile: not listed as a plugin option" "prof: harness@devsosin-harness  env: FOO=1" "$(plugin_ls prof)"

# Reference repos (proj ref): host clones mounted read-only, only in the projects that list them.
check "ref name from owner/repo" api "$(ref_name devsosin/api)"
check "ref name from https URL" api "$(ref_name https://github.com/devsosin/api.git)"
check "ref name from ssh URL" api "$(ref_name git@github.com:devsosin/api.git)"
check "ref name refs is refused" no "$(ref_name devsosin/refs >/dev/null && echo yes || echo no)"
REFS_DIR="$(mktemp -d)/refs"; o="$(mktemp -d)"
git init -q --bare -b main "$o/api.git"; git clone -q "$o/api.git" "$o/w" 2>/dev/null
git -C "$o/w" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one; git -C "$o/w" push -q origin HEAD:main
printf 'PROJECT_NAME=refp\nPROJECT_DIR=/w/refp\n' > "$(env_file refp)"
printf 'PROJECT_NAME=refq\nPROJECT_DIR=/w/refq\n' > "$(env_file refq)"
eval "$(declare -f dc | sed '1s/^dc /dc_real /')"   # kept for the knowledge checks below
dc() { refs_override "$1" >/dev/null; }   # no Docker here: only the override file
check "no refs: no override file" "" "$(refs_override refp)"
cmd_ref add refp "file://$o/api.git" >/dev/null 2>&1
check "ref add clones into REFS_DIR" yes "$([ -d "$REFS_DIR/api/.git" ] && echo yes || echo no)"
check "ref add lists it" api "$(project_var refp REFS)"
f="$(refs_override refp)"
check "override mounts read-only at /refs" 1 "$(grep -c "source: \"$REFS_DIR/api\", target: /refs/api, read_only: true" "$f")"
check "other project gets no mount" "" "$(refs_override refq)"
cmd_ref add refp "file://$o/api.git" >/dev/null 2>&1
check "ref add twice keeps one entry" api "$(project_var refp REFS)"
cmd_ref add refq "file://$o/api.git" >/dev/null 2>&1
check "second project reuses the clone" "refp refq" "$(ref_ls | awk '$1 == "api" {print $4, $5}')"
check "same name from another owner refused" "is a clone of" "$( (cmd_ref add refq other/api) 2>&1 | grep -o 'is a clone of' || true)"
check "bare name refused for add" "owner/repo or a URL" "$( (cmd_ref add refq api) 2>&1 | grep -o 'owner/repo or a URL' || true)"
git -C "$o/w" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two; git -C "$o/w" push -q origin HEAD:main
refresh_refs refp
check "refresh pulls the new commit" "$(git -C "$o/w" rev-parse HEAD)" "$(git -C "$REFS_DIR/api" rev-parse HEAD)"
git -C "$REFS_DIR/api" remote set-url origin "file://$o/gone.git"
check "failed pull warns and does not stop" "0 could not update" "$(refresh_refs refp 2>&1 >/dev/null | grep -o 'could not update' | sed 's/^/0 /')"
check "ref update reports failure" 1 "$(ref_update >/dev/null 2>&1; echo $?)"
check "ref add refused while a task runs" "running tasks" "$( (running_tasks() { echo t; }; cmd_ref add refp "file://$o/api.git") 2>&1 | grep -o 'running tasks' || true)"
mv "$REFS_DIR/api" "$REFS_DIR/api.moved"
check "missing clone is skipped with a warning" "missing" "$(refs_override refp 2>&1 >/dev/null | grep -o missing)"
check "missing clone leaves no override" "" "$(refs_override refp 2>/dev/null)"
mv "$REFS_DIR/api.moved" "$REFS_DIR/api"
cmd_ref rm refp api >/dev/null
check "ref rm drops it from the list" "" "$(project_var refp REFS)"
check "ref rm removes the override" no "$([ -f "$(refs_file refp)" ] && echo yes || echo no)"
check "ref rm keeps the clone" yes "$([ -d "$REFS_DIR/api/.git" ] && echo yes || echo no)"
check "ref rm of an unmounted ref refused" "not mounted" "$( (cmd_ref rm refp api) 2>&1 | grep -o 'not mounted' || true)"
check "project name refs is reserved" reserved "$( (cmd_new Refs) 2>&1 | grep -o reserved || true)"
eval "$(declare -f dc_real | sed '1s/^dc_real /dc /')"; rm -rf "$o" "$(dirname "$REFS_DIR")"

check "task refuses an unknown option" "unknown option: --here" "$( (cmd_task demo --here hi) 2>&1 | grep -o 'unknown option: --here' || true)"

# Images by code: Cargo.toml → rust, package.json → web, both → rust-web; switching only adds.
w="$(mktemp -d)"; mkdir -p "$w/api" "$w/fe"
check "image: nothing → base" agent-hub:base "$(image_for "$w")"
touch "$w/fe/package.json"
check "image: package.json → web" agent-hub:web "$(image_for "$w")"
touch "$w/api/Cargo.toml"
check "image: both → rust-web" agent-hub:rust-web "$(image_for "$w")"
check "image: rust only" agent-hub:rust "$(image_for "$w/api")"
check "union: rust + web repo" agent-hub:rust-web "$(image_union agent-hub:rust agent-hub:web)"
check "union: never drops a part" agent-hub:rust "$(image_union agent-hub:rust agent-hub:base)"
check "union: user image kept" my/img:1 "$(image_union my/img:1 agent-hub:rust)"
rm -rf "$w"

# rust-analyzer LSP plugin follows the image, when its marketplace is on the host.
printf 'PROJECT_NAME=lsp\nPROJECT_DIR=/w/lsp\nIMAGE=agent-hub:rust\n' > "$(env_file lsp)"
check "lsp: no marketplace, only a note" "proj plugin source add anthropics/claude-plugins-official" "$(sync_lsp lsp | grep -o 'proj plugin source add anthropics/claude-plugins-official')"
mkdir -p "$PLUGINS_DIR/claude-plugins-official/.claude-plugin"
echo '{"name":"claude-plugins-official","plugins":[{"name":"rust-analyzer-lsp"}]}' > "$PLUGINS_DIR/claude-plugins-official/.claude-plugin/marketplace.json"
sync_lsp lsp >/dev/null
check "lsp: on for rust" true "$(jq -r '.enabledPlugins["rust-analyzer-lsp@claude-plugins-official"]' "$(settings_file lsp)")"
check "lsp: marketplace mounted" /opt/plugins/claude-plugins-official "$(jq -r '.extraKnownMarketplaces["claude-plugins-official"].source.path' "$(settings_file lsp)")"
check "lsp: second sync changes nothing" "" "$(sync_lsp lsp)"
set_var lsp IMAGE agent-hub:web; sync_lsp lsp
check "lsp: off without rust" null "$(jq -r '.enabledPlugins["rust-analyzer-lsp@claude-plugins-official"]' "$(settings_file lsp)")"
check "lsp: harness stays on" true "$(jq -r '.enabledPlugins["harness@devsosin-harness"]' "$(settings_file lsp)")"
rm -rf "$PLUGINS_DIR/claude-plugins-official"

# knowledge MCP (proj knowledge): per-project tokens, the server's config, network joins. docker is stubbed.
dlog="$AGENT_HUB_HOME/docker.log"; : > "$dlog"; krun=no
docker() { echo "$*" >> "$dlog"; case "$1" in image) return 1 ;; inspect) [ "$krun" = yes ] && [ "${3:-}" = '{{.State.Running}}' ] && echo true; return 0 ;; esac; return 0; }
check "knowledge: needs KNOWLEDGE_REPO" "KNOWLEDGE_REPO" "$( (KNOWLEDGE_REPO=; knowledge_src) 2>&1 | grep -o 'KNOWLEDGE_REPO' | head -1)"
KNOWLEDGE_REPO=o/knowledge
printf 'PROJECT_NAME=kp\nPROJECT_DIR=/w/kp\n' > "$(env_file kp)"
printf 'PROJECT_NAME=kq\nPROJECT_DIR=/w/kq\n' > "$(env_file kq)"
kcfg="$KNOWLEDGE_DIR/mcp.config.json"
knowledge_set kp on >/dev/null
tok="$(cat "$(knowledge_token_file kp)")"
check "knowledge on: 48 hex token" yes "$(printf '%s' "$tok" | grep -qE '^[0-9a-f]{48}$' && echo yes || echo no)"
check "knowledge on: token file is 600" "-rw-------" "$(ls -l "$(knowledge_token_file kp)" | cut -c1-10)"
check "knowledge on: config readable by the server (hashes only)" "-rw-r--r--" "$(ls -l "$kcfg" | cut -c1-10)"
check "knowledge on: internal by default" internal "$(project_var kp KNOWLEDGE)"
check "config: client in server format" "kp internal false ops" "$(jq -r '.clients[0] | "\(.name) \(.maxSensitivity) \(.propose) \(.spaces[0])"' "$kcfg")"
check "config: sha256 of the project token" "$(printf '%s' "$tok" | shasum -a 256 | cut -d' ' -f1)" "$(jq -r '.clients[0].tokenSha256' "$kcfg")"
check "config: no plain token" null "$(jq -r '.clients[0].token' "$kcfg")"
check "config: token not in the file" 0 "$(grep -c "$tok" "$kcfg" || true)"
check "config: proposal section always there" "o/knowledge KNOWLEDGE_GITHUB_TOKEN 5" "$(jq -r '.proposal | "\(.repo) \(.tokenEnv) \(.maxPerHour)"' "$kcfg")"
check "config: listens inside the container" "0.0.0.0 8787" "$(jq -r '"\(.bind) \(.port)"' "$kcfg")"
check "config: project without knowledge left out" 1 "$(jq '.clients | length' "$kcfg")"
knowledge_set kp on --max confidential --propose >/dev/null
check "on again: confidential and propose" "confidential true" "$(jq -r '.clients[0] | "\(.maxSensitivity) \(.propose)"' "$kcfg")"
check "on again: token kept" "$tok" "$(cat "$(knowledge_token_file kp)")"
check "bad --max refused" "internal or confidential" "$( (knowledge_set kp on --max secret) 2>&1 | grep -o 'internal or confidential')"
knowledge_set kp rotate >/dev/null
check "rotate: new token" no "$([ "$(cat "$(knowledge_token_file kp)")" = "$tok" ] && echo yes || echo no)"
check "rotate: config follows" "$(token_sha256 "$(knowledge_token_file kp)")" "$(jq -r '.clients[0].tokenSha256' "$kcfg")"
check "rotate refused while off" "knowledge is off" "$( (knowledge_set kq rotate) 2>&1 | grep -o 'knowledge is off')"
check "refused while a task runs" "running tasks" "$( (running_tasks() { echo t; }; knowledge_set kp off) 2>&1 | grep -o 'running tasks')"
knowledge_set kq on >/dev/null
check "two projects, two clients" "kp kq" "$(jq -r '[.clients[].name] | sort | join(" ")' "$kcfg")"
check "tokens differ per project" no "$([ "$(cat "$(knowledge_token_file kp)")" = "$(cat "$(knowledge_token_file kq)")" ] && echo yes || echo no)"
krun=yes; : > "$dlog"
knowledge_attach kp
check "attach: joins the project network" 1 "$(grep -c '^network connect proj-kp_default knowledge-mcp$' "$dlog")"
knowledge_set kq off >/dev/null
check "off: token revoked" "" "$(cat "$(knowledge_token_file kq)")"
check "off: out of the config" "kp" "$(jq -r '[.clients[].name] | join(" ")' "$kcfg")"
check "off: server restarted for the new config" 1 "$(grep -c '^restart knowledge-mcp$' "$dlog")"
check "off: leaves the project network" 1 "$(grep -c '^network disconnect proj-kq_default knowledge-mcp$' "$dlog")"
: > "$dlog"; ensure_settings kp
dc kp up -d >/dev/null
check "dc up joins the server again" 1 "$(grep -c '^network connect proj-kp_default knowledge-mcp$' "$dlog")"
: > "$dlog"; dc kp down >/dev/null
check "dc down detaches the server first" "network disconnect proj-kp_default knowledge-mcp" "$(grep -v '^inspect' "$dlog" | head -1)"
printf 'PROJECT_NAME=kn\nPROJECT_DIR=/w/kn\n' > "$(env_file kn)"; ensure_settings kn
dc kn up -d >/dev/null
check "dc makes an empty secret for projects without knowledge" "-rw------- 0" "$(ls -l "$(knowledge_token_file kn)" | awk '{print substr($1, 1, 10), $5}')"
check "no knowledge: server not joined" 0 "$(grep -c '^network connect proj-kn_default' "$dlog" || true)"
unset -f docker; KNOWLEDGE_REPO=

# Host pulls of GitHub repos use the host's gh login (no `gh auth setup-git` needed).
if command -v gh >/dev/null 2>&1; then
  check "host git: gh credential helper for github.com" "!$(command -v gh) auth git-credential" "$(host_git config --get credential.https://github.com.helper)"
fi

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
