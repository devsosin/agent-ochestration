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
check "unparsable input passes" allow "$(echo 'not json' | "$H/guard" >/dev/null 2>&1 && echo allow || echo deny)"

# Work log: asks once for a line in log/YYYY-MM.md when files changed and the log did not.
stop() { jq -nc --arg c "$1" --argjson a "${2:-false}" '{cwd: $c, stop_hook_active: $a}' | AGENT_HUB_TASK=t9 "$H/worklog"; }
check "no changes: no request" "" "$(stop "$r")"
echo x > "$r/a.txt"
check "changed file: block" block "$(stop "$r" | jq -r .decision)"
check "request names the log file" yes "$(stop "$r" | jq -r .reason | grep -q "log/$(date +%Y-%m).md" && echo yes || echo no)"
check "request carries task and branch" yes "$(stop "$r" | jq -r .reason | grep -q 't9 agent/x' && echo yes || echo no)"
check "second stop passes" "" "$(stop "$r" true)"
mkdir -p "$r/log"; sleep 1; echo "- line" >> "$r/log/$(date +%Y-%m).md"
check "log written after changes: no request" "" "$(stop "$r")"
mkdir -p "$r/target"; sleep 1; touch "$r/target/build.o"
check "build output ignored" "" "$(stop "$r")"
check "missing cwd passes" "" "$(stop "$T/nope")"

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
