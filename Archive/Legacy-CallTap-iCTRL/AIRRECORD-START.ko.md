# AirRecord 개발 시작하기

이 안내는 AirRecord 1.1.8 · 빌드 13의 소스 정리와 학습용입니다. 빌드 13은 정리·문서 변경이며, 자동 녹음과 백그라운드 대기 로직은 빌드 12와 같습니다.

현재 작업 위치는 `C:\Users\Midori\Desktop\Midori_Server\IPA\AirRecord`입니다. 아래 파일 경로는 이 폴더를 기준으로 합니다. GitHub 저장소 이름은 계속 `Midori-D/CallTap`입니다.

## 먼저 알아둘 동작

AirRecord는 통화 음성을 직접 녹음하지 않습니다. 통화가 연결되면 아이폰 기본 전화 화면의 **더 보기 → 통화 녹음**을 누르며, 실제 녹음과 저장은 iOS가 처리합니다.

위치 대기는 선택 기능입니다. 위치 응답의 시각만 확인하고 좌표를 사용·저장·전송하지 않습니다. 위치 사용 표시와 배터리 소모가 생길 수 있습니다. LocalDevVPN·페어링·개발자 디스크 준비는 별도로 필요합니다. iOS 종료 정책까지 막는 무제한 실행이나 강제 종료 후 자동 복구는 보장하지 않습니다.

## 권장 읽기 순서

1. **앱의 시작과 화면**
   - `iCTRLApp/iCTRLApp.swift`: 앱 진입점, 공통 환경, 파일 가져오기와 시스템 알림을 연결합니다.
   - `iCTRLApp/Views/CallTapMainView.swift`: 현재 빌드에서 새 화면으로 들어가는 진입점입니다.
   - `iCTRLApp/Views/AirRecordGlassView.swift`: 홈·설정·기록 탭과 공통 카드입니다. 화면만 바꿔 보고 싶다면 여기부터 수정하세요. 실제 Liquid Glass 탭 바는 iOS의 `TabView`가 그립니다.
2. **통화 감시와 상태 변화**
   - `iCTRLApp/Automation/CallTapRawAXMonitor.swift`: `CXCallObserver`로 통화 상태를 읽고 준비·실행·중지를 관리합니다. 화면의 설정과 실제 실행 상태는 서로 다를 수 있습니다.
   - 같은 파일의 `CallTapRawAXGate`: 작업 세대와 현재 통화 조건을 잠금으로 보호하고, 오래된 비동기 작업의 입력을 거부합니다.
   - `iCTRLUITests/CallTapPolicy.swift`: 단일 연결 통화, 메뉴 처리 기한, 통화별 시작 요청 예약을 관리하는 공통 정책입니다. 결과가 불확실한 녹음 버튼을 반복해서 누르지 않게 하는 부분입니다.
3. **백그라운드 대기**
   - `iCTRLApp/Automation/AirRecordLocationKeepAlive.swift`: 사용자가 켠 위치 세션의 권한·시작·중지를 관리합니다. 새 세션은 앱 화면에서 준비합니다.
   - `iCTRLKit/KeepAlive/AirRecordLocationSessionPolicy.swift`: 현재 세션과 새 응답의 시각을 검증합니다. 이전 세션의 늦은 응답으로 중지된 감시를 되살리지 않습니다.
   - `iCTRLApp/Automation/AirRecordShortcuts.swift`: 단축어의 ‘통화 감시 재개’ 동작입니다. 전화 수신 자체를 깨우는 기능은 아닙니다.
4. **아이폰 개발자 서비스 연결**
   - `iCTRLApp/DDI/LocalDevVPN.swift`: 로컬 개발자 연결 경로를 확인합니다.
   - `PairingFileStore.swift`, `DeveloperDiskImageStore.swift`, `DDIMounter.swift`, `DDIMountView.swift`: 같은 DDI 폴더에서 페어링 자료 가져오기와 개발자 디스크 준비를 담당합니다.
   - 페어링 파일은 개인 기기의 접근 자료입니다. 소스에 넣거나 GitHub에 올리지 마세요.
5. **실제 화면 검사와 버튼 요청**
   - `iCTRLApp/Automation/CallTapRawAXClient.swift`: Swift 감시 코드와 네이티브 라이브러리를 연결합니다.
   - `RawAX/calltap_ax.rs`: 접근성 프로토콜, 녹음 항목 판별, 메뉴 전환 대기와 요청 후 상태 확인입니다.
   - `RawAX/ffi_calltap_ax.rs`: Rust 기능을 Swift에서 호출하기 위한 C 인터페이스입니다.
   - 요청이 수락됐다는 응답과 실제 녹음 시작은 다릅니다. 잠금 해제·통화 조건·한 번 요청 규칙을 유지하세요.

