# 맥미니 초기 설정

위에서부터 순서대로 한 번만 한다. **맥미니 화면 앞에서** 진행한다 — 브라우저 로그인·클립보드·키체인이 필요한 단계가 있어 SSH로는 막힌다.
✅ = MacBook에서 같은 절차로 확인함. 표시 없음 = 맥미니에서 처음 실행.

## 1. 상시 가동

```bash
sudo pmset -a sleep 0 disksleep 0 autorestart 1      # 잠자기 끄기, 정전 후 자동 켜짐
```

- 재부팅 후 무인 복구에는 자동 로그인이 필요하다(OrbStack·메인 에이전트가 로그인 세션에서 돈다). FileVault가 켜져 있으면 자동 로그인을 쓸 수 없으니 둘 중 고른다.
- 시스템 설정 → 일반 → 로그인 항목에 OrbStack, Tailscale 추가.

## 2. 앱과 도구

```bash
brew install --cask orbstack tailscale visual-studio-code
brew install gh
ls -ld ~/.local/state 2>/dev/null     # 출력 없으면 정상. 소유자가 root면: sudo chown -R "$USER":staff ~/.local/state ✅
curl -fsSL https://claude.ai/install.sh | bash        # 호스트 Claude Code → ~/.local/bin/claude ✅
```

- OrbStack 설정: Start at login 켜기, 메모리 상한 약 10GB (`orb config set memory_mib 10240`).
- `jq`는 macOS 기본 포함(`/usr/bin/jq`).

## 3. 원격 접속

채팅 지시(Remote Control)에는 필요 없다. 다른 기기에서 VS Code로 파일·diff를 보거나 터미널로 `proj`를 칠 때 필요하다.

| 대상 | 설정 |
|---|---|
| Tailscale | 맥미니와 내 기기들에서 로그인. 맥미니 이름을 `macmini`로 |
| SSH | 시스템 설정 → 일반 → 공유 → 원격 로그인 켜기. 내 기기들의 공개키를 `~/.ssh/authorized_keys`에 |
| 남의 PC | `code tunnel service install` → `vscode.dev/tunnel/<이름>` (GitHub 로그인, 2단계 인증 필수) |

내 기기의 `~/.ssh/config`:

```
Host macmini
  HostName macmini          # Tailscale MagicDNS 이름
  User <맥미니 사용자>
```

## 4. 저장소와 GitHub

경로는 자유. 아래는 기본값(`~/workspace`)이고, 다르게 두면 config에 적는다.

```bash
gh auth login                                          # 호스트용: 저장소 생성·비공개 clone (repo 권한) ✅
git clone https://github.com/devsosin/agent-ochestration ~/workspace/mac-agent
git clone https://github.com/devsosin/harness ~/workspace/harness
echo 'export PATH="$HOME/workspace/mac-agent/bin:$PATH"' >> ~/.zshrc && exec zsh
git config --global user.name  "<이름>"                # 계정 등록 때 기본값으로 쓰임
git config --global user.email "<이메일>"
```

| 설정 (`~/.agent-hub/config`) | 기본값 | 뜻 |
|---|---|---|
| `WORKSPACE_ROOT` | `~/workspace` | 프로젝트 폴더가 생기는 곳 |
| `HARNESS_DIR` | `$WORKSPACE_ROOT/harness` | harness clone 위치 |

`~/.agent-hub`(계정 토큰·작업 기록)는 옮기지 않는다. 동기화 폴더(SeaDrive 등) 안에 프로젝트나 `~/.agent-hub`를 두지 않는다.

## 5. 이미지와 계정

```bash
proj build                                             # 수 분. base 약 1.1GB, rust 약 2.2GB ✅
mkdir -p ~/.agent-hub && printf 'DEFAULT_ACCOUNT=sosin\nHUB_ACCOUNT=sosin\n' >> ~/.agent-hub/config   # 경로를 바꿨으면 WORKSPACE_ROOT=… 도
```

계정마다 반복 (sosin, fins). 브라우저에서 **그 계정으로 로그인된 상태**여야 한다:

1. `claude setup-token` → 브라우저 승인 → 토큰이 **두 줄로** 출력된다. 두 줄을 함께 드래그해서 Cmd+C. ✅
2. `proj account add sosin` → 토큰 입력란에서 **붙여 넣지 말고 Enter** (클립보드에서 한 줄로 읽음) → 짧은 요청으로 인증 확인 후 저장. ✅
3. GitHub 토큰 입력란: fine-grained 토큰(All repositories, Contents·Pull requests·Issues 읽기·쓰기, Administration 없음 — [accounts.md](accounts.md)). ✅
4. git 이름·이메일은 Enter면 4단계의 전역 설정을 쓴다. ✅

확인: `proj account ls`, `proj usage --refresh`, `bash <저장소>/tests/proj.test.sh`.

## 6. 메인 에이전트

```bash
proj hub init                 # ~/.agent-hub/hub 에 운영 지침 연결 ✅
proj hub login                # 1번(구독 계정) → 브라우저 로그인 → 폴더 신뢰 y → /exit ✅
proj hub run                  # "Enable Remote Control?" y → 폰에서 hub 세션 보이는지 확인 → Ctrl+C ✅
proj hub install              # launchd 등록: 로그인 시 시작, 꺼지면 30초 뒤 재시작
proj hub status               # state = running
proj idle install 3           # 30분마다 3시간 쉰 컨테이너 중지 (로그 ~/.agent-hub/idle.log)
```

`hub run`을 터미널에서 한 번 먼저 하는 이유: 폴더 신뢰와 Remote Control 활성화는 터미널에서만 답할 수 있고, launchd로 띄우면 묻지 못하고 종료한다.

## 7. 프로젝트 옮기기

폰에서 메인 에이전트에게 말로 해도 되고, 직접 해도 된다:

```bash
proj new shop-be --repo devsosin/SosinCommerce-BE --alias 커머스백엔드      # Rust면 rust 이미지 자동
proj new shop --workspace --alias 쇼핑몰 && proj add shop api --repo devsosin/SosinCommerce-BE
```

## 8. 확인

- [ ] 밖(폰 핫스팟)에서 Claude 앱 → Code → `hub`: "프로젝트 목록 보여줘"
- [ ] 밖에서 Tailscale + `ssh macmini` → `proj ls`
- [ ] 집 윈도우 PC: VS Code Remote-SSH로 `macmini` → `~/workspace` 열기, worktree diff 보기
- [ ] 남의 PC: vscode.dev 터널
- [ ] 맥미니 재부팅 → 사람 손 없이 위 항목이 다시 되는지 (`proj hub status`)
