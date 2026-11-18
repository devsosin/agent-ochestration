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
| 2026-11-18 | SeaDrive는 설정·이미지 공유용. 코드 동기화에 쓰지 않음 | 코드는 맥미니에만 두고 SSH로 직접 봄 |
| 2026-11-18 | 이미지 생성은 별도 서비스(MCP)로 제공, OpenAI 인증은 그 서비스에만 | 로그인 토큰 동시 갱신 충돌·노출 방지 (3단계) |

## 단계

| 단계 | 내용 | 상태 |
|---|---|---|
| 1 | 이미지, compose, `proj` (new·task·reply·status·logs·diff·close), 계정 | 완료 (MacBook OrbStack에서 확인) |
| 2 | 통합 에이전트: 호스트 작업 폴더·CLAUDE.md, Remote Control 서버 모드, launchd | 예정 |
| 3 | `proj test` (테스트 스택), imagegen MCP, 작업 대기열 | 예정 |
| 4 | 필요 시 dind 사이드카, code-server, 네트워크 송신 제한 | 예정 |

## 미결정 (TBD)

- 맥미니 자동 로그인과 FileVault 중 선택 — 사용자 ([setup-macmini.md](setup-macmini.md)).
- 프로젝트 에이전트 세션도 폰에서 직접 볼지 (그 프로젝트만 정식 로그인 예외) — 사용해 보고 결정.
