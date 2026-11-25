#!/bin/bash
# Agent hooks (image/hooks) fed fake Claude Code hook input. Runs under macOS /bin/bash 3.2.
set -euo pipefail
H="$(cd "$(dirname "$0")/../image/hooks" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi; }
# verdict <tool> <field> <value> [cwd]: allow | deny (guard exits 2 to block)
verdict() {
  jq -nc --arg t "$1" --arg f "$2" --arg v "$3" --arg c "${4:-$T}" '{tool_name: $t, tool_input: {($f): $v}, cwd: $c}' \
    | "$H/guard" >/dev/null 2>&1 && echo allow || echo deny
}

# .env files: only .env.example
check "cat .env"                deny  "$(verdict Bash command 'cat .env')"
check "cat ./app/.env.local"    deny  "$(verdict Bash command 'cat ./app/.env.local')"
check "source .env"             deny  "$(verdict Bash command 'set -a; . .env; set +a')"
check "grep in .env.production" deny  "$(verdict Bash command 'grep KEY "config/.env.production"')"
check "cat *.env"               deny  "$(verdict Bash command 'cat *.env')"
check "cat .envrc"              deny  "$(verdict Bash command 'cat .envrc')"
check "cat .env.example"        allow "$(verdict Bash command 'cat .env.example')"
check "cp .env.example"         allow "$(verdict Bash command 'cp .env.example .env.example.new')"
check "process.env in code"     allow "$(verdict Bash command 'node -e "console.log(process.env.HOME)"')"
check "env file in prose"       allow "$(verdict Bash command 'git commit -m "add dotenv loader"')"
check "Read .env"               deny  "$(verdict Read file_path /w/app/.env)"
check "Read .env.local"         deny  "$(verdict Read file_path /w/app/.env.local)"
check "Read .env.example"       allow "$(verdict Read file_path /w/app/.env.example)"
check "Edit .env"               deny  "$(verdict Edit file_path /w/.env)"
check "Write .env.example"      allow "$(verdict Write file_path /w/.env.example)"
check "Read config.env.ts"      allow "$(verdict Read file_path /w/src/config.env.ts)"
check "Grep in .env"            deny  "$(verdict Grep path /w/.env)"

# Merge gate: PRs and branch pushes are fine, merging and pushing the default branch need AGENT_HUB_ALLOW_MERGE=1.
r="$T/repo"; git init -q -b main "$r"; git -C "$r" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
check "gh pr create"            allow "$(verdict Bash command 'gh pr create --fill')"
check "gh issue create"         allow "$(verdict Bash command 'gh issue create -t x -b y')"
check "push agent branch"       allow "$(verdict Bash command 'git push -u origin agent/251125-1')"
check "gh pr merge"             deny  "$(verdict Bash command 'gh pr merge 3 --squash')"
check "merge via gh api"        deny  "$(verdict Bash command 'gh api -X PUT repos/o/r/pulls/3/merge')"
check "push main"               deny  "$(verdict Bash command 'git push origin main')"
check "push HEAD:main"          deny  "$(verdict Bash command 'cd x && git push origin HEAD:refs/heads/main')"
check "push --all"              deny  "$(verdict Bash command 'git push --all origin')"
check "bare push on main"       deny  "$(verdict Bash command 'git push' "$r")"
git -C "$r" switch -q -c agent/x
check "bare push on a branch"   allow "$(verdict Bash command 'git push' "$r")"
check "local merge of main"     allow "$(verdict Bash command 'git merge main')"
export AGENT_HUB_ALLOW_MERGE=1
check "merge task: gh pr merge" allow "$(verdict Bash command 'gh pr merge 3 --squash')"
check "merge task: still no .env" deny "$(verdict Bash command 'cat .env')"
unset AGENT_HUB_ALLOW_MERGE
# Folder boundary for file tools: the project dir, /tmp and Claude's own project memory only.
export AGENT_HUB_PROJECT_DIR=/w/proj   # not under /tmp, which is allowed
check "Write inside the project"   allow "$(verdict Write file_path /w/proj/docs/a.md)"
check "Write relative path"        allow "$(verdict Write file_path docs/a.md /w/proj)"
check "Write outside the project"  deny  "$(verdict Write file_path /var/agent-hub/tasks/x/meta)"
check "Edit via .. out of project" deny  "$(verdict Edit file_path /w/proj/../elsewhere/a.md)"
check "Write to /tmp"              allow "$(verdict Write file_path /tmp/scratch.txt)"
check "Write to Claude memory"     allow "$(CLAUDE_CONFIG_DIR=/home/node/.claude verdict Write file_path /home/node/.claude/projects/-w/memory/m.md)"
check "Read outside is fine"       allow "$(verdict Read file_path /etc/hosts)"
unset AGENT_HUB_PROJECT_DIR
check "no project dir: no boundary" allow "$(verdict Write file_path /var/agent-hub/tasks/x/meta)"

