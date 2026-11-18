# 계정

계정은 별칭으로 나눈다(예: `sosin`, `fins`). 같은 계정의 모든 세션은 사용량 한도를 함께 쓴다.

## 어디에 어떤 인증을 쓰나

| 쓰는 곳 | 인증 | 보관 위치 | 할 수 있는 것 |
|---|---|---|---|
| 프로젝트 컨테이너 | `claude setup-token` 토큰 (1년) | `~/.agent-hub/accounts/<alias>/claude.token` | 모델 호출. Remote Control·claude.ai 커넥터·claude.ai 동기화 플러그인은 불가 |
| 호스트 CLI (통합 에이전트) | 정식 로그인 | `CLAUDE_CONFIG_DIR=~/.claude-<alias>` | 전부. Remote Control은 정식 로그인만 가능 |
| Claude 데스크톱 앱 | 앱 로그인 | `~/workspace/claude.sh -u <alias>` 프로필 | 데스크톱 세션 |
| git / gh (컨테이너) | fine-grained GitHub 토큰, 계정당 하나 | `accounts/<alias>/gh.token` | 토큰에 허용한 저장소만 |
| gh (호스트, 메인 에이전트) | `gh auth login` | 호스트 키체인 | 저장소 생성(`proj new --create`) 등 관리 작업 |

## GitHub 토큰 (컨테이너용)

프로젝트마다 발급하지 않는다. 계정당 fine-grained 토큰 하나:

| 항목 | 값 |
|---|---|
| Repository access | All repositories (새로 만든 저장소도 자동 포함) |
| Permissions | Contents, Pull requests, Issues: Read and write. Metadata: Read |
| 주지 않음 | Administration, Workflows, Secrets — 저장소 생성·브랜치 보호 해제는 호스트 `gh`만 |

모든 저장소에 push할 수 있으므로, 중요한 저장소의 `main`에는 브랜치 보호를 건다.

## 계정 추가 · 토큰 교체

```bash
claude setup-token                 # 해당 계정으로 로그인된 브라우저에서 승인 → 토큰 출력
proj account add fins              # 토큰, GitHub 토큰(선택), git 이름·이메일 입력
proj account ls                    # 값은 보여주지 않음
```

- 토큰은 두 줄로 나뉘어 출력된다. 두 줄을 함께 복사한 뒤 토큰 입력란에서 **Enter만** 누르면 클립보드에서 줄바꿈 없이 읽는다(맥 화면에서만. SSH 접속 중이면 한 줄로 붙여 넣기).
- 저장 전에 토큰으로 짧은 요청을 보내 확인한다. 실패하면 아무것도 저장하지 않는다.
- git 이름·이메일을 비우면 호스트의 `git config --global` 값을 쓴다.
- 같은 명령을 다시 실행하면 교체된다. 파일을 그 자리에서 덮어쓰므로 실행 중인 컨테이너도 다음 작업부터 새 토큰을 쓴다.
- 기본 계정: `~/.agent-hub/config`에 `DEFAULT_ACCOUNT=sosin`.
- 프로젝트의 계정 바꾸기: `proj account use <name> <alias>` (아래 "사용량 한도").

## 사용량 한도

- 작업 로그(`rate_limit_event`)에 계정의 5시간·7일 한도 사용률이 남는다. `proj usage`, `proj account ls`가 계정별 최근 값을 보여 주고, 초기화 시각이 지난 구간은 0%로 본다.
- 작업 밖(메인 에이전트, 데스크톱 앱, claude.ai)에서 쓴 양은 로그에 없으므로, 작업을 시작할 때 값이 30분(`USAGE_STALE`)보다 오래됐으면 아주 짧은 요청(도구 없음, Haiku, 약 900토큰·0.0002달러)으로 먼저 갱신한다. `proj usage --refresh`는 바로 갱신. 결과는 `~/.agent-hub/usage/<alias>.jsonl`.
- 새 작업은 한도 중 하나라도 `USAGE_MAX`(기본 95%) 이상이면 거부된다. 거부되면 아무 흔적(worktree, 기록)도 남기지 않는다.
- 바꾸기: 프로젝트 계정 `proj account use <project> <alias>` (컨테이너 재생성, 실행 중 작업이 있으면 거부), 모델 `proj model <project> <model>`.
- 메인 에이전트(`~/.claude-<alias>`)도 같은 계정이면 같은 한도를 쓴다.

## 호스트 CLI에서 계정 나누기

```bash
# ~/.zshrc
alias claude-sosin='CLAUDE_CONFIG_DIR=~/.claude-sosin claude'
alias claude-fins='CLAUDE_CONFIG_DIR=~/.claude-fins claude'
```

처음 실행할 때 각각 로그인한다. 디렉터리마다 설정·기록·로그인이 따로다.

## 주의

- 토큰 값은 채팅·로그·커밋에 쓰지 않는다. `accounts/` 디렉터리는 700, 파일은 600.
- `setup-token` 토큰은 만료 1년. 만료되면 작업 결과가 `Not logged in`으로 실패한다 → 재발급 후 `proj account add`.
- GitHub 토큰은 저장소 범위로 발급한다. 컨테이너는 권한 확인 없이 실행되므로 토큰이 닿는 범위가 곧 피해 범위다.
