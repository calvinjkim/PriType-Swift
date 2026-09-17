# CONTRACT — 우측 Command 한/영 전환키 미동작 수정

작성일: 2026-09-15 · 브랜치: `claude/tender-bohr-sdwx9r` · 상태: **구현 완료, 실기기 검증 대기**

## 1. 증상

PriType 설정에서 한/영 전환키를 우측 Command로 지정해도, 실제로 우측 Command를 누르면 PriType 내부 한/영 모드가 바뀌지 않는다.

## 2. 원인 (탐색 결과)

같은 증상을 만드는 결함이 두 개 있고, 둘은 독립적이다.

| # | 원인 | 위치 | 성격 |
| --- | --- | --- | --- |
| A | macOS "Caps Lock으로 ABC 입력 소스 전환"(`TISRomanSwitchState`)이 켜져 있으면 PriType 전환키를 **세 곳**에서 조용히 무시한다. 한국어 macOS의 기본값이 켜짐이라 대부분의 사용자에게 전환키가 죽는다. 이 가드는 단일 모드 + 실제 ABC 소스 시절(2.7.x)의 충돌 방지책이었고, 현재의 2-모드 등록 구조에서는 두 경로가 모두 `HangulComposer.inputMode`로 수렴하므로 존재 이유가 없다. | `RightCommandSuppressor`, `IOKitManager`, `InputModeCoordinator` | 설계 잔재 + SOT 위반(같은 가드 3중 복제) |
| B | CGEventTap이 60초 내 3회 비활성화되면 IOKit 백업을 **켜기만 하고 CGEventTap을 끄지 않는다.** 이후 두 모니터가 동시에 살아 있어 우측 Command 1회 누름에 토글이 2번(탭은 key-down, IOKit은 key-up) 일어나 원래 모드로 돌아온다. 입력기 프로세스는 로그인 세션 내내 살아 있으므로 한 번 발생하면 영구적이다. | `RightCommandSuppressor.handleEvent` 탭 비활성화 분기, `main.swift` `onTapFailed` | 결함 |

부수 발견: 토글/한자 콜백 배선이 `main.swift`와 `SettingsWindowController.requestAccessibility`에 중복되어 있었고, 설정 쪽 경로에는 `onTapFailed`가 빠져 있었다(SOT 위반).

## 3. 계약 (완료 기준)

### 3-1. 단위 테스트로 검증 — `Tests/PriTypeCoreTests/ToggleKeyEventClassifierTests.swift`, `ConfigurationManagerTests.swift`

- [ ] C1. 우측 Command(keyCode 54) flagsChanged, Command 플래그 ON → `.toggle` (이벤트 소비)
- [ ] C2. 이어서 우측 Command 릴리즈(Command 플래그 OFF) → `.suppress`
- [ ] C3. 우측 Command를 누른 채 일반 키 keyDown → `.stripModifier(maskCommand)` (단축키가 아닌 일반 입력으로 전달)
- [ ] C4. 우측 Command를 뗀 뒤 일반 키 keyDown → `.passThrough`
- [ ] C5. Caps Lock LED가 켜진 상태(`maskAlphaShift` 포함)에서 우측 Command → 여전히 `.toggle` — 판정 로직은 macOS Caps Lock 상태를 입력으로 받지 않는다
- [ ] C6. Caps Lock(keyCode 57) flagsChanged → 항상 `.passThrough` (macOS 소유)
- [ ] C7. 좌측 Command(55)는 기본 바인딩(54)에서 `.passThrough`
- [ ] C8. 우측 Option(61) 누름 → `.hanja`, 릴리즈 → `.suppress`
- [ ] C9. 한자키가 전환키와 같은 키코드면 전환키가 우선하고 `.hanja`는 발생하지 않는다
- [ ] C10. Control+Space 조합 바인딩: Control ON keyDown 49 → `.toggle`, Control OFF → `.passThrough`
- [ ] C11. 일반 단일키 바인딩(F13=105) keyDown → `.toggle`
- [ ] C12. `KeyBinding.modifierFlagMask`: 54/55→Command, 61/58→Option, 62/59→Control, 56/60→Shift, 57→AlphaShift, 그 외→0

