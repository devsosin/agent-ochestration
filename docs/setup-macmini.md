# 맥미니 초기 설정

한 번만 한다. 표시가 없는 명령은 맥미니에서 아직 실행해 보지 않았다 — 실행하면서 고친다.

## 1. 상시 가동

| 항목 | 방법 |
|---|---|
| 잠자기 끄기, 정전 후 자동 시작 | `sudo pmset -a sleep 0 disksleep 0 autorestart 1` |
| 로그인 후 앱 자동 시작 | OrbStack·Tailscale을 로그인 항목에 추가 |
| 재부팅 후 무인 복구 | 자동 로그인 필요. FileVault가 켜져 있으면 자동 로그인 불가 → 둘 중 선택 (TBD) |

## 2. OrbStack

- 설정에서 "Start at login" 켜기.
- 메모리 상한 약 10GB: `orb config set memory_mib 10240` (나머지는 macOS·통합 에이전트·VS Code 서버 몫).

## 3. 원격 접속

| 대상 | 설정 |
|---|---|
| Tailscale | 맥미니와 내 기기들에 설치·로그인. 맥미니 이름 예: `macmini` |
| SSH | 시스템 설정 → 일반 → 공유 → 원격 로그인 켜기. 내 기기의 공개키를 `~/.ssh/authorized_keys`에 |
| 남의 PC | `code tunnel service install` → 어디서든 `vscode.dev/tunnel/<이름>` (GitHub 로그인, 2단계 인증 필수) |

내 기기의 `~/.ssh/config`:

```
Host macmini
  HostName macmini          # Tailscale MagicDNS 이름
  User sosin
```

## 4. 도구와 저장소

```bash
curl -fsSL https://claude.ai/install.sh | bash          # 호스트 Claude Code (통합 에이전트용)
brew install gh jq && gh auth login
git clone https://github.com/devsosin/harness ~/workspace/harness
git clone https://github.com/devsosin/agent-ochestration ~/workspace/mac-agent
echo 'export PATH="$HOME/workspace/mac-agent/bin:$PATH"' >> ~/.zshrc
```

## 5. agent-hub

```bash
proj build                                  # 첫 빌드 수 분, 이미지 약 1.1GB(base) / 2.2GB(rust)
proj account add sosin                      # docs/accounts.md
proj account add fins
mkdir -p ~/.agent-hub && echo 'DEFAULT_ACCOUNT=sosin' >> ~/.agent-hub/config
proj new SosinCommerce-BE --image agent-hub:rust   # 기존 폴더를 등록하는 예
bash ~/workspace/mac-agent/tests/proj.test.sh
```

## 6. 확인

- 밖에서 폰 핫스팟 + Tailscale로 `ssh macmini` → `proj ls`.
- 집 윈도우 PC: VS Code Remote-SSH로 `macmini` 접속 → `~/workspace` 열기.
- 남의 PC: 브라우저로 vscode.dev 터널 접속.
- 맥미니를 재부팅한 뒤 위 접속이 사람 손 없이 다시 되는지.