# Claude settings files stay with the user, also through the shell.
check "Write .claude/settings.local.json" deny "$(verdict Write file_path /w/.claude/settings.local.json)"
check "Edit .claude/settings.json"        deny "$(verdict Edit file_path /w/.claude/settings.json)"
check "shell write to settings"           deny "$(verdict Bash command 'echo {} > .claude/settings.local.json')"
check "sed -i on settings"                deny "$(verdict Bash command "sed -i 's/a/b/' .claude/settings.json")"
check "read settings"                     allow "$(verdict Bash command 'cat .claude/settings.json')"
check "Write other .claude files"         allow "$(verdict Write file_path /w/.claude/skills/x/SKILL.md)"

# No commits on the default branch (merge tasks excepted).
m="$T/onmain"; git init -q -b main "$m"; git -C "$m" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
check "commit on main"          deny  "$(verdict Bash command 'git commit -m x' "$m")"
check "commit on a branch"      allow "$(verdict Bash command 'git commit -m x' "$r")"
check "merge task commits main" allow "$(AGENT_HUB_ALLOW_MERGE=1 verdict Bash command 'git commit -m x' "$m")"
check "git merge on main"       deny  "$(verdict Bash command 'git merge chore/worklog' "$m")"
check "merge task merges main"  allow "$(AGENT_HUB_ALLOW_MERGE=1 verdict Bash command 'git merge agent/x' "$m")"
check "git merge-base on main"  allow "$(verdict Bash command 'git merge-base main HEAD' "$m")"

# Secrets in what is about to be committed; the message never shows the value.
fake="sk-ant-oat01-$(printf 'A%.0s' $(seq 1 40))"
echo "token=$fake" > "$r/leak.txt"
check "untracked secret, plain commit" allow "$(verdict Bash command 'git commit -m x' "$r")"
check "git add . && commit with secret" deny "$(verdict Bash command 'git add . && git commit -m x' "$r")"
git -C "$r" add leak.txt
check "staged secret"           deny  "$(verdict Bash command 'git commit -m x' "$r")"
msg="$(jq -nc --arg c "$r" '{tool_name: "Bash", tool_input: {command: "git commit -m x"}, cwd: $c}' | "$H/guard" 2>&1 >/dev/null || true)"
check "message names the file"  yes "$(printf '%s' "$msg" | grep -q leak.txt && echo yes || echo no)"
check "message hides the value" no  "$(printf '%s' "$msg" | grep -q "$fake" && echo yes || echo no)"
git -C "$r" rm -q --cached leak.txt; rm "$r/leak.txt"
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n' > "$r/id"; git -C "$r" add id
check "staged private key"      deny  "$(verdict Bash command 'git commit -m x' "$r")"
git -C "$r" rm -q --cached id; rm "$r/id"
check "clean commit"            allow "$(verdict Bash command 'git commit -m x' "$r")"