### 3-2. 코드 리뷰로 검증 (IMK·CGEventTap·TCC 의존, 단위 테스트 불가)

- [ ] R1. `capsLockInputSourceSwitchEnabled`를 읽어 전환을 막는 코드가 `Sources/`에 없다 (설정 화면 상태 카드 표시용 읽기만 남음)
- [ ] R2. CGEventTap 콜백(hot path)에서 `CFPreferencesCopyValue` IPC가 사라졌다
- [ ] R3. 탭 3회 비활성화 → `onTapFailed` 경로에서 **CGEventTap을 먼저 stop()한 뒤** IOKit을 start()한다 (`ToggleKeyMonitor.handOverToIOKit`)
- [ ] R4. 토글/한자/실패 콜백 배선은 `ToggleKeyMonitor.wireCallbacks()` 한 곳에만 존재한다
- [ ] R5. 설정 화면의 한/영 전환키 행이 Caps Lock 상태로 비활성화되지 않는다

### 3-3. 실기기(macOS) 검증 — 이 PR을 설치한 뒤 확인

- [ ] D1. 시스템 설정 "Caps Lock으로 ABC 전환" **켜짐** 상태에서 우측 Command 1회 → 메뉴바 `한`→`A`, 타이핑이 영문
- [ ] D2. 같은 상태에서 다시 1회 → `A`→`한`, 한글 조합
- [ ] D3. 같은 상태에서 Caps Lock 1회 → 모드 전환되고, 이어서 우측 Command 1회 → 반대로 전환 (두 경로 공존)
- [ ] D4. 한글 조합 중 우측 Command → 조합 중 글자 1회 commit 후 전환 (글자 유실/중복 없음)
- [ ] D5. 우측 Command를 누른 채 `c` 입력 → `Cmd+C`가 아니라 문자 `c` 입력
- [ ] D6. 시스템 설정 "Caps Lock으로 ABC 전환" **꺼짐** 상태에서 D1·D2 동일
- [ ] D7. 설정 창: Caps Lock 상태 카드는 남아 있고, 전환키 행은 항상 활성

## 4. Red → Green 기록

이 세션 환경(Linux, Swift 툴체인 없음)에서는 `swift test`를 실행할 수 없어 **Red/Green을 직접 확인하지 못했다.** 아래는 코드 기준 예상이며, macOS에서 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`로 확인해야 한다.

| 단계 | 대상 | 예상 결과 |
| --- | --- | --- |
| Red | 새 테스트 파일이 참조하는 `ToggleKeyEventClassifier`, `KeyBinding.modifierFlagMask`가 없음 | 컴파일 실패(= 실패) |
| Green | 분류기 + 프로퍼티 추가, 3중 가드 제거, 핸드오버 시 탭 중지 | 기존 172개 + 신규 테스트 통과 |

## 5. 변경 파일

- 신규: `Sources/PriTypeCore/ToggleKeyEventClassifier.swift`, `Sources/PriTypeCore/ToggleKeyMonitor.swift`, `Tests/PriTypeCoreTests/ToggleKeyEventClassifierTests.swift`
- 수정: `RightCommandSuppressor.swift`(판정 로직을 분류기로 위임, 핸드오버 시 재활성화 금지), `IOKitManager.swift`·`InputModeCoordinator.swift`(Caps Lock 가드 삭제), `ConfigurationManager.swift`(`KeyBinding.modifierFlagMask`), `main.swift`·`SettingsWindowController.swift`(배선을 `ToggleKeyMonitor`로 일원화, 전환키 행 비활성화 제거), `L10n.swift`·`ko/en Localizable.strings`(죽은 문자열 3개 제거, 설명 2개 수정), `HangulComposer.swift`(주석 1곳)
- 문서: `README.md`, `ARCHITECTURE.md`, `Docs/UnifiedInputArchitecture.md`, `CHANGELOG.md`
