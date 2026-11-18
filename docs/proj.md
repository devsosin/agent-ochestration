# proj 명령

`bin/proj` — 맥미니 호스트에서 실행한다. 저장소의 `bin`을 PATH에 추가해 두면 `proj`로 쓴다.

## 명령

| 명령 | 하는 일 |
|---|---|
| `proj build` | 이미지 `agent-hub:base`, `agent-hub:rust` 빌드 (Claude Code 업데이트도 이것으로) |
| `proj account add <alias>` / `ls` | 계정 토큰 저장 / 목록 ([accounts.md](accounts.md)) |
| `proj new <name> [--repo URL\|owner/name] [--alias 별칭] [--account A] [--image I] [--mem 6g]` | `$WORKSPACE_ROOT/<name>`을 clone(`owner/name`은 호스트 `gh`로, 비공개 포함)·새로 만들기(빈 초기 커밋)·기존 폴더 등록 후 컨테이너 시작. 이미지를 안 주면 `Cargo.toml`이 있을 때 rust |
| `proj new <name> --create [--public]` | 위와 같이 새로 만들고, 호스트 `gh`로 GitHub 저장소(기본 비공개)를 만들어 `origin`으로 push |
| `proj new <name> --workspace` | 여러 저장소를 담는 빈 워크스페이스 폴더 (루트는 git 저장소가 아님) |
| `proj add <ws> <folder> [--repo URL\|owner/name \| --create [--public]]` | 워크스페이스에 저장소 추가: clone 또는 새로 만들기(+GitHub). Rust 저장소면 이미지를 rust로 전환 |
| `proj image <name> <image>` | 이미지 바꾸고 컨테이너 재생성 (실행 중 작업이 있으면 거부) |
| `proj model <name> [model\|-]` | 그 프로젝트 작업에 쓸 모델 (`-`는 기본값). 다음 작업부터 적용, 재시작 없음 |
| `proj usage [--refresh]` | 계정별 5시간·7일 한도 사용률과 초기화 시각. `--refresh`는 계정마다 아주 짧은 요청(Haiku, 약 900토큰)을 보내 최신 값을 받음 |
| `proj idle [시간]` / `idle install [시간]` / `idle uninstall` | 작업·셸·활동이 없는 지 N시간(기본 3) 지난 컨테이너 중지. `install`은 30분마다 실행하도록 launchd 등록. 멈춘 컨테이너는 다음 작업이나 `proj up`에서 다시 켜짐 |
| `proj hub init` / `login` / `run` / `install` / `uninstall` / `status` | 메인 에이전트 관리 (아래 "메인 에이전트") |
| `proj imagegen install` / `uninstall` / `status` | 이미지 생성 MCP 서버를 launchd로 등록·해제·확인 (아래 "이미지 생성") |
| `proj alias <name> <별칭>` | 메인 에이전트가 알아듣는 이름 지정 (예: `스모크`). `proj new --alias`로도 지정 |
| `proj ls` | 프로젝트, 계정, 컨테이너 상태, 실행 중 작업 수, 별칭 |
| `proj up` / `down` / `shell <name>` | 시작 / 중지(컨테이너 삭제, 볼륨 유지) / 컨테이너 셸 |
| `proj rm <name> [--purge] [--yes]` | 컨테이너와 Claude 설정 볼륨 삭제, 폴더·작업 기록은 남김. `--purge`는 폴더·작업 기록까지 삭제하되 커밋 안 된 변경이나 원격에 없는 커밋이 있으면 거부. 확인은 터미널에서 직접 답하거나 `--yes` (파이프로 넣은 `y`는 거부) |
| `proj task <name> [--repo <folder>] [--here] <지시…\|->` | 새 worktree에서 `claude -p` 백그라운드 실행. 워크스페이스는 `--repo`로 저장소를 고르고, 없으면 루트에서 실행. `-`는 표준입력에서 지시를 읽음 |
| `proj reply <task> <지시…\|->` | 같은 세션을 이어서 실행 (`--resume`) |
| `proj status [task\|name]` | 작업 목록(삭제된 프로젝트 제외) 또는 한 작업의 상태·비용·결과 보고 |
| `proj wait <task> [초]` | 작업이 끝날 때까지 기다렸다가 `status` 출력 (기본 1800초, 넘으면 종료 코드 3). 메인 에이전트는 이것으로 기다림 |
| `proj logs <task> [-f]` | Claude의 메시지와 도구 호출 요약 (`-f` 실시간, 작업이 끝나면 멈춤) |
| `proj diff <task>` | 커밋 안 된 변경, base 이후 커밋, diffstat, VS Code로 여는 경로 |
| `proj close <task>` | worktree 삭제(브랜치 유지). 커밋 안 된 변경이 있으면 거부 |

## 프로젝트 종류

| 종류 | 만들기 | 작업 위치 | 동시 실행 |
|---|---|---|---|
| `repo` 저장소 하나 | `proj new <name> --repo …` / `--create` | `<repo>/.worktrees/<id>` (브랜치 `agent/<id>`) | 가능 |
| `ws` 워크스페이스 | `proj new <name> --workspace` + `proj add …` | `--repo <folder>`: `<ws>/<folder>/.worktrees/<id>` (루트·저장소 CLAUDE.md 모두 읽힘) | 가능 |
| | | `--repo` 없이: 워크스페이스 루트 (여러 저장소·루트 문서) | 같은 폴더에서 하나씩 |

