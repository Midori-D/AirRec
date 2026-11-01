# AirRecord · 에어레코드

iPhone 기본 전화 화면의 **더 보기 → 통화 녹음**을 순서대로 눌러 녹음 시작을 돕는 앱입니다. 실제 녹음과 저장은 iOS가 처리합니다. 현재 버전은 **1.1.9 · 빌드 14**이며 소스 구조와 개발 이름을 AirRecord로 정리했습니다.

## 시작하기

- [소스 공부와 첫 빌드](docs/START.ko.md)
- [변경 기록](docs/CHANGES.md)
- [위치 서비스를 이용한 장시간 대기](docs/LOCATION.md)
- [이전 소스 보관함](Archive/README.md)

## 현재 프로젝트

| 경로 | 역할 |
| --- | --- |
| `Sources/App/` | 앱 진입점, 화면, 통화 감시, 개발자 연결 준비 |
| `Sources/Core/` | 통화 정책, 위치 세션 정책, 공통 코드 |
| `Native/` | 접근성 서비스 통신과 Swift용 네이티브 인터페이스 |
| `Tests/Policy/` | 통화·위치 정책과 보존된 Helper 회귀 테스트 실행 |
| `Scripts/` | 앱 빌드, 네이티브 빌드, IPA 검사 스크립트 3개 |
| `project.yml` | AirRecord Xcode 프로젝트·타깃·스킴 정의 |
| `.github/workflows/build-airrecord.yml` | 현재 IPA를 만드는 GitHub Actions |
| `Archive/Legacy-CallTap-iCTRL/` | 정리 전 추적 소스를 원래 구조로 보존한 스냅샷 |

현재 앱의 Swift 소스는 `Sources/`에서 읽으세요. 이전 XCTest Runner와 Helper 확장은 현재 앱에 포함되지 않습니다. 일부 Helper 프로토콜 회귀 테스트는 보관 소스를 명시적으로 읽어 계속 실행합니다.

## 빌드와 설치

Windows에서는 변경을 커밋·푸시한 뒤 GitHub 저장소의 **Actions → Build AirRecord → Run workflow → main**을 실행합니다. 서버는 선택한 Git 커밋을 빌드하며, Windows 폴더를 직접 읽지 않습니다.

성공한 실행의 `AirRecord-iOS` Artifact에서 `AirRecord-unsigned.ipa`를 받아 SideStore에서 서명해 독립 앱으로 설치합니다. macOS에서 직접 빌드하려면 Xcode 27과 XcodeGen이 필요합니다.

```sh
bash Scripts/build-airrecord.sh
```

## 실행 조건과 호환성

iOS 27 대상이며 LocalDevVPN·페어링·개발자 디스크 준비가 필요합니다. 장시간 위치 대기는 사용자가 켜는 선택 기능입니다. 위치 좌표를 저장·전송하지 않지만 위치 사용 표시와 배터리 소모가 생길 수 있습니다. 강제 종료·재부팅 후에는 앱을 다시 열어 준비하세요. 무제한 백그라운드 실행을 보장하지 않습니다.

기존 설치와 설정을 이어 쓰도록 번들 ID와 저장 설정 키, 페어링 경로와 호환 인터페이스는 유지합니다. GitHub 저장소 이름도 `Midori-D/CallTap`을 그대로 사용합니다.

`build/`, `Frameworks/`, `release/`, 생성된 Xcode 프로젝트와 IPA는 소스와 구분합니다. `.gitignore`의 `*.md`는 새 Markdown 파일에 적용되며 이미 추적 중인 안내·출처 문서를 자동으로 제외하지 않습니다.

Based on [iCTRL](https://github.com/OpenMinis/iCTRL) (Apache-2.0). See [LICENSE](LICENSE), [NOTICE](NOTICE.md), and [Native protocol attribution](Native/IPB-LICENSE).
