# 구조와 결정

맥미니(M4, 16GB, 2TB, OrbStack, 상시 가동) 한 대에서 프로젝트마다 에이전트 컨테이너를 두고, 통합 에이전트 하나가 작업을 나눠 지시한다. 사용자는 어느 기기에서든 채팅으로 지시하고 VS Code로 결과를 본다.

## 구성

```
[어디서든] 폰 · 노트북 · 집 윈도우 PC · 남의 PC(브라우저)
   ├─ 채팅: claude.ai/code, Claude 앱 ──────────────▶ 통합 에이전트 (Remote Control)
   └─ 파일·diff: VS Code Remote-SSH(Tailscale) / vscode.dev 터널 ─▶ 맥미니 ~/workspace
Mac mini
 ├─ 통합 에이전트: 호스트의 claude, bin/proj 만 호출          (2단계)
 ├─ proj-<name> 컨테이너: claude -p, harness·켠 플러그인, 계정 토큰
 │    └─ ~/workspace/<name> (호스트와 같은 절대경로로 마운트)
 └─ ~/.agent-hub: 계정·프로젝트 설정·작업 기록
```

| 구성요소 | 위치 | 역할 |
|---|---|---|
| `bin/proj` | 호스트 | 프로젝트·계정·작업 관리 CLI ([proj.md](proj.md)) |
| `agent-hub:base` / `web` / `rust` / `rust-web` | 이미지 | Claude Code, gh, git, Node (+ Playwright·Chromium / + Rust·rust-analyzer / 둘 다). 코드로 자동 선택 |
| `compose/project.yml` | 프로젝트당 compose 프로젝트 `proj-<name>` | 마운트·시크릿·메모리 상한. 서비스 `agent`(에이전트), `docker`(Docker 프록시) |
| `agent-hub:dockerproxy` | 이미지 (`dockerproxy/`) | 호스트 Docker 소켓을 갖고 그 프로젝트 것만 통과시키는 API 프록시 (아래 보안 경계) |
| harness | `~/workspace/harness` → `/opt/harness:ro` | managed settings로 마켓플레이스 등록·활성화(기본 켬). 호스트에서 고치면 다음 세션부터 반영 |
| 플러그인 | `~/.agent-hub/plugins/<marketplace>/` → `/opt/plugins:ro` | `proj plugin source add`로 호스트에 git clone. 프로젝트별 managed settings(`~/.agent-hub/projects/<name>.managed-settings.json` → `/etc/claude-code/managed-settings.json:ro`)로 켜고 끄고 `env`로 옵션 전달 |
| 계정 | `~/.agent-hub/accounts/<alias>/` | [accounts.md](accounts.md) |

## 보안 경계

| 대상 | 프로젝트 컨테이너 | 이유 |
|---|---|---|
| Docker 소켓 | 넣지 않음. `DOCKER_HOST=tcp://docker:2375`(프로젝트별 프록시)만 | 소켓을 가진 쪽은 `/Users` 아래 무엇이든 마운트할 수 있음. 컨테이너 안 래퍼는 우회되므로 프록시가 소켓을 가짐 |
| 호스트 Docker (프록시 규칙) | 자기 프로젝트 것만 | 아래 표 |
| 호스트 `~/.ssh`, 키체인 | 넣지 않음 | git은 `GH_TOKEN`(https)으로만 |
| Claude 인증 | `setup-token` 토큰만 | 모델 호출만 가능. 정식 로그인은 호스트에만 |
| OpenAI(Codex) 로그인 | 넣지 않음 | 호스트 imagegen MCP만 사용. 컨테이너는 이미지 URL만 받음 |
| 플러그인 코드·managed settings | 읽기 전용 마운트 | 플러그인 hook은 컨테이너에서 코드를 실행하므로 코드는 호스트에서만 바뀜(`proj plugin source add`·`update`). 켜는 플러그인과 옵션도 호스트 파일이라 에이전트가 바꿀 수 없음. 마켓플레이스 폴더는 모든 프로젝트에 보이지만 켜진 것만 로드됨 |
| 권한 모드 | `bypassPermissions` (non-root) | 컨테이너가 경계. 네트워크 송신 제한은 아직 없음 (TBD) |
| knowledge MCP | 켠 프로젝트에만: 서버가 그 프로젝트 네트워크에 연결되고, 프로젝트별 토큰(secret)이 최대 sensitivity를 정함. 서버용 GitHub 토큰은 서버 컨테이너에만 | 끈 프로젝트는 서버 이름조차 못 찾음. 프로젝트끼리는 계속 분리. `confidential`은 사용자 확인 후에만 ([proj.md](proj.md) "지식 (knowledge MCP)") |
| 권한·훅 프로필 | managed settings(읽기 전용)에 공통 + 팀(`dev`·`marketing`) deny와 훅 | `.env` 차단(`.env.example`만), 병합은 `--merge` 작업만. 훅은 문자열 검사라 GitHub 브랜치 보호가 최종 차단 ([proj.md](proj.md) "권한·훅 프로필") |

