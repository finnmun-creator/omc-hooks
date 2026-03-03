# OMC Hooks — 한국어 가이드

> [English README](./README.md)

## Claude Code, 이렇게 쓰면 불편하지 않으셨나요?

Claude Code는 강력하지만, 터미널에서 쓰다 보면 이런 불편함이 있습니다:

**매번 y/n을 눌러야 합니다.**
파일 하나 수정하려 해도, 명령어 하나 실행하려 해도, 터미널에 `Allow? (y/n)` 이 뜹니다. 파일 10개를 고치는 작업이면 y를 10번 눌러야 합니다.

**뭘 하려는 건지 파악이 어렵습니다.**
터미널에 텍스트가 쭉 나오는데, 지금 Claude가 하려는 게 안전한 건지, 위험한 건지 한눈에 보이지 않습니다. `rm -rf`같은 위험한 명령도 `ls`같은 안전한 명령도 똑같은 모습으로 물어봅니다.

**한마디로:**
> Claude Code에 "눈"이 없습니다. 뭐가 위험하고 뭐가 안전한지 알려주는 시각적 표시가 없어요.

---

## omc-hooks는 뭘 해주나요?

omc-hooks는 Claude Code에 **GUI 팝업 창**을 붙여줍니다.

비유하자면 이렇습니다:

| 기존 Claude Code | omc-hooks 설치 후 |
|------------------|-------------------|
| 현관문에 초인종만 있는 집 | CCTV + 컬러 경고등이 달린 집 |
| 누가 오든 "열어줄까요?" 한마디 | 택배기사면 초록불, 낯선 사람이면 빨간불 |
| 매번 직접 확인해야 함 | 안전한 건 자동으로 통과 |

구체적으로:

1. **위험도를 색상으로 알려줍니다** — `ls`(파일 목록 보기)는 자동 통과, `rm`(파일 삭제)은 빨간 팝업으로 경고
2. **한 번 승인하면 기억합니다** — "이번만", "이 세션 동안", "항상" 중 선택 가능
3. **연속 작업을 한 번에 승인합니다** — 파일 10개를 수정할 때 첫 번째만 승인하면 5초간 나머지도 자동 통과 (버스트 모드)
4. **파일 변경 내용을 보여줍니다** — 어떤 코드가 지워지고 어떤 코드가 추가되는지 색상으로 표시

---

## 주요 기능 한눈에 보기

### 권한 승인 팝업

Claude Code가 도구를 실행하기 전에 팝업 창이 뜹니다.

- **4단계 위험 분류**
  - Tier 0 (자동 통과): `ls`, `git status`, 파일 읽기 등 안전한 작업
  - Tier 1 (초록색): `git commit`, `npm install` 등 일반 작업
  - Tier 2 (노란색): 소스 코드 수정, `curl` 등 주의가 필요한 작업
  - Tier 3 (빨간색): `rm`, `sudo`, `.env` 파일 수정 등 위험한 작업

- **4단계 승인 범위** — 팝업에서 선택할 수 있습니다
  - **이번만**: 딱 이 한 번만 허용
  - **세션**: 이 작업 세션 동안 같은 패턴은 자동 허용 (24시간)
  - **항상**: 이 패턴은 앞으로 계속 자동 허용
  - **도구 전체**: 이 도구의 모든 호출을 항상 허용

- **버스트 모드** (Windows) — 체크박스 하나로 5초간 연속 호출을 자동 승인

- **키보드 단축키** — 마우스 없이도 빠르게 조작
  - `[1]`~`[4]`: 승인 범위 선택
  - `Enter`: 허용
  - `Esc`: 거부

### 상태 표시줄 (HUD)

Claude Code 하단에 토큰 사용량을 실시간으로 표시합니다.

### 기타 부가 기능

| 기능 | 설명 |
|------|------|
| 키워드 감지 | "ultrawork", "analyze" 같은 모드 키워드를 자동 인식 |
| 질문 알림 | Claude가 질문할 때 팝업으로 알려줌 |
| 위임 경고 | 소스 파일 직접 수정 시 경고 표시 |
| 메모리 저장 | `<remember>` 태그로 정보를 세션 간 유지 |
| 세션 복원 | 이전 세션의 모드 상태를 자동 복원 |

---

## 설치 방법

### 필요한 것

시작하기 전에 이 두 가지가 설치되어 있어야 합니다:

