# proj 명령

`bin/proj` — 맥미니 호스트에서 실행한다. 저장소의 `bin`을 PATH에 추가해 두면 `proj`로 쓴다.

## 명령

| 명령 | 하는 일 |
|---|---|
| `proj build` | 이미지 `agent-hub:base`, `agent-hub:rust`, `agent-hub:dockerproxy` 빌드 (Claude Code 업데이트도 이것으로) |
| `proj account add <alias>` / `ls` | 계정 토큰 저장 / 목록 ([accounts.md](accounts.md)) |
| `proj new <name> [--repo URL\|owner/name] [--alias 별칭] [--account A] [--image I] [--mem 6g] [--profile dev\|marketing]` | `$WORKSPACE_ROOT/<name>`을 clone(`owner/name`은 호스트 `gh`로, 비공개 포함)·새로 만들기(빈 초기 커밋)·기존 폴더 등록 후 컨테이너 시작. 이미지를 안 주면 `Cargo.toml`이 있을 때 rust. 프로필 기본 `dev` (아래 "권한·훅 프로필") |
| `proj new <name> --create [--public]` | 위와 같이 새로 만들고, 호스트 `gh`로 GitHub 저장소(기본 비공개)를 만들어 `origin`으로 push |
| `proj new <name> --workspace` | 여러 저장소를 담는 빈 워크스페이스 폴더 (루트는 git 저장소가 아님) |
| `proj add <ws> <folder> [--repo URL\|owner/name \| --create [--public]]` | 워크스페이스에 저장소 추가: clone 또는 새로 만들기(+GitHub). Rust 저장소면 이미지를 rust로 전환 |
| `proj image <name> <image>` | 이미지 바꾸고 컨테이너 재생성 (실행 중 작업이 있으면 거부) |
| `proj model <name> [model\|-]` | 그 프로젝트 작업에 쓸 모델 (`-`는 기본값). 다음 작업부터 적용, 재시작 없음 |
| `proj usage [--refresh]` | 계정별 5시간·7일 한도 사용률과 초기화 시각. `--refresh`는 계정마다 아주 짧은 요청(Haiku, 약 900토큰)을 보내 최신 값을 받음 |
| `proj idle [시간]` / `idle install [시간]` / `idle uninstall` | 작업·셸·활동이 없는 지 N시간(기본 3) 지난 컨테이너 중지. 에이전트가 띄운 컨테이너(DB 등)는 활동으로 보지 않고 함께 멈춤. `install`은 30분마다 실행하도록 launchd 등록. 멈춘 컨테이너는 다음 작업이나 `proj up`에서 다시 켜짐 |
| `proj hub init` / `login` / `run` / `install` / `uninstall` / `status` | 메인 에이전트 관리 (아래 "메인 에이전트") |
| `proj imagegen install` / `uninstall` / `status` | 이미지 생성 MCP 서버를 launchd로 등록·해제·확인 (아래 "이미지 생성") |
| `proj plugin source add <owner/repo\|URL>` / `update [marketplace]` / `ls` | 플러그인 마켓플레이스 저장소를 `~/.agent-hub/plugins/<marketplace.json의 name>/`에 clone / `git pull --ff-only` / 목록 (아래 "플러그인") |
| `proj profile <name> [dev\|marketing]` | 권한·훅 프로필 보기 / 바꾸기 (다음 작업부터) |
| `proj plugin <name> add <plugin@marketplace> [--env KEY=VALUE …]` / `rm <plugin@marketplace>` / `ls` | 그 프로젝트에서 플러그인 켜기(옵션은 `env`, `KEY=`는 그 키 삭제) / 끄기 / 목록. `proj plugin ls`는 모든 프로젝트 |
| `proj alias <name> <별칭>` | 메인 에이전트가 알아듣는 이름 지정 (예: `스모크`). `proj new --alias`로도 지정 |
| `proj ls` | 프로젝트, 계정, 컨테이너 상태, 실행 중 작업 수, 별칭 |
| `proj up` / `down` / `shell <name>` | 시작 / 중지(컨테이너 삭제, 볼륨 유지. 에이전트가 띄운 컨테이너는 멈추기만) / 컨테이너 셸 |
| `proj rm <name> [--purge] [--yes]` | 컨테이너와 Claude 설정 볼륨, 에이전트가 띄운 컨테이너·네트워크·볼륨(라벨 `agent-hub.project=<name>`, DB 데이터 포함) 삭제, 폴더·작업 기록은 남김. `--purge`는 폴더·작업 기록·대화 기록(`sessions/<name>`)까지 삭제하되 커밋 안 된 변경이나 원격에 없는 커밋이 있으면 거부. 확인은 터미널에서 직접 답하거나 `--yes` (파이프로 넣은 `y`는 거부) |
| `proj task <name> [--repo <folder>] [--worktree] [--from <task\|branch>] [--merge] <지시…\|->` | 체크아웃에 기본 브랜치(`--from`이면 그 작업의 브랜치)에서 새 브랜치 `agent/<id>`를 만들고 `claude -p` 백그라운드 실행. `--worktree`는 `.worktrees/<id>`에서 실행(병렬용). 워크스페이스는 `--repo`로 저장소를 고르고, 없으면 루트에서 실행. `-`는 표준입력에서 지시를 읽음. `--merge`는 사용자가 병합을 요청한 작업(PR 병합 허용). `--here`는 예전 옵션(무시) |
| `proj reply <task> <지시…\|->` | 같은 세션을 이어서 실행 (`--resume`). 체크아웃이 다른 브랜치로 옮겨 갔으면 변경이 없을 때 작업 브랜치로 다시 전환. 세션 파일이나 작업 폴더가 없으면 실행하지 않고 `--from`을 안내 |
| `proj status [task\|name]` | 작업 목록(삭제된 프로젝트 제외) 또는 한 작업의 상태·비용·결과 보고. 끝난 작업의 `transcript.md`가 없거나 종료보다 오래됐으면 이때 다시 만듦 |
| `proj wait <task> [초]` | 작업이 끝날 때까지 기다렸다가 `status` 출력 (기본 1800초, 넘으면 종료 코드 3). 메인 에이전트는 이것으로 기다림 |
| `proj logs <task> [-f]` | Claude의 메시지와 도구 호출 요약 (`-f` 실시간, 작업이 끝나면 멈춤) |
| `proj transcript <task>` | 대화 기록 `transcript.md`를 지금 다시 만듦 (진행 중이면 그 시점까지). 아래 "대화 기록" |
| `proj diff <task>` | 커밋 안 된 변경, base 이후 작업 브랜치 커밋, diffstat, VS Code로 여는 경로 |
| `proj close <task>` | 체크아웃 작업: 아무것도 지우지 않음. 작업 브랜치에 있고 변경이 없으면 기본 브랜치로 돌아감. worktree 작업: worktree 삭제(브랜치 유지), 커밋 안 된 변경이 있으면 거부 |

