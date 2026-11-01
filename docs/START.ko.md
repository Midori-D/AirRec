# AirRecord 소스 공부와 첫 빌드

AirRecord 1.1.9 · 빌드 14의 개발 안내입니다. 현재 작업 폴더는 `C:\Users\Midori\Desktop\Midori_Server\IPA\AirRecord`이며, 아래 경로는 모두 프로젝트 루트를 기준으로 합니다.

## 전체 흐름

`화면에서 자동 시작 → 개발자 연결·위치 대기 준비 → 통화 상태 관찰 → 전화 화면 검사 → 녹음 시작 요청`

AirRecord가 음성을 직접 녹음하는 것은 아닙니다. iOS 기본 녹음 기능을 시작하도록 돕습니다. 요청이 수락됐다는 응답과 실제 녹음 타이머 시작은 구분해야 합니다.

## 1. 화면부터 읽기

- `Sources/App/AirRecordApp.swift`: 앱 진입점과 공통 환경, 파일 가져오기, 시스템 알림을 연결합니다.
- `Sources/App/Views/AirRecordGlassView.swift`: 홈·설정·기록 탭과 공통 카드입니다. 문구나 화면을 바꿔 보고 싶다면 여기부터 시작하세요. Liquid Glass 하단 메뉴는 iOS의 `TabView`가 그립니다.
- 화면 표시와 감시 로직을 구분하세요. 탭 전환은 통화 감시나 위치 세션을 중지하는 동작이 아닙니다.

## 2. 통화 감시와 안전한 요청

- `Sources/App/Automation/AirRecordMonitor.swift`: `CXCallObserver`의 통화 상태와 준비·실행·중지를 관리합니다. 설정이 켜져 있어도 실제 감시는 중지 상태일 수 있습니다.
- 같은 파일의 게이트는 작업 세대와 현재 통화 조건을 확인해 오래된 비동기 작업의 버튼 요청을 거부합니다.
- `Sources/Core/Automation/AirRecordPolicy.swift`: 단일 연결 통화, 메뉴 처리 기한, 통화별 시작 요청 예약을 관리합니다.
- 녹음 결과가 불확실하다고 시작 버튼을 반복해서 누르지 않습니다. 화면을 꾸밀 때도 통화별 한 번 요청 규칙을 유지하세요.

## 3. 백그라운드 대기와 단축어

- `Sources/App/Automation/AirRecordLocationKeepAlive.swift`: 사용자가 선택한 위치 세션의 권한·시작·중지를 관리합니다. 새 세션은 앱 화면에서 준비합니다.
- `Sources/Core/Background/AirRecordLocationSessionPolicy.swift`: 세션과 위치 응답 시각을 검증합니다. 이전 세션의 늦은 응답으로 중지된 감시를 되살리지 않습니다.
- `Sources/App/Automation/AirRecordShortcuts.swift`: 단축어의 ‘통화 감시 재개’ 동작입니다. 준비된 위치 세션을 재사용할 수 있지만 전화 수신 자체로 앱을 깨우는 기능은 아닙니다.

위치 대기는 좌표를 사용·저장·전송하지 않으며 통화 녹음 자체에도 위치가 필요하지 않습니다. 실행 유지를 위해 위치 업데이트를 사용하므로 위치 표시와 배터리 소모가 생길 수 있습니다. LocalDevVPN은 별도로 필요합니다. 강제 종료·재부팅 후에는 다시 준비해야 하며 무제한 실행을 보장하지 않습니다.

## 4. 개발자 연결과 화면 검사

- `Sources/App/DDI/`: `LocalDevVPN.swift`, `PairingFileStore.swift`, `DeveloperDiskImageStore.swift`, `DDIMounter.swift`, `DDIMountView.swift`가 연결 확인과 페어링·개발자 디스크 준비를 담당합니다.
- `Sources/App/Automation/AirRecordAXClient.swift`: Swift 감시 코드와 네이티브 라이브러리를 연결합니다.
- `Native/airrecord_ax.rs`: 접근성 프로토콜, 녹음 항목 판별, 메뉴 전환 대기와 요청 후 상태 확인입니다.
- `Native/ffi_airrecord_ax.rs`: Rust 기능을 Swift에서 호출하기 위한 C 인터페이스입니다.
- `Native/Fixtures/`: 프로토콜 요청의 형식을 비교하는 테스트 자료입니다.

