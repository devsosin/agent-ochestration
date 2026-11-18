# 계정

계정은 별칭으로 나눈다(예: `sosin`, `fins`). 같은 계정의 모든 세션은 사용량 한도를 함께 쓴다.

## 어디에 어떤 인증을 쓰나

| 쓰는 곳 | 인증 | 보관 위치 | 할 수 있는 것 |
|---|---|---|---|
| 프로젝트 컨테이너 | `claude setup-token` 토큰 (1년) | `~/.agent-hub/accounts/<alias>/claude.token` | 모델 호출. Remote Control·claude.ai 커넥터·claude.ai 동기화 플러그인은 불가 |
| 호스트 CLI (통합 에이전트) | 정식 로그인 | `CLAUDE_CONFIG_DIR=~/.claude-<alias>` | 전부. Remote Control은 정식 로그인만 가능 |
| Claude 데스크톱 앱 | 앱 로그인 | `~/workspace/claude.sh -u <alias>` 프로필 | 데스크톱 세션 |
| git / gh (컨테이너) | fine-grained GitHub 토큰 | `accounts/<alias>/gh.token` | 토큰에 허용한 저장소만 |

## 계정 추가 · 토큰 교체

```bash
claude setup-token                 # 해당 계정으로 로그인된 브라우저에서 승인 → 토큰 출력
proj account add fins              # 토큰, GitHub 토큰(선택), git 이름·이메일 입력
proj account ls                    # 값은 보여주지 않음
```

- 같은 명령을 다시 실행하면 교체된다. 파일을 그 자리에서 덮어쓰므로 실행 중인 컨테이너도 다음 작업부터 새 토큰을 쓴다.
- 기본 계정: `~/.agent-hub/config`에 `DEFAULT_ACCOUNT=sosin`.
- 프로젝트의 계정 바꾸기: `~/.agent-hub/projects/<name>.env`의 `ACCOUNT`, `ACCOUNT_DIR`을 고치고 `proj up <name>`.

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
