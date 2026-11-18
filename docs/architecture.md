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
| `compose/project.yml` | 프로젝트당 compose 프로젝트 `proj-<name>` | 마운트·시크릿·메모리 상한 |
| harness | `~/workspace/harness` → `/opt/harness:ro` | managed settings로 마켓플레이스 등록·활성화. 호스트에서 고치면 다음 세션부터 반영 |
| 계정 | `~/.agent-hub/accounts/<alias>/` | [accounts.md](accounts.md) |

## 보안 경계

| 대상 | 프로젝트 컨테이너 | 이유 |
|---|---|---|
| Docker 소켓 | 넣지 않음 | 소켓을 가진 쪽은 `/Users` 아래 무엇이든 마운트할 수 있음 |
| 호스트 `~/.ssh`, 키체인 | 넣지 않음 | git은 `GH_TOKEN`(https)으로만 |
| Claude 인증 | `setup-token` 토큰만 | 모델 호출만 가능. 정식 로그인은 호스트에만 |
| 권한 모드 | `bypassPermissions` (non-root) | 컨테이너가 경계. 네트워크 송신 제한은 아직 없음 (TBD) |

## 결정 기록

| 날짜 | 결정 | 이유 |
|---|---|---|
| 2026-11-18 | 컨테이너 런타임은 OrbStack | 사용자가 Docker Desktop에서 전환 |
| 2026-11-18 | 프로젝트 폴더는 호스트 `~/workspace/<name>`을 같은 경로로 바인드 마운트 | 호스트에서 VS Code·통합 에이전트가 바로 보고, worktree 절대경로가 양쪽에서 유효 |
| 2026-11-18 | 작업마다 worktree `.worktrees/<id>`, 브랜치 `agent/<id>`. 커밋까지, push·PR은 지시할 때만 | 병렬 작업 분리, 리뷰는 VS Code에서 |
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

## 단계

| 단계 | 내용 | 상태 |
|---|---|---|
| 1 | 이미지, compose, `proj` (new·task·reply·status·logs·diff·close), 계정 | 완료 (MacBook OrbStack에서 실제 토큰으로 확인) |
| 2 | 통합 에이전트: `hub/CLAUDE.md`·`hub/settings.json`, `proj hub` (Remote Control 서버 모드, launchd), `proj new --create` | 구현. MacBook에서 확인: 웹·폰 Remote Control, 말로 지시 → `--create` 비공개 저장소 → 작업 커밋 → push·PR. launchd 등록은 맥미니에서 |
| 3 | `proj test` (테스트 스택), imagegen MCP, 작업 대기열 | 예정 |
| 4 | 필요 시 dind 사이드카, code-server, 네트워크 송신 제한 | 예정 |

## 미결정 (TBD)

- 맥미니 자동 로그인과 FileVault 중 선택 — 사용자 ([setup-macmini.md](setup-macmini.md)).
- 프로젝트 에이전트 세션도 폰에서 직접 볼지 (그 프로젝트만 정식 로그인 예외) — 사용해 보고 결정.