## 프로젝트 종류

| 종류 | 만들기 | 작업 위치 | 동시 실행 |
|---|---|---|---|
| `repo` 저장소 하나 | `proj new <name> --repo …` / `--create` | 체크아웃 `<repo>` (브랜치 `agent/<id>`) | 하나씩. `--worktree`면 가능 |
| `ws` 워크스페이스 | `proj new <name> --workspace` + `proj add …` | `--repo <folder>`: `<ws>/<folder>` (루트·저장소 CLAUDE.md 모두 읽힘) | 저장소마다 하나씩. `--worktree`면 가능 |
| | | `--repo` 없이: 워크스페이스 루트 (여러 저장소·루트 문서) | 같은 폴더에서 하나씩 |

프로젝트 하나에 에이전트 하나라서, worktree 없이 폴더를 직접 고치는 작업은 같은 폴더(또는 그 상위·하위 폴더)에서 실행 중인 작업이 있거나 체크아웃에 커밋 안 된 변경이 있으면 거부합니다. 병렬이 꼭 필요하면 `--worktree`. `proj rm --purge`는 워크스페이스의 각 저장소를 검사하고, 저장소 밖 루트 파일(CLAUDE.md, docs 등)이 있으면 거부합니다.

## 작업 흐름

1. `proj task app "로그인 API에 rate limit 추가"` → 작업 ID(예: `261118-130303`)
   - 커밋이 있는 저장소: 체크아웃에서 기본 브랜치(`origin/HEAD`, 없으면 `main`/`master`)로부터 `agent/<id>`를 만들어 전환하고 실행. 커밋까지 하고 push·PR은 지시할 때만. 이전 작업 브랜치에 남아 있어도 새 작업은 기본 브랜치에서 시작.
   - 에이전트가 서브에이전트로 병렬 작업을 나누면 서브에이전트마다 worktree 격리(`isolation: worktree`, `.claude/worktrees/`)를 쓰도록 시스템 프롬프트로 안내.
   - `--worktree`: `.worktrees/<id>`에 같은 브랜치를 만들고 거기서 실행(같은 프로젝트 병렬 작업용).
   - 커밋이 없는 저장소·워크스페이스 루트: 폴더에서 바로 실행하고 브랜치를 만들지 않음.