### Docker 프록시 규칙 (`dockerproxy/server.py`)

소유는 라벨 `agent-hub.project=<name>`. 생성 요청에 프록시가 강제로 넣고(사용자가 준 값은 덮어씀), 라벨이 없으면 다른 프로젝트 것으로 본다. `agent`·`docker` 서비스 자체에는 라벨이 없어 에이전트가 건드릴 수 없다.

| API | 규칙 |
|---|---|
| `POST /containers/create` | 라벨 주입. bind 원본은 `PROJECT_DIR` 안만(심볼릭 링크를 풀어 확인, 푼 경로로 바꿔 전달). 소켓 마운트, `Privileged`, `CapAdd`, `Devices`·`DeviceRequests`, `CgroupParent`, `MaskedPaths`·`ReadonlyPaths`, `no-new-privileges` 외 `SecurityOpt`, Pid·Ipc·Userns·UTS·Cgroupns·Network의 `host`, 런타임·볼륨 드라이버 변경 거부. `container:<id>`·`VolumesFrom`·네트워크·이름 있는 볼륨은 자기 것만(없는 볼륨은 라벨을 붙여 먼저 만듦). 포트 게시(`-p`) 허용 |
| `/containers/{id}/*`, `/exec/*` | 그 컨테이너에 라벨이 있을 때만. 경로를 전체 ID로 바꿔 전달. privileged exec 거부 |
| `GET /containers/json`, `/volumes`, `/networks`, `/events` | 라벨 필터 강제 |
| 볼륨·네트워크 생성 | 라벨 주입. 볼륨 드라이버 옵션은 `type=tmpfs`만(`o=bind`로 호스트 경로를 붙일 수 있어서), 네트워크 드라이버는 bridge만. 조회·삭제·connect는 라벨이 있는 것만 |
| 이미지 pull·조회·push, `POST /build` | 허용. build는 라벨 주입, `networkmode=host` 거부, BuildKit(`/session`·`/grpc`) 미지원 → `DOCKER_BUILDKIT=0` |
| 이미지 태그 쓰기 (build `-t`, `docker tag`) | 새 이름이나 이 프로젝트가 빌드한 이미지만. `agent-hub:*`는 예약 (덮어쓰면 다른 프로젝트·프록시가 그 코드를 실행) |
| 이미지 삭제·prune, import·load, commit | 거부 (이미지 캐시는 모든 프로젝트 공유) |
| `/_ping`, `/version`, `/info`, `/distribution` | 허용 |
| 그 외 (swarm, plugins, `/system/df`, prune 전부 등) | 거부 |

알려진 한계: bind 원본 확인과 데몬의 마운트 사이에 프로젝트 폴더 안 경로를 심볼릭 링크로 바꾸면 확인을 피할 수 있다(경쟁 조건, Docker API로는 막을 수 없음). 아직 아무도 받지 않은 이미지 이름(예: 새 `postgres` 태그)을 먼저 빌드해 두면 다른 프로젝트가 그것을 쓸 수 있다. 포트 게시는 프로젝트 간 충돌할 수 있다.

## 결정 기록

