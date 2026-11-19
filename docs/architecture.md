# 구조와 결정

맥미니(M4, 16GB, 2TB, OrbStack, 상시 가동) 한 대에서 프로젝트마다 에이전트 컨테이너를 두고, 통합 에이전트 하나가 작업을 나눠 지시한다. 사용자는 어느 기기에서든 채팅으로 지시하고 VS Code로 결과를 본다.

## 구성

```
[어디서든] 폰 · 노트북 · 집 윈도우 PC · 남의 PC(브라우저)
   ├─ 채팅: claude.ai/code, Claude 앱 ──────────────▶ 통합 에이전트 (Remote Control)
   └─ 파일·diff: VS Code Remote-SSH(Tailscale) / vscode.dev 터널 ─▶ 맥미니 ~/workspace
Mac mini
 ├─ 통합 에이전트: 호스트의 claude, bin/proj 만 호출          (2단계)
 ├─ proj-<name> 컨테이너: claude -p, harness 플러그인, 계정 토큰
 │    └─ ~/workspace/<name> (호스트와 같은 절대경로로 마운트)
 └─ ~/.agent-hub: 계정·프로젝트 설정·작업 기록
```

| 구성요소 | 위치 | 역할 |
|---|---|---|
| `bin/proj` | 호스트 | 프로젝트·계정·작업 관리 CLI ([proj.md](proj.md)) |
| `agent-hub:base` / `agent-hub:rust` | 이미지 | Claude Code, gh, git, Node (+ Rust) |
| `compose/project.yml` | 프로젝트당 compose 프로젝트 `proj-<name>` | 마운트·시크릿·메모리 상한. 서비스 `agent`(에이전트), `docker`(Docker 프록시) |
| `agent-hub:dockerproxy` | 이미지 (`dockerproxy/`) | 호스트 Docker 소켓을 갖고 그 프로젝트 것만 통과시키는 API 프록시 (아래 보안 경계) |
| harness | `~/workspace/harness` → `/opt/harness:ro` | managed settings로 마켓플레이스 등록·활성화. 호스트에서 고치면 다음 세션부터 반영 |
| 계정 | `~/.agent-hub/accounts/<alias>/` | [accounts.md](accounts.md) |

## 보안 경계

| 대상 | 프로젝트 컨테이너 | 이유 |
|---|---|---|
| Docker 소켓 | 넣지 않음. `DOCKER_HOST=tcp://docker:2375`(프로젝트별 프록시)만 | 소켓을 가진 쪽은 `/Users` 아래 무엇이든 마운트할 수 있음. 컨테이너 안 래퍼는 우회되므로 프록시가 소켓을 가짐 |
| 호스트 Docker (프록시 규칙) | 자기 프로젝트 것만 | 아래 표 |
| 호스트 `~/.ssh`, 키체인 | 넣지 않음 | git은 `GH_TOKEN`(https)으로만 |
| Claude 인증 | `setup-token` 토큰만 | 모델 호출만 가능. 정식 로그인은 호스트에만 |
| OpenAI(Codex) 로그인 | 넣지 않음 | 호스트 imagegen MCP만 사용. 컨테이너는 이미지 URL만 받음 |
| 권한 모드 | `bypassPermissions` (non-root) | 컨테이너가 경계. 네트워크 송신 제한은 아직 없음 (TBD) |

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

## 단계

| 단계 | 내용 | 상태 |
|---|---|---|
| 1 | 이미지, compose, `proj` (new·task·reply·status·logs·diff·close), 계정 | 완료 (MacBook OrbStack에서 실제 토큰으로 확인) |
| 2 | 통합 에이전트: `hub/CLAUDE.md`·`hub/settings.json`, `proj hub` (Remote Control 서버 모드, launchd), `proj new --create` | 구현. MacBook에서 확인: 웹·폰 Remote Control, 말로 지시 → `--create` 비공개 저장소 → 작업 커밋 → push·PR. launchd 등록은 맥미니에서 |
| 3 | imagegen MCP | 구현. MacBook에서 확인: 실제 생성, Claude Code 연결, 컨테이너에서 내려받기. 맥미니 등록은 미확인 |
| 3+ | `proj test` (테스트 스택), 작업 대기열 | 예정 |
| 3+ | 프로젝트별 Docker 프록시 (#3) | 구현. MacBook OrbStack에서 확인, 맥미니는 미확인 |
| 4 | code-server, 네트워크 송신 제한 | 예정 |

## 미결정 (TBD)

- 맥미니 자동 로그인과 FileVault 중 선택 — 사용자 ([setup-macmini.md](setup-macmini.md)).
- 프로젝트 에이전트 세션도 폰에서 직접 볼지 (그 프로젝트만 정식 로그인 예외) — 사용해 보고 결정.