2. `proj status` / `proj logs <id> -f`로 진행 확인.
3. `proj diff <id>` → VS Code로 프로젝트 폴더(`--worktree`면 worktree)를 열어 diff 확인.
4. 고칠 점은 `proj reply <id> "…"`(같은 세션). 대화는 새로 시작하되 그 결과에서 이어 가려면 `proj task <name> --from <id> "…"`(새 세션, 그 브랜치에서 딴 새 브랜치). 끝나면 PR은 `proj reply <id> "harness github-pr로 PR 올려줘"`, 정리는 `proj close <id>`.

## 메인 에이전트 (hub)

호스트에서 `claude remote-control`로 상시 대기하며, 폰·브라우저 채팅으로 받은 지시를 `proj`로 나눠 맡긴다. 운영 지침은 `hub/CLAUDE.md`, 권한은 `hub/settings.json`(proj·읽기 전용 git/gh만 허용, 계정 폴더 읽기와 docker 직접 실행 금지). `proj hub run`이 그 안의 `~/workspace`·`~/.agent-hub`를 설정한 경로로 바꿔 `~/.agent-hub/hub-settings.json`으로 넘긴다.

| 순서 | 명령 | 비고 |
|---|---|---|
| 1 | `~/.agent-hub/config`에 `HUB_ACCOUNT=sosin` | 정식 로그인할 계정 (없으면 `DEFAULT_ACCOUNT`) |
| 2 | `proj hub init` | `~/.agent-hub/hub/`에 `CLAUDE.md` 링크 |
| 3 | `proj hub login` | `~/.claude-<alias>`로 claude 실행 → 폴더 신뢰, `/login` |
| 4 | `proj hub run` | 처음 한 번은 터미널에서: Remote Control 활성화 확인에 `y` |
| 5 | `proj hub install` | launchd 등록 (로그인 시 시작, 꺼지면 30초 후 재시작). 로그: `~/.agent-hub/hub/hub.log` |

접속: claude.ai/code 또는 Claude 앱의 세션 목록에서 `hub`. 앱에서 새 세션을 열면 같은 hub에 채팅방이 하나 더 생긴다(Remote Control 서버 모드). 작업 상태는 `proj`로 모든 세션이 공유한다.

계정 전환 (한도에 걸렸을 때):

| 순서 | 명령 | 비고 |
|---|---|---|
| 1 | `proj hub login --account fins` | 계정마다 처음 한 번, 맥미니 화면에서. 브라우저 로그인 → 폴더 신뢰 `y` → `/exit` |
| 2 | `proj hub run --account fins` | 처음 한 번. "Enable Remote Control?" `y` → 연결되면 Ctrl+C |
| 3 | `proj hub use fins` | `HUB_ACCOUNT` 변경 후 서비스 재시작. 그 계정의 Claude 앱에서 `hub` 사용. 로그인 안 된 계정이면 거부 |

채팅 기록은 계정별로 따로 남고 옮기지 않는다. 새 계정의 hub는 `proj status`·작업 기록으로 이어 간다. `proj hub status`는 현재 계정과 사용량도 보여 준다.

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

## Docker (프로젝트 컨테이너 안)