1. **Claude Code** — Anthropic의 CLI 도구 ([공식 문서](https://docs.anthropic.com/en/docs/claude-code))
2. **Node.js 18 이상** — [nodejs.org](https://nodejs.org)에서 다운로드

### 방법 1: npx로 설치 (가장 간단)

터미널에 이 한 줄만 입력하면 됩니다:

```
npx omc-hooks
```

끝입니다. Windows, macOS, Linux 모두 지원합니다.

**업데이트:**
```
npx omc-hooks@latest
```

**제거:**
```
npx omc-hooks uninstall
```

### 방법 2: GitHub에서 직접 받기

좀 더 직접 관리하고 싶다면:

**Windows:**
```powershell
git clone https://github.com/finnmun-creator/omc-hooks.git
cd omc-hooks
.\install.ps1
```

**macOS / Linux:**
```bash
git clone https://github.com/finnmun-creator/omc-hooks.git
cd omc-hooks
bash install.sh
```

### 설치하면 어디에 뭐가 생기나요?

| 설치되는 파일 | 위치 | 역할 |
|--------------|------|------|
| 훅 스크립트들 | `~/.claude/hooks/` | 핵심 동작 엔진 |
| Windows UI | `~/.claude/hooks/ui/win/` | 팝업 창 (Windows) |
| macOS UI | `~/.claude/hooks/ui/mac/` | 팝업 창 (macOS) |
| 상태 표시줄 | `~/.claude/hud/` | 토큰 HUD |
| 승인 규칙 | `~/.claude/gui-approvals.json` | 기본 승인 설정 |

기존 `settings.json`은 안전하게 병합됩니다. 이미 있는 훅 설정은 그대로 유지되고, omc-hooks 항목만 추가됩니다.

---

## 설치 후 어떻게 달라지나요?

### 시나리오 1: 평소처럼 Claude Code 사용

설치 후 별도 설정 없이 Claude Code를 실행하면 됩니다. 훅이 자동으로 동작합니다.

```
claude
```

### 시나리오 2: 안전한 명령 — 자동 통과

Claude가 `ls`, `git status`, 파일 읽기 등을 실행하려 할 때:
→ 팝업 없이 **자동으로 승인**됩니다. 작업 흐름이 끊기지 않습니다.

### 시나리오 3: 일반 작업 — 초록색 팝업

Claude가 `git commit`이나 `.md` 파일 수정을 하려 할 때:
→ **초록색 팝업**이 뜹니다. 안전한 작업이라는 뜻이에요.
→ Enter를 누르면 승인, 범위를 선택해서 반복 승인도 가능합니다.

### 시나리오 4: 주의 필요 — 노란색 팝업

Claude가 소스 코드(`.ts`, `.py` 등)를 수정하려 할 때:
→ **노란색 팝업**이 뜹니다. 변경될 코드의 전후 비교(diff)가 색상으로 표시됩니다.
→ 내용을 확인하고 승인/거부를 결정할 수 있습니다.

### 시나리오 5: 위험한 명령 — 빨간색 팝업

Claude가 `rm`, `sudo`, `.env` 파일 수정 등을 시도할 때:
→ **빨간색 팝업**이 뜹니다. 기본값이 "거부"로 설정되어 있어 실수로 승인할 위험이 줄어듭니다.

### 시나리오 6: 연속 수정 — 버스트 모드 (Windows)

Claude가 파일 10개를 연속으로 수정해야 할 때:
→ 첫 번째 팝업에서 "Burst Mode" 체크박스를 켜고 승인하면,
→ 5초간 같은 유형의 후속 호출이 **자동으로 승인**됩니다.

---

## 설정 커스터마이즈

`~/.claude/gui-approvals.json`에서 동작을 조정할 수 있습니다:

```json
{
  "rules": [],
  "version": 2,
  "config": {
    "autoApproveTier0": true,
    "autoApproveTier1": false,
    "dangerousRequireDoubleConfirm": true,
    "burstWindowMs": 5000,
    "sessionApprovalTTLHours": 24
  }
}
```

| 옵션 | 기본값 | 설명 |
|------|--------|------|
| `autoApproveTier0` | `true` | Tier 0(안전) 명령 자동 승인 |
| `autoApproveTier1` | `false` | Tier 1(일반) 명령도 자동 승인할지 여부 |
| `burstWindowMs` | `5000` | 버스트 모드 지속 시간 (밀리초) |
| `sessionApprovalTTLHours` | `24` | 세션 승인의 유효 시간 |

---

## 제거 방법

**npx로 설치한 경우:**
```
npx omc-hooks uninstall
```

**Git clone으로 설치한 경우:**

Windows:
```powershell
.\uninstall.ps1
```

macOS:
```bash
bash uninstall.sh
```

제거해도 `gui-approvals.json`(내가 설정한 승인 규칙)은 기본적으로 보존됩니다.

---

## 플랫폼별 참고사항

### Windows
- Windows Forms 기반의 풍부한 UI (색상 diff, 키보드 단축키)
- 버스트 모드 지원
- 4개 범위 라디오 버튼이 한 화면에 표시

### macOS
- osascript(AppleScript) 기반 네이티브 다이얼로그
- 버스트 모드 미지원 (osascript 제약)
- 2단계 다이얼로그 (허용/거부 → 범위 선택)
- Tier 3(위험) 명령은 영구 승인 불가 (세션 단위까지만)
- diff 색상 표시 미지원

---

## 라이선스

MIT

---

> 문제가 있거나 개선 아이디어가 있다면 [GitHub Issues](https://github.com/finnmun-creator/omc-hooks/issues)에 남겨주세요.