## 폴더 이름이 iCTRL인 이유

표시 이름은 AirRecord지만 원본 프로젝트의 내부 이름은 남아 있습니다. `project.yml`과 Xcode 대상·스킴·경로가 `iCTRLApp`, `iCTRLKit` 등을 참조하므로 폴더만 바꾸면 빌드가 깨질 수 있습니다. 공부를 시작할 때는 내부 이름을 그대로 두는 편이 좋습니다.

`iCTRLUITests`에는 옛 XCTest Runner 소스도 있습니다. 현재 IPA는 Runner를 사용하지 않지만 **`CallTapPolicy.swift`와 `Localized.swift`는 앱이 공유하므로 폴더 전체를 지우면 안 됩니다.** 이전 Helper 소스와 실험 문서도 보존되어 있으며, 현재 앱 대상에는 Helper 확장이 포함되지 않습니다. `project.yml`의 `sources`와 `excludes`에서 구분을 확인할 수 있습니다.

## 빌드가 이어지는 순서

`GitHub Actions workflow → 앱 빌드 스크립트 → 네이티브 라이브러리·정책 테스트 → Xcode → IPA 검사`

- `.github/workflows/build-calltap-rawax.yml`: macOS/Xcode 실행 환경, 캐시, 결과 업로드를 정합니다.
- `Scripts/build-calltap-rawax.sh`: `CallTapRawAX` 스킴으로 앱을 만들고 IPA를 패키징합니다.
- `Scripts/build-idevice-rawax.sh`: 지정된 `idevice` v0.1.68 커밋을 확인하고 RawAX 코드를 결합해 Rust 테스트와 iPhone용 라이브러리 빌드를 수행합니다. 고정 버전을 임의로 최신화하지 마세요.
- `Tests/CallTapPolicy/run.sh`, `Tests/CallTapPolicy/main.swift`: 통화 정책과 위치 세션 수명 등을 검사합니다. 실제 기기의 장시간 실행 성공을 대신하는 테스트는 아닙니다.
- `Scripts/verify-calltap-ax-ipa.py`: 버전, 권한 설명, 서명된 바이너리, 아이콘, 단축어 정보와 불필요한 Helper/XCTest 포함 여부를 확인합니다.

Windows 폴더 자체가 서버로 자동 전송되는 것은 아닙니다. **Actions는 GitHub에 push한 커밋을 빌드합니다.** Windows에서는 소스 편집과 Git 작업을 하고, Xcode 빌드는 Actions에서 수행합니다.

## 작은 수정부터 빌드해 보기

PowerShell에서 아래 순서로 진행합니다. 먼저 `git diff`로 의도한 수정만 있는지 확인하고, `git add`에는 바꾼 파일을 구체적으로 적으세요.

```powershell
Set-Location 'C:\Users\Midori\Desktop\Midori_Server\IPA\AirRecord'
git status --short
git diff
git add -- iCTRLApp/Views/AirRecordGlassView.swift
git commit -m "Adjust AirRecord screen wording"
git push origin main
```

그다음 GitHub 저장소의 **Actions → Build CallTap AX without XCTest → Run workflow → main**을 실행합니다. 성공한 실행의 Artifacts에서 IPA를 받아 SideStore로 설치합니다. 실패하면 첫 `error:`와 해당 단계 로그를 확인하세요. 끝의 `exit code 1`만으로 원인을 알 수는 없습니다.

버전을 바꿀 때는 빌드 스크립트의 `MARKETING_VERSION`·`CURRENT_PROJECT_VERSION`과 IPA 검사기의 기대 버전을 함께 변경해야 합니다. 그렇지 않으면 컴파일이 끝나도 패키지 검사에서 실패합니다.

## 소스와 결과물 보관

`release/`, `build/`, `Frameworks/`, 생성된 Xcode 프로젝트와 IPA는 로컬 결과물이며 Git에서 제외합니다. Actions 결과는 GitHub Artifacts에 보관됩니다. `outputs/`를 별도로 만들어 사용한다면 그 결과 파일도 소스와 구분하고 Git 제외 여부를 확인하세요.

이전 소스 사본·IPA·기기 진단 기록은 보관 자료입니다. 현재 개발 폴더 한 곳에서 수정하고, 필요한 변경만 커밋하면 어느 소스로 만든 IPA인지 추적하기 쉽습니다. 화면 수정 후에도 통화별 한 번 요청 규칙은 유지하고, 백그라운드 검증은 앱을 다시 열지 않은 상태에서 별도로 확인하세요.