| 항목 | 내용 |
|---|---|
| 접속 | `docker`, `docker compose`가 `DOCKER_HOST=tcp://docker:2375`(그 프로젝트의 프록시)로 호스트 Docker를 씀. 컨테이너에 소켓은 없음 |
| 할 수 있는 것 | 자기 프로젝트 컨테이너·볼륨·네트워크 생성·조작, 프로젝트 폴더 안 bind mount(`-v $PWD:/app`), 포트 게시, 이미지 pull·build |
| 막힌 것 | 프로젝트 폴더 밖 마운트, `--privileged`·`--cap-add`·장치, host PID/IPC/네트워크, 다른 프로젝트 것, 이미지 삭제·prune. 규칙: [architecture.md](architecture.md) "Docker 프록시 규칙" |
| 게시한 포트 | 에이전트에서는 `host.docker.internal:<포트>`로 접속 (`localhost` 아님). 맥미니에서는 `localhost:<포트>` |
| 빌드 | 클래식 빌더 (`DOCKER_BUILDKIT=0`). BuildKit 전용 문법(`RUN --mount` 등)은 안 됨 |
| Testcontainers | `TESTCONTAINERS_HOST_OVERRIDE=host.docker.internal`, Ryuk 끔(소켓 마운트가 필요해서). 남은 컨테이너는 `proj down`·`rm`이 라벨로 정리 |
| 준비 | 이 기능 이전에 만든 프로젝트는 `proj build` 후 `proj up <name>` (프록시 서비스 추가) |

## 플러그인

| 항목 | 내용 |
|---|---|
| 소스 | `proj plugin source add DietrichGebert/ponytail` → `~/.agent-hub/plugins/ponytail/` (`owner/repo`는 호스트 `gh`, URL은 `git clone`). 모든 컨테이너에 `/opt/plugins`로 읽기 전용 마운트 |
| 켜기 | `proj plugin app add ponytail@ponytail --env PONYTAIL_DEFAULT_MODE=full`. 이름은 `<플러그인>@<marketplace.json의 name>`. harness는 `harness@devsosin-harness`(기본 켬) |
| 설정 파일 | `~/.agent-hub/projects/<name>.managed-settings.json` (jq로 생성: `extraKnownMarketplaces`, `enabledPlugins`, `env`) → `/etc/claude-code/managed-settings.json:ro`. 없으면 `proj new`·`up`·다음 작업에서 `image/managed-settings.json` 기본값(harness만)으로 만듦 |
| 반영 | 다음 `claude -p` 작업부터, 컨테이너 재시작 없음 (파일을 같은 inode에 덮어써 실행 중 컨테이너에도 바로 보임. OrbStack에서 확인). 처음 쓸 때 `CLAUDE_CODE_SYNC_PLUGIN_INSTALL=1`로 Claude 설정 볼륨에 설치, 신뢰 확인 없음 |
| 갱신 | `proj plugin source update [marketplace]` — 컨테이너는 플러그인 코드를 바꿀 수 없음 |
| 준비 | 이 기능 이전에 만든 프로젝트는 `proj up <name>` 한 번 (새 마운트 추가) |

## 권한·훅 프로필

프로젝트 managed settings(`~/.agent-hub/projects/<name>.managed-settings.json`, 읽기 전용 마운트)에 `image/settings/common.json` + 팀 프로필을 합쳐 넣는다. deny 목록과 훅은 이어 붙이고, 플러그인·`env`는 그대로 둔다. `proj up`·작업 시작 때 저장소 파일로 다시 맞추므로 `git pull`만으로 반영된다.

| 프로필 | 내용 |
|---|---|
| 공통 | `.env` 계열·`*.pem`·`*.key` Read/Edit deny, `sudo` deny. 가드 훅, 작업 기록 훅 |
| `dev` (기본) | 추가 deny 없음: issue, 브랜치 push, `gh pr create` 가능. 병합은 `--merge` 작업에서만 |
| `marketing` | `git push`, `git remote add/set-url`, 데이터를 바꾸는 `curl`(`-X POST` 등, `-d`, `-F`)·`wget` deny |

