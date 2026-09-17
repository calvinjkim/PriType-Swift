# PROGRESS

프로젝트 상태 파일. 새 세션은 이 파일과 `CONTRACT.md`만 보고 이어서 작업할 수 있어야 한다.

## 현재 티켓: 우측 Command 한/영 전환키 미동작 + 전체 코드베이스 QA

- 브랜치: `claude/tender-bohr-sdwx9r`
- 계약: `CONTRACT.md`
- 진행 상태:
  - [x] 탐색(SOT 체크): 전환키 경로 `CGEventTap → InputModeCoordinator → PriTypeInputController → HangulComposer` 추적, 원인 A/B 확정
  - [x] 계약 작성 (`CONTRACT.md` §3)
  - [x] 테스트 작성 (`ToggleKeyEventClassifierTests.swift`, `ConfigurationManagerTests` 추가분)
  - [x] 최소 구현
  - [ ] **Red/Green 실행** — 이 세션 환경(Linux)에 Swift 툴체인이 없어 미실행. macOS에서 `swift test` 필요
  - [ ] 실기기 검증 (`CONTRACT.md` §3-3 D1~D7)
  - [x] 정리: 죽은 상태(`controlIsDown`), 죽은 문자열 3개, 중복 배선 제거

## 이번 세션에서 확인된 후속 과제 (이 PR 범위 밖)

QA 결과의 전체 목록은 PR 본문 참고. 구조 리스크 위주로 요약:

1. **문서 SOT 드리프트**: `Docs/UnifiedInputArchitecture.md`(canonical 표기)와 `ARCHITECTURE.md`가 "단일 입력 모드 등록·`selectInputMode:` 미사용·영어 모드 순수 pass-through"라고 서술하지만, 코드는 2-모드 등록(`Info.plist`), 전환 시 `selectInputMode:` 호출, 영어 모드 텍스트 편의(`TextConvenienceHandler.handleEnglishModeInput`) 소비를 한다. 이번 PR에서 전환키 정책 부분만 정정하고 나머지는 "superseded" 메모로 표시함. 정식 재작성 필요.
2. **레거시 설정 API**: `ToggleKey` enum, `toggleKey`, `rightCommandAsToggle`, `controlSpaceAsToggle`는 프로덕션 호출처가 없다(테스트·PriTypeVerify만 사용). 마이그레이션 경로(`toggleKey.asKeyBinding`)만 남기고 정리 대상.
3. **`ConfigurationManager` 싱글턴**: `private init` + 캐시 때문에 저장값 디코딩 sanitization(Caps Lock/Fn 바인딩 → 기본값 복원)이 단위 테스트 불가.
4. **`KeyRecorderRow`의 `conflictBinding`/`hasConflict` 파라미터**는 뷰 내부에서 사용되지 않음(충돌 처리는 `SettingsView.onChange`에 있음).
5. **우측 Command 판정이 좌/우 구분 없는 `maskCommand`를 사용**: 좌측 Command를 누른 채 우측 Command를 떼면 "눌림" 상태가 남아 이후 키에서 Command가 계속 제거될 수 있다. 장치별 비트(`NX_DEVICERCMDKEYMASK` 0x10 / `NX_DEVICELCMDKEYMASK` 0x08)로 정밀화 검토.
6. **`Package.swift`가 `libhangul-swift`를 `branch: "main"`으로 참조**: 재현 가능한 빌드가 `Package.resolved`에만 의존. 태그/리비전 고정 검토.