개인 페어링 파일과 기기 로그는 소스에 넣거나 GitHub에 올리지 마세요.

## 5. 빌드와 테스트 읽기

1. `.github/workflows/build-airrecord.yml`이 macOS/Xcode 환경과 캐시, 결과 업로드를 정합니다.
2. `Scripts/build-airrecord.sh`가 네이티브 빌드와 정책 테스트를 실행하고 XcodeGen으로 `project.yml`을 생성합니다. 프로젝트·타깃·스킴 이름은 AirRecord입니다.
3. `Scripts/build-native.sh`는 지정된 `idevice` v0.1.68 커밋을 확인하고 접근성 코드를 결합해 Rust 테스트와 iPhone용 라이브러리를 빌드합니다. 고정 버전을 임의로 최신화하지 마세요.
4. `Tests/Policy/run.sh`와 `main.swift`가 통화·위치 정책을 검사합니다. 이전 Helper의 lease·wire 회귀 테스트도 보관 소스를 명시적으로 읽어 실행합니다.
5. `Scripts/verify-airrecord-ipa.py`가 버전·권한 설명·아이콘·단축어 정보·서명된 바이너리와 Helper/XCTest 포함 여부를 검사합니다.

일부 네이티브 Helper 회귀 코드도 Archive에서 읽습니다. 이는 이전 프로토콜 검증을 보존하기 위한 것으로, 현재 앱이 Helper 확장을 실행한다는 뜻은 아닙니다. 단위 테스트와 빌드 성공만으로 실제 장시간 대기 성공을 확정할 수는 없습니다.

## 6. Windows에서 작은 수정 빌드하기

Windows 폴더를 편집하는 것만으로 서버 빌드에 반영되지는 않습니다. **Actions는 GitHub에 push한 커밋을 빌드합니다.** 먼저 변경을 확인하고 수정한 파일만 구체적으로 추가하세요.

```powershell
Set-Location 'C:\Users\Midori\Desktop\Midori_Server\IPA\AirRecord'
git status --short
git diff
git add -- Sources/App/Views/AirRecordGlassView.swift
git commit -m "Adjust AirRecord screen wording"
git push origin main
```

GitHub의 **Actions → Build AirRecord → Run workflow → main**을 실행합니다. 성공한 실행의 `AirRecord-iOS` Artifact에서 `AirRecord-unsigned.ipa`를 받아 SideStore에 설치하세요. 실패하면 해당 단계의 첫 `error:`를 확인하세요. 마지막 `exit code 1`만으로 원인을 알 수는 없습니다.

버전을 바꿀 때는 빌드 스크립트의 `MARKETING_VERSION`·`CURRENT_PROJECT_VERSION`과 IPA 검사기의 기대 버전을 함께 바꾸세요. `Config/Signing.xcconfig`는 현재 프로젝트의 설정 파일입니다.

## 7. 이름이 남아 있는 부분과 보관함

기존 설치를 이어 쓰기 위해 번들 ID `com.calltap.prototype.ictrl`, 저장 설정 키, 페어링 경로와 이전 `ictrl-app` URL 스킴은 유지합니다. 기존 단축어를 위해 Intent 타입과 Swift 모듈 식별자 `iCTRL`도 유지하며, Xcode 프로젝트·타깃·제품 이름은 AirRecord입니다. `calltap_ax_inspect` C 함수와 `CallTap AX:` 오류 접두사도 Swift와 네이티브 코드 사이의 호환 계약입니다.

`Archive/Legacy-CallTap-iCTRL/`에는 정리 전 커밋의 추적 파일을 원래 구조 그대로 보존했습니다. 자체 `.git`은 없는 소스 스냅샷입니다. 현재 앱 수정은 `Sources/`에서 하세요. 이전 XCTest Runner·Helper 확장은 앱 대상에서 제외됩니다.

`.gitignore`의 `*.md`는 새 Markdown 파일을 제외하지만 이미 추적 중인 문서와 `NOTICE.md`를 자동으로 해제하지 않습니다. 새 문서를 의도적으로 올릴 때만 `git add -f -- docs/파일명.md`처럼 파일을 지정하세요. `build/`, `Frameworks/`, `release/`, 생성된 Xcode 프로젝트와 IPA도 소스와 구분합니다.