| 훅 (`image/hooks/`, 이미지 `/usr/local/lib/agent-hub/hooks/`) | 동작 |
|---|---|
| `guard` (PreToolUse) | 경로·명령에 `.env` 이름이 있으면 거부, `.env.example`만 허용. `gh pr merge`, `pulls/<n>/merge` API, 기본 브랜치(main·master·origin HEAD)로의 push·`--all`은 `AGENT_HUB_ALLOW_MERGE=1`(`proj task --merge`)일 때만 |
| `worklog` (Stop) | 최근 1시간 안에 바뀐 파일이 있는데 `log/YYYY-MM.md`(저장소 루트, 아니면 작업 폴더)가 그 뒤에 안 바뀌었으면 한 번 막고 한 줄을 요청: `- YYYY-MM-DD HH:MM <task id\|shell> <branch> — 한 일` |

- 작업은 `bypassPermissions`로 돌므로 allow·ask 규칙은 효과가 없다. 막는 것은 deny와 훅뿐.
- 훅은 문자열 검사라 셸로 우회할 수 있다. 병합을 확실히 막으려면 GitHub 저장소에서 main 브랜치 보호를 켠다.
- 저장소 고유 규칙(예: 마케팅 SSOT 보호, 린트 훅)은 그 저장소의 `.claude/settings.json`에 커밋한다. managed 규칙이 우선하고, 에이전트가 고칠 수 있는 파일이라 공통 규칙은 넣지 않는다.
- 적용: `proj build`(훅 스크립트) 후 기존 프로젝트는 다음 작업부터 `dev`. 마케팅 프로젝트는 `proj profile <name> marketing`.
- 시각은 컨테이너 시간대(UTC) 기준.

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

플러그인: `~/.agent-hub/plugins/<marketplace>/`, 프로젝트별 설정 `~/.agent-hub/projects/<name>.managed-settings.json` (`proj rm`이 함께 삭제).

작업 기록: `~/.agent-hub/tasks/<name>/<id>/` — `prompt.txt`, `prompts.log`(지시 이력), `log.jsonl`, `stderr.log`, `meta`, `pid`, `exit`, `transcript.md`.

## 대화 기록 (transcript.md)

| 항목 | 내용 |
|---|---|
| 원본 | Claude Code 세션 파일. 컨테이너의 `/home/node/.claude/projects`를 호스트 `~/.agent-hub/sessions/<name>/`에 바인드 마운트 (`<cwd 인코딩>/<session_id>.jsonl`, 서브에이전트는 같은 세션 ID로 기록된 파일). 나머지 Claude 설정은 볼륨 그대로 |
| 만드는 때 | 작업이 끝난 뒤 `proj status`·`proj wait`가 볼 때(없거나 종료보다 오래됐으면), 또는 `proj transcript <task>` |
| 내용 | 메시지마다 로컬 일시 · 화자(`user` 지시, `agent` 메인, `subagent <종류> (<설명>)`, `tool` 짧은 결과), 텍스트, 도구 호출 한 줄 요약(`→ Bash: …`). 시간순 |
| 빼는 것 | thinking, API 요청 기록, 3줄·300자를 넘는 도구 결과(환경변수 출력 등). `sk-ant-`·`ghp_`·`github_pat_` 등 토큰과 `*TOKEN=`·`*SECRET=`·`*PASSWORD=`·`*API_KEY=` 값은 `[REDACTED]` |
| `proj reply` | 그 작업의 모든 실행(세션 ID)을 모아 다시 만들므로 이어진 대화가 같은 파일에 뒤에 붙음 |
| 준비 | 이 기능 이전에 만든 프로젝트는 `proj up <name>`으로 컨테이너를 다시 만들어야 마운트가 생김. 그 전 작업은 기록이 볼륨에만 있어 만들 수 없음 |

## 알려진 한계

- 상한을 넘으면 대기하지 않고 거부한다 (대기열은 3단계).
- 컨테이너의 네트워크 송신은 제한하지 않는다.
- 작업은 `bypassPermissions`로 실행된다. 컨테이너에 넣은 토큰 범위 안에서는 확인 없이 무엇이든 할 수 있다.