`--here`나 워크스페이스 루트처럼 worktree 없이 폴더를 직접 고치는 작업은, 같은 폴더에서 이미 실행 중인 작업이 있으면 거부합니다. `proj rm --purge`는 워크스페이스의 각 저장소를 검사하고, 저장소 밖 루트 파일(CLAUDE.md, docs 등)이 있으면 거부합니다.

## 작업 흐름

1. `proj task app "로그인 API에 rate limit 추가"` → 작업 ID(예: `261118-130303`)
   - 커밋이 있는 저장소: `.worktrees/<id>`에 브랜치 `agent/<id>`를 만들고 거기서 실행. 커밋까지 하고 push·PR은 지시할 때만.
   - `--here` 또는 커밋이 없는 저장소: 프로젝트 폴더에서 바로 실행하고 커밋하지 않음.
2. `proj status` / `proj logs <id> -f`로 진행 확인.
3. `proj diff <id>` → VS Code로 worktree를 열어 diff 확인.
4. 고칠 점은 `proj reply <id> "…"`. 끝나면 PR은 `proj reply <id> "harness github-pr로 PR 올려줘"`, 정리는 `proj close <id>`.

## 메인 에이전트 (hub)

호스트에서 `claude remote-control`로 상시 대기하며, 폰·브라우저 채팅으로 받은 지시를 `proj`로 나눠 맡긴다. 운영 지침은 `hub/CLAUDE.md`, 권한은 `hub/settings.json`(proj·읽기 전용 git/gh만 허용, 계정 폴더 읽기와 docker 직접 실행 금지). `proj hub run`이 그 안의 `~/workspace`·`~/.agent-hub`를 설정한 경로로 바꿔 `~/.agent-hub/hub-settings.json`으로 넘긴다.

| 순서 | 명령 | 비고 |
|---|---|---|
| 1 | `~/.agent-hub/config`에 `HUB_ACCOUNT=sosin` | 정식 로그인할 계정 (없으면 `DEFAULT_ACCOUNT`) |
| 2 | `proj hub init` | `~/.agent-hub/hub/`에 `CLAUDE.md` 링크 |
| 3 | `proj hub login` | `~/.claude-<alias>`로 claude 실행 → 폴더 신뢰, `/login` |
| 4 | `proj hub run` | 처음 한 번은 터미널에서: Remote Control 활성화 확인에 `y` |
| 5 | `proj hub install` | launchd 등록 (로그인 시 시작, 꺼지면 30초 후 재시작). 로그: `~/.agent-hub/hub/hub.log` |

접속: claude.ai/code 또는 Claude 앱의 세션 목록에서 `hub`.

## 이미지 생성 (imagegen)

| 항목 | 내용 |
|---|---|
| 구성 | 호스트의 `imagegen/server.py`(MCP, Python 표준 라이브러리)가 호스트 Codex CLI의 ChatGPT 로그인으로 이미지를 만든다. API 키 불필요 |
| 접속 | `127.0.0.1:7801`. 컨테이너는 `host.docker.internal:7801`(이미지의 `/etc/agent-hub/mcp.json`, 작업마다 `--mcp-config`) |
| 도구 | `generate_image(prompt)` → 결과 URL. 에이전트가 `curl -o <경로> <URL>`로 프로젝트에 저장. 파일은 24시간 보관 (`~/.agent-hub/imagegen/`) |
| 안전 | Codex는 읽기 전용 sandbox에 셸·앱·플러그인 도구를 끄고 실행 → 프롬프트로 할 수 있는 건 이미지 생성뿐. 한 번에 하나씩 |
| 비용 | 한 장 약 20초, Codex 약 2.8만 토큰(대부분 캐시) + ChatGPT 플랜의 이미지 한도 |
| 준비 | 호스트에서 `codex login`(ChatGPT) → `proj imagegen install`. 이미지에 MCP 설정이 들어가므로 처음 한 번 `proj build` 후 `proj up <name>` |
| 로그 | `~/.agent-hub/imagegen.log` |

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
| `USAGE_MAX` | `0.95` (계정의 5시간·7일 한도 중 하나라도 넘으면 새 작업 거부) | 〃 |
| `IDLE_HOURS` | `3` (`proj idle` 기본값) | 〃 |
| `USAGE_STALE` | `1800` (작업 시작 시 사용량 값이 이보다 오래됐으면 먼저 짧은 요청으로 갱신, 초) | 〃 |
| `AGENT_HUB_HOME` | `~/.agent-hub` | 환경변수 (계정 토큰이 있으므로 동기화 폴더에 두지 않는다) |

작업 기록: `~/.agent-hub/tasks/<name>/<id>/` — `prompt.txt`, `prompts.log`(지시 이력), `log.jsonl`, `stderr.log`, `meta`, `pid`, `exit`.

## 알려진 한계

- 상한을 넘으면 대기하지 않고 거부한다 (대기열은 3단계).
- 컨테이너의 네트워크 송신은 제한하지 않는다.
- 작업은 `bypassPermissions`로 실행된다. 컨테이너에 넣은 토큰 범위 안에서는 확인 없이 무엇이든 할 수 있다.
