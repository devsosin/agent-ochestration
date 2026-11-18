# proj 명령

`bin/proj` — 맥미니 호스트에서 실행한다. PATH에 `~/workspace/mac-agent/bin`을 추가해 두면 `proj`로 쓴다.

## 명령

| 명령 | 하는 일 |
|---|---|
| `proj build` | 이미지 `agent-hub:base`, `agent-hub:rust` 빌드 (Claude Code 업데이트도 이것으로) |
| `proj account add <alias>` / `ls` | 계정 토큰 저장 / 목록 ([accounts.md](accounts.md)) |
| `proj new <name> [--repo URL] [--account A] [--image agent-hub:rust] [--mem 6g]` | `~/workspace/<name>`을 clone·새로 만들기·기존 폴더 등록 후 컨테이너 시작 |
| `proj ls` | 프로젝트, 계정, 컨테이너 상태, 실행 중 작업 수 |
| `proj up` / `down` / `shell <name>` | 시작 / 중지(컨테이너 삭제, 볼륨 유지) / 컨테이너 셸 |
| `proj rm <name>` | 컨테이너와 Claude 설정 볼륨 삭제. 프로젝트 폴더·작업 기록은 남김 |
| `proj task <name> [--here] <지시…\|->` | 새 worktree에서 `claude -p` 백그라운드 실행. `-`는 표준입력에서 지시를 읽음 |
| `proj reply <task> <지시…\|->` | 같은 세션을 이어서 실행 (`--resume`) |
| `proj status [task\|name]` | 작업 목록 또는 한 작업의 상태·비용·결과 보고 |
| `proj logs <task> [-f]` | Claude의 메시지와 도구 호출 요약 (`-f` 실시간) |
| `proj diff <task>` | 커밋 안 된 변경, base 이후 커밋, diffstat, VS Code로 여는 경로 |
| `proj close <task>` | worktree 삭제(브랜치 유지). 커밋 안 된 변경이 있으면 거부 |

## 작업 흐름

1. `proj task app "로그인 API에 rate limit 추가"` → 작업 ID(예: `261118-130303`)
   - 커밋이 있는 저장소: `.worktrees/<id>`에 브랜치 `agent/<id>`를 만들고 거기서 실행. 커밋까지 하고 push·PR은 지시할 때만.
   - `--here` 또는 커밋이 없는 저장소: 프로젝트 폴더에서 바로 실행하고 커밋하지 않음.
2. `proj status` / `proj logs <id> -f`로 진행 확인.
3. `proj diff <id>` → VS Code로 worktree를 열어 diff 확인.
4. 고칠 점은 `proj reply <id> "…"`. 끝나면 PR은 `proj reply <id> "harness github-pr로 PR 올려줘"`, 정리는 `proj close <id>`.

## 상태

| 상태 | 뜻 |
|---|---|
| `running` | 컨테이너 안에서 실행 중 |
| `done` | 정상 종료 |
| `failed` | 오류 종료. `proj status <id>`의 결과와 stderr 확인 (`Not logged in`이면 토큰 문제) |
| `lost` | 종료 기록 없이 끝남 (컨테이너 재시작 등). `proj reply`로 이어서 실행 |

## 설정과 파일

| 항목 | 기본값 | 바꾸는 곳 |
|---|---|---|
| `WORKSPACE_ROOT` | `~/workspace` | `~/.agent-hub/config` 또는 환경변수 |
| `HARNESS_DIR` | `$WORKSPACE_ROOT/harness` | 〃 |
| `DEFAULT_ACCOUNT` | 없음 | 〃 |
| `MAX_TASKS` | `2` (전체 동시 실행. 넘으면 거부) | 〃 |
| `AGENT_HUB_HOME` | `~/.agent-hub` | 환경변수 |

작업 기록: `~/.agent-hub/tasks/<name>/<id>/` — `prompt.txt`, `prompts.log`(지시 이력), `log.jsonl`, `stderr.log`, `meta`, `pid`, `exit`.

## 알려진 한계

- 상한을 넘으면 대기하지 않고 거부한다 (대기열은 3단계).
- 컨테이너의 네트워크 송신은 제한하지 않는다.
- 작업은 `bypassPermissions`로 실행된다. 컨테이너에 넣은 토큰 범위 안에서는 확인 없이 무엇이든 할 수 있다.