check "unparsable input passes" allow "$(echo 'not json' | "$H/guard" >/dev/null 2>&1 && echo allow || echo deny)"

# Work log: asks once for a line in log/YYYY-MM.md when files changed and the log did not.
stop() { jq -nc --arg c "$1" --argjson a "${2:-false}" '{cwd: $c, stop_hook_active: $a}' | "$H/worklog"; }
check "no changes: no request" "" "$(stop "$r")"
echo x > "$r/a.txt"
check "changed file: block" block "$(stop "$r" | jq -r .decision)"
check "request names the log file" yes "$(stop "$r" | jq -r .reason | grep -q "log/$(date +%Y-%m).md" && echo yes || echo no)"
check "dev header" yes "$(stop "$r" | jq -r .reason | grep -qxF '| 일시 | 이슈·PR | 작업내용 | 브랜치 |' && echo yes || echo no)"
check "header separator" yes "$(stop "$r" | jq -r .reason | grep -qxF '|---|---|---|---|' && echo yes || echo no)"
check "row has time and branch" yes "$(stop "$r" | jq -r .reason | grep -qE '^\| [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} \| .* \| agent/x \|$' && echo yes || echo no)"
check "marketing columns" yes "$(jq -nc --arg c "$r" '{cwd: $c}' | AGENT_HUB_PROFILE=marketing "$H/worklog" | jq -r .reason | grep -qxF '| 시각 | 에이전트 | 내용 | 참조 |' && echo yes || echo no)"
# Workspace (project dir is not a repo): one log at its root, with the repo folder as 대상.
w="$T/ws"; mkdir -p "$w"; git init -q -b main "$w/api"; echo x > "$w/api/b.txt"
ws="$(jq -nc --arg c "$w/api" '{cwd: $c}' | AGENT_HUB_PROJECT_DIR="$w" "$H/worklog" | jq -r .reason)"
check "workspace: log at the root" yes "$(printf '%s' "$ws" | grep -qF "in $w." && echo yes || echo no)"
check "workspace: 대상 column" yes "$(printf '%s' "$ws" | grep -qxF '| 일시 | 대상 | 이슈·PR | 작업내용 | 브랜치 |' && echo yes || echo no)"
check "workspace: repo folder as 대상" yes "$(printf '%s' "$ws" | grep -qE '^\| [0-9-]+ [0-9:]+ \| api \| ' && echo yes || echo no)"
check "single repo: no 대상 column" no "$(jq -nc --arg c "$r" '{cwd: $c}' | AGENT_HUB_PROJECT_DIR="$r" "$H/worklog" | jq -r .reason | grep -q '대상' && echo yes || echo no)"
check "second stop passes" "" "$(stop "$r" true)"
mkdir -p "$r/log"; sleep 1; echo "- line" >> "$r/log/$(date +%Y-%m).md"
check "log written after changes: no request" "" "$(stop "$r")"
mkdir -p "$r/target"; sleep 1; touch "$r/target/build.o"
check "build output ignored" "" "$(stop "$r")"
check "missing cwd passes" "" "$(stop "$T/nope")"

# SessionStart: the last rows of the newest log as context.
recent() { jq -nc --arg c "$1" '{cwd: $c}' | "$H/worklog" recent; }
printf '| 일시 | 이슈·PR | 작업내용 | 브랜치 |\n|---|---|---|---|\n' > "$r/log/$(date +%Y-%m).md"
for i in 1 2 3 4 5 6 7; do echo "| 2026-11-25 0$i:00 | - | row $i | agent/x |" >> "$r/log/$(date +%Y-%m).md"; done
check "recent: five rows" 5 "$(recent "$r" | grep -c '^| 2026')"
check "recent: newest last" yes "$(recent "$r" | tail -1 | grep -q 'row 7' && echo yes || echo no)"
check "recent: no header" 0 "$(recent "$r" | grep -c '작업내용')"
check "recent: no log, no output" "" "$(recent "$m")"

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