| 날짜 | 결정 | 이유 |
|---|---|---|
| 2026-11-18 | 컨테이너 런타임은 OrbStack | 사용자가 Docker Desktop에서 전환 |
| 2026-11-18 | 프로젝트 폴더는 호스트 `~/workspace/<name>`을 같은 경로로 바인드 마운트 | 호스트에서 VS Code·통합 에이전트가 바로 보고, worktree 절대경로가 양쪽에서 유효 |
| 2026-11-18 | 작업마다 worktree `.worktrees/<id>`, 브랜치 `agent/<id>`. 커밋까지, push·PR은 지시할 때만 | 병렬 작업 분리, 리뷰는 VS Code에서. 2026-11-19에 체크아웃 기본으로 바뀜 |
| 2026-11-18 | 동시 실행 작업 2개 (`MAX_TASKS`), 컨테이너 메모리 상한 6g | RAM 16GB |
| 2026-11-18 | 계정 여러 개: 프로젝트마다 계정 별칭 하나 | 개인(sosin)·회사(fins) 크레딧 모두 사용 가능 (사용자 결정) |
| 2026-11-18 | GitHub: 메인 에이전트는 호스트 `gh`(저장소 생성 포함), 프로젝트 컨테이너는 계정당 fine-grained 토큰(All repositories, Administration 없음) | 저장소마다 토큰을 새로 만들 필요 없이 새 저장소도 바로 작업 가능 |
| 2026-11-18 | 메인 에이전트는 사용자와 한국어로 대화(전문 용어는 영어 가능), 프로젝트 에이전트에게 주는 지시는 영어 | 사용자 결정 |
| 2026-11-18 | 사용자는 "~하게 해줘" 없이 바로 지시하고, 메인 에이전트가 이름·한글 별칭으로 프로젝트를 찾아 맡긴 뒤 기다렸다가 보고 | 사용자 결정 |
| 2026-11-18 | 삭제 등 되돌릴 수 없는 작업은 채팅에서 확인 후 `--yes`. 파이프 입력은 동의로 보지 않음 | 메인 에이전트가 `echo y \|`로 확인을 우회한 사례 |
| 2026-11-18 | 두 흐름: 기존 저장소 clone(`--repo owner/name`) / 새 워크스페이스에 저장소 여러 개(`--workspace` + `proj add`). 워크스페이스 작업은 저장소별 worktree, 여러 저장소에 걸친 작업은 루트에서 하나씩 | 사용자 요청. 상위 CLAUDE.md가 자동으로 읽혀 루트 지침이 저장소 작업에도 적용됨 |
| 2026-11-18 | 유휴 컨테이너(작업·셸·활동 없이 3시간)는 launchd로 30분마다 자동 중지, 다음 작업 때 자동 시작 | RAM 16GB에서 메모리 확보 (사용자 요청) |
| 2026-11-18 | 사용량: 작업 로그의 `rate_limit_event`로 계정별 5h·7d 사용률 추적, 95% 이상이면 새 작업 거부. 계정·모델은 프로젝트별로 중간에 변경 | 사용자 요청. 별도 API 없이 claude 출력만 사용 |
| 2026-11-18 | SeaDrive는 설정·이미지 공유용. 코드 동기화에 쓰지 않음 | 코드는 맥미니에만 두고 SSH로 직접 봄 |
| 2026-11-18 | 이미지 생성은 별도 서비스(MCP)로 제공, OpenAI 인증은 그 서비스에만 | 로그인 토큰 동시 갱신 충돌·노출 방지 (3단계) |
| 2026-11-19 | 프로젝트 에이전트가 호스트 Docker를 쓴다(모든 프로젝트 기본). 자기 프로젝트 것만: 프로젝트별 프록시 사이드카가 소켓을 갖고 라벨로 소유를 판단 | 테스트 DB·compose 스택이 필요. 메인 에이전트는 채팅·검토용, 프로젝트 에이전트에는 넉넉한 권한, 통제는 harness (사용자 결정, #3) |
| 2026-11-19 | 포트 게시(`-p`) 허용, `--network host`·이미지 삭제·prune 금지 | 프론트엔드 디버깅용 localhost. OrbStack의 host 네트워크는 맥과 같지 않음. 이미지 캐시는 공유 (사용자 결정) |
| 2026-11-19 | `proj rm`은 라벨 붙은 컨테이너·네트워크·볼륨까지 삭제, `proj down`은 그 컨테이너를 멈춤. `proj idle`은 그 컨테이너를 활동으로 보지 않고 에이전트와 함께 멈춤 | 프로젝트는 compose·시드로 다시 띄울 수 있게 구성 (사용자 결정). 잊힌 DB가 메모리를 계속 쓰지 않게 |
| 2026-11-18 | imagegen: 호스트 MCP 서버가 호스트 Codex의 ChatGPT(Plus) 로그인으로 생성, Codex는 셸 없이 읽기 전용, 결과는 URL로 내려받기 | 사용자가 API 키 대신 구독 OAuth를 원함. 별도 컨테이너·로그인 없이 호스트 하나만 인증 보유 |
| 2026-11-19 | 대화 기록은 작업 폴더의 `transcript.md`(일시 포함)로 남긴다. 원본은 Claude Code 세션 파일: 컨테이너 `~/.claude/projects`만 `~/.agent-hub/sessions/<name>/`에 바인드 마운트하고, `proj`가 호스트에서 만든다. DB·컨테이너 안 스킬·스크립트는 쓰지 않음. 보관은 `proj rm --purge` 전까지 (#2) | 사후 확인용. 세션 기록에 줄마다 `timestamp`가 있고 서브에이전트 기록도 같은 곳에 남음. 에이전트가 직접 남기면 빠뜨리거나 토큰을 씀 (사용자 결정) |
| 2026-11-19 | 작업은 체크아웃에서 기본 브랜치로부터 `agent/<id>`를 만들어 커밋. 커밋 안 된 변경이 있거나 같은 폴더에 실행 중인 작업이 있으면 거부. 워크스페이스 `--repo`도 같은 규칙. worktree는 `proj task --worktree`로 명시할 때만, 서브에이전트 병렬은 Claude Code worktree 격리(`isolation: worktree`) (#1) | 프로젝트당 에이전트 하나(1:1). VS Code에서 폴더 하나로 리뷰, worktree가 쌓이지 않음 (사용자 결정) |
| 2026-11-19 | 플러그인은 호스트 `~/.agent-hub/plugins/`에 git clone해 모든 컨테이너에 읽기 전용으로 올리고, 프로젝트별 managed settings로 켜고 끈다. 옵션은 settings `env`, harness는 기본 켬(`rm`으로 끌 수 있음). 메인 에이전트는 `proj plugin source add`·`update`·`ls`를 바로 실행, 프로젝트별 `add`·`rm`은 사용자 승인 후 (#6) | 컨테이너 안에서 플러그인을 설치할 수 없다는 프로젝트 에이전트 보고. managed settings는 신뢰 확인이 없어 `claude -p`에서도 동작, 버전은 호스트에서 고정 (사용자 결정) |
| 2026-11-19 | 이어서 작업: 같은 세션은 `proj reply`, 새 세션은 `proj task --from <task>`(그 작업 브랜치에서 새 브랜치). 세션이 없을 때 reply가 자동으로 새 세션을 만들지 않음. 예전 볼륨 세션은 사용자가 1회 수동 복사 (#11) | #8 전환 때 컨테이너 재생성으로 볼륨 세션이 가려져 reply가 실패한 사례. 다시 생기지 않는 1회성 원인 (사용자 결정) |
| 2026-11-23 | 메인 에이전트 계정 전환은 `proj hub use <alias>`(설정 변경 + 서비스 재시작), 사용자만 실행. 채팅 기록은 옮기지 않고 작업 상태(`proj`)로 이어 감. hub는 자기 계정 80% 이상이면 안내 (#14). 주제별 채팅방은 Remote Control 서버 모드로 이미 가능 (#15 종료) | 한도에 걸리면 hub 대화도 막힘 (사용자 결정) |
| 2026-11-25 | 권한·훅을 공통 / 개발팀(`dev`) / 마케팅팀(`marketing`) 프로필로 나누고 `proj new --profile`로 적용. 공통: `.env` 읽기·쓰기 금지(`.env.example`만), 작업 기록은 프로젝트 `log/YYYY-MM.md`에 한 줄(도구 사용 내역은 기록 안 함). 개발팀: issue, push, PR 생성 허용, 병합은 사용자가 요청할 때 `proj task --merge`로 순서대로 (#17) | 사용자 결정 |
| 2026-11-25 | 작업 기록은 Markdown 표: `dev`는 `일시 \| 이슈·PR \| 작업내용 \| 브랜치`, `marketing`은 `시각 \| 에이전트 \| 내용 \| 참조`, 워크스페이스는 루트에 하나로 `대상` 열 추가. 컨테이너 시간대 KST | 사용자 결정 |
| 2026-11-25 | 공통 가드에 작업 폴더 경계(파일 도구), `.claude/settings*.json` 쓰기 차단, 기본 브랜치 직접 commit 차단, commit 전 비밀값 검사 추가, 세션 시작 때 최근 작업 기록. `rm -rf` 공통 deny·게시 API 호스트 차단·컨테이너 workspace 신뢰 등록은 하지 않음 (#19) | 사용자 결정 |
| 2026-11-25 | 병합 예외는 `proj task --merge` 하나: 원격 없는 저장소의 기본 브랜치 로컬 `git merge`도 그 작업에서만, 작업 기록 행은 병합 작업이 기본 브랜치에 바로 commit(로그 전용 브랜치 안 씀) (#23) | 사용자 결정 |
| 2026-11-25 | 프론트엔드용 Playwright: `base` 이미지에 Playwright MCP와 Chromium·시스템 라이브러리(rust도 상속). 에이전트 브라우저는 headless·isolated MCP (#25) | 사용자 요청, 별도 이미지 대신 base |
| 2026-11-27 | 참고 저장소: `$WORKSPACE_ROOT/refs/<repo>` 전용 clone을 연결한 프로젝트 컨테이너에만 `/refs/<repo>` 읽기 전용으로. `proj task`·`reply` 직전 호스트에서 pull(실패해도 진행), 안내는 워크스페이스 CLAUDE.md (#30) | 참고용 코드를 에이전트가 고치지 않게, 작업 브랜치와 부딪히지 않게, 다른 계정 프로젝트에 안 보이게 (사용자 결정) |
| 2026-11-27 | 이미지를 개발 환경별로 나눔: `base` / `web`(Playwright) / `rust`(+ rust-analyzer, LSP 플러그인 자동) / `rust-web`. `Cargo.toml`·`package.json`으로 자동 선택, 마케팅은 `base`. #25의 base 포함 결정을 바꿈 (#29) | Rust 컨테이너에 브라우저(약 1.1GB)가 필요 없고, 프론트에는 rust가 필요 없음 (사용자 결정) |
| 2026-11-27 | Rust 검사는 개발 프로필 훅(`rust-check`): 수정 직후 SQL 상태 문자열, 작업 끝에 fmt·clippy(`--workspace`, 한 번만 막음). ponytail audit은 리팩토링 때만, 지도 길이는 늘리지 않음 (#28) | 규칙을 CLAUDE.md에 길게 적지 않고 작업 중에 강제. 마케팅 프로필에는 불필요 (사용자 결정) |
| 2026-11-27 | knowledge MCP: 공유 네트워크 대신 켠 프로젝트 네트워크에만 서버 연결, 프로젝트별 토큰 → 최대 sensitivity(기본 `internal`, `confidential`은 사용자 확인), 쓰기는 `propose_update` PR만, 서버 수명주기는 `proj knowledge`, 지식 저장소는 `refs/` clone (#34) | 계정·프로젝트 경계 유지, 사실 변경은 항상 사용자 리뷰 (사용자 결정) |
| 2026-11-28 | harness는 플러그인 캐시를 쓰지 않고 매 실행 `--plugin-dir /opt/harness/plugins`로 로드, `proj task`·`reply` 직전에 호스트 checkout을 pull(5분 중복 방지, 실패는 경고). 참고 저장소·knowledge도 같은 시점에 pull (#37) | Claude Code가 managed 플러그인을 처음 설치한 복사본으로 계속 써서 최신 harness가 반영되지 않았음 (사용자 요청) |

## 단계

| 단계 | 내용 | 상태 |
|---|---|---|
| 1 | 이미지, compose, `proj` (new·task·reply·status·logs·diff·close), 계정 | 완료 (MacBook OrbStack에서 실제 토큰으로 확인) |
| 2 | 통합 에이전트: `hub/CLAUDE.md`·`hub/settings.json`, `proj hub` (Remote Control 서버 모드, launchd), `proj new --create` | 구현. MacBook에서 확인: 웹·폰 Remote Control, 말로 지시 → `--create` 비공개 저장소 → 작업 커밋 → push·PR. launchd 등록은 맥미니에서 |
| 3 | imagegen MCP | 구현. MacBook에서 확인: 실제 생성, Claude Code 연결, 컨테이너에서 내려받기. 맥미니 등록은 미확인 |
| 3+ | `proj test` (테스트 스택), 작업 대기열 | 예정 |
| 3+ | 프로젝트별 Docker 프록시 (#3) | 구현. MacBook OrbStack에서 확인, 맥미니는 미확인 |
| 3+ | 프로젝트별 플러그인 `proj plugin` (#6) | 구현. MacBook OrbStack에서 확인(가짜 토큰: ponytail SessionStart hook `level: full`, 다른 프로젝트엔 없음, 읽기 전용). 실제 토큰 작업·맥미니는 미확인 |
| 4 | code-server, 네트워크 송신 제한 | 예정 |

## 미결정 (TBD)

- 맥미니 자동 로그인과 FileVault 중 선택 — 사용자 ([setup-macmini.md](setup-macmini.md)).
- 프로젝트 에이전트 세션도 폰에서 직접 볼지 (그 프로젝트만 정식 로그인 예외) — 사용해 보고 결정.
